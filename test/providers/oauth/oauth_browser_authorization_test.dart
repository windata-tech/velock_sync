import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_browser_authorization.dart';
import 'package:velock_sync/providers/oauth/oauth_callback_link_receiver.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

void main() {
  test(
    'opens the PKCE URL through the injected system browser launcher',
    () async {
      final browser = _Browser();
      final authorization = OAuthBrowserAuthorization(
        browser: browser,
        service: OAuthAuthorizationService(
          session: OAuthAuthorizationSession(
            stateStore: InMemoryOAuthAuthorizationStateStore(),
            random: Random(8),
          ),
          tokenClient: OAuthTokenClient(),
          credentialStore: InMemoryCredentialStore(),
        ),
      );
      await authorization.begin(_config);
      expect(browser.launched?.host, 'accounts.example.test');
      expect(
        browser.launched?.queryParameters['code_challenge_method'],
        'S256',
      );
    },
  );

  test(
    'completes only the callback whose state matches the browser flow',
    () async {
      final links = StreamController<Uri>();
      final receiver = OAuthCallbackLinkReceiver(links.stream);
      addTearDown(() async {
        await receiver.dispose();
        await links.close();
      });
      final browser = _Browser();
      final credentials = InMemoryCredentialStore();
      final authorization = OAuthBrowserAuthorization(
        browser: browser,
        service: OAuthAuthorizationService(
          session: OAuthAuthorizationSession(
            stateStore: InMemoryOAuthAuthorizationStateStore(),
            random: Random(8),
          ),
          tokenClient: _TokenClient(),
          credentialStore: credentials,
        ),
      );

      final credential = authorization.authorize(
        config: _config,
        callbackReceiver: receiver,
      );
      await Future<void>.delayed(Duration.zero);
      links.add(
        Uri.parse(
          'velocksync://oauth/callback?state=${browser.launched!.queryParameters['state']}&code=code',
        ),
      );

      final ref = await credential;
      expect(await credentials.readOAuthTokens(ref), isNotNull);
    },
  );
}

final _config = OAuthAuthorizationConfig(
  providerId: 'provider',
  authorizationEndpoint: Uri(
    scheme: 'https',
    host: 'accounts.example.test',
    path: '/authorize',
  ),
  tokenEndpoint: Uri(
    scheme: 'https',
    host: 'accounts.example.test',
    path: '/token',
  ),
  clientId: 'public-client',
  redirectUri: Uri(scheme: 'velocksync', host: 'oauth', path: '/callback'),
  scopes: {'scope'},
);

class _Browser implements OAuthBrowserLauncher {
  Uri? launched;
  @override
  Future<bool> launch(Uri authorizationUri) async {
    launched = authorizationUri;
    return true;
  }
}

class _TokenClient extends OAuthTokenClient {
  @override
  Future<OAuthTokenBundle> exchangeAuthorizationCode({
    required Uri tokenEndpoint,
    required String clientId,
    required Uri redirectUri,
    required String code,
    required String codeVerifier,
  }) async => OAuthTokenBundle(
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresAt: DateTime.utc(2031),
  );
}
