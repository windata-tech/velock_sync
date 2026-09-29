import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

final _connection = ConnectionModel(
  id: 'test',
  name: 'Test NAS',
  source: 'test',
  target: 'test',
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.invalid',
    port: '443',
    path: '/share',
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

class _Detail extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _connection;
}

class FakeBrowser extends RemoteFileBrowser {
  final opened = <String>[];
  String path = '/share';

  FileBrowserState listing(String at) => FileBrowserState(
    path: at,
    rootPath: '/share',
    files: [WebdavFile(path: '$at/child', isDir: true, name: 'child')],
  );

  @override
  bool get canGoBack => path != '/share';
  @override
  String get currentPath => path;
  @override
  Future<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async => listing(path);
  @override
  Future<void> go(String value) async {
    opened.add(value);
    path = value;
    state = AsyncData(listing(value));
  }

  @override
  Future<void> refresh() async {}
}

Future<FakeBrowser> pumpBrowser(
  WidgetTester tester, {
  List<String> initialSegments = const [],
}) async {
  late FakeBrowser browser;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionDetailProvider('test').overrideWith(_Detail.new),
        remoteFileBrowserProvider(
          connectionModel: _connection,
        ).overrideWith(() => browser = FakeBrowser()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Connection('test', initialSegments: initialSegments),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return browser;
}

void main() {
  testWidgets('no initial folder keeps the configured root', (tester) async {
    final browser = await pumpBrowser(tester);
    expect(browser.opened, isEmpty);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('remote-browser-current-path')))
          .data,
      '/share',
    );
  });

  testWidgets('an initial folder opens inside the connection root', (
    tester,
  ) async {
    final browser = await pumpBrowser(
      tester,
      initialSegments: const ['USB_HDD_8T', '111'],
    );
    // The backup's own folder, resolved against the connection root.
    expect(browser.opened, ['/share/USB_HDD_8T/111']);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('remote-browser-current-path')))
          .data,
      '/share/USB_HDD_8T/111',
    );
    // Inside the connection root the browser can still walk back up.
    expect(browser.canGoBack, isTrue);
  });

  testWidgets('a folder outside the connection root is refused', (
    tester,
  ) async {
    final browser = await pumpBrowser(
      tester,
      initialSegments: const ['../../etc'],
    );
    expect(browser.opened.where((path) => !path.startsWith('/share')), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
