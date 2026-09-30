import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Token endpoint details shared by authorization, refresh and folder picking,
/// so the three places can never disagree about how a provider is reached.
class OAuthProviderEndpoints {
  const OAuthProviderEndpoints({
    required this.tokenEndpoint,
    this.tokenRequestFormat = OAuthTokenRequestFormat.form,
    this.clientSecret,
  });

  final Uri tokenEndpoint;
  final OAuthTokenRequestFormat tokenRequestFormat;

  /// Only present for providers whose published token flow cannot work
  /// without one (Baidu Netdisk). It comes from a build-time define and is
  /// never persisted or logged, but anything compiled into an app binary can
  /// be extracted, so it must be treated as low-trust.
  final String? clientSecret;

  static const _baiduSecret = String.fromEnvironment(
    'BAIDU_NETDISK_SECRET_KEY',
  );
  static const _aliyunSecret = String.fromEnvironment(
    'ALIYUN_DRIVE_CLIENT_SECRET',
  );

  static OAuthProviderEndpoints of(RemoteProviderType providerType) =>
      switch (providerType) {
        RemoteProviderType.googleDrive => OAuthProviderEndpoints(
          tokenEndpoint: Uri.https('oauth2.googleapis.com', '/token'),
        ),
        RemoteProviderType.oneDrive => OAuthProviderEndpoints(
          tokenEndpoint: Uri.https(
            'login.microsoftonline.com',
            '/common/oauth2/v2.0/token',
          ),
        ),
        RemoteProviderType.baiduNetdisk => OAuthProviderEndpoints(
          tokenEndpoint: Uri.https('openapi.baidu.com', '/oauth/2.0/token'),
          tokenRequestFormat: OAuthTokenRequestFormat.query,
          clientSecret: _baiduSecret.isEmpty ? null : _baiduSecret,
        ),
        RemoteProviderType.aliyunDrive => OAuthProviderEndpoints(
          tokenEndpoint: Uri.https('openapi.alipan.com', '/oauth/access_token'),
          tokenRequestFormat: OAuthTokenRequestFormat.json,
          clientSecret: _aliyunSecret.isEmpty ? null : _aliyunSecret,
        ),
        RemoteProviderType.webDav => throw UnsupportedError(
          'WebDAV is not an OAuth provider.',
        ),
      };
}
