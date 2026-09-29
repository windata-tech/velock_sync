/// A row that sits inside an iconed card must not be the only one without a
/// glyph.
///
/// The user reported the manage tab: 「更换保存位置」 leads with a cloud and the
/// row directly under it, 「重新连接格间」, led with nothing. The overview card
/// had the same defect in its conditional 「查看等待传输的内容」 row.
///
/// With `BACKUP_UI_FONT` and `BACKUP_UI_SCREENSHOT_DIR` set it also writes the
/// rendered screens; without them it only asserts.
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
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

const _profileId = 'velock-profile';

void main() {
  final captureKey = GlobalKey();

  setUpAll(() async {
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null && File(font).existsSync()) {
      final bytes = File(font).readAsBytes();
      for (final family in const ['RowQA', 'Roboto', '.SF Pro Text']) {
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

  testWidgets('every action row in these cards leads with a glyph', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    await SyncProfileRepository(database).save(_profile());
    // One unfinished transfer, so the conditional pending row is on screen.
    await database.beginTransferJob(
      transferId: 'pending-1',
      profileId: _profileId,
      direction: TransferJobDirection.upload,
      logicalKey: 'vault/batches/batch-9',
      expectedSize: 4096,
    );

    await _pumpDetail(tester, database, captureKey);

    for (final title in const ['云端保存位置', '传输记录', '查看等待传输的内容', '管理']) {
      expect(_leadingOf(tester, title), isNotNull, reason: title);
    }
    await capture(tester, '01-overview-with-pending');

    await tester.ensureVisible(find.text('管理'));
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();

    for (final title in const ['更换保存位置', '重新连接格间']) {
      expect(_leadingOf(tester, title), isNotNull, reason: title);
    }
    await capture(tester, '02-manage');

    await tester.ensureVisible(find.text('断开此连接'));
    await tester.pumpAndSettle();
    await capture(tester, '03-manage-danger-zone');
    expect(tester.takeException(), isNull);
  });
}

/// The `leading` widget of the tile that shows [title].
Widget? _leadingOf(WidgetTester tester, String title) => tester
    .widget<AdaptiveListTile>(
      find
          .ancestor(
            of: find.text(title),
            matching: find.byType(AdaptiveListTile),
          )
          .first,
    )
    .leading;

Future<void> _pumpDetail(
  WidgetTester tester,
  SyncStateDatabase database,
  GlobalKey captureKey,
) async {
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
}

/// A CJK font everywhere, including the Cupertino styles the page resolves for
/// itself; without it a render shows placeholder glyphs instead of copy.
ThemeData _qaTheme() {
  final cupertino = CupertinoTextThemeData(
    textStyle: const CupertinoTextThemeData().textStyle.copyWith(
      fontFamily: 'RowQA',
    ),
    navTitleTextStyle: const CupertinoTextThemeData().navTitleTextStyle
        .copyWith(fontFamily: 'RowQA'),
    navLargeTitleTextStyle: const CupertinoTextThemeData()
        .navLargeTitleTextStyle
        .copyWith(fontFamily: 'RowQA'),
    actionTextStyle: const CupertinoTextThemeData().actionTextStyle.copyWith(
      fontFamily: 'RowQA',
    ),
    tabLabelTextStyle: const CupertinoTextThemeData().tabLabelTextStyle
        .copyWith(fontFamily: 'RowQA'),
  );
  return ThemeData(
    platform: TargetPlatform.iOS,
    fontFamily: 'RowQA',
    cupertinoOverrideTheme: CupertinoThemeData(textTheme: cupertino),
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
