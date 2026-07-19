import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class OAuthPkcePair {
  const OAuthPkcePair({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;
}

/// Provider-neutral OAuth 2.0 authorization-code + PKCE (S256) helpers.
abstract final class OAuthPkce {
  static OAuthPkcePair generate({Random? random}) {
    final source = random ?? Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(64, (_) => source.nextInt(256)),
    );
    final verifier = base64UrlEncode(bytes).replaceAll('=', '');
    return OAuthPkcePair(
      verifier: verifier,
      challenge: codeChallenge(verifier),
    );
  }

  static String codeChallenge(String verifier) {
    if (verifier.length < 43 || verifier.length > 128) {
      throw ArgumentError.value(verifier, 'verifier', 'must be 43-128 chars');
    }
    return base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
  }

  static Uri authorizationUri({
    required Uri endpoint,
    required String clientId,
    required Uri redirectUri,
    required Iterable<String> scopes,
    required String state,
    required OAuthPkcePair pkce,
    Map<String, String> additionalParameters = const {},
  }) {
    if (clientId.isEmpty || state.isEmpty || scopes.isEmpty) {
      throw ArgumentError('OAuth authorization parameters are required.');
    }
    return endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        ...additionalParameters,
        'client_id': clientId,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        'redirect_uri': redirectUri.toString(),
        'response_type': 'code',
        'scope': scopes.join(' '),
        'state': state,
      },
    );
  }
}
