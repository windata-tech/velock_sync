import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart'
    as state;
import 'package:velock_sync/features/connection/ui/connections.dart';
import 'package:velock_sync/features/connection/ui/new_connection.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

class _TestConnections extends state.Connections {
  _TestConnections(this.connections);
  final List<ConnectionModel> connections;

  @override
  Future<List<ConnectionModel>> build() async => connections;
}

Widget _app({
  required Widget child,
  required TargetPlatform platform,
  String language = 'en',
}) => ProviderScope(
  child: MaterialApp(
    // The design language the app picks follows ThemeData.platform.
    theme: ThemeData(platform: platform),
    locale: Locale(language),
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: child,
  ),
);

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform English empty list to WebDAV and HTTP warning', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(
        overrides: [
          state.connectionsProvider.overrideWith(() => _TestConnections([])),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Connections()),
          GoRoute(
            name: 'newConnection',
            path: '/new',
            builder: (_, _) => const NewConnection(),
          ),
          GoRoute(
            name: 'protocols',
            path: '/protocols',
            builder: (_, _) => const Protocols(),
          ),
          GoRoute(
            name: 'newWebDav',
            path: '/webdav',
            builder: (_, _) => const NewWebDav(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: ThemeData(platform: platform),
            locale: const Locale('en'),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No Remote Connections Yet'), findsOneWidget);
      await tester.tap(find.text('Add Remote Connection'));
      await tester.pumpAndSettle();
      expect(
        container.read(state.connectionCreationProvider)?.name,
        'New Connection',
      );
      expect(find.text('Velock'), findsOneWidget);
      await tester.tap(find.text('Choose Remote Protocol'));
      await tester.pumpAndSettle();
      expect(find.text('Where to save'), findsOneWidget);
      expect(find.text('Other Services'), findsOneWidget);
      expect(find.text('Baidu Netdisk'), findsOneWidget);
      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      expect(find.text('New WebDAV Connection'), findsOneWidget);
      for (final label in [
        'Server Address',
        'Port',
        'Subpath',
        'Username',
        'Password',
        'Enable HTTPS',
        'Save',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.byType(AdaptiveSwitch));
      await tester.pumpAndSettle();
      expect(find.text('Use Insecure HTTP?'), findsOneWidget);
      expect(find.text('Use HTTP Anyway'), findsOneWidget);
      await tester.tap(find.text('Keep HTTPS'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch)).value,
        isTrue,
      );
      await tester.tap(find.byType(AdaptiveSwitch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use HTTP Anyway'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch)).value,
        isFalse,
      );
      expect(
        tester
            .widget<AdaptiveTextFormField>(
              find.byKey(const ValueKey('webdav_address')),
            )
            .controller
            .text,
        'http://',
      );
    });

    testWidgets('$platform English WebDAV validation', (tester) async {
      await tester.pumpWidget(
        _app(child: const NewWebDav(), platform: platform),
      );
      await tester.pumpAndSettle();
      Future<void> enter(String field, String text) => tester.enterText(
        find.descendant(
          of: find.byKey(ValueKey('webdav_$field')),
          matching: find.byType(EditableText),
        ),
        text,
      );
      Future<void> save() async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }

      await enter('address', '');
      await save();
      expect(find.text('Enter a server address'), findsOneWidget);
      expect(find.text('Enter a port'), findsOneWidget);
      await enter('address', 'invalid');
      await save();
      expect(find.text('Enter a valid server address'), findsOneWidget);
      await enter('address', 'http://example.com');
      await enter('user', 'user');
      await save();
      expect(
        find.text('The address must start with https:// when HTTPS is enabled'),
        findsOneWidget,
      );
      expect(find.text('Enter a password'), findsWidgets);
      await enter('user', '');
      await enter('password', 'password');
      await save();
      expect(find.text('Enter a username'), findsWidgets);
    });
  }

  testWidgets('Chinese WebDAV labels remain available', (tester) async {
    await tester.pumpWidget(
      _app(
        child: const NewWebDav(),
        platform: TargetPlatform.iOS,
        language: 'zh',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新建 WebDAV 连接'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets(
    'saved connection rows show English status and preserve user names',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          state.connectionsProvider.overrideWith(
            () => _TestConnections([
              ConnectionModel(
                id: 'saved',
                name: 'My NAS',
                source: '格间',
                target: 'https://example.com',
                protocol: const WebDavProtocolModel(
                  protocolType: WebDavProtocolType.https,
                  address: 'https://example.com',
                  port: '443',
                ),
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
                status: ConnectionStatus.active,
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: const Connections(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My NAS'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Connected Services'), findsOneWidget);
      expect(find.text('WebDAV · https://example.com'), findsOneWidget);
    },
  );
}
