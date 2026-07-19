import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Public OAuth registration supplied at build time. Client IDs are public;
/// client secrets are intentionally neither accepted nor stored here.
abstract final class OAuthPublicClientConfiguration {
  static final redirectUri = Uri(
    scheme: 'velocksync',
    host: 'oauth',
    path: '/callback',
  );

  static OAuthAuthorizationConfig forProvider(RemoteProviderType providerType) {
    final clientId = switch (providerType) {
      RemoteProviderType.googleDrive => const String.fromEnvironment(
        'GOOGLE_OAUTH_CLIENT_ID',
      ),
      RemoteProviderType.oneDrive => const String.fromEnvironment(
        'ONEDRIVE_OAUTH_CLIENT_ID',
      ),
      _ => throw UnsupportedError(
        '${providerType.name} is not a public-client OAuth provider.',
      ),
    };
    return fromClientId(providerType: providerType, clientId: clientId);
  }

  static OAuthAuthorizationConfig fromClientId({
    required RemoteProviderType providerType,
    required String clientId,
  }) {
    if (clientId.trim().isEmpty) {
      throw OAuthClientRegistrationMissingException(providerType);
    }
    return switch (providerType) {
      RemoteProviderType.googleDrive => OAuthAuthorizationConfig.googleDrive(
        clientId: clientId,
        redirectUri: redirectUri,
      ),
      RemoteProviderType.oneDrive => OAuthAuthorizationConfig.oneDrive(
        clientId: clientId,
        redirectUri: redirectUri,
      ),
      _ => throw UnsupportedError(
        '${providerType.name} is not a public-client OAuth provider.',
      ),
    };
  }
}

class OAuthClientRegistrationMissingException implements Exception {
  const OAuthClientRegistrationMissingException(this.providerType);

  final RemoteProviderType providerType;

  @override
  String toString() =>
      'OAuthClientRegistrationMissingException(${providerType.name})';
}
