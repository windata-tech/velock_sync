/// Shared harness for the plain (unencrypted) folder sync widget tests.
///
/// Every seam that would otherwise reach a platform channel or the network is
/// replaced:
///
/// * an in-memory [SyncStateDatabase] instead of the on-disk app database,
/// * [FakeFolderAccessAuthorizer] instead of the native folder picker,
/// * an in-memory WebDAV folder loader instead of `WebDavBackupFolderBrowser`,
/// * a protocol probe that never dials out (`Connections.build` schedules a
///   status sweep on the next event-loop turn),
/// * mocked shared preferences, because creating a location resolves the shared
///   device id through `LocalDataManager`.
///
/// The real [createAppRouter] tree is mounted, so route pushes/pops behave
/// exactly like production.
library;

import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/features/plain_sync/local_folder_open.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// A WebDAV connection as the wizard and the location cards expect it.
ConnectionModel webDavConnection({
  String id = 'conn-1',
  String name = '我的 NAS',
}) => ConnectionModel(
  id: id,
  name: name,
  source: '文件同步',
  target: _webDavAddress,
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: _webDavAddress,
    port: '443',
    path: '/dav',
  ),
  createdAt: DateTime.utc(2026, 9, 27),
  updatedAt: DateTime.utc(2026, 9, 27),
  status: ConnectionStatus.active,
);

const _webDavAddress = 'https://nas.example.test';

/// A WebDAV connection that is *not* WebDAV: folder sync must refuse to use it.
ConnectionModel oAuthConnection({String id = 'oauth-1', String name = '网盘'}) =>
    ConnectionModel(
      id: id,
      name: name,
      source: '文件同步',
      target: 'oauth://provider',
      protocol: const OAuthProtocolModel(
        providerType: RemoteProviderType.webDav,
        clientId: 'public-client',
        credentialRef: 'secure-ref',
        rootId: 'root',
      ),
      createdAt: DateTime.utc(2026, 9, 27),
      updatedAt: DateTime.utc(2026, 9, 27),
      status: ConnectionStatus.active,
    );

/// The local folder the fake authorizer hands back.
///
/// A path that never has to exist: [FolderAccessGrant.localPath] validates
/// nothing and the provisioner only takes the basename, so the test stays free
/// of filesystem I/O.
final testLocalFolder = Directory('/tmp/plain-sync-widget-test/照片');

const testLocalFolderName = '照片';

/// Records how often the app asked for a folder and returns a fixed grant.
class FakeFolderAccessAuthorizer implements FolderAccessAuthorizer {
  FakeFolderAccessAuthorizer(this.grant);

  /// Null models the user cancelling the system picker.
  FolderAccessGrant? grant;
  int calls = 0;

  @override
  Future<FolderAccessGrant?> authorizeDirectory() async {
    calls++;
    return grant;
  }
}

/// One mounted plain sync app plus the fake seams a test may assert on.
class PlainSyncWorld {
  PlainSyncWorld._({
    required this.runServiceBox,
    required this.tester,
    required this.database,
    required this.container,
    required this.router,
    required this.authorizer,
    required this.loadedFolders,
    required this.createdFolders,
    required this.remoteChecks,
  });

  final List<StubPlainRunService> runServiceBox;

  /// The injected run service, or null when the test did not inject one.
  StubPlainRunService? get runService =>
      runServiceBox.isEmpty ? null : runServiceBox.first;
  final WidgetTester tester;
  final SyncStateDatabase database;
  final ProviderContainer container;
  final GoRouter router;
  final FakeFolderAccessAuthorizer authorizer;

  /// Remote paths the app asked the folder picker to list.
  final List<List<String>> loadedFolders;

  /// Remote folders the app tried to create; must stay empty in these tests.
  final List<List<String>> createdFolders;

  /// Every pre-create remote writability check, with its exact arguments.
  final List<({String connectionId, List<String> remoteRootSegments})>
  remoteChecks;

