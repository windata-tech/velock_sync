/// OAuth credentials returned by an authorization-code or refresh grant.
///
/// This value must only be stored through [CredentialStore]. It deliberately
/// has no JSON representation so it cannot accidentally be embedded in a
/// connection record or a sync package.
class OAuthTokenBundle {
  const OAuthTokenBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.tokenType = 'Bearer',
    this.scopes = const {},
  }) : assert(accessToken != ''),
       assert(refreshToken != '');

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String tokenType;
  final Set<String> scopes;

  bool isExpiringWithin(Duration margin, {DateTime? now}) =>
      !expiresAt.isAfter((now ?? DateTime.now()).add(margin));
}
