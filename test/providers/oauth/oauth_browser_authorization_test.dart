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
import 'package:velock_sync/providers/oauth/oauth_web_authentication_session.dart';

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

  group('web-authentication session', () {
    late StreamController<Uri> links;
    late OAuthCallbackLinkReceiver receiver;
    setUp(() {
      links = StreamController<Uri>();
      receiver = OAuthCallbackLinkReceiver(links.stream);
    });
    tearDown(() async {
      await receiver.dispose();
      await links.close();
    });

    test(
      'receives an undeclared per-client scheme without the browser',
      () async {
        final browser = _Browser();
        final credentials = InMemoryCredentialStore();
        final capturer = _Capturer(
          (uri) => Uri.parse(
            'com.googleusercontent.apps.123-abc:/oauth2redirect'
            '?state=${uri.queryParameters['state']}&code=code',
          ),
        );
        final ref = await _authorization(
          browser: browser,
          capturer: capturer,
          credentials: credentials,
        ).authorize(config: _googleStyleConfig, callbackReceiver: receiver);

        expect(await credentials.readOAuthTokens(ref), isNotNull);
        expect(capturer.redirectUri, _googleStyleConfig.redirectUri);
        expect(browser.launched, isNull);
      },
    );

    test('still validates state on the captured callback', () async {
      final credentials = InMemoryCredentialStore();
      final capturer = _Capturer(
        (_) => Uri.parse(
          'com.googleusercontent.apps.123-abc:/oauth2redirect'
          '?state=forged&code=code',
        ),
      );
      await expectLater(
        _authorization(
          browser: _Browser(),
          capturer: capturer,
          credentials: credentials,
        ).authorize(config: _googleStyleConfig, callbackReceiver: receiver),
        throwsA(isA<OAuthAuthorizationException>()),
      );
    });

    test(
      'without a session, an undeclared scheme never opens the browser',
      () async {
        final browser = _Browser();
        await expectLater(
          _authorization(
            browser: browser,
          ).authorize(config: _googleStyleConfig, callbackReceiver: receiver),
          throwsA(isA<OAuthRedirectUnsupportedException>()),
        );
        expect(browser.launched, isNull);
      },
    );
  });
}

OAuthBrowserAuthorization _authorization({
  required _Browser browser,
  OAuthCallbackCapturer? capturer,
  InMemoryCredentialStore? credentials,
}) => OAuthBrowserAuthorization(
  browser: browser,
  capturer: capturer,
  service: OAuthAuthorizationService(
    session: OAuthAuthorizationSession(
      stateStore: InMemoryOAuthAuthorizationStateStore(),
      random: Random(8),
    ),
    tokenClient: _TokenClient(),
    credentialStore: credentials ?? InMemoryCredentialStore(),
  ),
);

/// A user's own Google "iOS" client: its redirect scheme is not declared in
/// the app, so only a web-authentication session can receive it.
final _googleStyleConfig = OAuthAuthorizationConfig(
  providerId: 'provider',
  authorizationEndpoint: _config.authorizationEndpoint,
  tokenEndpoint: _config.tokenEndpoint,
  clientId: '123-abc.apps.googleusercontent.com',
  redirectUri: Uri.parse('com.googleusercontent.apps.123-abc:/oauth2redirect'),
  scopes: {'scope'},
);

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

class _Capturer implements OAuthCallbackCapturer {
  _Capturer(this.respond);

  final Uri Function(Uri authorizationUri) respond;
  Uri? redirectUri;

  @override
  Future<Uri> capture({
    required Uri authorizationUri,
    required Uri redirectUri,
  }) async {
    this.redirectUri = redirectUri;
    return respond(authorizationUri);
  }
}

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
    String? clientSecret,
    OAuthTokenRequestFormat format = OAuthTokenRequestFormat.form,
  }) async => OAuthTokenBundle(
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresAt: DateTime.utc(2031),
  );
}