  /// Set by a test that pushed the wizard: completes with the value the wizard
  /// route popped with (`true` once a location was created).
  Future<bool?>? wizardPop;

  /// The profile as the repository reads it back from the database.
  Future<PlainFolderSyncProfile?> readProfile(String profileId) =>
      PlainFolderSyncProfileRepository(database).read(profileId);

  Future<List<PlainFolderSyncProfile>> listProfiles() =>
      PlainFolderSyncProfileRepository(database).list();

  /// Re-reads the location list after the database changed mid-test — the same
  /// invalidation the page's own refresh action performs.
  Future<void> refreshListView() async {
    container.invalidate(plainLocationViewsProvider);
    await tester.pumpAndSettle();
  }

  Future<PlainFolderSyncProfile> seedPlainProfile({
    String profileId = 'plain-1',
    String displayName = '照片同步',
    String localDisplayName = testLocalFolderName,
    String? localRootReference,
    String connectionId = 'conn-1',
    List<String> remoteRootSegments = const ['photos', 'phone'],
    MirrorDirection direction = MirrorDirection.bidirectional,
    MirrorConflictPolicy conflictPolicy = MirrorConflictPolicy.keepBoth,
    PlainFolderProfileState state = PlainFolderProfileState.active,
    List<MirrorBaselineEntry> baseline = const [],
  }) async {
    final profile = PlainFolderSyncProfile(
      profileId: profileId,
      datasetId: 'dataset-$profileId',
      deviceId: 'device-1',
      displayName: displayName,
      localRootReference: localRootReference ?? testLocalFolder.path,
      localDisplayName: localDisplayName,
      connectionId: connectionId,
      remoteRootSegments: remoteRootSegments,
      direction: direction,
      conflictPolicy: conflictPolicy,
      state: state,
      createdAt: DateTime.utc(2026, 9, 27),
    );
    await PlainFolderSyncProfileRepository(database).save(profile);
    if (baseline.isNotEmpty) {
      await database.upsertMirrorEntries(profileId, baseline);
    }
    return profile;
  }

  /// One finished mirror run, used to drive the status line.
  Future<void> seedMirrorRun({
    String profileId = 'plain-1',
    int uploadedFileCount = 0,
    int downloadedFileCount = 0,
    int heldDeletionCount = 0,
    String? failureCode,
  }) => database.saveMirrorRunStats(
    MirrorRunStats(
      runId: 'run-$profileId',
      profileId: profileId,
      startedAt: DateTime.utc(2026, 9, 27, 8),
      finishedAt: DateTime.utc(2026, 9, 27, 8),
      uploadedFileCount: uploadedFileCount,
      downloadedFileCount: downloadedFileCount,
      heldDeletionCount: heldDeletionCount,
      failureCode: failureCode,
    ),
  );

  Future<void> dispose() async {
    container.dispose();
    await database.close();
  }
}

