import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';

/// Stores provider secrets outside regular application preferences and sync
/// state. The returned reference is safe to persist in a connection record.
abstract interface class CredentialStore {
  Future<String> writeWebDavPassword(String password);

  Future<String?> readWebDavPassword(String credentialRef);

  /// Stores OAuth tokens outside the connection database and sync payloads.
  Future<String> writeOAuthTokens(OAuthTokenBundle tokens);

  Future<OAuthTokenBundle?> readOAuthTokens(String credentialRef);

  /// Replaces a token bundle at its existing opaque reference after refresh.
  Future<void> updateOAuthTokens(String credentialRef, OAuthTokenBundle tokens);

  Future<void> delete(String credentialRef);
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage, Uuid? uuid})
    : _storage = storage ?? const FlutterSecureStorage(),
      _uuid = uuid ?? const Uuid();

  static const _webDavPrefix = 'velock-sync/webdav/';
  static const _oauthPrefix = 'velock-sync/oauth/';

  final FlutterSecureStorage _storage;
  final Uuid _uuid;

  @override
  Future<String> writeWebDavPassword(String password) async {
    if (password.isEmpty) {
      throw ArgumentError.value(password, 'password', 'must not be empty');
    }
    final credentialRef = '$_webDavPrefix${_uuid.v4()}';
    await _storage.write(key: credentialRef, value: password);
    return credentialRef;
  }

  @override
  Future<String?> readWebDavPassword(String credentialRef) {
    if (!credentialRef.startsWith(_webDavPrefix)) return Future.value(null);
    return _storage.read(key: credentialRef);
  }

  @override
  Future<String> writeOAuthTokens(OAuthTokenBundle tokens) async {
    if (tokens.accessToken.isEmpty || tokens.refreshToken.isEmpty) {
      throw ArgumentError('OAuth access and refresh tokens must not be empty.');
    }
    final credentialRef = '$_oauthPrefix${_uuid.v4()}';
    await _storage.write(
      key: credentialRef,
      value: jsonEncode({
        'accessToken': tokens.accessToken,
        'refreshToken': tokens.refreshToken,
        'expiresAt': tokens.expiresAt.toUtc().toIso8601String(),
        'tokenType': tokens.tokenType,
        'scopes': tokens.scopes.toList(growable: false),
      }),
    );
    return credentialRef;
  }

  @override
  Future<OAuthTokenBundle?> readOAuthTokens(String credentialRef) async {
    if (!credentialRef.startsWith(_oauthPrefix)) return null;
    final encoded = await _storage.read(key: credentialRef);
    if (encoded == null) return null;
    try {
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic>) return null;
      final accessToken = json['accessToken'];
      final refreshToken = json['refreshToken'];
      final expiresAt = json['expiresAt'];
      if (accessToken is! String ||
          accessToken.isEmpty ||
          refreshToken is! String ||
          refreshToken.isEmpty ||
          expiresAt is! String) {
        return null;
      }
      final parsedExpiry = DateTime.tryParse(expiresAt);
      if (parsedExpiry == null) return null;
      final scopes = json['scopes'];
      return OAuthTokenBundle(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: parsedExpiry.toUtc(),
        tokenType: json['tokenType'] is String
            ? json['tokenType'] as String
            : 'Bearer',
        scopes: scopes is List ? scopes.whereType<String>().toSet() : const {},
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> updateOAuthTokens(
    String credentialRef,
    OAuthTokenBundle tokens,
  ) async {
    if (!credentialRef.startsWith(_oauthPrefix)) {
      throw ArgumentError.value(credentialRef, 'credentialRef');
    }
    if (tokens.accessToken.isEmpty || tokens.refreshToken.isEmpty) {
      throw ArgumentError('OAuth access and refresh tokens must not be empty.');
    }
    await _storage.write(
      key: credentialRef,
      value: jsonEncode({
        'accessToken': tokens.accessToken,
        'refreshToken': tokens.refreshToken,
        'expiresAt': tokens.expiresAt.toUtc().toIso8601String(),
        'tokenType': tokens.tokenType,
        'scopes': tokens.scopes.toList(growable: false),
      }),
    );
  }

  @override
  Future<void> delete(String credentialRef) =>
      _storage.delete(key: credentialRef);
}
