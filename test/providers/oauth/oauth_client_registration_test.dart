import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  group('OAuthClientRegistration.normalized', () {
    test('trims every field', () {
      final registration = OAuthClientRegistration.normalized(
        type: RemoteProviderType.baiduNetdisk,
        clientId: '  app-key ',
        clientSecret: ' secret\n',
        appFolderName: ' My Sync ',
      );
      expect(registration.clientId, 'app-key');
      expect(registration.clientSecret, 'secret');
      expect(registration.appFolderName, 'My Sync');
    });

    test('never pairs a Google or Microsoft public client with a secret', () {
      for (final type in [
        RemoteProviderType.googleDrive,
        RemoteProviderType.oneDrive,
      ]) {
        expect(
          () => OAuthClientRegistration.normalized(
            type: type,
            clientId: 'id',
            clientSecret: 'secret',
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'oauth.registration.secret_not_accepted',
            ),
          ),
        );
      }
    });

    test('Baidu needs its SecretKey; Aliyun does not', () {
      expect(
        () => OAuthClientRegistration.normalized(
          type: RemoteProviderType.baiduNetdisk,
          clientId: 'app-key',
          clientSecret: '  ',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'oauth.registration.secret_missing',
          ),
        ),
      );
      expect(
        OAuthClientRegistration.normalized(
          type: RemoteProviderType.aliyunDrive,
          clientId: 'app-id',
        ).clientSecret,
        isNull,
      );
    });

    test('rejects values that cannot work', () {
      String code(void Function() build) {
        try {
          build();
        } on FormatException catch (error) {
          return error.message;
        }
        return 'accepted';
      }

      expect(
        code(
          () => OAuthClientRegistration.normalized(
            type: RemoteProviderType.googleDrive,
            clientId: 'has space',
          ),
        ),
        'oauth.registration.client_id_invalid',
      );
      expect(
        code(
          () => OAuthClientRegistration.normalized(
            type: RemoteProviderType.baiduNetdisk,
            clientId: 'key',
            clientSecret: 'a b',
          ),
        ),
        'oauth.registration.secret_invalid',
      );
      for (final folder in ['a/b', r'a\b', '..', 'x' * 65]) {
        expect(
          code(
            () => OAuthClientRegistration.normalized(
              type: RemoteProviderType.baiduNetdisk,
              clientId: 'key',
              clientSecret: 'secret',
              appFolderName: folder,
            ),
          ),
          'oauth.registration.app_folder_invalid',
        );
      }
      expect(
        code(
          () => OAuthClientRegistration.normalized(
            type: RemoteProviderType.aliyunDrive,
            clientId: 'id',
            appFolderName: 'Only Baidu has one',
          ),
        ),
        'oauth.registration.app_folder_invalid',
      );
    });
  });

  group('secure JSON', () {
    test('round-trips', () {
      final original = OAuthClientRegistration.normalized(
        type: RemoteProviderType.baiduNetdisk,
        clientId: 'key',
        clientSecret: 'secret',
        appFolderName: 'My Sync',
      );
      final copy = OAuthClientRegistration.fromSecureJson(
        RemoteProviderType.baiduNetdisk,
        original.toSecureJson(),
      );
      expect(copy?.clientId, 'key');
      expect(copy?.clientSecret, 'secret');
      expect(copy?.appFolderName, 'My Sync');
      expect(
        OAuthClientRegistration.normalized(
          type: RemoteProviderType.googleDrive,
          clientId: 'id',
        ).toSecureJson(),
        {'clientId': 'id'},
      );
    });

    test('a damaged entry reads as no registration', () {
      for (final json in <Object?>[
        null,
        'not a map',
        <String, Object?>{},
        {'clientId': 42},
        {'clientId': 'key', 'clientSecret': 1},
        // Valid shape, but Baidu cannot work without its secret.
        {'clientId': 'key'},
      ]) {
        expect(
          OAuthClientRegistration.fromSecureJson(
            RemoteProviderType.baiduNetdisk,
            json,
          ),
          isNull,
          reason: '$json',
        );
      }
      // A secret smuggled into a Google entry is rejected, not ignored.
      expect(
        OAuthClientRegistration.fromSecureJson(RemoteProviderType.googleDrive, {
          'clientId': 'id',
          'clientSecret': 'secret',
        }),
        isNull,
      );
    });
  });

  group('fromUserRegistration', () {
    test('public clients get no secret and persist none', () {
      for (final type in [
        RemoteProviderType.googleDrive,
        RemoteProviderType.oneDrive,
      ]) {
        final config = OAuthPublicClientConfiguration.fromUserRegistration(
          providerType: type,
          registration: const OAuthClientRegistration(clientId: 'user-id'),
        );
        expect(config.clientId, 'user-id');
        expect(config.clientSecret, isNull);
        expect(config.persistClientSecret, isFalse);
      }
    });

    test('Baidu uses only the user secret and keeps it with the grant', () {
      final config = OAuthPublicClientConfiguration.fromUserRegistration(
        providerType: RemoteProviderType.baiduNetdisk,
        registration: const OAuthClientRegistration(
          clientId: 'user-key',
          clientSecret: 'user-secret',
        ),
      );
      expect(config.clientId, 'user-key');
      expect(config.clientSecret, 'user-secret');
      expect(config.persistClientSecret, isTrue);
      expect(config.tokenRequestFormat, OAuthTokenRequestFormat.query);
      expect(
        OAuthPublicClientConfiguration.isBuiltInClientId(
          RemoteProviderType.baiduNetdisk,
          'user-key',
        ),
        isFalse,
      );
      expect(
        () => OAuthPublicClientConfiguration.fromUserRegistration(
          providerType: RemoteProviderType.baiduNetdisk,
          registration: const OAuthClientRegistration(clientId: 'user-key'),
        ),
        throwsA(isA<OAuthClientRegistrationMissingException>()),
      );
    });

    test('Aliyun without a secret persists nothing', () {
      final config = OAuthPublicClientConfiguration.fromUserRegistration(
        providerType: RemoteProviderType.aliyunDrive,
        registration: const OAuthClientRegistration(clientId: 'app-id'),
      );
      expect(config.clientSecret, isNull);
      expect(config.persistClientSecret, isFalse);
    });
  });

  group('credential store', () {
    OAuthTokenBundle bundle(String access) => OAuthTokenBundle(
      accessToken: access,
      refreshToken: 'refresh',
      expiresAt: DateTime.utc(2030),
    );

    test('keeps a grant secret across token refreshes', () async {
      final store = InMemoryCredentialStore();
      final withSecret = await store.writeOAuthTokens(
        bundle('a'),
        clientSecret: 'user-secret',
      );
      final withoutSecret = await store.writeOAuthTokens(bundle('b'));
      expect(await store.readOAuthClientSecret(withSecret), 'user-secret');
      expect(await store.readOAuthClientSecret(withoutSecret), isNull);

      await store.updateOAuthTokens(withSecret, bundle('a2'));
      expect((await store.readOAuthTokens(withSecret))?.accessToken, 'a2');
      expect(await store.readOAuthClientSecret(withSecret), 'user-secret');
      expect(await store.readOAuthClientSecret('velock-sync/webdav/x'), isNull);
    });

    test('stores, replaces and removes a registration per provider', () async {
      final store = InMemoryCredentialStore();
      const google = OAuthClientRegistration(clientId: 'g');
      await store.writeOAuthClientRegistration(
        RemoteProviderType.googleDrive,
        google,
      );
      expect(
        await store.readOAuthClientRegistration(RemoteProviderType.oneDrive),
        isNull,
      );
      expect(
        (await store.readOAuthClientRegistration(
          RemoteProviderType.googleDrive,
        ))?.clientId,
        'g',
      );
      await store.deleteOAuthClientRegistration(RemoteProviderType.googleDrive);
      expect(
        await store.readOAuthClientRegistration(RemoteProviderType.googleDrive),
        isNull,
      );
    });
  });

  test('refresh sends the grant secret, not the build secret', () async {
    final store = InMemoryCredentialStore();
    final ref = await store.writeOAuthTokens(
      OAuthTokenBundle(
        accessToken: 'old',
        refreshToken: 'refresh',
        expiresAt: DateTime.utc(2000),
      ),
      clientSecret: 'user-secret',
    );
    final sent = <String?>[];
    final provider = OAuthAccessTokenProvider(
      credentialStore: store,
      tokenClient: OAuthTokenClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((options) async {
            sent.add(options.uri.queryParameters['client_secret']);
            return ResponseBody.fromString(
              '{"access_token":"new","refresh_token":"refresh-2","expires_in":3600}',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            );
          }),
        clock: () => DateTime.utc(2030),
      ),
      credentialRef: ref,
      clientId: 'user-key',
      tokenEndpoint: Uri.parse('https://token.example.test/token'),
      clientSecret: 'build-secret',
      tokenRequestFormat: OAuthTokenRequestFormat.query,
      clock: () => DateTime.utc(2030),
    );

    expect(await provider.bearerToken(), 'new');
    expect(sent, ['user-secret']);
    expect(await store.readOAuthClientSecret(ref), 'user-secret');
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) => _handler(options);
}
