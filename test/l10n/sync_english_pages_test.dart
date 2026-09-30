/// English-locale guard for the pages that used to be Chinese-only.
///
/// `sync_locale_test.dart` only ever mounted `NewSyncProfile` — an unreachable
/// route — while asserting that the English UI paints no Chinese. The screens a
/// user really reaches (the settings tab, the activity log, the connection help
/// page, the connection detail page, the Baidu token page) were therefore free
/// to carry hundreds of raw CJK literals with no `syncText` call, and no test
/// noticed.
///
/// This file mounts those real pages with `Locale('en')` and fails if a single
/// CJK character is painted or announced. Fixture data (profile names, stored
/// failure copy) is English on purpose: user data is not copy and is never
/// translated by the UI.
library;

import 'package:dio/dio.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/activity/ui/sync_activity.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/features/connection/ui/connection_guidance.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_settings.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/l10n/sync_language.dart';
import 'package:velock_sync/l10n/sync_language_setting.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Any CJK ideograph: an English screen must not paint one.
final _cjk = RegExp(r'[\u4e00-\u9fff]');

/// Links, not copy. The Baidu platform documents itself under Chinese paths
/// (https://pan.baidu.com/union/doc/使用入门/...), so a URL is stripped before
/// the check instead of being translated.
final _url = RegExp(r'https?://\S+');

