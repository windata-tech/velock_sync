import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';

/// OAuth details for one provider. Google and Microsoft are public PKCE
/// clients; [clientSecret] exists only for providers whose published token
/// flow requires one. A build-time secret is never persisted; a secret from
/// the user's own registration is kept with the grant ([persistClientSecret])
/// because every later refresh needs it.
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
    this.clientSecret,
    this.tokenRequestFormat = OAuthTokenRequestFormat.form,
    this.persistClientSecret = false,
  });

  final String providerId;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final String clientId;
  final Uri redirectUri;
  final Set<String> scopes;
  final Uri? revocationEndpoint;
  final Map<String, String> additionalParameters;
  final String? clientSecret;
  final OAuthTokenRequestFormat tokenRequestFormat;
  final bool persistClientSecret;

  OAuthAuthorizationConfig withUserSecret(String? secret) =>
      OAuthAuthorizationConfig(
        providerId: providerId,
        authorizationEndpoint: authorizationEndpoint,
        tokenEndpoint: tokenEndpoint,
        clientId: clientId,
        redirectUri: redirectUri,
        scopes: scopes,
        revocationEndpoint: revocationEndpoint,
        additionalParameters: additionalParameters,
        clientSecret: secret,
        tokenRequestFormat: tokenRequestFormat,
        persistClientSecret: secret != null,
      );

  /// Google Drive public-client authorization. `drive.file` limits it to files
  /// the app creates or the user explicitly selects for the app; `drive.appdata`
  /// covers the hidden app folder, the default location. Both are
  /// non-sensitive scopes, so a user's own unverified registration can use
  /// them without Google's app review.
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
    scopes: const {
      'https://www.googleapis.com/auth/drive.file',
      'https://www.googleapis.com/auth/drive.appdata',
    },
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

  /// Baidu Netdisk open platform. Scopes are comma separated by Baidu, so the
  /// whole list is one value. The token endpoint needs the SecretKey.
  factory OAuthAuthorizationConfig.baiduNetdisk({
    required String clientId,
    required Uri redirectUri,
    String? clientSecret,
  }) => OAuthAuthorizationConfig(
    providerId: 'baiduNetdisk',
    authorizationEndpoint: Uri.parse(
      'https://openapi.baidu.com/oauth/2.0/authorize',
    ),
    tokenEndpoint: Uri.parse('https://openapi.baidu.com/oauth/2.0/token'),
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: const {'basic,netdisk'},
    additionalParameters: const {'display': 'mobile'},
    clientSecret: clientSecret,
    tokenRequestFormat: OAuthTokenRequestFormat.query,
  );

  /// Aliyun Drive (alipan) open platform. PKCE lets a mobile client exchange
  /// the code without an app secret; one is sent only when the build has it.
  factory OAuthAuthorizationConfig.aliyunDrive({
    required String clientId,
    required Uri redirectUri,
    String? clientSecret,
  }) => OAuthAuthorizationConfig(
    providerId: 'aliyunDrive',
    authorizationEndpoint: Uri.parse(
      'https://openapi.alipan.com/oauth/authorize',
    ),
    tokenEndpoint: Uri.parse('https://openapi.alipan.com/oauth/access_token'),
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: const {'user:base,file:all:read,file:all:write'},
    clientSecret: clientSecret,
    tokenRequestFormat: OAuthTokenRequestFormat.json,
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
      clientSecret: config.clientSecret,
      format: config.tokenRequestFormat,
    );
    return _credentialStore.writeOAuthTokens(
      tokens,
      clientSecret: config.persistClientSecret ? config.clientSecret : null,
    );
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
