import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';

/// Test-only credential store. Production code must use [SecureCredentialStore].
class InMemoryCredentialStore implements CredentialStore {
  InMemoryCredentialStore({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String credentialRef) async {
    _values.remove(credentialRef);
  }

  @override
  Future<String?> readWebDavPassword(String credentialRef) async =>
      credentialRef.startsWith('velock-sync/webdav/')
      ? _values[credentialRef]
      : null;

  @override
  Future<OAuthTokenBundle?> readOAuthTokens(String credentialRef) async {
    final encoded = _values[credentialRef];
    if (encoded == null || !credentialRef.startsWith('velock-sync/oauth/')) {
      return null;
    }
    final payload = jsonDecode(encoded);
    if (payload is! Map<String, dynamic>) return null;
    final accessToken = payload['accessToken'];
    final refreshToken = payload['refreshToken'];
    final expiry = payload['expiresAt'];
    if (accessToken is! String ||
        refreshToken is! String ||
        expiry is! String) {
      return null;
    }
    final expiresAt = DateTime.tryParse(expiry);
    if (expiresAt == null) return null;
    final scopes = payload['scopes'];
    return OAuthTokenBundle(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      tokenType: payload['tokenType'] is String
          ? payload['tokenType'] as String
          : 'Bearer',
      scopes: scopes is List ? scopes.whereType<String>().toSet() : const {},
    );
  }

  @override
  Future<String> writeWebDavPassword(String password) async {
    final ref = 'velock-sync/webdav/${_uuid.v4()}';
    _values[ref] = password;
    return ref;
  }

  @override
  Future<String> writeOAuthTokens(OAuthTokenBundle tokens) async {
    if (tokens.accessToken.isEmpty || tokens.refreshToken.isEmpty) {
      throw ArgumentError('OAuth access and refresh tokens must not be empty.');
    }
    final ref = 'velock-sync/oauth/${_uuid.v4()}';
    _values[ref] = jsonEncode({
      'accessToken': tokens.accessToken,
      'refreshToken': tokens.refreshToken,
      'expiresAt': tokens.expiresAt.toUtc().toIso8601String(),
      'tokenType': tokens.tokenType,
      'scopes': tokens.scopes.toList(growable: false),
    });
    return ref;
  }

  @override
  Future<void> updateOAuthTokens(
    String credentialRef,
    OAuthTokenBundle tokens,
  ) async {
    if (!credentialRef.startsWith('velock-sync/oauth/')) {
      throw ArgumentError.value(credentialRef, 'credentialRef');
    }
    if (!_values.containsKey(credentialRef)) {
      throw StateError('OAuth credential reference does not exist.');
    }
    _values[credentialRef] = jsonEncode({
      'accessToken': tokens.accessToken,
      'refreshToken': tokens.refreshToken,
      'expiresAt': tokens.expiresAt.toUtc().toIso8601String(),
      'tokenType': tokens.tokenType,
      'scopes': tokens.scopes.toList(growable: false),
    });
  }
}