/// Mounts the real route tree at [location] with all plain sync seams faked.
///
/// [folderListing] answers the backup folder picker; the default returns no
/// subfolders so a test can select the connection root itself.
/// [remoteWritableCheck] replaces the pre-create remote writability probe; the
/// default accepts every folder, so no test ever dials a provider.
Future<PlainSyncWorld> pumpPlainSyncApp(
  WidgetTester tester, {
  String location = '/files',
  Locale locale = const Locale('zh'),
  TargetPlatform platform = TargetPlatform.iOS,
  List<ConnectionModel> connections = const [],
  Future<List<WebDavBackupFolder>> Function(List<String> segments)?
  folderListing,
  Future<void> Function({
    required String connectionId,
    required List<String> remoteRootSegments,
  })?
  remoteWritableCheck,
  Size surface = const Size(390, 844),
  Future<MirrorRunOutcome> Function(String profileId)? plainRun,
  Future<MirrorRunOutcome> Function(
    String profileId,
    Set<String> confirmedPaths,
  )?
  plainConfirmedDeletions,
  FolderLauncher? folderLauncher,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  await LocalDataManager.instance.init();

  final database = await SyncStateDatabase.inMemory();
  if (connections.isNotEmpty) {
    await database.replaceConnectionPayloads({
      for (final connection in connections)
        connection.id: jsonEncode(connection.toJson()),
    });
  }

  final authorizer = FakeFolderAccessAuthorizer(
    FolderAccessGrant.localPath(testLocalFolder),
  );
  final loadedFolders = <List<String>>[];
  final createdFolders = <List<String>>[];
  // The provider override assigns its stub here when it is first read, i.e.
  // after the world is built, so the box is shared instead of copied.
  final runServiceBox = <StubPlainRunService>[];
  final remoteChecks =
      <({String connectionId, List<String> remoteRootSegments})>[];

  final container = ProviderContainer(
    overrides: [
      syncStateDatabaseProvider.overrideWithValue(database),
      folderAccessAuthorizerProvider.overrideWithValue(authorizer),
      backupFolderLoaderProvider.overrideWithValue(({
        required WebDavProtocolModel protocol,
        required List<String> relativeSegments,
      }) async {
        loadedFolders.add(List<String>.of(relativeSegments));
        return await folderListing?.call(relativeSegments) ??
            const <WebDavBackupFolder>[];
      }),
      backupFolderCreatorProvider.overrideWithValue(({
        required WebDavProtocolModel protocol,
        required List<String> relativeSegments,
        required String name,
      }) async {
        createdFolders.add([...relativeSegments, name]);
      }),
      // The wizard proves the chosen remote folder accepts a write before it
      // creates anything. Default: accept; tests inject a failing check.
      plainRemoteWritableCheckProvider.overrideWithValue(({
        required String connectionId,
        required List<String> remoteRootSegments,
      }) async {
        remoteChecks.add((
          connectionId: connectionId,
          remoteRootSegments: List<String>.of(remoteRootSegments),
        ));
        if (remoteWritableCheck != null) {
          await remoteWritableCheck(
            connectionId: connectionId,
            remoteRootSegments: remoteRootSegments,
          );
        }
      }),
      // Opening a folder must never reach the real system file manager from a
      // widget test; the injected launcher records the URL instead.
      if (folderLauncher != null)
        folderLauncherProvider.overrideWithValue(folderLauncher),
      // Connections.build() sweeps statuses on the next turn; probing for real
      // would open a WebDAV socket from a widget test.
      protocolConnectionProbeProvider.overrideWithValue(
        ({required credentials, required protocol}) async => true,
      ),
      // A test that asserts the in-flight state injects a run that stays
      // pending, because the card owns that state instead of a modal dialog.
      if (plainRun != null)
        plainFolderServiceProvider.overrideWith((ref) {
          if (runServiceBox.isEmpty) {
            runServiceBox.add(
              StubPlainRunService(
                database: ref.watch(syncStateDatabaseProvider),
                profiles: ref.watch(plainFolderProfilesProvider),
                connections: ref.watch(connectionRepositoryProvider),
                runHandler: plainRun,
                confirmedDeletionsHandler: plainConfirmedDeletions,
              ),
            );
          }
          return runServiceBox.first;
        }),
    ],
  );
  addTearDown(container.dispose);

  final router = createAppRouter(initialLocation: location);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: platform),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();

  final world = PlainSyncWorld._(
    runServiceBox: runServiceBox,
    tester: tester,
    database: database,
    container: container,
    router: router,
    authorizer: authorizer,
    loadedFolders: loadedFolders,
    createdFolders: createdFolders,
    remoteChecks: remoteChecks,
  );
  addTearDown(world.dispose);
  return world;
}

/// A [PlainFolderSyncService] whose `run` is replaced by the test, so a test
/// can hold one run in flight and assert the card-owned progress state.
///
/// The plain runner deliberately has no modal progress dialog: the location
/// card's own primary button owns the spinner and the disabled state.
class StubPlainRunService extends PlainFolderSyncService {
  StubPlainRunService({
    required super.database,
    required super.profiles,
    required super.connections,
    required this.runHandler,
    this.confirmedDeletionsHandler,
  });

