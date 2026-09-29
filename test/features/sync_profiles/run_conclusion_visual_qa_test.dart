/// Visual QA for the run conclusion (“无需传输” vs “已完成”).
///
/// Run with a real CJK font and an output directory:
///   BACKUP_UI_FONT=/System/Library/Fonts/STHeiti\ Medium.ttc \
///   BACKUP_UI_SCREENSHOT_DIR=/tmp/run-conclusion-qa \
///   flutter test test/features/sync_profiles/run_conclusion_visual_qa_test.dart
///
/// Without those variables the test still runs (and asserts the screens render)
/// but writes no files.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

const _profileId = 'velock-profile';

void main() {
  final captureKey = GlobalKey();

  setUpAll(() async {
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null && File(font).existsSync()) {
      // The popup resolves its own default family, so the same face is
      // registered under the names a Cupertino/Material sheet asks for.
      final bytes = File(font).readAsBytes();
      for (final family in const [
        'RunQA',
        'Roboto',
        '.SF Pro Text',
        '.SF UI Text',
        'CupertinoSystemText',
      ]) {
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

  testWidgets('captures the transfer history and an empty run record', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    await SyncProfileRepository(database).save(_profile());
    await _seedRuns(database);

    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(
      overrides: [
        syncStateDatabaseProvider.overrideWithValue(database),
        syncProfileRepositoryProvider.overrideWithValue(
          SyncProfileRepository(database),
        ),
        velockWizardReadinessServiceProvider.overrideWithValue(
          const _UnavailableReadinessService(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/sync-profiles/$_profileId',
      routes: [
        GoRoute(
          path: '/sync-profiles/:profileId',
          builder: (context, state) =>
              SyncProfileDetail(profileId: state.pathParameters['profileId']!),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
          ],
          theme: _qaTheme(),
          builder: (context, child) =>
              RepaintBoundary(key: captureKey, child: child!),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('无需传输 · '), findsOneWidget);
    await capture(tester, '01-overview-latest-run');

    await tester.ensureVisible(find.text('传输记录'));
    await tester.tap(find.text('传输记录'));
    await tester.pumpAndSettle();
    expect(find.text('无需传输'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    await capture(tester, '02-transfer-history');

    // The sheet gets its own harness: the profile page renders under the
    // Cupertino theme, which resolves a font stack the QA override is not part
    // of, so a sheet opened on top of it would capture placeholder glyphs.
    await tester.pumpWidget(_sheetHarness(captureKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开记录'));
    await tester.pumpAndSettle();
    expect(find.text('同步记录 · 无需传输'), findsOneWidget);
    expect(find.text('上传对象'), findsOneWidget);
    await capture(tester, '03-run-record-nothing-to-transfer');
  });
}

/// A run record with nothing transferred, on a plain screen.
Widget _sheetHarness(GlobalKey captureKey) {
  final run = SyncRunRecord(
    runId: 'run-nothing',
    profileId: _profileId,
    state: 'completed',
    startedAt: DateTime.utc(2026, 9, 26, 22, 27),
    completedAt: DateTime.utc(2026, 9, 26, 22, 27, 4),
    errorCode: null,
    errorCategory: null,
    retryable: null,
    retryAfter: null,
    suggestedAction: null,
    providerStatusCode: null,
  );
  // The iOS sheet variant reaches for a provider, so the harness needs a
  // scope of its own.
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [...GlobalMaterialLocalizations.delegates],
      theme: _qaTheme(),
      // A Cupertino popup has no Material ancestor of its own, so the sheet
      // inherits this style; without it the QA render shows placeholder glyphs
      // instead of the wording under review.
      builder: (context, child) => RepaintBoundary(
        key: captureKey,
        child: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'RunQA'),
          child: child!,
        ),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: const Color(0xFFF2F2F7),
          body: Center(
            child: TextButton(
              onPressed: () => showRunDetails(context, run),
              child: const Text('打开记录'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// One run that moved an object, one failure, then one run with nothing to
/// move — the newest, so the overview summarises it too.
Future<void> _seedRuns(SyncStateDatabase database) async {
  await database.startSyncRun(
    runId: 'run-moved-object',
    profileId: _profileId,
    startedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
  );
  await database.beginTransferJob(
    transferId: 'transfer-1',
    profileId: _profileId,
    direction: TransferJobDirection.upload,
    logicalKey: 'vault/batches/batch-1',
    expectedSize: 296,
  );
  await database.completeTransferJob(
    transferId: 'transfer-1',
    completedBytes: 296,
  );
  await database.finishSyncRun(
    runId: 'run-moved-object',
    state: 'completed',
    completedAt: DateTime.now().toUtc(),
  );
  // Every later run starts after the object landed, so it is not attributed to
  // them.
  final landedAt = (await database.listTransferHistory(
    profileId: _profileId,
  )).single.completedAt!;

  await database.startSyncRun(
    runId: 'run-failed',
    profileId: _profileId,
    startedAt: landedAt.add(const Duration(milliseconds: 1)),
  );
  await database.finishSyncRun(
    runId: 'run-failed',
    state: 'failed',
    completedAt: landedAt.add(const Duration(milliseconds: 2)),
    failure: const SyncFailure(
      errorCode: 'provider.http.401',
      category: SyncErrorCategory.authenticationRequired,
      retryable: true,
      suggestedAction: 'Sign in again.',
    ),
  );

  await database.startSyncRun(
    runId: 'run-nothing',
    profileId: _profileId,
    startedAt: landedAt.add(const Duration(milliseconds: 3)),
  );
  await database.finishSyncRun(
    runId: 'run-nothing',
    state: 'completed',
    completedAt: landedAt.add(const Duration(milliseconds: 4)),
  );
}

SyncProfileEnvelope _profile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: _profileId,
  datasetId: 'velock-dataset',
  vaultId: 'velock-vault',
  deviceId: 'consumer-device',
  displayName: '家庭 NAS 的格间',
  connectionId: 'connection-1',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'schemaVersion': 1,
    'pairedProducerId': 'producer-device',
    'pairedProducerPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  createdAt: DateTime.utc(2026, 9, 12),
);

class _UnavailableReadinessService implements VelockWizardReadinessService {
  const _UnavailableReadinessService();

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(
        VelockWizardAvailability.temporarilyUnavailable,
      );
}

/// One QA theme for both harnesses: a CJK font everywhere, including the
/// Cupertino styles a bottom sheet resolves for itself.
ThemeData _qaTheme() {
  final cupertino = CupertinoTextThemeData(
    textStyle: const CupertinoTextThemeData().textStyle.copyWith(
      fontFamily: 'RunQA',
    ),
    navTitleTextStyle: const CupertinoTextThemeData().navTitleTextStyle
        .copyWith(fontFamily: 'RunQA'),
    navLargeTitleTextStyle: const CupertinoTextThemeData()
        .navLargeTitleTextStyle
        .copyWith(fontFamily: 'RunQA'),
    actionTextStyle: const CupertinoTextThemeData().actionTextStyle.copyWith(
      fontFamily: 'RunQA',
    ),
    tabLabelTextStyle: const CupertinoTextThemeData().tabLabelTextStyle
        .copyWith(fontFamily: 'RunQA'),
  );
  return ThemeData(
    platform: TargetPlatform.iOS,
    fontFamily: 'RunQA',
    cupertinoOverrideTheme: CupertinoThemeData(textTheme: cupertino),
  );
}
