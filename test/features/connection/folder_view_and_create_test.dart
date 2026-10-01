/// Folder screens show tiles or rows, one shared choice the user can switch,
/// and the connection browser can make a new folder where it stands.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/state/folder_view_mode.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/features/connection/ui/remote_folder_views.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

const _root = '/dav';
const _child = '/dav/硬盘';

final _connection = ConnectionModel(
  id: 'test',
  name: 'Test NAS',
  source: 'test',
  target: 'test',
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: 'https://nas.example.com',
    port: '443',
    path: _root,
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

FileBrowserState _state(List<WebdavFile> files) =>
    FileBrowserState(path: _child, rootPath: _root, files: files);

final _files = [
  const WebdavFile(path: '$_child/照片', isDir: true, name: '照片'),
  WebdavFile(
    path: '$_child/notes.txt',
    isDir: false,
    name: 'notes.txt',
    size: 2048,
    modified: DateTime(2026, 9, 30, 13, 20),
  ),
];

class _Detail extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _connection;
}

/// Sits in `/dav/硬盘`; every refresh answers with [next].
class _Browser extends RemoteFileBrowser {
  List<WebdavFile> next = _files;
  final refreshed = <String>[];

  @override
  String get currentPath => _child;

  @override
  bool get canGoBack => true;

  @override
  FileBrowserState? get visibleState => state.value;

  @override
  Future<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async => _state(_files);

  @override
  Future<void> refresh() => go(currentPath);

  @override
  Future<void> go(String path) async {
    refreshed.add(path);
    state = AsyncData(_state(next));
  }
}

typedef _Created = ({List<String> parent, String name});

Future<(_Browser, List<_Created>, List<String>)> _pumpBrowser(
  WidgetTester tester, {
  FolderViewMode start = FolderViewMode.grid,
  Object? createError,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final browser = _Browser();
  final created = <_Created>[];
  final stored = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionDetailProvider('test').overrideWith(_Detail.new),
        remoteFileBrowserProvider(
          connectionModel: _connection,
        ).overrideWith(() => browser),
        folderViewModeBootstrapProvider.overrideWithValue(start),
        folderViewModeWriterProvider.overrideWithValue(
          (value) async => stored.add(value),
        ),
        backupFolderCreatorProvider.overrideWithValue(({
          required protocol,
          required relativeSegments,
          required name,
        }) async {
          expect(protocol, _connection.protocol);
          if (createError != null) throw createError;
          created.add((parent: relativeSegments, name: name));
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: const Connection('test'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (browser, created, stored);
}

Future<void> _enterNewFolder(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('remote-browser-new-folder')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('new-backup-folder-name')), name);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('confirm-new-backup-folder')));
  await tester.pumpAndSettle();
}

void main() {
  group('connection browser', () {
    testWidgets('switches between tiles and rows and remembers it', (
      tester,
    ) async {
      final (_, _, stored) = await _pumpBrowser(tester);
      expect(find.byType(RemoteEntryTile), findsNWidgets(2));
      expect(find.byType(RemoteEntryRow), findsNothing);

      await tester.tap(find.byKey(const Key('folder-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteEntryTile), findsNothing);
      expect(find.byType(RemoteEntryRow), findsNWidgets(2));
      // A row has room for what a tile leaves out.
      expect(find.text('2 KB · 2026-09-30 13:20'), findsOneWidget);
      expect(stored, ['list']);

      await tester.tap(find.byKey(const Key('folder-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteEntryTile), findsNWidgets(2));
      expect(stored, ['list', 'grid']);
    });

    testWidgets('opens with the remembered layout', (tester) async {
      await _pumpBrowser(tester, start: FolderViewMode.list);
      expect(find.byType(RemoteEntryRow), findsNWidgets(2));
    });

    for (final mode in FolderViewMode.values) {
      testWidgets('a ${mode.name} entry still opens', (tester) async {
        final (browser, _, _) = await _pumpBrowser(tester, start: mode);
        await tester.tap(find.byKey(const ValueKey('remote-entry-照片')));
        await tester.pumpAndSettle();
        expect(browser.refreshed, ['$_child/照片']);
      });
    }

    testWidgets('creates one folder where the browser stands', (tester) async {
      final (browser, created, _) = await _pumpBrowser(tester);
      browser.next = [
        ..._files,
        const WebdavFile(path: '$_child/新建', isDir: true, name: '新建'),
      ];
      await _enterNewFolder(tester, ' 新建 ');

      expect(created, hasLength(1));
      // Relative to the connection's own folder, as the creator expects.
      expect(created.single.parent, ['硬盘']);
      expect(created.single.name, '新建');
      expect(browser.refreshed, [_child]);
      expect(find.text('新建'), findsOneWidget);
    });

    testWidgets('a name already used here creates nothing', (tester) async {
      final (_, created, _) = await _pumpBrowser(tester);
      for (final name in ['照片', 'notes.txt', '../外面']) {
        await _enterNewFolder(tester, name);
        expect(
          find.byKey(const Key('new-backup-folder-name')),
          findsOneWidget,
          reason: '"$name" keeps the dialog open',
        );
        await tester.enterText(
          find.byKey(const Key('new-backup-folder-name')),
          '',
        );
        await tester.tap(find.byKey(const Key('cancel-new-backup-folder')));
        await tester.pumpAndSettle();
      }
      expect(created, isEmpty);
    });

    testWidgets('a refused folder says why and changes nothing', (
      tester,
    ) async {
      final (browser, created, _) = await _pumpBrowser(
        tester,
        createError: ProviderRequestException.fromStatus(403),
      );
      await _enterNewFolder(tester, '新建');
      expect(created, isEmpty);
      expect(find.text('这个位置没有新建文件夹的权限，请选择其他位置。'), findsOneWidget);
      expect(browser.refreshed, isEmpty);
    });
  });

  group('folder picker', () {
    testWidgets('shares the layout and opens folders in both', (tester) async {
      final opened = <List<String>>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            folderViewModeWriterProvider.overrideWithValue((_) async {}),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: BackupFolderPicker(
              connectionName: 'Test NAS',
              basePath: _root,
              loadFolders: (segments) async {
                opened.add(segments);
                return segments.isEmpty
                    ? const [WebDavBackupFolder(name: '照片')]
                    : const [];
              },
              createFolder: (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RemoteEntryTile), findsOneWidget);

      await tester.tap(find.byKey(const Key('folder-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteEntryTile), findsNothing);
      expect(find.byType(RemoteEntryRow), findsOneWidget);
      expect(find.byKey(const Key('new-backup-folder')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('backup-folder-照片')));
      await tester.pumpAndSettle();
      expect(opened.last, ['照片']);
    });
  });
}
