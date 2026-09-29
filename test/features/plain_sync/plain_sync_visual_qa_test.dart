/// Visual QA for the plain (unencrypted) folder sync screens.
///
/// Run with a real CJK font and an output directory:
///   BACKUP_UI_FONT=/System/Library/Fonts/Supplemental/PingFang-SC-Bold.ttf \
///   BACKUP_UI_SCREENSHOT_DIR=/tmp/plain-sync-qa \
///   flutter test test/features/plain_sync/plain_sync_visual_qa_test.dart
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
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_detail.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_sync_home.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

class _Connections implements ConnectionRepository {
  _Connections(this.connection);

  final ConnectionModel connection;

  @override
  Future<ConnectionModel?> getConnectionById(String id) async => connection;

  @override
  Future<String?> readWebDavPassword(String? credentialRef) async => 'secret';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StaticAuthorizer implements FolderAccessAuthorizer {
  _StaticAuthorizer(this.grant);

  final FolderAccessGrant? grant;

  @override
  Future<FolderAccessGrant?> authorizeDirectory() async => grant;
}

void main() {
  final captureKey = GlobalKey();
  late SyncStateDatabase database;
  late PlainFolderSyncProfileRepository profiles;

  final connection = ConnectionModel(
    id: 'conn-nas',
    name: '家里 NAS',
    source: '',
    target: '',
    protocol: WebDavProtocolModel(
      protocolType: WebDavProtocolType.https,
      address: 'https://nas.local',
      port: '5006',
      path: '/parcool',
      username: 'parcool',
      credentialRef: 'cred-1',
    ),
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    status: ConnectionStatus.active,
  );

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = PlainFolderSyncProfileRepository(database);
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null && File(font).existsSync()) {
      final loader = FontLoader('PlainQA')
        ..addFont(
          File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
      for (final entry in {
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        'packages/cupertino_icons/CupertinoIcons':
            'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      }.entries) {
        final icons = FontLoader(entry.key)
          ..addFont(rootBundle.load(entry.value));
        await icons.load();
      }
    }
  });

  tearDown(() => database.close());

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

  Widget app(
    Widget home, {
    FolderAccessGrant? localGrant,
    TargetPlatform platform = TargetPlatform.iOS,
  }) => ProviderScope(
    key: UniqueKey(),
    overrides: [
      syncStateDatabaseProvider.overrideWithValue(database),
      plainFolderProfilesProvider.overrideWithValue(profiles),
      connectionRepositoryProvider.overrideWithValue(_Connections(connection)),
      folderAccessAuthorizerProvider.overrideWithValue(
        _StaticAuthorizer(localGrant),
      ),
      backupFolderLoaderProvider.overrideWithValue(
        ({required protocol, required relativeSegments}) async => [
          const WebDavBackupFolder(name: 'velock-photos'),
          const WebDavBackupFolder(name: 'docs'),
        ],
      ),
    ],
    child: MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [...GlobalMaterialLocalizations.delegates],
      theme: ThemeData(
        platform: platform,
        fontFamily: 'PlainQA',
        cupertinoOverrideTheme: CupertinoThemeData(
          textTheme: CupertinoTextThemeData(
            textStyle: const CupertinoTextThemeData().textStyle.copyWith(
              fontFamily: 'PlainQA',
            ),
            navTitleTextStyle: const CupertinoTextThemeData().navTitleTextStyle
                .copyWith(fontFamily: 'PlainQA'),
            navLargeTitleTextStyle: const CupertinoTextThemeData()
                .navLargeTitleTextStyle
                .copyWith(fontFamily: 'PlainQA'),
            actionTextStyle: const CupertinoTextThemeData().actionTextStyle
                .copyWith(fontFamily: 'PlainQA'),
            tabLabelTextStyle: const CupertinoTextThemeData().tabLabelTextStyle
                .copyWith(fontFamily: 'PlainQA'),
          ),
        ),
      ),
      builder: (context, child) =>
          RepaintBoundary(key: captureKey, child: child!),
      home: home,
    ),
  );

  Future<PlainFolderSyncProfile> seed({
    required String id,
    required String name,
    required String localName,
    required List<String> segments,
    MirrorDirection direction = MirrorDirection.bidirectional,
    int uploaded = 0,
    int downloaded = 0,
    int conflicts = 0,
    int heldDeletions = 0,
    String? failureCode,
  }) async {
    final profile = PlainFolderSyncProfile(
      profileId: id,
      datasetId: 'ds-$id',
      deviceId: 'device-1',
      displayName: name,
      localRootReference: '/tmp/$localName',
      localDisplayName: localName,
      connectionId: connection.id,
      remoteRootSegments: segments,
      direction: direction,
      createdAt: DateTime.utc(2026, 9, 27, 10),
    );
    await profiles.save(profile);
    await database.saveMirrorRunStats(
      MirrorRunStats(
        runId: 'run-$id',
        profileId: id,
        startedAt: DateTime.utc(2026, 9, 27, 12, 30),
        finishedAt: DateTime.utc(2026, 9, 27, 12, 31),
        uploadedFileCount: uploaded,
        downloadedFileCount: downloaded,
        conflictCount: conflicts,
        heldDeletionCount: heldDeletions,
        bytesTransferred: 1024 * 1024 * 3,
        failureCode: failureCode,
      ),
    );
    if (conflicts > 0) {
      await database.recordMirrorConflicts(id, [
        for (var index = 0; index < conflicts; index++)
          MirrorPlannedConflict(
            relativePath: 'photos/IMG_$index.jpg',
            kind: MirrorConflictKind.bothModified,
            resolution: MirrorConflictResolution.keepBoth,
            conflictCopyPath:
                'photos/IMG_$index (本机冲突 2026-09-27 12-30-00).jpg',
          ),
      ], detectedAt: DateTime.utc(2026, 9, 27, 12, 31));
    }
    return profile;
  }

  testWidgets('captures the plain sync screens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 1. Empty state.
    await tester.pumpWidget(app(const PlainSyncHome()));
    await tester.pumpAndSettle();
    expect(find.text('添加第一个同步位置'), findsOneWidget);
    await capture(tester, '01-home-empty');

    // 2. Two locations with different directions and states.
    await seed(
      id: 'plain-1',
      name: '手机照片',
      localName: '照片',
      segments: ['velock-photos'],
      uploaded: 12,
      downloaded: 2,
    );
    await seed(
      id: 'plain-2',
      name: '工作文档备份',
      localName: 'Work',
      segments: ['docs', 'from-phone'],
      direction: MirrorDirection.uploadOnly,
      uploaded: 340,
      heldDeletions: 12,
      conflicts: 1,
    );
    await tester.pumpWidget(app(const PlainSyncHome()));
    await tester.pumpAndSettle();
    expect(find.text('手机照片'), findsOneWidget);
    expect(find.text('工作文档备份'), findsOneWidget);
    expect(find.text('仅上传'), findsOneWidget);
    await capture(tester, '02-home-two-locations');

    // 3. Detail page with conflicts.
    await tester.pumpWidget(
      app(const PlainLocationDetail(profileId: 'plain-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('本机文件夹'), findsOneWidget);
    expect(find.text('远端文件夹'), findsOneWidget);
    await capture(tester, '03-detail');

    // 4. Detail page while deletions wait for confirmation.
    await tester.pumpWidget(
      app(const PlainLocationDetail(profileId: 'plain-2')),
    );
    await tester.pumpAndSettle();
    expect(find.text('有删除等待确认'), findsOneWidget);
    await capture(tester, '04-detail-held-deletions');
  });
}
