import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:velock_sync/providers/oauth/oauth_pkce.dart';

/// A short-lived PKCE transaction retained across a system-browser redirect.
class OAuthPendingAuthorization {
  const OAuthPendingAuthorization({
    required this.state,
    required this.verifier,
    required this.createdAt,
  });

  final String state;
  final String verifier;
  final DateTime createdAt;
}

abstract interface class OAuthAuthorizationStateStore {
  Future<void> save(String providerId, OAuthPendingAuthorization pending);
  Future<OAuthPendingAuthorization?> read(String providerId);
  Future<void> delete(String providerId);
}

/// Platform-secure state storage; authorization state is not regular app data.
class SecureOAuthAuthorizationStateStore
    implements OAuthAuthorizationStateStore {
  SecureOAuthAuthorizationStateStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'velock-sync/oauth-pending/';
  final FlutterSecureStorage _storage;

  @override
  Future<void> save(String providerId, OAuthPendingAuthorization pending) =>
      _storage.write(
        key: _key(providerId),
        value: jsonEncode({
          'state': pending.state,
          'verifier': pending.verifier,
          'createdAt': pending.createdAt.toUtc().toIso8601String(),
        }),
      );

  @override
  Future<OAuthPendingAuthorization?> read(String providerId) async {
    final encoded = await _storage.read(key: _key(providerId));
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['state'] is! String ||
          value['verifier'] is! String ||
          value['createdAt'] is! String) {
        return null;
      }
      final createdAt = DateTime.tryParse(value['createdAt'] as String);
      if (createdAt == null) return null;
      return OAuthPendingAuthorization(
        state: value['state'] as String,
        verifier: value['verifier'] as String,
        createdAt: createdAt.toUtc(),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> delete(String providerId) =>
      _storage.delete(key: _key(providerId));

  static String _key(String providerId) {
    if (providerId.isEmpty || providerId.contains('/')) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    return '$_prefix$providerId';
  }
}

class InMemoryOAuthAuthorizationStateStore
    implements OAuthAuthorizationStateStore {
  final Map<String, OAuthPendingAuthorization> _pending = {};
  @override
  Future<void> delete(String providerId) async => _pending.remove(providerId);
  @override
  Future<OAuthPendingAuthorization?> read(String providerId) async =>
      _pending[providerId];
  @override
  Future<void> save(
    String providerId,
    OAuthPendingAuthorization pending,
  ) async => _pending[providerId] = pending;
}

class OAuthAuthorizationSession {
  OAuthAuthorizationSession({
    required OAuthAuthorizationStateStore stateStore,
    this.maximumAge = const Duration(minutes: 10),
    Random? random,
    DateTime Function()? clock,
  }) : _stateStore = stateStore,
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final OAuthAuthorizationStateStore _stateStore;
  final Duration maximumAge;
  final Random _random;
  final DateTime Function() _clock;

  Future<Uri> begin({
    required String providerId,
    required Uri authorizationEndpoint,
    required String clientId,
    required Uri redirectUri,
    required Iterable<String> scopes,
    Map<String, String> additionalParameters = const {},
  }) async {
    final pkce = OAuthPkce.generate(random: _random);
    final state = _randomString();
    await _stateStore.save(
      providerId,
      OAuthPendingAuthorization(
        state: state,
        verifier: pkce.verifier,
        createdAt: _clock().toUtc(),
      ),
    );
    return OAuthPkce.authorizationUri(
      endpoint: authorizationEndpoint,
      clientId: clientId,
      redirectUri: redirectUri,
      scopes: scopes,
      state: state,
      pkce: pkce,
      additionalParameters: additionalParameters,
    );
  }

  /// Validates and consumes a callback before its code is exchanged for tokens.
  Future<OAuthAuthorizationGrant> consumeCallback({
    required String providerId,
    required Uri callback,
  }) async {
    final pending = await _stateStore.read(providerId);
    if (pending == null) {
      throw const OAuthAuthorizationException('No pending authorization.');
    }
    if (!_clock().toUtc().isBefore(pending.createdAt.add(maximumAge))) {
      await _stateStore.delete(providerId);
      throw const OAuthAuthorizationException('Authorization state expired.');
    }
    final states = callback.queryParametersAll['state'];
    if (states == null ||
        states.length != 1 ||
        states.single != pending.state) {
      throw const OAuthAuthorizationException('Authorization state mismatch.');
    }
    final error = callback.queryParameters['error'];
    if (error != null) {
      await _stateStore.delete(providerId);
      throw OAuthAuthorizationException(
        'Provider authorization failed: $error',
      );
    }
    final codes = callback.queryParametersAll['code'];
    if (codes == null || codes.length != 1 || codes.single.isEmpty) {
      throw const OAuthAuthorizationException('Authorization code is missing.');
    }
    await _stateStore.delete(providerId);
    return OAuthAuthorizationGrant(
      code: codes.single,
      verifier: pending.verifier,
    );
  }

  String _randomString() => base64UrlEncode(
    Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256))),
  ).replaceAll('=', '');
}

class OAuthAuthorizationGrant {
  const OAuthAuthorizationGrant({required this.code, required this.verifier});
  final String code;
  final String verifier;
}

class OAuthAuthorizationException implements Exception {
  const OAuthAuthorizationException(this.message);
  final String message;
  @override
  String toString() => 'OAuthAuthorizationException: $message';
}
