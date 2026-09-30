import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_credentials.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Stores provider secrets outside regular application preferences and sync
/// state. The returned reference is safe to persist in a connection record.
abstract interface class CredentialStore {
  Future<String> writeWebDavPassword(String password);

  Future<String?> readWebDavPassword(String credentialRef);

  /// Stores OAuth tokens outside the connection database and sync payloads.
  ///
  /// [clientSecret] is kept with the grant when the user supplied their own
  /// app registration, so refreshing keeps working even if that registration
  /// is later changed or removed.
  Future<String> writeOAuthTokens(
    OAuthTokenBundle tokens, {
    String? clientSecret,
  });

  Future<OAuthTokenBundle?> readOAuthTokens(String credentialRef);

  /// The secret stored with this grant by [writeOAuthTokens], if any.
  Future<String?> readOAuthClientSecret(String credentialRef);

  /// Replaces a token bundle at its existing opaque reference after refresh.
  /// A secret stored with the grant is kept.
  Future<void> updateOAuthTokens(String credentialRef, OAuthTokenBundle tokens);

  /// The user's own app registration for [type], used instead of the one
  /// built into this app.
  Future<void> writeOAuthClientRegistration(
    RemoteProviderType type,
    OAuthClientRegistration registration,
  );

  Future<OAuthClientRegistration?> readOAuthClientRegistration(
    RemoteProviderType type,
  );

  Future<void> deleteOAuthClientRegistration(RemoteProviderType type);

  /// Stores the optional, manually configured Baidu OAuth bundle outside the
  /// connection database. This is a staging credential only; the Baidu
  /// RemoteObjectStore is not enabled yet.
  Future<void> writeBaiduNetdiskCredentials(
    BaiduNetdiskCredentialBundle credentials,
  );

  Future<BaiduNetdiskCredentialBundle?> readBaiduNetdiskCredentials();

  Future<void> deleteBaiduNetdiskCredentials();

  Future<void> delete(String credentialRef);
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage, Uuid? uuid})
    : _storage = storage ?? const FlutterSecureStorage(),
      _uuid = uuid ?? const Uuid();

  static const _webDavPrefix = 'velock-sync/webdav/';
  static const _oauthPrefix = 'velock-sync/oauth/';
  static const _baiduNetdiskKey = 'velock-sync/baidu-netdisk/credentials';
  static const _oauthClientPrefix = 'velock-sync/oauth-client/';

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
  Future<String> writeOAuthTokens(
    OAuthTokenBundle tokens, {
    String? clientSecret,
  }) async {
    if (tokens.accessToken.isEmpty || tokens.refreshToken.isEmpty) {
      throw ArgumentError('OAuth access and refresh tokens must not be empty.');
    }
    final credentialRef = '$_oauthPrefix${_uuid.v4()}';
    await _storage.write(
      key: credentialRef,
      value: encodeOAuthGrant(tokens, clientSecret: clientSecret),
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
  Future<String?> readOAuthClientSecret(String credentialRef) async {
    if (!credentialRef.startsWith(_oauthPrefix)) return null;
    return decodeOAuthGrantSecret(await _storage.read(key: credentialRef));
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
    final secret = decodeOAuthGrantSecret(
      await _storage.read(key: credentialRef),
    );
    await _storage.write(
      key: credentialRef,
      value: encodeOAuthGrant(tokens, clientSecret: secret),
    );
  }

  @override
  Future<void> writeOAuthClientRegistration(
    RemoteProviderType type,
    OAuthClientRegistration registration,
  ) => _storage.write(
    key: '$_oauthClientPrefix${type.name}',
    value: jsonEncode(registration.toSecureJson()),
  );

  @override
  Future<OAuthClientRegistration?> readOAuthClientRegistration(
    RemoteProviderType type,
  ) async {
    final encoded = await _storage.read(key: '$_oauthClientPrefix${type.name}');
    if (encoded == null) return null;
    try {
      return OAuthClientRegistration.fromSecureJson(type, jsonDecode(encoded));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> deleteOAuthClientRegistration(RemoteProviderType type) =>
      _storage.delete(key: '$_oauthClientPrefix${type.name}');

  @override
  Future<void> writeBaiduNetdiskCredentials(
    BaiduNetdiskCredentialBundle credentials,
  ) async {
    if (credentials.appKey.trim().isEmpty ||
        credentials.accessToken.trim().isEmpty) {
      throw ArgumentError('Baidu AppKey and access token must not be empty.');
    }
    await _storage.write(
      key: _baiduNetdiskKey,
      value: jsonEncode(credentials.toSecureJson()),
    );
  }

  @override
  Future<BaiduNetdiskCredentialBundle?> readBaiduNetdiskCredentials() async {
    final encoded = await _storage.read(key: _baiduNetdiskKey);
    if (encoded == null) return null;
    try {
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic>) return null;
      return BaiduNetdiskCredentialBundle.fromSecureJson(json);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> deleteBaiduNetdiskCredentials() =>
      _storage.delete(key: _baiduNetdiskKey);

  @override
  Future<void> delete(String credentialRef) =>
      _storage.delete(key: credentialRef);
}

/// One JSON shape for a stored grant, shared by every [CredentialStore].
String encodeOAuthGrant(OAuthTokenBundle tokens, {String? clientSecret}) =>
    jsonEncode({
      'accessToken': tokens.accessToken,
      'refreshToken': tokens.refreshToken,
      'expiresAt': tokens.expiresAt.toUtc().toIso8601String(),
      'tokenType': tokens.tokenType,
      'scopes': tokens.scopes.toList(growable: false),
      if (clientSecret != null && clientSecret.isNotEmpty)
        'clientSecret': clientSecret,
    });

String? decodeOAuthGrantSecret(String? encoded) {
  if (encoded == null) return null;
  try {
    final json = jsonDecode(encoded);
    if (json is! Map<String, dynamic>) return null;
    final secret = json['clientSecret'];
    return secret is String && secret.isNotEmpty ? secret : null;
  } on FormatException {
    return null;
  }
}
