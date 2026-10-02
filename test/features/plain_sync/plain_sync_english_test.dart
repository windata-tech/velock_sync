/// English-locale coverage for the two plain (unencrypted) sync pages.
///
/// Both pages are built from `syncText`, except for a few leftovers that leaked
/// Chinese onto an English device:
///
/// * the screen-reader labels of the loading states
///   (`plain_sync_home.dart`, `plain_location_detail.dart`), and
/// * the "remote connection deleted" row, whose Chinese fallback used to be
///   produced in `plain_sync_providers.dart` before the UI localized it.
///
/// These tests render the real pages with `Locale('en')` and fail if any CJK
/// character is painted or announced. The last test pins the fact behind the
/// settings page's 新配置默认策略 footer: a new location really is stored with
/// background sync off, so that footer's wording is the truthful one.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/features/plain_sync/ui/add_plain_location.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_detail.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_sync_home.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

import 'plain_sync_test_support.dart';

const _profileId = 'plain-1';
const _remoteName = 'Home NAS';

final _cjk = RegExp(r'[\u4e00-\u9fff]');

void main() {
  testWidgets('the files tab paints no Chinese on an English device', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      locale: const Locale('en'),
      // No connection rows at all: the location's connection was deleted, which
      // is the case that used to fall back to a Chinese string.
      connections: const [],
    );
    await world.seedPlainProfile(
      profileId: _profileId,
      displayName: 'Phone photos',
      localDisplayName: 'Photos',
      connectionId: 'conn-gone',
    );
    await world.refreshListView();

    expect(find.byType(PlainSyncHome), findsOneWidget);
    expect(find.text('Remote connection deleted'), findsOneWidget);
    expect(find.text('File sync'), findsWidgets);
    expect(find.text('Sync now'), findsOneWidget);

    final seen = await _scanPages(tester);
    expect(seen, contains('Details'));
    expect(seen, contains('This device'));
  });

  testWidgets('the card labels stay on one line and the paths line up', (
    tester,
  ) async {
    // The label column used to be a fixed 34pt: enough for 本机/远端, but
    // English broke it into "This devi / ce" and "Rem / ote".
    final world = await pumpPlainSyncApp(
      tester,
      locale: const Locale('en'),
      connections: [webDavConnection(name: _remoteName)],
    );
    await world.seedPlainProfile(
      profileId: _profileId,
      displayName: 'Phone photos',
      localDisplayName: 'Photos',
    );
    await world.refreshListView();

    for (final label in const ['This device', 'Remote']) {
      final line = tester.getSize(find.text(label));
      final style = tester.widget<Text>(find.text(label)).style!;
      expect(
        line.height,
        lessThan(style.fontSize! * 2),
        reason: '"$label" wrapped onto more than one line',
      );
    }
    final local = tester.getTopLeft(find.text('Photos')).dx;
    final remote = tester
        .getTopLeft(
          find.textContaining(RegExp('^${RegExp.escape(_remoteName)}')),
        )
        .dx;
    expect(local, closeTo(remote, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the location detail page paints no Chinese in English', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      locale: const Locale('en'),
      connections: const [],
    );
    await world.seedPlainProfile(
      profileId: _profileId,
      displayName: 'Phone photos',
      localDisplayName: 'Photos',
      connectionId: 'conn-gone',
    );
    await world.refreshListView();
    world.router.push<void>('/plain-locations/$_profileId');
    await tester.pumpAndSettle();
    expect(find.byType(PlainLocationDetail), findsOneWidget);
    expect(find.text('Remote connection deleted'), findsOneWidget);

    final seen = await _scanPages(tester);
    for (final label in const [
      'This location',
      'Local folder',
      'Remote folder',
      'Direction',
      'Last sync',
      'Background policy',
      'Danger zone',
    ]) {
      expect(seen, contains(label), reason: 'missing row: $label');
    }
  });

  testWidgets('both loading states announce themselves in English', (
    tester,
  ) async {
    // A never-completing read keeps both pages on their loading state, where
    // the only user-facing string is the screen-reader label.
    final pending = Completer<List<PlainLocationView>>();
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);

    await _pumpEnglish(
      tester,
      home: const PlainSyncHome(),
      scope: (home) => ProviderScope(
        key: UniqueKey(),
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(database),
          plainLocationViewsProvider.overrideWith((ref) => pending.future),
        ],
        child: home,
      ),
    );
    await tester.pump();
    expect(find.byType(AdaptiveLoadingState), findsOneWidget);
    expect(_semanticLabels(tester), contains('Loading sync locations'));
    _expectNoChinese(tester);

    await _pumpEnglish(
      tester,
      home: const PlainLocationDetail(profileId: _profileId),
      scope: (home) => ProviderScope(
        key: UniqueKey(),
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(database),
          plainLocationViewsProvider.overrideWith((ref) => pending.future),
        ],
        child: home,
      ),
    );
    await tester.pump();
    expect(find.byType(AdaptiveLoadingState), findsOneWidget);
    expect(_semanticLabels(tester), contains('Loading sync location'));
    _expectNoChinese(tester);
  });

  testWidgets('a new sync location really starts with background sync off', (
    tester,
  ) async {
    // Pins the fact the settings page's 新配置默认策略 footer states: the wizard
    // creates the location with `backgroundPolicy.enabled = false`, so the
    // footer has to tell the user to turn 后台同步 on themselves. If this ever
    // becomes true, that footer must change with it.
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection()],
      platform: TargetPlatform.android,
      folderListing: (segments) async => [
        WebDavBackupFolder(name: segments.isEmpty ? 'Mirror' : 'Photos'),
      ],
    );
    world.wizardPop = world.router.push<bool>('/plain-locations/new');
    await tester.pumpAndSettle();
    expect(find.byType(AddPlainLocation), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('plain-pick-local')));
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-1')));
    await tapVisible(tester, find.byKey(const Key('plain-remote-conn-1')));
    await tester.tap(find.byKey(const ValueKey('backup-folder-Mirror')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('plain-wizard-next-2')));
    await scrollAndTap(tester, find.byKey(const Key('plain-wizard-create')));

    final profiles = await world.listProfiles();
    expect(profiles, hasLength(1));
    expect(
      profiles.single.backgroundEnabled,
      isFalse,
      reason:
          'the settings footer promises this switch still has to be turned on',
    );
    expect(profiles.single.remoteRootSegments, ['Mirror']);
    expect(tester.takeException(), isNull);
  });
}

