import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';

void main() {
  group('CredentialStore', () {
    test(
      'persists a secret behind an opaque reference and supports deletion',
      () async {
        final store = InMemoryCredentialStore();
        final ref = await store.writeWebDavPassword('not-in-preferences');

        expect(ref, startsWith('velock-sync/webdav/'));
        expect(ref, isNot(contains('not-in-preferences')));
        expect(await store.readWebDavPassword(ref), 'not-in-preferences');

        await store.delete(ref);
        expect(await store.readWebDavPassword(ref), isNull);
      },
    );
  });

  test(
    'stores OAuth refresh tokens behind a separate opaque reference',
    () async {
      final store = InMemoryCredentialStore();
      final ref = await store.writeOAuthTokens(
        OAuthTokenBundle(
          accessToken: 'access-token',
          refreshToken: 'refresh-token',
          expiresAt: DateTime.utc(2030),
          scopes: const {'offline_access', 'Files.ReadWrite'},
        ),
      );

      expect(ref, startsWith('velock-sync/oauth/'));
      expect(ref, isNot(contains('refresh-token')));
      expect(await store.readWebDavPassword(ref), isNull);
      final tokens = await store.readOAuthTokens(ref);
      expect(tokens?.refreshToken, 'refresh-token');
      expect(tokens?.scopes, contains('offline_access'));

      await store.updateOAuthTokens(
        ref,
        OAuthTokenBundle(
          accessToken: 'new-access',
          refreshToken: 'new-refresh',
          expiresAt: DateTime.utc(2031),
        ),
      );
      expect((await store.readOAuthTokens(ref))?.accessToken, 'new-access');

      await store.delete(ref);
      expect(await store.readOAuthTokens(ref), isNull);
    },
  );
}
