/// Only location types this build can finish setting up are offered when
/// adding a connection. Google Drive / OneDrive come back as soon as a public
/// client ID is built in; Baidu Netdisk and Aliyun Drive have no adapter.
///
/// Saved connections of a hidden type must still be listed (and therefore
/// editable/deletable), and the developer Client ID form is debug-only.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart'
    as state;
import 'package:velock_sync/features/connection/ui/connection_guidance.dart';
import 'package:velock_sync/features/connection/ui/connections.dart';
import 'package:velock_sync/features/connection/ui/new_connection.dart';
import 'package:velock_sync/features/connection/ui/new_oauth.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// A release build without any OAuth client ID.
final _releaseUnconfigured = RemoteProviderAvailability.forBuild(
  developerMode: false,
  hasBuiltInClientId: (_) => false,
);

/// A release build with both public client IDs built in.
final _releaseConfigured = RemoteProviderAvailability.forBuild(
  developerMode: false,
  hasBuiltInClientId: (type) =>
      type == RemoteProviderType.googleDrive ||
      type == RemoteProviderType.oneDrive,
);

class _TestConnections extends state.Connections {
  _TestConnections(this.connections);
  final List<ConnectionModel> connections;

  @override
  Future<List<ConnectionModel>> build() async => connections;
}

ConnectionModel _savedGoogleDrive() => ConnectionModel(
  id: 'conn-oauth',
  name: 'Old Google Drive',
  source: 'googleDrive',
  target: 'Google Drive',
  protocol: const OAuthProtocolModel(
    providerType: RemoteProviderType.googleDrive,
    clientId: 'client-1',
    credentialRef: 'cred-2',
    rootId: 'root',
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  required RemoteProviderAvailability availability,
  List<Override> overrides = const [],
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      remoteProviderAvailabilityProvider.overrideWithValue(availability),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('RemoteProviderAvailability.forBuild', () {
    test('a release build without client IDs offers only WebDAV', () {
      expect(_releaseUnconfigured.ordered, [RemoteProviderType.webDav]);
      expect(_releaseUnconfigured.allowsDeveloperClientId, isFalse);
      expect(_releaseUnconfigured.describe(chinese: true), 'WebDAV');
      expect(_releaseUnconfigured.describe(chinese: false), 'WebDAV');
    });

    test('built-in client IDs re-enable only the configured provider', () {
      final googleOnly = RemoteProviderAvailability.forBuild(
        developerMode: false,
        hasBuiltInClientId: (type) => type == RemoteProviderType.googleDrive,
      );
      expect(googleOnly.ordered, [
        RemoteProviderType.webDav,
        RemoteProviderType.googleDrive,
      ]);
      expect(googleOnly.describe(chinese: false), 'WebDAV or Google Drive');
      expect(
        _releaseConfigured.describe(chinese: true),
        'WebDAV、Google Drive 或 OneDrive',
      );
      expect(
        _releaseConfigured.describe(chinese: false),
        'WebDAV, Google Drive, or OneDrive',
      );
    });

    test('Baidu Netdisk and Aliyun Drive are never offered', () {
      for (final developerMode in [false, true]) {
        final availability = RemoteProviderAvailability.forBuild(
          developerMode: developerMode,
          hasBuiltInClientId: (_) => true,
        );
        expect(
          availability.canCreate(RemoteProviderType.baiduNetdisk),
          isFalse,
        );
        expect(availability.canCreate(RemoteProviderType.aliyunDrive), isFalse);
      }
    });

    test('debug builds keep the OAuth providers for developers', () {
      final debug = RemoteProviderAvailability.forBuild(
        developerMode: true,
        hasBuiltInClientId: (_) => false,
      );
      expect(debug.canCreate(RemoteProviderType.googleDrive), isTrue);
      expect(debug.canCreate(RemoteProviderType.oneDrive), isTrue);
      expect(debug.allowsDeveloperClientId, isTrue);
    });
  });

  testWidgets('the picker hides every provider this build cannot set up', (
    tester,
  ) async {
    await _pump(tester, const Protocols(), availability: _releaseUnconfigured);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.text('Google Drive'), findsNothing);
    expect(find.text('OneDrive'), findsNothing);
    expect(find.text('百度网盘'), findsNothing);
    expect(find.text('阿里云盘'), findsNothing);
    expect(find.text('其他服务'), findsNothing);
    // The header no longer claims every location is encrypted.
    expect(find.textContaining('加密对象'), findsNothing);
    expect(find.textContaining('文件同步写入的是普通文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('configured OAuth providers are shown in the picker', (
    tester,
  ) async {
    await _pump(tester, const Protocols(), availability: _releaseConfigured);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('OneDrive'), findsOneWidget);
    expect(find.text('百度网盘'), findsNothing);
    expect(find.text('阿里云盘'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the English picker header is plaintext-honest and has no CJK', (
    tester,
  ) async {
    await _pump(
      tester,
      const Protocols(),
      availability: _releaseUnconfigured,
      locale: const Locale('en'),
    );
    expect(
      find.textContaining('File sync writes ordinary files'),
      findsOneWidget,
    );
    expect(find.textContaining('encrypted objects'), findsNothing);
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(matches(RegExp(r'[一-鿿]'))));
    }
  });

  testWidgets('the new-connection summary names only available types', (
    tester,
  ) async {
    await _pump(
      tester,
      const NewConnection(),
      availability: _releaseUnconfigured,
    );
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.textContaining('Google Drive'), findsNothing);
    expect(find.textContaining('OneDrive'), findsNothing);
    expect(find.textContaining('只有加密后的同步对象'), findsNothing);
  });

  testWidgets('the help overview documents only available types', (
    tester,
  ) async {
    await _pump(
      tester,
      const ConnectionHelpPage(),
      availability: _releaseUnconfigured,
    );
    expect(find.text('WebDAV'), findsWidgets);
    expect(find.text('Google Drive'), findsNothing);
    expect(find.text('OneDrive'), findsNothing);
    expect(find.text('百度网盘'), findsNothing);
    expect(find.text('阿里云盘'), findsNothing);
  });

  testWidgets('a saved connection of a hidden type is still listed', (
    tester,
  ) async {
    await _pump(
      tester,
      const Connections(),
      availability: _releaseUnconfigured,
      overrides: [
        state.connectionsProvider.overrideWith(
          () => _TestConnections([_savedGoogleDrive()]),
        ),
      ],
    );
    expect(find.text('Old Google Drive'), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    expect(find.text('删除连接'), findsOneWidget);
    expect(find.text('修改连接'), findsOneWidget);
  });

  group('release OAuth page without a built-in client ID', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await LocalDataManager.instance.init();
    });

    testWidgets('shows no developer form and ignores a saved Client ID', (
      tester,
    ) async {
      // A Client ID left behind by a debug build must not unlock sign-in.
      await LocalDataManager.instance.setStringAsync(
        AppKeys.googleOAuthClientId,
        'left-over.apps.example',
      );
      await _pump(
        tester,
        const NewOAuthConnection(providerType: RemoteProviderType.googleDrive),
        availability: _releaseUnconfigured,
      );
      expect(find.textContaining('此版本暂未开通'), findsOneWidget);
      expect(find.byKey(const Key('oauth-choose-another')), findsOneWidget);
      expect(find.byKey(const Key('oauth-developer-settings')), findsNothing);
      expect(find.byKey(const Key('oauth-client-id-field')), findsNothing);
      expect(find.byKey(const Key('oauth-sign-in')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
