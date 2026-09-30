import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  test('builds minimal Google public-client PKCE configuration', () {
    const clientId = '123-abc.apps.googleusercontent.com';
    final config = OAuthPublicClientConfiguration.fromClientId(
      providerType: RemoteProviderType.googleDrive,
      clientId: clientId,
    );

    expect(config.clientId, clientId);
    // An "iOS" Google client only accepts its reversed Client ID as scheme.
    expect(
      config.redirectUri.toString(),
      'com.googleusercontent.apps.123-abc:/oauth2redirect',
    );
    expect(config.scopes, {
      'https://www.googleapis.com/auth/drive.file',
      // The default root is the hidden app folder, unreachable without it.
      'https://www.googleapis.com/auth/drive.appdata',
    });
    expect(config.revocationEndpoint, isNotNull);
  });

  test('only Google derives its redirect from the Client ID', () {
    expect(
      OAuthPublicClientConfiguration.fromClientId(
        providerType: RemoteProviderType.oneDrive,
        clientId: 'microsoft-client',
      ).redirectUri.toString(),
      'velocksync://oauth/callback',
    );
    for (final notGoogle in [
      'public-google-client',
      'x.apps.googleusercontent.com.evil',
      'a/b.apps.googleusercontent.com',
      '.apps.googleusercontent.com',
    ]) {
      expect(
        () => OAuthPublicClientConfiguration.fromClientId(
          providerType: RemoteProviderType.googleDrive,
          clientId: notGoogle,
        ),
        throwsA(isA<OAuthClientRegistrationMissingException>()),
        reason: notGoogle,
      );
    }
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
        clientId: 'app-key',
      ),
      // Baidu also needs its SecretKey, which tests never define.
      throwsA(isA<OAuthClientRegistrationMissingException>()),
    );
    expect(
      () => OAuthPublicClientConfiguration.fromClientId(
        providerType: RemoteProviderType.webDav,
        clientId: 'not-used',
      ),
      throwsUnsupportedError,
    );
  });
}
