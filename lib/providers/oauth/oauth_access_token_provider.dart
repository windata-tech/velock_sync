import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

/// Supplies a valid bearer token and rotates it in platform secure storage.
class OAuthAccessTokenProvider {
  OAuthAccessTokenProvider({
    required CredentialStore credentialStore,
    required OAuthTokenClient tokenClient,
    required this.credentialRef,
    required this.clientId,
    required this.tokenEndpoint,
    this.refreshMargin = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _credentialStore = credentialStore,
       _tokenClient = tokenClient,
       _clock = clock ?? DateTime.now;

  final CredentialStore _credentialStore;
  final OAuthTokenClient _tokenClient;
  final String credentialRef;
  final String clientId;
  final Uri tokenEndpoint;
  final Duration refreshMargin;
  final DateTime Function() _clock;

  Future<String> bearerToken({bool forceRefresh = false}) async {
    final current = await _credentialStore.readOAuthTokens(credentialRef);
    if (current == null) throw const OAuthCredentialUnavailableException();
    if (!forceRefresh &&
        !current.isExpiringWithin(refreshMargin, now: _clock())) {
      return current.accessToken;
    }
    final refreshed = await _tokenClient.refresh(
      tokenEndpoint: tokenEndpoint,
      clientId: clientId,
      current: current,
    );
    await _credentialStore.updateOAuthTokens(credentialRef, refreshed);
    return refreshed.accessToken;
  }

  Future<Map<String, String>> authorizationHeaders({
    bool forceRefresh = false,
  }) async => {
    'Authorization': 'Bearer ${await bearerToken(forceRefresh: forceRefresh)}',
  };
}

class OAuthCredentialUnavailableException implements Exception {
  const OAuthCredentialUnavailableException();

  @override
  String toString() =>
      'OAuthCredentialUnavailableException: OAuth credentials are unavailable.';
}
