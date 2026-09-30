import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/providers/oauth/oauth_callback_link_receiver.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_web_authentication_session.dart';

abstract interface class OAuthBrowserLauncher {
  Future<bool> launch(Uri authorizationUri);
}

class SystemOAuthBrowserLauncher implements OAuthBrowserLauncher {
  @override
  Future<bool> launch(Uri authorizationUri) =>
      launchUrl(authorizationUri, mode: LaunchMode.externalApplication);
}

/// Opens OAuth only in the platform browser; callback handling stays explicit.
class OAuthBrowserAuthorization {
  OAuthBrowserAuthorization({
    required OAuthAuthorizationService service,
    OAuthBrowserLauncher? browser,
    OAuthCallbackCapturer? capturer,
  }) : _service = service,
       _browser = browser ?? SystemOAuthBrowserLauncher(),
       _capturer = capturer;

  final OAuthAuthorizationService _service;
  final OAuthBrowserLauncher _browser;

  /// When present, sign-in runs in the platform web-authentication sheet,
  /// which returns the redirect directly and works for any scheme.
  final OAuthCallbackCapturer? _capturer;

  Future<void> begin(OAuthAuthorizationConfig config) async {
    final authorizationUri = await _service.begin(config);
    if (!await _browser.launch(authorizationUri)) {
      throw const OAuthBrowserLaunchException();
    }
  }

  Future<String> complete({
    required OAuthAuthorizationConfig config,
    required Uri callback,
  }) => _service.complete(config: config, callback: callback);

  /// Starts browser authorization and consumes the matching registered app
  /// callback. The receiver is armed before opening the browser so cold-start
  /// and fast callbacks cannot race the PKCE transaction.
  Future<String> authorize({
    required OAuthAuthorizationConfig config,
    required OAuthCallbackLinkReceiver callbackReceiver,
  }) async {
    final capturer = _capturer;
    if (capturer == null &&
        !OAuthCallbackLinkReceiver.isOAuthCallback(config.redirectUri)) {
      // Opening the browser would strand the user on a redirect no app
      // on this device can receive.
      throw OAuthRedirectUnsupportedException(config.redirectUri);
    }
    final authorizationUri = await _service.begin(config);
    if (capturer != null) {
      final callback = await capturer.capture(
        authorizationUri: authorizationUri,
        redirectUri: config.redirectUri,
      );
      return complete(config: config, callback: callback);
    }
    final state = authorizationUri.queryParameters['state'];
    if (state == null || state.isEmpty) {
      throw StateError('OAuth authorization URL is missing state.');
    }
    final callback = callbackReceiver.waitForCallback(state);
    if (!await _browser.launch(authorizationUri)) {
      throw const OAuthBrowserLaunchException();
    }
    return complete(config: config, callback: await callback);
  }

  Future<void> disconnect({
    required OAuthAuthorizationConfig config,
    required String credentialRef,
  }) => _service.disconnect(config: config, credentialRef: credentialRef);
}

class OAuthBrowserLaunchException implements Exception {
  const OAuthBrowserLaunchException();
  @override
  String toString() =>
      'OAuthBrowserLaunchException: Unable to open the system browser.';
}
