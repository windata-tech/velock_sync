import 'dart:async';

import 'package:app_links/app_links.dart';

/// Receives only the registered OAuth callback scheme and keeps a callback
/// until its PKCE state is claimed. Token handling stays in the authorization
/// service, which validates state and exchanges the code.
class OAuthCallbackLinkReceiver {
  OAuthCallbackLinkReceiver(Stream<Uri> links) {
    _subscription = links.listen(_accept);
  }

  factory OAuthCallbackLinkReceiver.system() =>
      OAuthCallbackLinkReceiver(AppLinks().uriLinkStream);

  late final StreamSubscription<Uri> _subscription;
  final _callbacks = StreamController<Uri>.broadcast();
  final Map<String, Uri> _pendingByState = {};

  Future<Uri> waitForCallback(String state) {
    final pending = _pendingByState.remove(state);
    if (pending != null) return Future.value(pending);
    return _callbacks.stream
        .firstWhere((callback) => callback.queryParameters['state'] == state)
        .then((callback) {
          _pendingByState.remove(state);
          return callback;
        });
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await _callbacks.close();
  }

  void _accept(Uri callback) {
    if (!isOAuthCallback(callback)) return;
    final state = callback.queryParameters['state'];
    if (state == null || state.isEmpty) return;
    _pendingByState[state] = callback;
    _callbacks.add(callback);
  }

  static bool isOAuthCallback(Uri uri) =>
      uri.scheme == 'velocksync' &&
      uri.host == 'oauth' &&
      uri.path == '/callback';
}
