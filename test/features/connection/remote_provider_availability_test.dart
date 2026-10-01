/// Every cloud drive is offered when adding a connection. The repository
/// ships no keys, so without a built-in one the user signs in with an app
/// they registered themselves, entered on the connection page — in release
/// builds too.
///
/// Saved connections of any type must still be listed (and therefore
/// editable/deletable).
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart'
    as state;
import 'package:velock_sync/features/connection/ui/connection_guidance.dart';
import 'package:velock_sync/features/connection/ui/connections.dart';
import 'package:velock_sync/features/connection/ui/new_oauth.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/features/connection/ui/remote_provider_icon.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// A release build without any OAuth client ID.
final _releaseUnconfigured = RemoteProviderAvailability.forBuild(
  hasBuiltInClientId: (_) => false,
);

/// A release build with both public client IDs built in.
final _releaseConfigured = RemoteProviderAvailability.forBuild(
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
  InMemoryCredentialStore? credentials,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      remoteProviderAvailabilityProvider.overrideWithValue(availability),
      credentialStoreProvider.overrideWithValue(
        credentials ?? InMemoryCredentialStore(),
      ),
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
      expect(
        _releaseUnconfigured.needsOwnRegistration,
        RemoteProviderAvailability.oauthProviderTypes,
      );
      expect(_releaseUnconfigured.describe(chinese: true), 'WebDAV');
      expect(_releaseUnconfigured.describe(chinese: false), 'WebDAV');
    });

    test('built-in client IDs re-enable only the configured provider', () {
      final googleOnly = RemoteProviderAvailability.forBuild(
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

    test('Baidu Netdisk and Aliyun Drive follow their registration', () {
      final configured = RemoteProviderAvailability.forBuild(
        hasBuiltInClientId: (_) => true,
      );
      expect(configured.canCreate(RemoteProviderType.baiduNetdisk), isTrue);
      expect(configured.canCreate(RemoteProviderType.aliyunDrive), isTrue);
      final missing = RemoteProviderAvailability.forBuild(
        hasBuiltInClientId: (_) => false,
      );
      expect(missing.canCreate(RemoteProviderType.baiduNetdisk), isFalse);
      expect(missing.canCreate(RemoteProviderType.aliyunDrive), isFalse);
    });

    test('only providers without a built-in key need the user’s own', () {
      expect(_releaseConfigured.needsOwnRegistration, [
        RemoteProviderType.baiduNetdisk,
        RemoteProviderType.aliyunDrive,
      ]);
      final all = RemoteProviderAvailability.forBuild(
        hasBuiltInClientId: (_) => true,
      );
      expect(all.needsOwnRegistration, isEmpty);
    });
  });

  testWidgets('providers without a built-in key are listed for own keys', (
    tester,
  ) async {
    await _pump(tester, const Protocols(), availability: _releaseUnconfigured);
    expect(find.text('WebDAV'), findsOneWidget);
    for (final type in RemoteProviderAvailability.oauthProviderTypes) {
      expect(find.byKey(Key('protocol-${type.name}')), findsOneWidget);
    }
    expect(find.text('更多云盘'), findsNothing);
    expect(find.byKey(const Key('protocols-more-toggle')), findsNothing);
    expect(find.textContaining('使用你自己在百度网盘开放平台注册的应用密钥登录'), findsOneWidget);
    // Google's own-key sign-in needs the iOS web-authentication sheet; the
    // test platform is Android, so the tile says so up front.
    expect(find.textContaining('目前只支持 iPhone 和 iPad'), findsOneWidget);
    expect(find.text('使用你自己在 Microsoft Entra 注册的应用密钥登录。'), findsOneWidget);
    expect(find.textContaining('额度也归你自己'), findsOneWidget);
    // No build options or environment variables are shown to users.
    expect(find.textContaining('dart-define'), findsNothing);
    expect(find.textContaining('此版本暂未开通'), findsNothing);
    // The header no longer claims every location is encrypted.
    expect(find.textContaining('加密对象'), findsNothing);
    expect(find.textContaining('文件同步写入的是普通文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('built-in keys sign in directly, the rest use own keys', (
    tester,
  ) async {
    await _pump(tester, const Protocols(), availability: _releaseConfigured);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('OneDrive'), findsOneWidget);
    expect(find.text('使用 Google 账号授权，然后选择同步所用的云端目录。'), findsOneWidget);
    expect(find.byKey(const Key('protocol-baiduNetdisk')), findsOneWidget);
    expect(find.textContaining('使用你自己在阿里云盘开放平台注册的应用密钥登录'), findsOneWidget);
    expect(find.textContaining('使用你自己在 Microsoft Entra 注册'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each storage type has its own icon and colour', (tester) async {
    await _pump(
      tester,
      const Protocols(),
      availability: RemoteProviderAvailability.forBuild(
        hasBuiltInClientId: (_) => true,
      ),
    );
    final drawn = RemoteProviderType.values
        .where((type) => remoteProviderOfficialLogo(type) == null)
        .toList();
    final badges = tester
        .widgetList<AdaptiveIconBadge>(find.byType(AdaptiveIconBadge))
        .toList();
    expect(badges, hasLength(drawn.length));
    expect(badges.map((b) => b.icon).toSet(), hasLength(badges.length));
    expect(badges.map((b) => b.color).toSet(), hasLength(badges.length));
  });

  testWidgets('Google Drive shows its published logo, unmodified', (
    tester,
  ) async {
    await _pump(
      tester,
      const Protocols(),
      availability: RemoteProviderAvailability.forBuild(
        hasBuiltInClientId: (_) => true,
      ),
    );
    final logo = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/providers/google_drive.png',
    );
    expect(logo, findsOneWidget);
    final image = tester.widget<Image>(logo);
    // Resizing is allowed; recolouring or a tinted tile is not.
    expect(image.color, isNull);
    expect(image.colorBlendMode, isNull);
    expect(
      find.ancestor(of: logo, matching: find.byType(AdaptiveIconBadge)),
      findsNothing,
    );
    // Brand rules: OneDrive stays on the drawn icon.
    expect(remoteProviderOfficialLogo(RemoteProviderType.oneDrive), isNull);
  });

  testWidgets('every cloud service sits in one group with the same wording', (
    tester,
  ) async {
    await _pump(
      tester,
      const Protocols(),
      availability: RemoteProviderAvailability.forBuild(
        hasBuiltInClientId: (_) => true,
      ),
    );
    expect(find.byType(AdaptiveListSection), findsOneWidget);
    expect(find.text('其他服务'), findsNothing);
    expect(find.textContaining('然后选择同步所用的云端目录。'), findsNWidgets(4));
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

  testWidgets('the help overview documents every type, without build flags', (
    tester,
  ) async {
    await _pump(
      tester,
      const ConnectionHelpPage(),
      availability: _releaseUnconfigured,
    );
    for (final title in [
      'WebDAV',
      'Google Drive',
      'OneDrive',
      '百度网盘',
      '阿里云盘',
    ]) {
      await tester.scrollUntilVisible(
        find.text(title),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsWidgets);
    }
    expect(find.textContaining('dart-define'), findsNothing);
    expect(find.textContaining('不需要填写任何密钥'), findsNothing);
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

  group('release OAuth page without a built-in key', () {
    testWidgets('offers the own-key form instead of a dead end', (
      tester,
    ) async {
      await _pump(
        tester,
        const NewOAuthConnection(providerType: RemoteProviderType.googleDrive),
        availability: _releaseUnconfigured,
      );
      expect(find.textContaining('此版本暂未开通'), findsNothing);
      expect(find.byKey(const Key('oauth-own-key-form')), findsOneWidget);
      expect(find.byKey(const Key('oauth-own-client-id')), findsOneWidget);
      // Google and Microsoft are public clients: no secret field.
      expect(find.byKey(const Key('oauth-own-secret')), findsNothing);
      // Google's redirect is derived from the Client ID; what the user must
      // register is the bundle ID of an "iOS" client.
      expect(find.text('velocksync://oauth/callback'), findsNothing);
      expect(find.text('tech.windata.velock.sync'), findsOneWidget);
      expect(find.byKey(const Key('oauth-choose-another')), findsOneWidget);
      expect(find.byKey(const Key('oauth-sign-in')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final full in [true, false]) {
      testWidgets(
        full
            ? 'a Google sign-in for file sync says it asks for all files'
            : 'a Google sign-in for backups keeps quiet about all files',
        (tester) async {
          final credentials = InMemoryCredentialStore();
          await credentials.writeOAuthClientRegistration(
            RemoteProviderType.googleDrive,
            const OAuthClientRegistration(
              clientId: '123-abc.apps.googleusercontent.com',
            ),
          );
          await _pump(
            tester,
            NewOAuthConnection(
              providerType: RemoteProviderType.googleDrive,
              fullDriveAccess: full,
            ),
            availability: _releaseUnconfigured,
            credentials: credentials,
          );
          expect(find.text('登录并选择保存位置'), findsOneWidget);
          expect(
            find.byKey(const Key('oauth-google-full-access-note')),
            full ? findsOneWidget : findsNothing,
          );
          expect(
            find.textContaining('所有 Google 云端硬盘文件'),
            full ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('Baidu asks for the SecretKey and app name', (tester) async {
      final credentials = InMemoryCredentialStore();
      await _pump(
        tester,
        const NewOAuthConnection(providerType: RemoteProviderType.baiduNetdisk),
        availability: _releaseUnconfigured,
        credentials: credentials,
      );
      expect(find.byKey(const Key('oauth-own-secret')), findsOneWidget);
      expect(find.byKey(const Key('oauth-own-app-folder')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('oauth-own-client-id')),
        'user-app-key',
      );
      await tester.tap(find.byKey(const Key('oauth-own-save')));
      await tester.pumpAndSettle();
      // Nothing is stored until the registration is complete.
      expect(find.byKey(const Key('oauth-own-error')), findsOneWidget);
      expect(
        await credentials.readOAuthClientRegistration(
          RemoteProviderType.baiduNetdisk,
        ),
        isNull,
      );

      await tester.enterText(
        find.byKey(const Key('oauth-own-secret')),
        'user-secret',
      );
      await tester.enterText(
        find.byKey(const Key('oauth-own-app-folder')),
        'My Sync',
      );
      await tester.tap(find.byKey(const Key('oauth-own-save')));
      await tester.pumpAndSettle();

      final saved = await credentials.readOAuthClientRegistration(
        RemoteProviderType.baiduNetdisk,
      );
      expect(saved?.clientId, 'user-app-key');
      expect(saved?.clientSecret, 'user-secret');
      expect(saved?.appFolderName, 'My Sync');
      // The sign-in page now runs on the user's app, rooted in its folder.
      expect(find.byKey(const Key('oauth-own-key-form')), findsNothing);
      expect(find.byKey(const Key('oauth-sign-in')), findsOneWidget);
      await tester.tap(find.byKey(const Key('oauth-advanced-location')));
      await tester.pumpAndSettle();
      expect(find.text('正在使用你自己的应用密钥'), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('oauth-root-id')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '/apps/My Sync',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
