import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

void main() {
  test(
    'refreshes expiring tokens in place and can force a retry refresh',
    () async {
      var calls = 0;
      final store = InMemoryCredentialStore();
      final ref = await store.writeOAuthTokens(
        OAuthTokenBundle(
          accessToken: 'old-access',
          refreshToken: 'refresh',
          expiresAt: DateTime.utc(2030),
        ),
      );
      final provider = OAuthAccessTokenProvider(
        credentialStore: store,
        tokenClient: OAuthTokenClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter((options) async {
              calls++;
              return ResponseBody.fromString(
                '{"access_token":"access-$calls","expires_in":3600}',
                200,
                headers: {
                  Headers.contentTypeHeader: [Headers.jsonContentType],
                },
              );
            }),
          clock: () => DateTime.utc(2030),
        ),
        credentialRef: ref,
        clientId: 'public-client',
        tokenEndpoint: Uri.parse('https://token.example.test/token'),
        clock: () => DateTime.utc(2030),
      );

      expect(await provider.bearerToken(), 'access-1');
      expect(await provider.bearerToken(), 'access-1');
      expect(await provider.bearerToken(forceRefresh: true), 'access-2');
      expect(calls, 2);
      expect((await store.readOAuthTokens(ref))?.accessToken, 'access-2');
    },
  );
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this._handler);

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
