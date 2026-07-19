import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

void main() {
  test('provides public-client defaults with the minimum provider scopes', () {
    final redirectUri = Uri.parse('velocksync://oauth/callback');

    final google = OAuthAuthorizationConfig.googleDrive(
      clientId: 'google-client',
      redirectUri: redirectUri,
    );
    final oneDrive = OAuthAuthorizationConfig.oneDrive(
      clientId: 'microsoft-client',
      redirectUri: redirectUri,
    );

    expect(google.providerId, 'googleDrive');
    expect(google.scopes, {'https://www.googleapis.com/auth/drive.file'});
    expect(google.revocationEndpoint?.host, 'oauth2.googleapis.com');
    expect(oneDrive.providerId, 'oneDrive');
    expect(oneDrive.scopes, {'Files.ReadWrite', 'offline_access'});
    expect(oneDrive.revocationEndpoint, isNull);
  });

  test(
    'exchanges a consumed callback and returns only a secure credential reference',
    () async {
      final credentials = InMemoryCredentialStore();
      final service = OAuthAuthorizationService(
        session: OAuthAuthorizationSession(
          stateStore: InMemoryOAuthAuthorizationStateStore(),
          random: Random(7),
          clock: () => DateTime.utc(2030),
        ),
        tokenClient: _TokenClient(),
        credentialStore: credentials,
      );
      final config = OAuthAuthorizationConfig(
        providerId: 'google',
        authorizationEndpoint: Uri.parse('https://accounts.example.test/auth'),
        tokenEndpoint: Uri.parse('https://accounts.example.test/token'),
        clientId: 'public-client',
        redirectUri: Uri.parse('velocksync://oauth/callback'),
        scopes: const {'scope'},
      );
      final launch = await service.begin(config);
      final ref = await service.complete(
        config: config,
        callback: Uri.parse(
          'velocksync://oauth/callback?state=${launch.queryParameters['state']}&code=code',
        ),
      );
      expect(ref, startsWith('velock-sync/oauth/'));
      expect(ref, isNot(contains('refresh-token')));
      expect(
        (await credentials.readOAuthTokens(ref))?.refreshToken,
        'refresh-token',
      );
    },
  );

  test(
    'revokes a supported grant before removing its secure credential',
    () async {
      final credentials = InMemoryCredentialStore();
      final tokenClient = _TokenClient();
      final service = OAuthAuthorizationService(
        session: OAuthAuthorizationSession(
          stateStore: InMemoryOAuthAuthorizationStateStore(),
          random: Random(7),
          clock: () => DateTime.utc(2030),
        ),
        tokenClient: tokenClient,
        credentialStore: credentials,
      );
      final config = OAuthAuthorizationConfig(
        providerId: 'google',
        authorizationEndpoint: Uri.parse('https://accounts.example.test/auth'),
        tokenEndpoint: Uri.parse('https://accounts.example.test/token'),
        revocationEndpoint: Uri.parse('https://accounts.example.test/revoke'),
        clientId: 'public-client',
        redirectUri: Uri.parse('velocksync://oauth/callback'),
        scopes: const {'scope'},
      );
      final launch = await service.begin(config);
      final ref = await service.complete(
        config: config,
        callback: Uri.parse(
          'velocksync://oauth/callback?state=${launch.queryParameters['state']}&code=code',
        ),
      );

      await service.disconnect(config: config, credentialRef: ref);

      expect(tokenClient.revokedRefreshToken, 'refresh-token');
      expect(await credentials.readOAuthTokens(ref), isNull);
    },
  );
}

class _TokenClient extends OAuthTokenClient {
  String? revokedRefreshToken;

  @override
  Future<OAuthTokenBundle> exchangeAuthorizationCode({
    required Uri tokenEndpoint,
    required String clientId,
    required Uri redirectUri,
    required String code,
    required String codeVerifier,
  }) async => OAuthTokenBundle(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.utc(2031),
  );

  @override
  Future<void> revoke({
    required Uri revocationEndpoint,
    required String refreshToken,
  }) async {
    revokedRefreshToken = refreshToken;
  }
}
