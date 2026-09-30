import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Shows the authorization page in the platform's web-authentication sheet
/// and returns the redirect it captured, without the app having to declare
/// the redirect scheme. That is what lets a user's own Google "iOS" client
/// (whose scheme is its reversed Client ID) sign in at all.
abstract interface class OAuthCallbackCapturer {
  Future<Uri> capture({
    required Uri authorizationUri,
    required Uri redirectUri,
  });
}

/// `ASWebAuthenticationSession` on iOS. Null on platforms without it, where
/// only the bundle-declared `velocksync://` callback can be received.
class PlatformOAuthCallbackCapturer implements OAuthCallbackCapturer {
  const PlatformOAuthCallbackCapturer._();

  static const _channel = MethodChannel('tech.windata.velock.sync/web_auth');

  static OAuthCallbackCapturer? forCurrentPlatform() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
      ? const PlatformOAuthCallbackCapturer._()
      : null;

  @override
  Future<Uri> capture({
    required Uri authorizationUri,
    required Uri redirectUri,
  }) async {
    final String? callback;
    try {
      callback = await _channel.invokeMethod<String>('authenticate', {
        'url': authorizationUri.toString(),
        'callbackScheme': redirectUri.scheme,
      });
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') {
        throw const OAuthAuthorizationCancelledException();
      }
      rethrow;
    }
    final uri = callback == null ? null : Uri.tryParse(callback);
    // The sheet only completes on this scheme, but the result is still
    // checked: state and code validation happen later in the session.
    if (uri == null || uri.scheme != redirectUri.scheme) {
      throw StateError('Web authentication returned an unexpected callback.');
    }
    return uri;
  }
}

/// The user closed the sign-in sheet. Not an error worth reporting.
class OAuthAuthorizationCancelledException implements Exception {
  const OAuthAuthorizationCancelledException();

  @override
  String toString() => 'OAuthAuthorizationCancelledException';
}

/// The redirect this registration needs cannot be received on this platform
/// (for example a Google client's reversed-ID scheme outside iOS).
class OAuthRedirectUnsupportedException implements Exception {
  const OAuthRedirectUnsupportedException(this.redirectUri);

  final Uri redirectUri;

  @override
  String toString() =>
      'OAuthRedirectUnsupportedException(${redirectUri.scheme})';
}
