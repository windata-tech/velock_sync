import 'package:dio/dio.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Persistable, non-secret configuration for an OAuth remote target.
class OAuthRemoteTargetConfig {
  const OAuthRemoteTargetConfig({
    required this.providerType,
    required this.clientId,
    required this.credentialRef,
    required this.rootId,
  });

  final RemoteProviderType providerType;
  final String clientId;
  final String credentialRef;
  final String rootId;

  Map<String, String> toSafeJson() => {
    'providerType': providerType.name,
    'clientId': clientId,
    'credentialRef': credentialRef,
    'rootId': rootId,
  };
}

/// Constructs an OAuth provider without exposing refresh tokens to callers.
class OAuthRemoteTargetFactory {
  OAuthRemoteTargetFactory({
    required CredentialStore credentialStore,
    OAuthTokenClient? tokenClient,
    Dio? dio,
  }) : _credentialStore = credentialStore,
       _tokenClient = tokenClient ?? OAuthTokenClient(dio: dio),
       _dio = dio;

  final CredentialStore _credentialStore;
  final OAuthTokenClient _tokenClient;
  final Dio? _dio;

  RemoteObjectStore create(OAuthRemoteTargetConfig target) {
    if (target.clientId.isEmpty ||
        target.credentialRef.isEmpty ||
        target.rootId.isEmpty) {
      throw ArgumentError('OAuth remote target configuration is incomplete.');
    }
    return switch (target.providerType) {
      RemoteProviderType.googleDrive => GoogleDriveObjectStore(
        accessTokenProvider: _accessTokens(
          target,
          Uri.https('oauth2.googleapis.com', '/token'),
        ),
        parentId: target.rootId,
        dio: _dio,
      ),
      RemoteProviderType.oneDrive => OneDriveObjectStore(
        accessTokenProvider: _accessTokens(
          target,
          Uri.https('login.microsoftonline.com', '/common/oauth2/v2.0/token'),
        ),
        rootItemId: target.rootId,
        dio: _dio,
      ),
      RemoteProviderType.baiduNetdisk || RemoteProviderType.aliyunDrive =>
        throw OAuthProviderRequiresTokenBrokerException(target.providerType),
      _ => throw UnsupportedError('Provider is not OAuth object storage.'),
    };
  }

  OAuthAccessTokenProvider _accessTokens(
    OAuthRemoteTargetConfig target,
    Uri tokenEndpoint,
  ) => OAuthAccessTokenProvider(
    credentialStore: _credentialStore,
    tokenClient: _tokenClient,
    credentialRef: target.credentialRef,
    clientId: target.clientId,
    tokenEndpoint: tokenEndpoint,
  );
}

/// The provider's published token flow requires a confidential client secret.
/// A mobile build must not contain that secret; use a separately operated,
/// least-privilege token broker before enabling this provider.
class OAuthProviderRequiresTokenBrokerException implements Exception {
  const OAuthProviderRequiresTokenBrokerException(this.providerType);

  final RemoteProviderType providerType;

  String get errorCode => 'provider.oauth.token_broker_required';

  @override
  String toString() =>
      'OAuthProviderRequiresTokenBrokerException(${providerType.name})';
}
