/// Widget tests for one plain (unencrypted) folder sync location's detail page.
///
/// The page is opened through the real router from the files tab, so removal
/// also verifies that the route pops back to the list.
library;

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart'
    show AlertDialog, CircularProgressIndicator;
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_detail.dart';

import 'plain_sync_test_support.dart';

const _profileId = 'plain-1';

void main() {
  /// Mounts the files tab, seeds one bidirectional location and opens it.
  Future<PlainSyncWorld> openDetail(
    WidgetTester tester, {
    MirrorDirection direction = MirrorDirection.bidirectional,
    MirrorConflictPolicy conflictPolicy = MirrorConflictPolicy.keepBoth,
    PlainFolderProfileState state = PlainFolderProfileState.active,
    List<MirrorBaselineEntry> baseline = const [],
    Locale locale = const Locale('zh'),
    Size surface = const Size(390, 844),
    Future<MirrorRunOutcome> Function(String profileId)? plainRun,
  }) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
      locale: locale,
      surface: surface,
      plainRun: plainRun,
    );
    await world.seedPlainProfile(
      profileId: _profileId,
      direction: direction,
      conflictPolicy: conflictPolicy,
      state: state,
      baseline: baseline,
    );
    // The tab already read the (empty) list, so re-read it after seeding.
    await world.refreshListView();
    world.router.push<void>('/plain-locations/$_profileId');
    await tester.pumpAndSettle();
    expect(find.byType(PlainLocationDetail), findsOneWidget);
    return world;
  }

  testWidgets('both halves can be opened before being changed', (tester) async {
    final launched = <Uri>[];
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
      folderLauncher: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    await world.seedPlainProfile(profileId: _profileId);
    await world.refreshListView();
    world.router.push<void>('/plain-locations/$_profileId');
    await tester.pumpAndSettle();

    // The local folder is handed to the system file manager.
    final openLocal = find.byKey(const Key('plain-local-open'));
    expect(openLocal, findsOneWidget);
    await tapVisible(tester, openLocal);
    // Percent-encoded URL path, decoding back to the chosen folder.
    expect(Uri.decodeComponent(launched.single.path), testLocalFolder.path);
    expect(launched.single.scheme, 'file');
    // Opening is a side action: the page stays where it was.
    expect(find.byType(PlainLocationDetail), findsOneWidget);
    expect(find.byKey(const Key('plain-local-change')), findsOneWidget);

    // The remote folder opens in the app's own browser, scoped to the folder
    // this location mirrors (not the connection root).
    final openRemote = find.byKey(const Key('plain-remote-open'));
    expect(openRemote, findsOneWidget);
    await tapVisible(tester, openRemote);
    expect(find.byType(Connection), findsOneWidget);
    expect(tester.widget<Connection>(find.byType(Connection)).initialSegments, [
      'photos',
      'phone',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail shows both halves, the current direction and conflicts', (
    tester,
  ) async {
    await openDetail(tester);

    // Both halves of the location.
    final local = find.byKey(const Key('plain-local-folder'));
    expect(local, findsOneWidget);
    expect(
      find.descendant(of: local, matching: find.text('本机文件夹')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: local, matching: find.text(testLocalFolderName)),
      findsOneWidget,
    );
    final remote = find.byKey(const Key('plain-remote-folder'));
    expect(remote, findsOneWidget);
    expect(
      find.descendant(of: remote, matching: find.text('远端文件夹')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: remote, matching: find.text('我的 NAS/photos/phone')),
      findsOneWidget,
    );

    // Every direction is listed, and only the stored one is marked.
    for (final value in MirrorDirection.values) {
      expect(
        find.byKey(Key('plain-detail-direction-${value.name}')),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('plain-detail-direction-bidirectional')),
        matching: find.byIcon(CupertinoIcons.checkmark_alt_circle_fill),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('plain-detail-direction-uploadOnly')),
        matching: find.byIcon(CupertinoIcons.circle),
      ),
      findsOneWidget,
    );

    // Conflicts are configurable for a two-way location, and the stored policy
    // is marked.
    expect(find.text('冲突处理'), findsOneWidget);
    for (final value in MirrorConflictPolicy.values) {
      expect(
        find.byKey(Key('plain-detail-conflict-${value.name}')),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('plain-detail-conflict-keepBoth')),
        matching: find.byIcon(CupertinoIcons.checkmark_alt_circle_fill),
      ),
      findsOneWidget,
    );
    // Both primary actions exist while the location is active.
    expect(find.byKey(const Key('plain-detail-run')), findsOneWidget);
    expect(find.byKey(const Key('plain-detail-pause')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing the direction persists and hides the conflict section',
    (tester) async {
      final world = await openDetail(tester);

      await tapVisible(
        tester,
        find.byKey(const Key('plain-detail-direction-uploadOnly')),
      );

      // Nothing is written yet: the draft waits for the header's save action.
      expect(
        (await world.readProfile(_profileId))?.direction,
        MirrorDirection.bidirectional,
      );
      expect(find.byKey(const Key('plain-detail-save')), findsOneWidget);
      // One-way sync never asks about conflicts.
      expect(find.text('冲突处理'), findsNothing);
      for (final value in MirrorConflictPolicy.values) {
        expect(
          find.byKey(Key('plain-detail-conflict-${value.name}')),
          findsNothing,
        );
      }
      // The stored direction is the marked one now.
      expect(
        find.descendant(
          of: find.byKey(const Key('plain-detail-direction-uploadOnly')),
          matching: find.byIcon(CupertinoIcons.checkmark_alt_circle_fill),
        ),
        findsOneWidget,
      );

      // Switching back restores the section with the policy still in place.
      await tapVisible(
        tester,
        find.byKey(const Key('plain-detail-direction-bidirectional')),
      );
      expect(find.text('冲突处理'), findsOneWidget);
      // Back to the stored value: there is nothing left to save.
      expect(find.byKey(const Key('plain-detail-save')), findsNothing);

      // Saving writes the draft through and clears the action.
      await tapVisible(
        tester,
        find.byKey(const Key('plain-detail-direction-uploadOnly')),
      );
      await tapVisible(tester, find.byKey(const Key('plain-detail-save')));
      final restored = await world.readProfile(_profileId);
      expect(restored?.direction, MirrorDirection.uploadOnly);
      expect(restored?.conflictPolicy, MirrorConflictPolicy.keepBoth);
      expect(find.byKey(const Key('plain-detail-save')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing the conflict policy persists', (tester) async {
    final world = await openDetail(tester);

    await tapVisible(
      tester,
      find.byKey(const Key('plain-detail-conflict-preferRemote')),
    );

    // The row marks the draft, the record still holds the old value ...
    expect(find.byKey(const Key('plain-detail-save')), findsOneWidget);
    expect(
      (await world.readProfile(_profileId))?.conflictPolicy,
      MirrorConflictPolicy.keepBoth,
    );

    // ... until the header saves it.
    await tapVisible(tester, find.byKey(const Key('plain-detail-save')));
    final stored = await world.readProfile(_profileId);
    expect(stored?.conflictPolicy, MirrorConflictPolicy.preferRemote);
    expect(stored?.direction, MirrorDirection.bidirectional);
    expect(
      find.descendant(
        of: find.byKey(const Key('plain-detail-conflict-preferRemote')),
        matching: find.byIcon(CupertinoIcons.checkmark_alt_circle_fill),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving with an unsaved draft asks before dropping it', (
    tester,
  ) async {
    final world = await openDetail(tester);

    await tapVisible(
      tester,
      find.byKey(const Key('plain-detail-direction-uploadOnly')),
    );

    // Cancelling the prompt keeps the page, the draft and the stored value.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存这次修改？'), findsOneWidget);
    await tapVisible(tester, find.text('取消'));
    expect(find.byType(PlainLocationDetail), findsOneWidget);
    expect(
      (await world.readProfile(_profileId))?.direction,
      MirrorDirection.bidirectional,
    );
    expect(find.byKey(const Key('plain-detail-save')), findsOneWidget);

    // Discarding leaves without writing the draft.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-draft-discard')));
    await tester.pumpAndSettle();
    expect(find.byType(PlainLocationDetail), findsNothing);
    expect(
      (await world.readProfile(_profileId))?.direction,
      MirrorDirection.bidirectional,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a dirty page can save the draft on the way out', (
    tester,
  ) async {
    final world = await openDetail(tester);

    await tapVisible(
      tester,
      find.byKey(const Key('plain-detail-conflict-preferLocal')),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('plain-draft-save')));
    await tester.pumpAndSettle();

    expect(find.byType(PlainLocationDetail), findsNothing);
    final stored = await world.readProfile(_profileId);
    expect(stored?.conflictPolicy, MirrorConflictPolicy.preferLocal);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clean page leaves without any prompt', (tester) async {
    await openDetail(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('保存这次修改？'), findsNothing);
    expect(find.byType(PlainLocationDetail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pausing from the detail page persists in place', (tester) async {
    final world = await openDetail(tester);

    await tapVisible(tester, find.byKey(const Key('plain-detail-pause')));

    final stored = await world.readProfile(_profileId);
    expect(stored?.state, PlainFolderProfileState.paused);
    expect(find.byKey(const Key('plain-detail-pause')), findsNothing);
    expect(
      tester
          .widget<BackupActionButton>(find.byKey(const Key('plain-detail-run')))
          .label,
      '继续同步',
    );
    expect(find.text('已暂停'), findsOneWidget);

    // Resuming uses the repository's own state transition, so the same page can
    // put the location back to work.
    await tapVisible(tester, find.byKey(const Key('plain-detail-run')));
    expect(
      (await world.readProfile(_profileId))?.state,
      PlainFolderProfileState.active,
    );
    expect(
      tester
          .widget<BackupActionButton>(find.byKey(const Key('plain-detail-run')))
          .label,
      '立即同步',
    );
    expect(find.text('已暂停'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a running detail page shows inline progress instead of a modal dialog',
    (tester) async {
      final pending = Completer<MirrorRunOutcome>();
      final world = await openDetail(tester, plainRun: (_) => pending.future);

      final primary = find.byKey(const Key('plain-detail-run'));
      await tapVisible(tester, primary, settle: false);

      expect(find.text('正在同步…'), findsOneWidget);
      final busyButton = tester.widget<BackupActionButton>(primary);
      expect(busyButton.busy, isTrue);
      expect(busyButton.onPressed, isNull);
      // The paired secondary action stays disabled too, and the only spinner on
      // screen belongs to the busy button.
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('plain-detail-pause')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
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
      expect(world.tester.takeException(), isNull);
    },
  );

  testWidgets('removal confirms first, clears the baseline and pops', (
    tester,
  ) async {
    final world = await openDetail(
      tester,
      baseline: [
        MirrorBaselineEntry(
          relativePath: 'notes.txt',
          kind: MirrorEntryKind.file,
          localSize: 12,
          remoteSize: 12,
          syncedAt: DateTime.utc(2026, 9, 27),
        ),
      ],
    );
    expect(await world.database.readMirrorEntries(_profileId), hasLength(1));

    final remove = find.byKey(const Key('plain-remove'));
    await scrollAndTap(tester, remove);

    // The confirmation explains what is and is not deleted.
    expect(find.text('删除这个同步位置？'), findsOneWidget);
    expect(
      find.text('只删除本机的同步配置和同步记录。本机文件夹和远端文件夹里的文件都不会被删除，也不会被改动。'),
      findsOneWidget,
    );

    // Cancelling keeps the location and its baseline.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plain-remove-confirm')), findsNothing);
    expect(await world.listProfiles(), hasLength(1));
    expect(await world.database.readMirrorEntries(_profileId), hasLength(1));

    await scrollAndTap(tester, remove);
    await tester.tap(find.byKey(const Key('plain-remove-confirm')));
    await tester.pumpAndSettle();

    // Confirming removes the location: hidden from every list, row retained.
    expect(find.byType(PlainLocationDetail), findsNothing);
    expect(await world.listProfiles(), isEmpty);
    expect(await world.readProfile(_profileId), isNull);
    expect(
      await world.database.readVisibleSyncProfilePayload(_profileId),
      isNull,
    );
    expect(
      await world.database.readSyncProfilePayload(_profileId),
      isNotNull,
      reason: 'the durable row is retained, only its state becomes removed',
    );
    // ...and its mirror baseline is gone, so a later location cannot inherit it.
    expect(await world.database.readMirrorEntries(_profileId), isEmpty);
    // The tab is showing its empty state again.
    expect(find.text('添加第一个同步位置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final locale in const [Locale('zh'), Locale('en')]) {
    testWidgets('detail states the remote folder is not encrypted ($locale)', (
      tester,
    ) async {
      // The English labels are wider, and the status-badge Row in the detail
      // status card (`plain_location_detail.dart:574-590`) has no flex or wrap
      // fallback: with the monospace test font it overflows the 390px phone by
      // 16px. A 430px wide phone gives the same page the room its own layout
      // assumes (see the report for the file:line).
      await openDetail(tester, locale: locale, surface: const Size(430, 932));

      expect(
        find.text(
          locale.languageCode == 'zh'
              ? '远端是明文文件夹：能访问这个云端账号的人都能看到和修改这些文件。'
              : 'The remote folder is not encrypted: anyone with access to that cloud account can read and change these files.',
        ),
        findsOneWidget,
      );
      // The encryption claim is made about the remote side only, and the page
      // keeps the location's own name.
      expect(find.text('照片同步'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
