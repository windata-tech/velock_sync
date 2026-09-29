/// Visual QA for the deletion-protection card, in both real states.
///
/// Run with a real CJK font and an output directory:
///   BACKUP_UI_FONT=/System/Library/Fonts/STHeiti\ Medium.ttc \
///   BACKUP_UI_SCREENSHOT_DIR=/tmp/deletion-protection-qa \
///   flutter test test/features/sync_profiles/deletion_protection_visual_qa_test.dart
///
/// Without those variables the test still runs (and asserts both states render)
/// but writes no files.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_settings.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart'
    show GarbageCollectionDiagnostics;
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';

void main() {
  final captureKey = GlobalKey();

  setUpAll(() async {
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null && File(font).existsSync()) {
      final bytes = File(font).readAsBytes();
      for (final family in const ['DelQA', 'Roboto']) {
        final loader = FontLoader(family)
          ..addFont(bytes.then((b) => ByteData.sublistView(b)));
        await loader.load();
      }
    }
    for (final entry in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      final icons = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await icons.load();
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['BACKUP_UI_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('captures the deletion-protection card in three states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // State 1: the shipped device state on 2026-09-27 — every pass skipped at
    // `checkpoint-missing`, counts never measured.
    await _pumpSettings(tester, captureKey, _skippedGc());
    await _scrollToCard(tester);
    expect(find.text('尚未生效'), findsOneWidget);
    expect(find.text('尚未执行'), findsOneWidget);
    expect(find.text('尚未统计'), findsNWidgets(2));
    expect(find.textContaining('上次检查：'), findsOneWidget);
    await capture(tester, '01-deletion-protection-blocked');

    // State 2: the first real pass after the recovery fix (2026-09-27 10:37).
    // The checkpoint and the candidate are real, but the retention window has
    // not passed, so nothing was reclaimed: a completed check, not a cleanup.
    await _pumpSettings(tester, captureKey, _checkedNothingDueGc());
    await _scrollToCard(tester);
    expect(find.text('已开启'), findsOneWidget);
    expect(find.text('尚未执行'), findsOneWidget);
    expect(find.text('0 台设备'), findsOneWidget);
    expect(find.text('1 台'), findsOneWidget);
    expect(find.textContaining('已删除 0 个对象'), findsOneWidget);
    await capture(tester, '02-deletion-protection-checked-nothing-due');

    // State 3: a pass that really reclaimed objects, which is the only state
    // allowed to show a cleanup time.
    await _pumpSettings(tester, captureKey, _cleanedGc());
    await _scrollToCard(tester);
    expect(find.text('已开启'), findsOneWidget);
    expect(find.text('尚未执行'), findsNothing);
    expect(find.textContaining('已删除 3 个对象'), findsOneWidget);
    expect(find.text('尚未统计'), findsNothing);
    await capture(tester, '03-deletion-protection-cleaned');
  });
}

Future<void> _scrollToCard(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('最近清理'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(
  WidgetTester tester,
  GlobalKey captureKey,
  GarbageCollectionDiagnostics? gc,
) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        syncSettingsServiceProvider.overrideWithValue(_QaSettingsService(gc)),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [
          ...GlobalMaterialLocalizations.delegates,
        ],
        theme: _qaTheme(),
        builder: (context, child) =>
            RepaintBoundary(key: captureKey, child: child!),
        home: const SyncSettings(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

GarbageCollectionDiagnostics _skippedGc() => GarbageCollectionDiagnostics(
  runId: 'gc-skipped',
  profileId: 'profile-1',
  vaultId: 'vault-1',
  state: 'skipped',
  startedAt: DateTime.utc(2026, 9, 27, 2, 16, 21),
  completedAt: DateTime.utc(2026, 9, 27, 2, 16, 21),
  checkpointId: null,
  retentionCutoff: null,
  activeDeviceCount: 0,
  unackedDeviceCount: 0,
  candidateCount: 0,
  eligibleCandidateCount: 0,
  deletedObjectCount: 0,
  retentionManifestComplete: null,
  planId: null,
  skipReason: 'checkpoint-missing',
);

GarbageCollectionDiagnostics _checkedNothingDueGc() =>
    GarbageCollectionDiagnostics(
      runId: 'gc-checked',
      profileId: 'profile-1',
      vaultId: 'vault-1',
      state: 'completed',
      startedAt: DateTime.utc(2026, 9, 27, 2, 37, 34),
      completedAt: DateTime.utc(2026, 9, 27, 2, 37, 35),
      checkpointId: 'v1-54c5db05cb5c7ea2ee875505e1cee346',
      retentionCutoff: DateTime.utc(2026, 8, 21),
      activeDeviceCount: 1,
      unackedDeviceCount: 0,
      candidateCount: 1,
      eligibleCandidateCount: 0,
      deletedObjectCount: 0,
      retentionManifestComplete: true,
      planId: null,
      skipReason: null,
    );

GarbageCollectionDiagnostics _cleanedGc() => GarbageCollectionDiagnostics(
  runId: 'gc-completed',
  profileId: 'profile-1',
  vaultId: 'vault-1',
  state: 'completed',
  startedAt: DateTime.utc(2026, 9, 27, 2, 16, 21),
  completedAt: DateTime.utc(2026, 9, 27, 2, 16, 23),
  checkpointId: 'v1-54c5db05cb5c7ea2ee875505e1cee346',
  retentionCutoff: DateTime.utc(2026, 8, 21),
  activeDeviceCount: 1,
  unackedDeviceCount: 1,
  candidateCount: 4,
  eligibleCandidateCount: 1,
  deletedObjectCount: 3,
  retentionManifestComplete: true,
  planId: 'plan-1',
  skipReason: null,
);

class _QaSettingsService implements SyncSettingsService {
  _QaSettingsService(this.garbageCollection);

  final GarbageCollectionDiagnostics? garbageCollection;

  @override
  Future<SyncSettingsSnapshot> load() async => SyncSettingsSnapshot(
    settings: const SyncGlobalSettings(backgroundEnabled: true),
    backgroundSupported: true,
    backgroundEligibleProfileCount: 1,
    staging: const StagingSpaceSummary(),
    garbageCollection: garbageCollection,
  );

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) => load();

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async =>
      const SyncSettingsCleanupSummary();

  @override
  Future<String> exportSanitizedDiagnostics() async => '{}';
}

/// A CJK font everywhere, including the Cupertino styles the page resolves for
/// itself.
ThemeData _qaTheme() {
  final cupertino = CupertinoTextThemeData(
    textStyle: const CupertinoTextThemeData().textStyle.copyWith(
      fontFamily: 'DelQA',
    ),
    navTitleTextStyle: const CupertinoTextThemeData().navTitleTextStyle
        .copyWith(fontFamily: 'DelQA'),
    navLargeTitleTextStyle: const CupertinoTextThemeData()
        .navLargeTitleTextStyle
        .copyWith(fontFamily: 'DelQA'),
    actionTextStyle: const CupertinoTextThemeData().actionTextStyle.copyWith(
      fontFamily: 'DelQA',
    ),
    tabLabelTextStyle: const CupertinoTextThemeData().tabLabelTextStyle
        .copyWith(fontFamily: 'DelQA'),
  );
  return ThemeData(
    platform: TargetPlatform.iOS,
    fontFamily: 'DelQA',
    cupertinoOverrideTheme: CupertinoThemeData(textTheme: cupertino),
  );
}
