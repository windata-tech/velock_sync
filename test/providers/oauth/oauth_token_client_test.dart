import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

void main() {
  group('OAuthTokenClient', () {
    test(
      'exchanges an authorization code using PKCE without a client secret',
      () async {
        final adapter = _FakeAdapter((options) {
          expect(options.data['grant_type'], 'authorization_code');
          expect(options.data['code_verifier'], 'verifier');
          expect(options.data, isNot(contains('client_secret')));
          return _response(options, {
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_in': 3600,
            'scope': 'files.read offline_access',
          });
        });
        final client = OAuthTokenClient(
          dio: Dio()..httpClientAdapter = adapter,
          clock: () => DateTime.utc(2030),
        );

        final tokens = await client.exchangeAuthorizationCode(
          tokenEndpoint: Uri.parse('https://token.example.test/token'),
          clientId: 'public-client',
          redirectUri: Uri.parse('velocksync://oauth/callback'),
          code: 'code',
          codeVerifier: 'verifier',
        );

        expect(tokens.refreshToken, 'refresh');
        expect(tokens.expiresAt, DateTime.utc(2030, 1, 1, 1));
      },
    );

    test(
      'keeps the prior refresh token when a refresh response omits it',
      () async {
        final client = OAuthTokenClient(
          dio: Dio()
            ..httpClientAdapter = _FakeAdapter(
              (options) => _response(options, {
                'access_token': 'new-access',
                'expires_in': 60,
              }),
            ),
          clock: () => DateTime.utc(2030),
        );
        final tokens = await client.refresh(
          tokenEndpoint: Uri.parse('https://token.example.test/token'),
          clientId: 'public-client',
          current: OAuthTokenBundle(
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            expiresAt: DateTime.utc(2029),
          ),
        );
        expect(tokens.accessToken, 'new-access');
        expect(tokens.refreshToken, 'old-refresh');
      },
    );

    test('revokes a refresh token without a client secret', () async {
      final client = OAuthTokenClient(
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) {
            expect(options.data['token'], 'refresh');
            expect(options.data['token_type_hint'], 'refresh_token');
            expect(options.data, isNot(contains('client_secret')));
            return _response(options, {});
          }),
      );

      await client.revoke(
        revocationEndpoint: Uri.parse('https://token.example.test/revoke'),
        refreshToken: 'refresh',
      );
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) => _handler(options);
}

Future<ResponseBody> _response(
  RequestOptions options,
  Map<String, dynamic> response,
) async => ResponseBody.fromString(
  jsonEncode(response),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
