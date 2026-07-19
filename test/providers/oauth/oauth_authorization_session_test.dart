import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';

void main() {
  test(
    'persists a PKCE transaction and consumes a matching callback once',
    () async {
      final store = InMemoryOAuthAuthorizationStateStore();
      final session = OAuthAuthorizationSession(
        stateStore: store,
        random: Random(4),
        clock: () => DateTime.utc(2030),
      );
      final authorization = await session.begin(
        providerId: 'google',
        authorizationEndpoint: Uri.parse('https://accounts.example.test/auth'),
        clientId: 'public-client',
        redirectUri: Uri.parse('velocksync://oauth/callback'),
        scopes: const ['scope'],
      );
      final grant = await session.consumeCallback(
        providerId: 'google',
        callback: Uri.parse(
          'velocksync://oauth/callback?state=${authorization.queryParameters['state']}&code=code',
        ),
      );
      expect(grant.code, 'code');
      expect(grant.verifier.length, greaterThanOrEqualTo(43));
      await expectLater(
        session.consumeCallback(providerId: 'google', callback: authorization),
        throwsA(isA<OAuthAuthorizationException>()),
      );
    },
  );

  test(
    'does not consume a pending transaction for a mismatched state',
    () async {
      final store = InMemoryOAuthAuthorizationStateStore();
      final session = OAuthAuthorizationSession(
        stateStore: store,
        random: Random(5),
        clock: () => DateTime.utc(2030),
      );
      final authorization = await session.begin(
        providerId: 'one-drive',
        authorizationEndpoint: Uri.parse('https://login.example.test/auth'),
        clientId: 'client',
        redirectUri: Uri.parse('velocksync://callback'),
        scopes: const ['scope'],
      );
      await expectLater(
        session.consumeCallback(
          providerId: 'one-drive',
          callback: Uri.parse('velocksync://callback?state=wrong&code=x'),
        ),
        throwsA(isA<OAuthAuthorizationException>()),
      );
      expect(await store.read('one-drive'), isNotNull);
      expect(authorization.queryParameters['state'], isNot('wrong'));
    },
  );

  test('expires and clears abandoned authorization state', () async {
    final store = InMemoryOAuthAuthorizationStateStore();
    final session = OAuthAuthorizationSession(
      stateStore: store,
      maximumAge: const Duration(minutes: 1),
      random: Random(6),
      clock: () => DateTime.utc(2030, 1, 1, 0, 2),
    );
    await store.save(
      'provider',
      OAuthPendingAuthorization(
        state: 'state',
        verifier: 'a' * 43,
        createdAt: DateTime.utc(2030),
      ),
    );
    await expectLater(
      session.consumeCallback(
        providerId: 'provider',
        callback: Uri.parse('velocksync://callback?state=state&code=x'),
      ),
      throwsA(isA<OAuthAuthorizationException>()),
    );
    expect(await store.read('provider'), isNull);
  });
}
