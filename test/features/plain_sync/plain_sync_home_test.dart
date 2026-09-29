/// Widget tests for the plain (unencrypted) folder sync tab home.
///
/// The real route tree is mounted so tapping the create entry exercises the
/// production `/plain-locations/new` route, and the location cards are read
/// back from an in-memory database seeded through
/// [PlainFolderSyncProfileRepository].
library;

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/plain_sync/ui/add_plain_location.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';

import 'plain_sync_test_support.dart';

void main() {
  /// The innermost status card that carries [name], so a badge is asserted on
  /// the card it belongs to and not on a sibling location.
  Finder locationCard(String name) => find
      .ancestor(of: find.text(name), matching: find.byType(BackupCard))
      .first;

  testWidgets('empty state offers the first location and opens the wizard', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(tester);

    // The empty card and its entry.
    expect(find.text('添加第一个同步位置'), findsOneWidget);
    expect(find.text('选择本机文件夹，再选择远端文件夹，两边就会保持一致。'), findsOneWidget);
    final create = find.byKey(const Key('plain-location-create'));
    expect(create, findsOneWidget);

    // Nothing else claims to be configured yet: no location card, no legacy
    // section, no "manage earlier encrypted sync" entry.
    expect(find.text('双向同步'), findsNothing);
    expect(find.text('旧版加密文件夹同步'), findsNothing);
    expect(find.text('管理旧版加密同步'), findsNothing);
    expect(find.byKey(const Key('legacy-encrypted-manage')), findsNothing);

    await tapVisible(tester, create);

    // The real router pushed the wizard route from the tab home. `push` is
    // imperative, so the route is read from the pushed page's own state.
    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(
      GoRouterState.of(tester.element(find.byType(AddPlainLocation))).uri.path,
      '/plain-locations/new',
    );
    expect(world.router.canPop(), isTrue);
    expect(find.text('选择本机文件夹'), findsWidgets);

    // It is a pushed page, so the standard back control returns to the tab.
    await tapVisible(tester, find.byType(AppBackButton));
    expect(find.byType(AddPlainLocation), findsNothing);
    expect(find.text('添加第一个同步位置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one location shows both halves, direction and sync status', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      // A wider surface than the default 390pt: with the test font the Cupertino
      // navigation bar's leading slot overflows by 1.2px at 390pt (a font
      // artifact, not a layout bug), which aborts the frame before the wizard
      // can be driven to completion.
      surface: const Size(430, 932),
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile();
    await world.refreshListView();

    final card = locationCard('照片同步');
    expect(find.text('照片同步'), findsOneWidget);
    // Local half.
    expect(
      find.descendant(of: card, matching: find.text('本机')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text(testLocalFolderName)),
      findsOneWidget,
    );
    // Remote half: connection name plus the selected remote path.
    expect(
      find.descendant(of: card, matching: find.text('远端')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('我的 NAS/photos/phone')),
      findsOneWidget,
    );
    // Direction badge and the not-yet-synced status.
    expect(
      find.descendant(of: card, matching: find.text('双向同步')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('还没有同步过')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('点“立即同步”开始第一次同步。')),
      findsOneWidget,
    );

    // Both per-location actions exist.
    expect(find.byKey(const Key('plain-location-run-plain-1')), findsOneWidget);
    expect(
      find.byKey(const Key('plain-location-open-plain-1')),
      findsOneWidget,
    );
    // Adding happens from the header "+"; the wide row under the list is gone,
    // and so is the first-run card.
    expect(find.byKey(const Key('plain-location-add')), findsOneWidget);
    expect(find.byKey(const Key('plain-location-create')), findsNothing);
    expect(find.text('添加同步位置'), findsNothing);
    expect(find.text('添加第一个同步位置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the header add button opens the wizard from a populated list', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile();
    await world.refreshListView();

    // With at least one location the wide row is gone; the header "+" is the
    // only entry and it must still push the wizard.
    expect(find.text('添加同步位置'), findsNothing);
    final add = find.byKey(const Key('plain-location-add'));
    expect(add, findsOneWidget);

    await tapVisible(tester, add);

    expect(find.byType(AddPlainLocation), findsOneWidget);
    expect(
      GoRouterState.of(tester.element(find.byType(AddPlainLocation))).uri.path,
      '/plain-locations/new',
    );
    expect(world.router.canPop(), isTrue);
    expect(find.text('第 1 步，共 3 步'), findsOneWidget);

    // Back returns to the list with the location still there.
    await tapVisible(tester, find.byType(AppBackButton));
    expect(find.byType(AddPlainLocation), findsNothing);
    expect(find.byKey(const Key('plain-location-run-plain-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the location card lines up with the page text', (tester) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile();
    await world.refreshListView();

    // BackupCard owns the page's 16pt horizontal margin. Wrapping it in another
    // page inset made the card surface visibly narrower than the intro text, so
    // the surface must line up with the paragraph above it.
    final intro = tester.getRect(find.textContaining('每个同步位置把本机'));
    final card = tester.getRect(find.byType(BackupCard).first);
    const pageInset = AppSpacing.page;
    expect(card.left, 0);
    expect(
      card.right,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );
    expect(card.left + pageInset, intro.left);
    expect(card.right - pageInset, intro.right);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a freshly created location syncs for the first time by itself', (
    tester,
  ) async {
    final ran = <String>[];
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
      // The real picker needs a folder to offer; everything else is default.
      folderListing: (segments) async => segments.isEmpty
          ? const [WebDavBackupFolder(name: '手机备份')]
          : const [WebDavBackupFolder(name: '照片')],
      plainRun: (profileId) async {
        ran.add(profileId);
        return completedPlainRun();
      },
    );

    // Create one through the real wizard: local folder, remote folder, create.
    await tapVisible(tester, find.byKey(const Key('plain-location-add')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-pick-local')));
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-1')));
    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
    // The picker is pushed as its own route and lists the connection root one
    // frame later.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-folder-手机备份')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));
    // Step 3 is longer than the viewport, so the create button must be
    // scrolled into view before it exists.
    await scrollAndTap(tester, find.byKey(const Key('plain-wizard-create')));
    await tester.pumpAndSettle();

    // Back on the list, the new location already started its first sync: the
    // promise of the wizard is that both sides begin matching.
    expect(find.byType(AddPlainLocation), findsNothing);
    expect(await world.listProfiles(), hasLength(1));
    expect(ran, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('direction badge follows the stored direction', (tester) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile(
      profileId: 'plain-up',
      displayName: '只上传位置',
      direction: MirrorDirection.uploadOnly,
    );
    await world.seedPlainProfile(
      profileId: 'plain-down',
      displayName: '只下载位置',
      direction: MirrorDirection.downloadOnly,
    );
    await world.refreshListView();

    expect(
      find.descendant(of: locationCard('只上传位置'), matching: find.text('仅上传')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: locationCard('只下载位置'), matching: find.text('仅下载')),
      findsOneWidget,
    );
    expect(find.text('双向同步'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('held deletions ask for confirmation instead of syncing', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile();
    await world.seedMirrorRun(heldDeletionCount: 3);
    await world.refreshListView();

    final card = locationCard('照片同步');
    expect(
      find.descendant(of: card, matching: find.text('有删除等待确认')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('检测到 3 项删除，超过安全阈值，已暂停删除。确认后才会执行。'),
      ),
      findsOneWidget,
    );
    // The primary action uses plainLocationStatus' confirm wording, not the
    // ordinary "sync now" label.
    final primary = tester.widget<BackupActionButton>(
      find.byKey(const Key('plain-location-run-plain-1')),
    );
    expect(primary.label, '查看并确认');
    expect(primary.onPressed, isNotNull);
    expect(
      find.descendant(of: card, matching: find.text('立即同步')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a running location shows inline progress instead of a modal dialog',
    (tester) async {
      final pending = Completer<MirrorRunOutcome>();
      final world = await pumpPlainSyncApp(
        tester,
        connections: [webDavConnection()],
        plainRun: (_) => pending.future,
      );
      await world.seedPlainProfile();
      await world.refreshListView();

      final primary = find.byKey(const Key('plain-location-run-plain-1'));
      await tester.ensureVisible(primary);
      await tester.pumpAndSettle();
      await tester.tap(primary);
      // The busy button animates a spinner forever, so pump explicit frames.
      await tester.pump();

      expect(find.text('正在同步…'), findsOneWidget);
      final busyButton = tester.widget<BackupActionButton>(primary);
      expect(busyButton.busy, isTrue);
      expect(busyButton.onPressed, isNull);
      // The only spinner on screen belongs to that button.
      expect(
        find.descendant(
          of: primary,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Nothing blocks the page while the run is in flight.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);

      pending.complete(completedPlainRun());
      await tester.pumpAndSettle();

      final idleButton = tester.widget<BackupActionButton>(primary);
      expect(idleButton.busy, isFalse);
      expect(idleButton.onPressed, isNotNull);
      expect(find.text('正在同步…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a paused location resumes from its own card', (tester) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile(state: PlainFolderProfileState.paused);
    await world.refreshListView();

    final card = locationCard('照片同步');
    expect(
      find.descendant(of: card, matching: find.text('已暂停')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('不会自动同步；点“继续”后恢复。')),
      findsOneWidget,
    );
    final primary = find.byKey(const Key('plain-location-run-plain-1'));
    expect(tester.widget<BackupActionButton>(primary).label, '继续');

    await tapVisible(tester, primary);

    expect(
      (await world.readProfile('plain-1'))?.state,
      PlainFolderProfileState.active,
    );
    expect(
      tester.widget<BackupActionButton>(primary).label,
      '立即同步',
      reason: 'an active location offers the ordinary sync action again',
    );
    expect(find.descendant(of: card, matching: find.text('已暂停')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired encrypted tasks no longer appear on the files tab', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
    );
    await world.seedPlainProfile();
    await _seedLegacyEncryptedProfile(world.database);
    await world.refreshListView();

    // The plain location still renders on its own.
    expect(find.text('照片同步'), findsOneWidget);
    expect(find.byKey(const Key('plain-location-run-plain-1')), findsOneWidget);
    expect(
      find.descendant(of: locationCard('照片同步'), matching: find.text('双向同步')),
      findsOneWidget,
    );

    // The retired encrypted task is not shown, advertised or manageable here:
    // its only entry point is Settings.
    expect(find.text('旧版加密文件夹同步'), findsNothing);
    expect(find.text('旧工作文件夹'), findsNothing);
    expect(find.byKey(const Key('legacy-encrypted-manage')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming held deletions shows the paths and approves only them', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
      plainRun: (profileId) async =>
          heldPlainRun(paths: const ['照片/a.jpg', '照片/b.jpg']),
    );
    final profile = await world.seedPlainProfile();
    await world.refreshListView();

    final primary = find.byKey(Key('plain-location-run-${profile.profileId}'));
    await tester.ensureVisible(primary);
    await tester.pumpAndSettle();
    await tester.tap(primary);
    // The card's button keeps a spinner while the run and the review are open,
    // so settle explicitly with frames instead of pumpAndSettle.
    await _settleFrames(tester);

    // The review names the files instead of only counting them: the user is
    // about to delete them.
    expect(find.byKey(const Key('plain-confirm-deletions')), findsOneWidget);
    expect(find.textContaining('照片/a.jpg'), findsOneWidget);
    expect(find.textContaining('照片/b.jpg'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plain-confirm-deletions')));
    await _settleFrames(tester);

    // The deletion pass carries exactly the reviewed paths, so a plan that grew
    // since the review can never be executed.
    expect(world.runService!.confirmedDeletionCalls, 1);
    expect(world.runService!.confirmedPathSets.single, {
      '照片/a.jpg',
      '照片/b.jpg',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling held deletions deletes nothing', (tester) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
      plainRun: (profileId) async => heldPlainRun(paths: const ['照片/a.jpg']),
    );
    final profile = await world.seedPlainProfile();
    await world.refreshListView();

    final primary = find.byKey(Key('plain-location-run-${profile.profileId}'));
    await tester.ensureVisible(primary);
    await tester.pumpAndSettle();
    await tester.tap(primary);
    await _settleFrames(tester);
    await tapVisible(tester, find.text('先不删除'), settle: false);
    await _settleFrames(tester);

    expect(world.runService!.confirmedDeletionCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

/// A pre-plain-sync encrypted folder task, saved exactly like production does.
///
/// It must never appear on the files tab again: the retired protocol has no
/// entry point, and `isBackgroundEligible` excludes it so it cannot run either.
Future<void> _seedLegacyEncryptedProfile(SyncStateDatabase database) =>
    SyncProfileRepository(database).save(
      SyncProfileEnvelope(
        kind: SyncDatasetKind.selectedFolder,
        profileId: 'legacy-folder',
        datasetId: 'legacy-dataset',
        vaultId: 'legacy-vault',
        deviceId: 'this-device',
        displayName: '旧工作文件夹',
        connectionId: 'conn-1',
        state: SyncProfileState.active,
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        dataset: const {
          'schemaVersion': 1,
          'pairedProducerId': 'source',
          'pairedProducerPublicKey':
              'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        },
        createdAt: DateTime.utc(2026, 9, 20),
      ),
    );

/// Advances a fixed number of frames.
///
/// The card's running button animates a spinner for as long as the run (and the
/// deletion review) is open, so `pumpAndSettle` would never return.
Future<void> _settleFrames(WidgetTester tester, {int frames = 12}) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
