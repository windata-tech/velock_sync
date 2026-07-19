import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  test('builds minimal Google public-client PKCE configuration', () {
    final config = OAuthPublicClientConfiguration.fromClientId(
      providerType: RemoteProviderType.googleDrive,
      clientId: 'public-google-client',
    );

    expect(config.clientId, 'public-google-client');
    expect(config.redirectUri.toString(), 'velocksync://oauth/callback');
    expect(config.scopes, {'https://www.googleapis.com/auth/drive.file'});
    expect(config.revocationEndpoint, isNotNull);
  });

  test('rejects missing or secret-requiring public OAuth registrations', () {
    expect(
      () => OAuthPublicClientConfiguration.fromClientId(
        providerType: RemoteProviderType.oneDrive,
        clientId: '',
      ),
      throwsA(isA<OAuthClientRegistrationMissingException>()),
    );
    expect(
      () => OAuthPublicClientConfiguration.fromClientId(
        providerType: RemoteProviderType.baiduNetdisk,
        clientId: 'not-used',
      ),
      throwsUnsupportedError,
    );
  });
}
