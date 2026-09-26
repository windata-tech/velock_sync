import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
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
    path: '/backup',
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

class _Detail extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _connection;
}

class _Browser extends RemoteFileBrowser {
  String path = '/backup';
  @override
  bool get canGoBack => path != '/backup';
  @override
  String get currentPath => path;
  FileBrowserState listing() => FileBrowserState(
    path: path,
    rootPath: '/backup',
    files: [WebdavFile(path: '$path/child', isDir: true, name: 'child')],
  );
  @override
  Future<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async => listing();
  @override
  Future<void> go(String value) async {
    path = value;
    state = AsyncData(listing());
  }

  @override
  Future<void> goBack() => go(path.substring(0, path.lastIndexOf('/')));
  void failChild() {
    path = '$path/denied';
    state = AsyncError(StateError('denied'), StackTrace.current);
  }
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$platform connection back climbs folders before closing route',
      (tester) async {
        late _Browser browser;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              connectionDetailProvider('test').overrideWith(_Detail.new),
              remoteFileBrowserProvider(
                connectionModel: _connection,
              ).overrideWith(() => browser = _Browser()),
            ],
            child: PlatformProvider(
              initialPlatform: platform,
              builder: (_) => MaterialApp(
                locale: const Locale('zh'),
                supportedLocales: const [Locale('zh'), Locale('en')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: ThemeData(platform: platform),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      child: const Text('open'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Connection('test'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('/backup'), findsOneWidget);
        await tester.tap(find.text('child'));
        await tester.pumpAndSettle();
        expect(find.text('/backup/child'), findsOneWidget);
        await tester.tap(find.text('child'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AppBackButton));
        await tester.pumpAndSettle();
        expect(find.text('/backup/child'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('/backup'), findsOneWidget);
        browser.failChild();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AppBackButton));
        await tester.pumpAndSettle();
        expect(find.text('/backup'), findsOneWidget);
        await tester.tap(find.byType(AppBackButton));
        await tester.pumpAndSettle();
        expect(find.text('open'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
