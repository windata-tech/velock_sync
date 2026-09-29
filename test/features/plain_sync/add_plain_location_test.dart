/// Widget tests for the three-step "add plain location" wizard.
///
/// The wizard runs against the real route tree, an in-memory database and a
/// fake folder authorizer/remote folder loader, so no platform picker, no
/// WebDAV request and no real timer is involved.
///
/// Tests that push the remote folder picker run on Android: on iOS the
/// Cupertino navigation bar merges the two pages' bars while the route is
/// pushed, and the wizard's `n/3` step counter (37.8px in the monospace test
/// font, ~18px with a real font) overflows that transitional bar by ~1px. It is
/// a transition-frame artifact of the test font, not a page layout, so the
/// picker flows are exercised on the Material app bar instead.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/plain_sync/ui/add_plain_location.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_sync_home.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/widgets/common_widgets.dart' show AppBackButton;

import 'plain_sync_test_support.dart';

void main() {
  /// Mounts the app on the files tab and pushes the wizard route, exactly like
  /// the tab's "add location" entry does.
  Future<PlainSyncWorld> openWizard(
    WidgetTester tester, {
    List<ConnectionModel> connections = const [],
    Future<List<WebDavBackupFolder>> Function(List<String> segments)?
    folderListing,
    Future<void> Function({
      required String connectionId,
      required List<String> remoteRootSegments,
    })?
    remoteWritableCheck,
    TargetPlatform platform = TargetPlatform.iOS,
  }) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: connections,
      folderListing: folderListing,
      remoteWritableCheck: remoteWritableCheck,
      platform: platform,
    );
    world.wizardPop = world.router.push<bool>('/plain-locations/new');
    await tester.pumpAndSettle();
    expect(find.byType(AddPlainLocation), findsOneWidget);
    return world;
  }

  /// Step 1: pick the local folder and move on.
  Future<void> pickLocalAndContinue(
    WidgetTester tester, {
    String folderName = testLocalFolderName,
  }) async {
    await tapVisible(tester, find.byKey(const Key('plain-pick-local')));
    expect(find.text(folderName), findsOneWidget);
    expect(find.text('已选择'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-1')));
    expect(find.text('第 2 步，共 3 步'), findsOneWidget);
  }

  /// Step 2: open the connection, enter [folderName] and use it, then advance
  /// to step 3. Mirrors the folder-picker flow of the step-3 tests.
  Future<void> pickRemoteAndContinue(
    WidgetTester tester, {
    String folderName = '手机备份',
  }) async {
    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
    await tester.tap(find.byKey(ValueKey('backup-folder-$folderName')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));
    expect(find.text('第 3 步，共 3 步'), findsOneWidget);
  }

  /// The location the router is really showing.
  ///
  /// `router.push()` adds an imperative page without touching the route
  /// information provider, so a wizard that was pushed still reports `/files`
  /// there; the delegate's top match is what the user sees.
  String shownRoute(PlainSyncWorld world) =>
      world.router.routerDelegate.currentConfiguration.last.matchedLocation;

  /// Every step shows the header back button; it belongs to the wizard page.
  Finder wizardHeaderBack() => find.descendant(
    of: find.byType(AddPlainLocation),
    matching: find.byType(AppBackButton),
  );

  /// The semantics label [AppBackButton] publishes for the wizard's header.
  Iterable<String?> wizardHeaderBackLabels(WidgetTester tester) => tester
      .widgetList<Semantics>(
        find.descendant(
          of: wizardHeaderBack(),
          matching: find.byType(Semantics),
        ),
      )
      .map((widget) => widget.properties.label);

  testWidgets('step 1 needs a local folder before Next', (tester) async {
    final world = await openWizard(tester);

    expect(find.text('第 1 步，共 3 步'), findsOneWidget);
    expect(find.text('选择本机文件夹'), findsWidgets);
    // Nothing is selected yet, so Next stays disabled.
    expect(find.text('还没有选择'), findsOneWidget);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-1')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('plain-wizard-next-1')));
    await tester.pumpAndSettle();
    // A disabled button cannot advance the wizard.
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);
    expect(world.authorizer.calls, 0);

    await tapVisible(tester, find.byKey(const Key('plain-pick-local')));

    expect(world.authorizer.calls, 1);
    // The picked folder's name replaces the placeholder and Next unlocks.
    expect(find.text(testLocalFolderName), findsOneWidget);
    expect(find.text('已选择'), findsOneWidget);
    expect(find.text('还没有选择'), findsNothing);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-1')),
          )
          .onPressed,
      isNotNull,
    );

    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-1')));
    expect(find.text('第 2 步，共 3 步'), findsOneWidget);
    expect(find.text('选择远端文件夹'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the local picker keeps Next disabled', (
    tester,
  ) async {
    final world = await openWizard(tester);
    // The user dismisses the system folder picker without choosing anything.
    world.authorizer.grant = null;

    await tapVisible(tester, find.byKey(const Key('plain-pick-local')));

    expect(world.authorizer.calls, 1);
    expect(find.text('还没有选择'), findsOneWidget);
    expect(find.byKey(const Key('plain-wizard-error')), findsNothing);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-1')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);
    expect(await world.listProfiles(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('step 2 explains when there is no usable remote connection', (
    tester,
  ) async {
    await openWizard(tester);
    await pickLocalAndContinue(tester);

    expect(find.text('还没有可用的远端连接'), findsOneWidget);
    expect(
      find.text('文件夹同步用的是 WebDAV（NAS 或网盘提供的 WebDAV 地址）。先添加一个连接，选好文件夹后就能开始同步。'),
      findsOneWidget,
    );
    // Not a dead end: the wizard offers the connection form itself instead of
    // making the user abandon the wizard and find the settings row by hand.
    expect(find.byKey(const Key('plain-add-connection')), findsOneWidget);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-add-connection')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-2')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(BackupFolderPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('step 2 does not offer a non-WebDAV connection', (tester) async {
    await openWizard(tester, connections: [oAuthConnection()]);
    await pickLocalAndContinue(tester);

    // Only WebDAV folders can be mirrored as plain files.
    expect(find.byKey(const Key('plain-remote-oauth-1')), findsNothing);
    expect(find.text('网盘'), findsNothing);
    expect(find.text('还没有可用的远端连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('step 2 picks the remote folder through the folder picker', (
    tester,
  ) async {
    final world = await openWizard(
      tester,
      connections: [webDavConnection()],
      platform: TargetPlatform.android,
      folderListing: (segments) async => segments.isEmpty
          ? const [WebDavBackupFolder(name: '手机备份')]
          : const [WebDavBackupFolder(name: '照片')],
    );
    await pickLocalAndContinue(tester);

    expect(find.byKey(const Key('plain-remote-conn-1')), findsOneWidget);
    expect(find.text('我的 NAS'), findsOneWidget);
    expect(find.text('选择一个文件夹'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));

    // The real folder picker is pushed and loads the connection root.
    expect(find.byType(BackupFolderPicker), findsOneWidget);
    expect(world.loadedFolders, [<String>[]]);
    expect(find.byKey(const ValueKey('backup-folder-手机备份')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup-folder-手机备份')));
    await tester.pumpAndSettle();
    expect(world.loadedFolders, [
      <String>[],
      ['手机备份'],
    ]);
    expect(find.byKey(const ValueKey('backup-folder-照片')), findsOneWidget);

    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();

    // Back on the wizard with the chosen path shown and Next unlocked.
    expect(find.byType(BackupFolderPicker), findsNothing);
    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(find.text('/手机备份'), findsOneWidget);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-2')),
          )
          .onPressed,
      isNotNull,
    );
    // Browsing is read-only: nothing was created and no profile written.
    expect(world.createdFolders, isEmpty);
    expect(await world.listProfiles(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting the connection root is refused with an explanation', (
    tester,
  ) async {
    final world = await openWizard(
      tester,
      connections: [webDavConnection()],
      platform: TargetPlatform.android,
    );
    await pickLocalAndContinue(tester);

    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
    // The picker allows "use this folder" at the root, which is not a real
    // remote folder to mirror.
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plain-wizard-error')), findsOneWidget);
    expect(find.text('请进入一个真实存在的文件夹再选择；连接根位置可能只是只读入口。'), findsOneWidget);
    expect(find.text('选择一个文件夹'), findsOneWidget);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-2')),
          )
          .onPressed,
      isNull,
    );
    expect(await world.listProfiles(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  // QA 2026-09-29: the first-sync note always described the two-way merge.
  testWidgets('the first-sync note follows the chosen direction', (
    tester,
  ) async {
    await openWizard(
      tester,
      connections: [webDavConnection()],
      platform: TargetPlatform.android,
      folderListing: (segments) async => segments.isEmpty
          ? const [WebDavBackupFolder(name: '手机备份')]
          : const [],
    );
    await pickLocalAndContinue(tester);
    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
    await tester.tap(find.byKey(ValueKey('backup-folder-手机备份')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));

    // The note sits below the options, outside the built part of the list.
    final noteFinder = find.byKey(const Key('plain-first-sync-note'));
    Future<String> note() async {
      await tester.scrollUntilVisible(
        noteFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      return tester.widget<Text>(noteFinder).data!;
    }

    expect(await note(), contains('第一次同步会合并两边'));

    await tapVisible(
      tester,
      find.byKey(const Key('plain-direction-uploadOnly')),
    );
    expect(await note(), contains('第一次同步只上传'));
    expect(await note(), contains('只在远端的文件保持原样，不会下载'));
    expect(await note(), isNot(contains('下载到本机')));
    expect(await note(), isNot(contains('冲突设置')));

    await tapVisible(
      tester,
      find.byKey(const Key('plain-direction-downloadOnly')),
    );
    expect(await note(), contains('第一次同步只下载'));
    expect(await note(), contains('只在本机的文件保持原样，不会上传'));
    expect(await note(), isNot(contains('上传到远端')));
    expect(await note(), isNot(contains('冲突设置')));

    // The plaintext warning stays for every direction.
    expect(await note(), contains('远端是明文'));
  });

  testWidgets(
    'step 3 creates the location with the chosen direction and policy',
    (tester) async {
      final world = await openWizard(
        tester,
        connections: [webDavConnection()],
        platform: TargetPlatform.android,
        folderListing: (segments) async => segments.isEmpty
            ? const [WebDavBackupFolder(name: '手机备份')]
            : const [],
      );
      await pickLocalAndContinue(tester);
      await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
      await tester.tap(find.byKey(ValueKey('backup-folder-手机备份')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));

      expect(find.text('第 3 步，共 3 步'), findsOneWidget);
      expect(find.text('同步方式'), findsWidgets);
      // The name field must be reachable and editable. (Its controller is
      // created on the wizard's first build, before a local folder exists, so
      // the default name -- `add_plain_location.dart:186` -- is not shown in
      // the field; the test types the name explicitly instead of asserting the
      // defective prefill. See the report for the file:line.)
      final nameField = find.byKey(const Key('plain-name-field'));
      await tester.enterText(nameField, '照片同步');
      await tester.pumpAndSettle();

      // A two-way location offers conflict handling.
      expect(find.text('冲突处理'), findsOneWidget);
      expect(find.byKey(const Key('plain-conflict-keepBoth')), findsOneWidget);
      expect(
        find.byKey(const Key('plain-direction-bidirectional')),
        findsOneWidget,
      );

      // Choose the conflict policy first, then switch to a one-way direction.
      await tapVisible(
        tester,
        find.byKey(const Key('plain-conflict-preferLocal')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('plain-direction-uploadOnly')),
      );

      // A one-way location has nothing to resolve, so the section disappears.
      expect(find.text('冲突处理'), findsNothing);
      expect(find.byKey(const Key('plain-conflict-keepBoth')), findsNothing);
      expect(find.byKey(const Key('plain-conflict-preferLocal')), findsNothing);
      expect(
        find.byKey(const Key('plain-conflict-preferRemote')),
        findsNothing,
      );

      final popResult = world.wizardPop;
      expect(popResult, isNotNull);
      // The remote folder is proved writable before the location exists.
      expect(world.remoteChecks, isEmpty);

      await tapVisible(tester, find.byKey(const Key('plain-wizard-create')));
      await tester.pumpAndSettle();

      // The wizard route was popped back to the files tab, and it popped with
      // `true` so the tab knows to re-read its list.
      expect(find.byType(AddPlainLocation), findsNothing);
      expect(find.byType(PlainSyncHome), findsOneWidget);
      expect(await popResult, isTrue);

      final profiles = await world.listProfiles();
      expect(profiles, hasLength(1));
      final profile = profiles.single;
      expect(profile.displayName, '照片同步');
      expect(profile.direction, MirrorDirection.uploadOnly);
      expect(profile.conflictPolicy, MirrorConflictPolicy.preferLocal);
      expect(profile.remoteRootSegments, ['手机备份']);
      expect(profile.localDisplayName, testLocalFolderName);
      expect(profile.localRootReference, testLocalFolder.path);
      expect(profile.connectionId, 'conn-1');
      expect(profile.deviceId, isNotEmpty);
      expect(profile.isActive, isTrue);
      // No folder was created remotely; only the confirmed one was selected.
      expect(world.createdFolders, isEmpty);
      // The writability check ran once, for exactly the chosen remote folder,
      // before the location was stored.
      expect(world.remoteChecks, hasLength(1));
      expect(world.remoteChecks.single.connectionId, 'conn-1');
      expect(world.remoteChecks.single.remoteRootSegments, ['手机备份']);
      // The list is re-read after creation, so the new card is already there.
      expect(find.text('照片同步'), findsOneWidget);
      expect(
        find.byKey(Key('plain-location-run-${profile.profileId}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  group('a Velock backup folder is refused as soon as it is picked', () {
    Future<void> pickAndExpectRefused(
      WidgetTester tester,
      PlainSyncWorld world, {
      required List<String> path,
      required String message,
    }) async {
      await pickLocalAndContinue(tester);
      await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
      for (final segment in path) {
        await tester.tap(find.byKey(ValueKey('backup-folder-$segment')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();

      expect(find.byType(AddPlainLocation), findsOneWidget);
      expect(find.byKey(const Key('plain-wizard-error')), findsOneWidget);
      expect(find.textContaining(message), findsOneWidget);
      // The folder was not taken: Next stays locked, nothing probed or stored.
      expect(find.text('选择一个文件夹'), findsOneWidget);
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('plain-wizard-next-2')),
            )
            .onPressed,
        isNull,
      );
      expect(world.remoteChecks, isEmpty);
      expect(world.createdFolders, isEmpty);
      expect(await world.listProfiles(), isEmpty);
      expect(tester.takeException(), isNull);
    }

    Future<List<WebDavBackupFolder>> backupTree(List<String> segments) async =>
        switch (segments) {
          [] => const [WebDavBackupFolder(name: 'velock-backup')],
          ['velock-backup'] => const [WebDavBackupFolder(name: 'velock-sync')],
          _ => const [WebDavBackupFolder(name: 'v1')],
        };

    testWidgets('the folder of a backup configured on this device', (
      tester,
    ) async {
      final world = await openWizard(
        tester,
        connections: [webDavConnection()],
        platform: TargetPlatform.android,
        // No marker folder: the refusal comes from the local backup profile.
        folderListing: (segments) async => segments.isEmpty
            ? const [WebDavBackupFolder(name: 'velock-backup')]
            : const [],
      );
      await SyncProfileRepository(world.database).save(
        VelockSyncProfile(
          profileId: 'backup',
          datasetId: 'dataset',
          vaultId: 'vault',
          deviceId: 'consumer',
          displayName: '我的格间',
          connectionId: 'conn-1',
          remoteRootSegments: const ['velock-backup'],
          pairedProducerId: 'source',
          pairedProducerPublicKeyId: 'public-key-ref',
          exchangeBindingId: 'binding',
          backgroundPolicy: const SyncProfileBackgroundPolicy(),
          state: SyncProfileState.active,
          createdAt: DateTime.utc(2026, 9, 29),
        ).toEnvelope(),
      );

      await pickAndExpectRefused(
        tester,
        world,
        path: ['velock-backup'],
        message: '我的格间',
      );
    });

    testWidgets('a folder holding a backup made on another device', (
      tester,
    ) async {
      final world = await openWizard(
        tester,
        connections: [webDavConnection()],
        platform: TargetPlatform.android,
        folderListing: backupTree,
      );
      await pickAndExpectRefused(
        tester,
        world,
        path: ['velock-backup'],
        message: '这个远端文件夹里有格间的加密备份',
      );
    });

    testWidgets('a folder inside a backup', (tester) async {
      final world = await openWizard(
        tester,
        connections: [webDavConnection()],
        platform: TargetPlatform.android,
        folderListing: backupTree,
      );
      await pickAndExpectRefused(
        tester,
        world,
        path: ['velock-backup', 'velock-sync'],
        message: '这个远端文件夹里有格间的加密备份',
      );
    });
  });

  testWidgets('a remote folder that cannot be written stores nothing', (
    tester,
  ) async {
    final world = await openWizard(
      tester,
      connections: [webDavConnection()],
      platform: TargetPlatform.android,
      folderListing: (segments) async => segments.isEmpty
          ? const [WebDavBackupFolder(name: '只读共享')]
          : const [],
      // The probe fails the way the service fails for a missing or read-only
      // remote folder (`plain_folder_sync_service.dart:220-228`).
      remoteWritableCheck:
          ({required connectionId, required remoteRootSegments}) async {
            throw const PlainFolderSyncException(
              SyncFailure(
                errorCode: 'plain_folder.remote_folder_unwritable',
                category: SyncErrorCategory.permissionRequired,
                retryable: false,
                suggestedAction:
                    '远端文件夹不存在或这个账号不能写入。请在详情页重新选择一个真实存在、且可写入的远端文件夹。',
              ),
            );
          },
    );
    await pickLocalAndContinue(tester);
    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
    await tester.tap(find.byKey(const ValueKey('backup-folder-只读共享')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));
    expect(find.text('第 3 步，共 3 步'), findsOneWidget);

    // The wizard body is long: the Create button is only built once the list is
    // scrolled to the bottom.
    await scrollAndTap(tester, find.byKey(const Key('plain-wizard-create')));

    // The wizard stays open and explains the failure inline; nothing is stored
    // and no remote folder is created.
    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(find.text('第 3 步，共 3 步'), findsOneWidget);
    expect(find.byKey(const Key('plain-wizard-error')), findsOneWidget);
    // The wizard speaks to a user who is still on step 3/3, so it does not
    // repeat the service wording that points at a details page.
    expect(
      find.text('这个远端文件夹不存在，或者这个账号不能写入。请返回上一步，选择另一个真实存在、可写入的文件夹。'),
      findsOneWidget,
    );
    expect(world.remoteChecks, hasLength(1));
    expect(world.remoteChecks.single.remoteRootSegments, ['只读共享']);
    expect(await world.listProfiles(), isEmpty);
    expect(await world.database.readVisibleSyncProfilePayloads(), isEmpty);
    expect(world.createdFolders, isEmpty);
    // Create is available again so the user can retry after fixing the folder.
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-create')),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a connection or folder nothing is written', (
    tester,
  ) async {
    final world = await openWizard(tester);

    // Step 1 without a folder: Next is disabled and nothing is persisted.
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-1')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('plain-wizard-next-1')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);

    await pickLocalAndContinue(tester);

    // Step 2 without a connection: no Create action exists and Next is off.
    final next = find.byKey(const Key('plain-wizard-next-2'));
    expect(tester.widget<BackupActionButton>(next).onPressed, isNull);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('第 2 步，共 3 步'), findsOneWidget);
    expect(find.byKey(const Key('plain-wizard-create')), findsNothing);

    expect(await world.listProfiles(), isEmpty);
    expect(await world.database.readVisibleSyncProfilePayloads(), isEmpty);
    expect(world.createdFolders, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a successful create leaves the wizard even when it is the first route',
    (tester) async {
      // The app was opened straight on `/plain-locations/new` (deep link or a
      // restored route): the wizard is the first route of the navigator, so
      // there is nothing below it to pop back to. A save that tried to pop
      // anyway used to be reported as "创建同步位置失败" although the profile
      // had already been written.
      final world = await pumpPlainSyncApp(
        tester,
        location: '/plain-locations/new',
        connections: [webDavConnection()],
        platform: TargetPlatform.android,
        folderListing: (segments) async => segments.isEmpty
            ? const [WebDavBackupFolder(name: '手机备份')]
            : const [],
        // The real probe dials the remote folder; this test has no network.
        remoteWritableCheck:
            ({required connectionId, required remoteRootSegments}) async {},
      );

      expect(find.byType(AddPlainLocation), findsOneWidget);
      expect(find.byType(PlainSyncHome), findsNothing);
      // Precondition of the bug: popping is impossible from here.
      expect(world.router.canPop(), isFalse);
      expect(find.text('第 1 步，共 3 步'), findsOneWidget);

      await pickLocalAndContinue(tester);
      await pickRemoteAndContinue(tester);

      await tester.enterText(find.byKey(const Key('plain-name-field')), '照片同步');
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const Key('plain-direction-uploadOnly')),
      );

      final create = find.byKey(const Key('plain-wizard-create'));
      // Bring Create into view without tapping it yet: the frames right after
      // the tap are exactly where the false failure used to be painted.
      await tester.scrollUntilVisible(
        create,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plain-wizard-error')), findsNothing);

      await tester.tap(create);
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.byKey(const Key('plain-wizard-error')),
          findsNothing,
          reason:
              'the location was saved, so no failure may be shown (frame $frame)',
        );
      }
      await tester.pumpAndSettle();

      // Exactly one location was stored, with the chosen settings.
      expect(world.remoteChecks, hasLength(1));
      expect(world.remoteChecks.single.connectionId, 'conn-1');
      expect(world.remoteChecks.single.remoteRootSegments, ['手机备份']);
      final profiles = await world.listProfiles();
      expect(profiles, hasLength(1));
      final profile = profiles.single;
      expect(profile.displayName, '照片同步');
      expect(profile.direction, MirrorDirection.uploadOnly);
      expect(profile.remoteRootSegments, ['手机备份']);
      expect(profile.localDisplayName, testLocalFolderName);
      expect(profile.localRootReference, testLocalFolder.path);

      // ... and the wizard left instead of stranding the user on itself: with
      // no route to pop, it returns to the files tab.
      expect(find.byType(AddPlainLocation), findsNothing);
      expect(find.byKey(const Key('plain-wizard-error')), findsNothing);
      expect(world.router.routeInformationProvider.value.uri.path, '/files');
      expect(find.byType(PlainSyncHome), findsOneWidget);
      expect(
        find.byKey(Key('plain-location-open-${profile.profileId}')),
        findsOneWidget,
      );
      expect(find.text('照片同步'), findsWidgets);
      expect(world.createdFolders, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the header back leaves the wizard from the first step', (
    tester,
  ) async {
    final world = await openWizard(tester);

    // Step 1 with a folder picked: Next is enabled, but the header back is the
    // way out and its label says so instead of "previous step".
    await tapVisible(tester, find.byKey(const Key('plain-pick-local')));
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);
    expect(find.text('已选择'), findsOneWidget);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-1')),
          )
          .onPressed,
      isNotNull,
    );

    expect(wizardHeaderBack(), findsOneWidget);
    expect(wizardHeaderBackLabels(tester), contains('返回文件同步'));

    final pop = world.wizardPop;
    expect(pop, isNotNull);
    await tapVisible(tester, wizardHeaderBack());
    await tester.pumpAndSettle();

    // Leaving from step 1 pops the wizard route, exactly like the system back.
    expect(find.byType(AddPlainLocation), findsNothing);
    expect(find.text('第 1 步，共 3 步'), findsNothing);
    expect(find.byType(PlainSyncHome), findsOneWidget);
    expect(world.router.routeInformationProvider.value.uri.path, '/files');
    expect(await pop, isTrue);
    expect(await world.listProfiles(), isEmpty);
    expect(tester.takeException(), isNull);

    // The same button on step 2 only walks one step back: the wizard stays
    // mounted and the route does not change.
    world.wizardPop = world.router.push<bool>('/plain-locations/new');
    await tester.pumpAndSettle();
    await pickLocalAndContinue(tester);
    expect(find.text('第 2 步，共 3 步'), findsOneWidget);

    await tapVisible(tester, wizardHeaderBack());
    await tester.pumpAndSettle();

    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);
    expect(find.text('第 2 步，共 3 步'), findsNothing);
    // One step back inside the pushed wizard: no navigation happened.
    expect(shownRoute(world), '/plain-locations/new');
    // The picked folder survived the step back, so the same button can also
    // walk forward again instead of restarting the wizard.
    expect(find.text(testLocalFolderName), findsOneWidget);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('plain-wizard-next-1')),
          )
          .onPressed,
      isNotNull,
    );
    expect(await world.listProfiles(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('moving between steps clears a stale failure', (tester) async {
    final world = await openWizard(
      tester,
      connections: [webDavConnection()],
      platform: TargetPlatform.android,
      folderListing: (segments) async => segments.isEmpty
          ? const [WebDavBackupFolder(name: '只读共享')]
          : const [],
      remoteWritableCheck:
          ({required connectionId, required remoteRootSegments}) async {
            throw const PlainFolderSyncException(
              SyncFailure(
                errorCode: 'plain_folder.remote_folder_unwritable',
                category: SyncErrorCategory.permissionRequired,
                retryable: false,
                suggestedAction: '远端文件夹不存在或这个账号不能写入。',
              ),
            );
          },
    );
    await pickLocalAndContinue(tester);
    await pickRemoteAndContinue(tester, folderName: '只读共享');

    await scrollAndTap(tester, find.byKey(const Key('plain-wizard-create')));

    // This failure is real -- nothing was saved -- so the wizard keeps it on
    // step 3.
    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(find.text('第 3 步，共 3 步'), findsOneWidget);
    expect(find.byKey(const Key('plain-wizard-error')), findsOneWidget);
    expect(world.remoteChecks, hasLength(1));
    expect(await world.listProfiles(), isEmpty);

    // The secondary action on step 3 goes one step back and must not carry the
    // stale banner into step 2.
    final stepBack = find.widgetWithText(BackupActionButton, '上一步');
    expect(stepBack, findsOneWidget);
    await tapVisible(tester, stepBack);

    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(find.text('第 2 步，共 3 步'), findsOneWidget);
    expect(find.byKey(const Key('plain-wizard-error')), findsNothing);
    // Walking one step back stays inside the wizard route.
    expect(shownRoute(world), '/plain-locations/new');

    // Forward again: the cleared failure does not come back, and the wizard
    // does not silently re-run the remote probe.
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));
    expect(find.text('第 3 步，共 3 步'), findsOneWidget);
    expect(find.byKey(const Key('plain-wizard-error')), findsNothing);
    expect(world.remoteChecks, hasLength(1));
    expect(await world.listProfiles(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