const _connectionRoot = '/backup';
const _connectionChild = '/backup/child';
final _connection = ConnectionModel(
  id: 'test',
  name: 'Test NAS',
  source: 'test',
  target: 'test',
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.invalid',
    port: '443',
    path: _connectionRoot,
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

void main() {
  testWidgets('the settings tab paints no Chinese on an English device', (
    tester,
  ) async {
    await _pump(
      tester,
      ProviderContainer(
        overrides: [
          syncLanguageBootstrapProvider.overrideWithValue(SyncLanguage.english),
          syncSettingsServiceProvider.overrideWithValue(_FakeSettingsService()),
        ],
      ),
      const SyncSettings(),
    );
    // The page both paints and scrolls: check every viewport, not just the first.
    await _checkWholePage(
      tester,
      allowLanguageEndonym: true,
      where: 'the settings tab',
    );
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('the activity page paints no Chinese when it is empty', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    await _pump(tester, _activityContainer(database), const SyncActivity());
    _expectNoChinese(tester, where: 'the empty activity page');
    expect(find.text('No sync activity yet'), findsOneWidget);
  });

  testWidgets(
    'the activity page paints no Chinese with runs, transfers and conflicts',
    (tester) async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SyncProfileRepository(database);
      await repository.save(_profile('profile-1'));

      await database.startSyncRun(
        runId: 'run-1',
        profileId: 'profile-1',
        startedAt: DateTime.utc(2026, 9, 27, 8),
      );
      await database.finishSyncRun(
        runId: 'run-1',
        state: 'failed',
        completedAt: DateTime.utc(2026, 9, 27, 8, 1),
        failure: const SyncFailure(
          errorCode: 'provider.http.401',
          category: SyncErrorCategory.authenticationRequired,
          retryable: true,
          // The engine owns this stored string. Real producers still write it in
          // Chinese (for example lib/providers/webdav/webdav_object_store.dart),
          // which is a producer-side gap this page cannot translate away.
          suggestedAction: 'Sign in to the server again and retry.',
          providerStatusCode: 401,
        ),
      );
      await database.beginTransferJob(
        transferId: 'transfer-1',
        profileId: 'profile-1',
        direction: TransferJobDirection.upload,
        logicalKey: 'opaque-protocol-key',
        expectedSize: 4096,
      );
      await database.updateTransferProgress(
        transferId: 'transfer-1',
        completedBytes: 2048,
      );
      await database.recordFolderConflict(
        conflictId: 'conflict-1',
        profileId: 'profile-1',
        entityId: 'entity-1',
        sourceDeviceId: 'device-2',
        localRevisionId: 'revision-local',
        incomingRevisionId: 'revision-remote',
        type: 'modify-modify',
      );

      await _pump(
        tester,
        _activityContainer(database, repository),
        const SyncActivity(),
      );
      _expectNoChinese(tester, where: 'the activity page');
      expect(find.text('Sync failed'), findsOneWidget);
      expect(find.text('Recent syncs'), findsOneWidget);
      expect(find.text('Transfers to resume'), findsOneWidget);
      expect(find.text('Upload in progress'), findsOneWidget);
      expect(find.text('Conflicts to review'), findsOneWidget);
      expect(find.text('Both devices changed this item'), findsOneWidget);

      // The run sheet keeps the protocol detail one level deeper.
      await tester.tap(find.text('Sync failed'));
      await tester.pumpAndSettle();
      _expectNoChinese(tester, where: 'the activity run sheet');
      for (final label in const [
        'Started',
        'Finished',
        'Result',
        'Likely cause',
        'Suggested action',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // The collapsed protocol detail shares one text node with its heading.
      expect(find.textContaining('Technical details'), findsOneWidget);
      expect(
        find.text('Sign in to the server again and retry.'),
        findsOneWidget,
      );
      // The run sheet scrolls once its message is long.
      await tester.ensureVisible(find.text('Close'));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // Every conflict action is English too.
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
      await tester.pumpAndSettle();
      _expectNoChinese(tester, where: 'the conflict action menu');
      expect(find.text('Keep this device version'), findsOneWidget);
      expect(find.text('Keep remote version'), findsOneWidget);
      expect(find.text('Keep both versions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the connection help page paints no Chinese for any provider', (
    tester,
  ) async {
    for (final provider in <RemoteProviderType?>[
      null,
      ...RemoteProviderType.values,
    ]) {
      await _pump(
        tester,
        ProviderContainer(),
        ConnectionHelpPage(providerType: provider),
      );
      await _checkWholePage(
        tester,
        allowOfficialDocUrls: true,
        where: 'the connection help page for $provider',
      );
    }
  });

  // One mount per state: the connection page swaps its whole scroll body
  // between a grid, an empty state and an error state.
  testWidgets('the connection listing paints no Chinese', (tester) async {
    await _pump(
      tester,
      _connectionContainer(_listingState()),
      const Connection('test'),
    );
    _expectNoChinese(tester, where: 'the connection listing');
    expect(find.text('Test NAS'), findsOneWidget);
    expect(find.text('child'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the empty connection folder paints no Chinese', (tester) async {
    await _pump(
      tester,
      _connectionContainer(
        const FileBrowserState(
          path: _connectionRoot,
          rootPath: _connectionRoot,
          files: [],
        ),
      ),
      const Connection('test'),
    );
    _expectNoChinese(tester, where: 'the empty connection folder');
    expect(find.text('This folder is empty'), findsOneWidget);
    expect(find.text('Remote files and folders show up here.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the connection browser error paints no Chinese', (tester) async {
    await _pump(
      tester,
      _connectionContainer(
        _listingState(),
        error: DioException(
          requestOptions: RequestOptions(path: _connectionRoot),
          response: Response(
            requestOptions: RequestOptions(path: _connectionRoot),
            statusCode: 401,
          ),
          type: DioExceptionType.badResponse,
        ),
      ),
      const Connection('test'),
    );
    _expectNoChinese(tester, where: 'the connection browser error');
    expect(find.text('Sign-in failed'), findsOneWidget);
    expect(
      find.text(
        'The remote server rejected this account. Enter the username and password again and retry.',
      ),
      findsOneWidget,
    );
    expect(find.text('Edit connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing connection paints no Chinese', (tester) async {
    await _pump(
      tester,
      ProviderContainer(
        overrides: [
          connectionDetailProvider('gone').overrideWith(_MissingDetail.new),
        ],
      ),
      const Connection('gone'),
    );
    _expectNoChinese(tester, where: 'the missing connection page');
    expect(find.text('Connection not found'), findsOneWidget);
    expect(find.text('Back to connections'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // This used to be a known gap: the capability rows came from
  // `lib/providers/provider_capability_summary.dart`, which held raw CJK
  // literals, so an English sheet painted Chinese. The file is localized now,
  // so the sheet is checked like every other English screen.
  testWidgets('the connection info sheet paints no Chinese', (tester) async {
    await _pump(
      tester,
      _connectionContainer(_listingState()),
      const Connection('test'),
    );
    await tester.tap(find.byKey(const Key('connection-info')));
    await tester.pumpAndSettle();

    expect(find.text('Connection info'), findsOneWidget);
    expect(
      find.textContaining('Browse, upload and download files on the service'),
      findsOneWidget,
    );
    expect(find.textContaining('No resume'), findsOneWidget);
    _expectNoChinese(tester, where: 'the connection info sheet');
    expect(tester.takeException(), isNull);
  });
}

/// The activity page's providers, with the database under test.
ProviderContainer _activityContainer(
  SyncStateDatabase database, [
  SyncProfileRepository? repository,
]) => ProviderContainer(
  overrides: [
    syncStateDatabaseProvider.overrideWithValue(database),
    syncProfileRepositoryProvider.overrideWithValue(
      repository ?? SyncProfileRepository(database),
    ),
    conflictResolutionServiceProvider.overrideWithValue(
      _UnusedConflictResolution(),
    ),
  ],
);

/// The connection page's providers, with one fixed browser result.
ProviderContainer _connectionContainer(
  FileBrowserState state, {
  Object? error,
}) => ProviderContainer(
  overrides: [
    connectionDetailProvider('test').overrideWith(_FoundDetail.new),
    remoteFileBrowserProvider(
      connectionModel: _connection,
    ).overrideWith(() => _FakeBrowser(state, error: error)),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget page,
) async {
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [
          Locale('en'),
          Locale('zh'),
          Locale('zh', 'CN'),
        ],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every string the page actually paints.
List<String> _paintedTexts(
  WidgetTester tester, {
  bool allowLanguageEndonym = false,
}) {
  final excluded = <String>{};
  if (allowLanguageEndonym) {
    // The language picker names each language in its own script; that endonym
    // is the only Chinese an English page may show. The exclusion is scoped to
    // those rows.
    excluded.addAll(
      tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SyncLanguageSetting),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data ?? ''),
    );
  }
  return [
    for (final text in tester.widgetList<Text>(find.byType(Text)))
      if (!excluded.contains(text.data ?? '')) text.data ?? '',
  ];
}

Iterable<String> _semanticLabels(WidgetTester tester) => tester
    .widgetList<Semantics>(find.byType(Semantics))
    .map((widget) => widget.properties.label)
    .whereType<String>();

void _expectNoChinese(
  WidgetTester tester, {
  required String where,
  bool allowOfficialDocUrls = false,
  bool allowLanguageEndonym = false,
}) {
  for (final data in _paintedTexts(
    tester,
    allowLanguageEndonym: allowLanguageEndonym,
  )) {
    final checked = allowOfficialDocUrls ? data.replaceAll(_url, '') : data;
    expect(
      _cjk.hasMatch(checked),
      isFalse,
      reason: '$where paints Chinese in en: “$data”',
    );
  }
  for (final label in _semanticLabels(tester)) {
    expect(
      _cjk.hasMatch(label),
      isFalse,
      reason: '$where announces Chinese in en: “$label”',
    );
  }
}

/// Checks every viewport of a long, lazily built page: a `ListView` only builds
/// what is visible, so one check at the top would miss the rest of the page.
Future<void> _checkWholePage(
  WidgetTester tester, {
  required String where,
  bool allowOfficialDocUrls = false,
  bool allowLanguageEndonym = false,
}) async {
  var previousOffset = -1.0;
  for (var step = 0; step < 240; step++) {
    _expectNoChinese(
      tester,
      where: '$where (scroll step $step)',
      allowOfficialDocUrls: allowOfficialDocUrls,
      allowLanguageEndonym: allowLanguageEndonym,
    );
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) return;
    final position = tester.state<ScrollableState>(scrollable.first).position;
    if (step > 0 && (position.pixels - previousOffset).abs() < 0.5) return;
    previousOffset = position.pixels;
    await tester.drag(scrollable.first, const Offset(0, -420));
    await tester.pumpAndSettle();
  }
  fail('$where never reached the end of its scrollable content');
}

FileBrowserState _listingState() => FileBrowserState(
  path: _connectionRoot,
  rootPath: _connectionRoot,
  files: [WebdavFile(path: _connectionChild, isDir: true, name: 'child')],
);

SyncProfileEnvelope _profile(String profileId) => SyncProfileEnvelope(
  kind: SyncDatasetKind.selectedFolder,
  profileId: profileId,
  datasetId: 'dataset-$profileId',
  vaultId: 'vault-$profileId',
  deviceId: 'device-$profileId',
  displayName: 'Family NAS',
  connectionId: 'connection-$profileId',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'rootPath': '/safe/path',
    'rootKeyRef': 'secure/root',
    'signingKeyRef': 'secure/signing',
  },
  createdAt: DateTime.utc(2026, 9, 27),
);

class _FoundDetail extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _connection;
}

class _MissingDetail extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => null;
}

/// A browser that answers with fixed content, or fails with [error].
class _FakeBrowser extends RemoteFileBrowser {
  _FakeBrowser(this.initialState, {this.error});

  final FileBrowserState initialState;
  final Object? error;

  @override
  FileBrowserState? get visibleState => state.value;

  @override
  String get currentPath => initialState.path;

  @override
  bool get canGoBack => false;

  @override
  Future<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return initialState;
  }
}

/// The page reads the service on every build; resolving is never exercised by
/// these locale tests.
class _UnusedConflictResolution implements ConflictResolutionService {
  @override
  Future<ConflictResolutionResult> resolve({
    required String conflictId,
    required ConflictResolutionStrategy strategy,
  }) async => const ConflictResolutionResult.completed();
}

class _FakeSettingsService implements SyncSettingsService {
  @override
  Future<SyncSettingsSnapshot> load() async => SyncSettingsSnapshot(
    settings: const SyncGlobalSettings(
      backgroundEnabled: true,
      defaultAllowCellular: true,
      defaultRequiresCharging: true,
    ),
    backgroundSupported: true,
    backgroundEligibleProfileCount: 2,
    staging: const StagingSpaceSummary(
      totalBytes: 3 * 1024 * 1024,
      fileCount: 4,
      batchCount: 2,
    ),
    garbageCollection: null,
  );

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) => load();

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async =>
      const SyncSettingsCleanupSummary(
        freedBytes: 1024,
        preservedRecoverableBatchCount: 1,
      );

  @override
  Future<String> exportSanitizedDiagnostics() async => '{}';
}
