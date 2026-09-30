import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';

/// How a provider expects token requests to be encoded.
enum OAuthTokenRequestFormat {
  /// RFC 6749 form-encoded POST (Google, Microsoft).
  form,

  /// JSON POST body (Aliyun Drive open platform).
  json,

  /// GET with query parameters (Baidu Netdisk open platform).
  query,
}

/// Exchanges and refreshes OAuth credentials. Most providers are public PKCE
/// clients; [clientSecret] is only sent for providers whose published flow
/// requires one, and it is never written to storage or included in errors.
class OAuthTokenClient {
  OAuthTokenClient({Dio? dio, DateTime Function()? clock})
    : _dio = dio ?? Dio(),
      _clock = clock ?? DateTime.now;

  final Dio _dio;
  final DateTime Function() _clock;

  Future<OAuthTokenBundle> exchangeAuthorizationCode({
    required Uri tokenEndpoint,
    required String clientId,
    required Uri redirectUri,
    required String code,
    required String codeVerifier,
    String? clientSecret,
    OAuthTokenRequestFormat format = OAuthTokenRequestFormat.form,
  }) => _request(tokenEndpoint, format, {
    'grant_type': 'authorization_code',
    'client_id': clientId,
    'client_secret': ?clientSecret,
    'redirect_uri': redirectUri.toString(),
    'code': code,
    'code_verifier': codeVerifier,
  });

  Future<OAuthTokenBundle> refresh({
    required Uri tokenEndpoint,
    required String clientId,
    required OAuthTokenBundle current,
    String? clientSecret,
    OAuthTokenRequestFormat format = OAuthTokenRequestFormat.form,
  }) async {
    final refreshed = await _request(
      tokenEndpoint,
      format,
      {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'client_secret': ?clientSecret,
        'refresh_token': current.refreshToken,
      },
      allowMissingRefreshToken: true,
      previous: current,
    );
    return refreshed;
  }

  /// Revokes a refresh token when the OAuth provider publishes an RFC 7009
  /// compatible endpoint. This remains a public-client request: no secret is
  /// sent or stored by the app.
  Future<void> revoke({
    required Uri revocationEndpoint,
    required String refreshToken,
  }) async {
    try {
      await _dio.postUri<void>(
        revocationEndpoint,
        data: {'token': refreshToken, 'token_type_hint': 'refresh_token'},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (error) {
      throw OAuthTokenException(
        'OAuth revocation endpoint request failed (${error.response?.statusCode ?? 'network'}).',
      );
    }
  }

  Future<OAuthTokenBundle> _request(
    Uri endpoint,
    OAuthTokenRequestFormat format,
    Map<String, String> body, {
    bool allowMissingRefreshToken = false,
    OAuthTokenBundle? previous,
  }) async {
    try {
      final response = switch (format) {
        OAuthTokenRequestFormat.form => await _dio.postUri<Object>(
          endpoint,
          data: body,
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        OAuthTokenRequestFormat.json => await _dio.postUri<Object>(
          endpoint,
          data: body,
          options: Options(contentType: Headers.jsonContentType),
        ),
        OAuthTokenRequestFormat.query => await _dio.getUri<Object>(
          endpoint.replace(
            queryParameters: {...endpoint.queryParameters, ...body},
          ),
        ),
      };
      final raw = response.data;
      final data = raw is Map<String, dynamic>
          ? raw
          : raw is String && raw.trim().startsWith('{')
          ? jsonDecode(raw) as Map<String, dynamic>
          : null;
      final accessToken = data?['access_token'];
      final refreshToken = data?['refresh_token'];
      final expiresIn = data?['expires_in'];
      if (accessToken is! String ||
          accessToken.isEmpty ||
          (!allowMissingRefreshToken &&
              (refreshToken is! String || refreshToken.isEmpty))) {
        throw const OAuthTokenException('OAuth token response is incomplete.');
      }
      final seconds = expiresIn is int
          ? expiresIn
          : expiresIn is num
          ? expiresIn.toInt()
          : int.tryParse('$expiresIn');
      if (seconds == null || seconds <= 0) {
        throw const OAuthTokenException('OAuth token response has no expiry.');
      }
      final scope = data?['scope'];
      return OAuthTokenBundle(
        accessToken: accessToken,
        refreshToken: refreshToken is String && refreshToken.isNotEmpty
            ? refreshToken
            : previous!.refreshToken,
        expiresAt: _clock().toUtc().add(Duration(seconds: seconds)),
        tokenType: data?['token_type'] is String
            ? data!['token_type'] as String
            : 'Bearer',
        scopes: scope is String
            ? scope
                  .split(RegExp(r'[\s,]+'))
                  .where((value) => value.isNotEmpty)
                  .toSet()
            : previous?.scopes ?? const {},
      );
    } on OAuthTokenException {
      rethrow;
    } on FormatException {
      throw const OAuthTokenException('OAuth token response is malformed.');
    } on DioException catch (error) {
      throw OAuthTokenException(
        'OAuth token endpoint request failed (${error.response?.statusCode ?? 'network'}).',
      );
    }
  }
}

class OAuthTokenException implements Exception {
  const OAuthTokenException(this.message);

  final String message;

  @override
  String toString() => 'OAuthTokenException: $message';
}