  final Future<MirrorRunOutcome> Function(String profileId) runHandler;

  /// The follow-up pass that actually deletes what the user reviewed. Records
  /// the exact path set it was approved with, so a test can prove that a plan
  /// the user never saw can never be executed.
  final Future<MirrorRunOutcome> Function(
    String profileId,
    Set<String> confirmedPaths,
  )?
  confirmedDeletionsHandler;

  int runCalls = 0;
  int confirmedDeletionCalls = 0;
  final confirmedPathSets = <Set<String>>[];

  @override
  Future<MirrorRunOutcome> run(
    String profileId, {
    bool allowDeletions = false,
    void Function(MirrorProgress progress)? onProgress,
    RemoteOperationCancellation? cancellation,
  }) {
    runCalls++;
    return runHandler(profileId);
  }

  @override
  Future<MirrorRunOutcome> runConfirmedDeletions(
    String profileId,
    Set<String> confirmedPaths, {
    void Function(MirrorProgress progress)? onProgress,
    RemoteOperationCancellation? cancellation,
  }) {
    confirmedDeletionCalls++;
    confirmedPathSets.add(Set<String>.of(confirmedPaths));
    final handler = confirmedDeletionsHandler;
    if (handler == null) {
      return Future<MirrorRunOutcome>.value(completedPlainRun());
    }
    return handler(profileId, confirmedPaths);
  }
}

/// An outcome that reports held deletions, i.e. the state a location is in when
/// a run crossed the deletion safety threshold.
MirrorRunOutcome heldPlainRun({
  required List<String> paths,
  int heldCount = 0,
}) => MirrorRunOutcome(
  stats: MirrorRunStats(
    runId: 'run-plain-held',
    profileId: 'plain-1',
    startedAt: DateTime.utc(2026, 9, 27, 9),
    finishedAt: DateTime.utc(2026, 9, 27, 9, 1),
    heldDeletionCount: heldCount == 0 ? paths.length : heldCount,
  ),
  conflicts: const [],
  heldDeletions: MirrorHeldDeletions(
    actions: [
      for (final path in paths)
        MirrorAction(
          type: MirrorActionType.deleteLocalEntry,
          relativePath: path,
          outcome: MirrorPathOutcome.unchanged,
        ),
    ],
    knownEntryCount: paths.length,
    limit: 1,
  ),
);

/// An outcome that reports one uploaded file, so a finished run has real
/// result wording instead of an empty summary.
MirrorRunOutcome completedPlainRun({
  int uploadedFileCount = 1,
  int downloadedFileCount = 0,
}) => MirrorRunOutcome(
  stats: MirrorRunStats(
    runId: 'run-plain-1',
    profileId: 'plain-1',
    startedAt: DateTime.utc(2026, 9, 27, 8),
    finishedAt: DateTime.utc(2026, 9, 27, 8, 1),
    uploadedFileCount: uploadedFileCount,
    downloadedFileCount: downloadedFileCount,
  ),
  conflicts: const [],
  heldDeletions: null,
);

/// Taps [finder] after scrolling it into view; keys in long list pages are
/// frequently laid out below the fold.
///
/// Pass `settle: false` when the tap starts an in-flight transfer: the busy
/// button's inline spinner animates forever, so the tree never settles and the
/// test must pump explicit frames instead.
Future<void> tapVisible(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  await tester.ensureVisible(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Flush the scroll jump before tapping, or the tap uses stale geometry.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Scrolls the page's outer list until [finder] is visible, then taps it.
///
/// The outer list is the first [Scrollable] in tree order, and it is the one
/// whose lazy children (long wizard/detail bodies) have to be built by
/// scrolling before they can be found.
Future<void> scrollAndTap(
  WidgetTester tester,
  Finder finder, {
  double delta = 240,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
