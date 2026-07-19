import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_pkce.dart';

void main() {
  test('generates an S256 PKCE pair', () {
    final pair = OAuthPkce.generate(random: Random(7));
    expect(pair.verifier.length, greaterThanOrEqualTo(43));
    expect(pair.challenge, OAuthPkce.codeChallenge(pair.verifier));
  });

  test('creates an authorization-code URL with PKCE and opaque state', () {
    final pair = OAuthPkcePair(verifier: 'a' * 43, challenge: 'challenge');
    final uri = OAuthPkce.authorizationUri(
      endpoint: Uri.parse('https://login.example.test/authorize'),
      clientId: 'client-id',
      redirectUri: Uri.parse('velocksync://oauth/callback'),
      scopes: const ['Files.ReadWrite', 'offline_access'],
      state: 'opaque-state',
      pkce: pair,
    );
    expect(uri.queryParameters['code_challenge_method'], 'S256');
    expect(uri.queryParameters['scope'], 'Files.ReadWrite offline_access');
    expect(uri.queryParameters['state'], 'opaque-state');
  });
}
