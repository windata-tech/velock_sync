import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

/// Public-client OAuth details. It intentionally has no client secret field.
class OAuthAuthorizationConfig {
  const OAuthAuthorizationConfig({
    required this.providerId,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    required this.redirectUri,
    required this.scopes,
    this.revocationEndpoint,
    this.additionalParameters = const {},
  });

  final String providerId;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final String clientId;
  final Uri redirectUri;
  final Set<String> scopes;
  final Uri? revocationEndpoint;
  final Map<String, String> additionalParameters;

  /// Google Drive public-client authorization with the file scope, limited to
  /// files the app creates or the user explicitly selects for the app.
  factory OAuthAuthorizationConfig.googleDrive({
    required String clientId,
    required Uri redirectUri,
  }) => OAuthAuthorizationConfig(
    providerId: 'googleDrive',
    authorizationEndpoint: Uri.parse(
      'https://accounts.google.com/o/oauth2/v2/auth',
    ),
    tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
    revocationEndpoint: Uri.parse('https://oauth2.googleapis.com/revoke'),
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: const {'https://www.googleapis.com/auth/drive.file'},
    additionalParameters: const {'access_type': 'offline'},
  );

  /// Microsoft Graph public-client authorization for the signed-in user's
  /// files. `offline_access` is required to obtain a refresh token.
  factory OAuthAuthorizationConfig.oneDrive({
    required String clientId,
    required Uri redirectUri,
  }) => OAuthAuthorizationConfig(
    providerId: 'oneDrive',
    authorizationEndpoint: Uri.parse(
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    ),
    tokenEndpoint: Uri.parse(
      'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    ),
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: const {'Files.ReadWrite', 'offline_access'},
  );
}

/// Completes a PKCE browser flow without exposing tokens to UI or persistence.
class OAuthAuthorizationService {
  OAuthAuthorizationService({
    required OAuthAuthorizationSession session,
    required OAuthTokenClient tokenClient,
    required CredentialStore credentialStore,
  }) : _session = session,
       _tokenClient = tokenClient,
       _credentialStore = credentialStore;

  final OAuthAuthorizationSession _session;
  final OAuthTokenClient _tokenClient;
  final CredentialStore _credentialStore;

  Future<Uri> begin(OAuthAuthorizationConfig config) => _session.begin(
    providerId: config.providerId,
    authorizationEndpoint: config.authorizationEndpoint,
    clientId: config.clientId,
    redirectUri: config.redirectUri,
    scopes: config.scopes,
    additionalParameters: config.additionalParameters,
  );

  Future<String> complete({
    required OAuthAuthorizationConfig config,
    required Uri callback,
  }) async {
    final grant = await _session.consumeCallback(
      providerId: config.providerId,
      callback: callback,
    );
    final tokens = await _tokenClient.exchangeAuthorizationCode(
      tokenEndpoint: config.tokenEndpoint,
      clientId: config.clientId,
      redirectUri: config.redirectUri,
      code: grant.code,
      codeVerifier: grant.verifier,
    );
    return _credentialStore.writeOAuthTokens(tokens);
  }

  /// Revokes the remote grant when supported, then removes the locally stored
  /// OAuth tokens. If remote revocation fails, the local credential remains so
  /// the user can retry rather than silently losing control of the grant.
  Future<void> disconnect({
    required OAuthAuthorizationConfig config,
    required String credentialRef,
  }) async {
    final tokens = await _credentialStore.readOAuthTokens(credentialRef);
    if (tokens != null && config.revocationEndpoint != null) {
      await _tokenClient.revoke(
        revocationEndpoint: config.revocationEndpoint!,
        refreshToken: tokens.refreshToken,
      );
    }
    await _credentialStore.delete(credentialRef);
  }
}