/// Scrolls the page top to bottom, checking every frame, and returns every text
/// the page built on the way (the pages are lazily laid out lists).
Future<Set<String>> _scanPages(WidgetTester tester, {int steps = 12}) async {
  final seen = <String>{};
  for (var step = 0; step <= steps; step++) {
    _expectNoChinese(tester);
    seen.addAll(
      tester.widgetList<Text>(find.byType(Text)).map((text) => text.data ?? ''),
    );
    seen.addAll(_semanticLabels(tester));
    if (step == steps) break;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
    await tester.pumpAndSettle();
  }
  return seen;
}

/// Pumps one page directly, in an English app wrapped by [scope].
Future<void> _pumpEnglish(
  WidgetTester tester, {
  required Widget home,
  required ProviderScope Function(Widget home) scope,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    scope(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home,
      ),
    ),
  );
}

Iterable<String> _semanticLabels(WidgetTester tester) => tester
    .widgetList<Semantics>(find.byType(Semantics))
    .map((widget) => widget.properties.label)
    .whereType<String>();

/// Nothing on these pages may be Chinese in en: not painted text, and not a
/// screen-reader label. Folder names are the user's own data, which is why the
/// fixtures above use English names.
void _expectNoChinese(WidgetTester tester) {
  for (final data
      in tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')) {
    expect(
      _cjk.hasMatch(data),
      isFalse,
      reason: 'Chinese text is still painted in en: “$data”',
    );
  }
  for (final label in _semanticLabels(tester)) {
    expect(
      _cjk.hasMatch(label),
      isFalse,
      reason: 'Chinese semantics label is still announced in en: “$label”',
    );
  }
}
