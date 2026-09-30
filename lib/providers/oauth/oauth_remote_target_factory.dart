import 'package:dio/dio.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_provider_endpoints.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
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
        accessTokenProvider: _accessTokens(target),
        parentId: target.rootId,
        dio: _dio,
      ),
      RemoteProviderType.oneDrive => OneDriveObjectStore(
        accessTokenProvider: _accessTokens(target),
        rootItemId: target.rootId,
        dio: _dio,
      ),
      RemoteProviderType.baiduNetdisk => BaiduNetdiskObjectStore(
        accessTokenProvider: _accessTokens(target),
        rootPath: target.rootId,
        dio: _dio,
      ),
      RemoteProviderType.aliyunDrive => AliyunDriveObjectStore(
        accessTokenProvider: _accessTokens(target),
        rootId: target.rootId,
        dio: _dio,
      ),
      _ => throw UnsupportedError('Provider is not OAuth object storage.'),
    };
  }

  OAuthAccessTokenProvider _accessTokens(OAuthRemoteTargetConfig target) =>
      oauthAccessTokensFor(
        target,
        credentialStore: _credentialStore,
        tokenClient: _tokenClient,
      );
}

/// The one place a stored OAuth target is turned into a token provider, so
/// syncing and folder picking always refresh against the same endpoint.
OAuthAccessTokenProvider oauthAccessTokensFor(
  OAuthRemoteTargetConfig target, {
  required CredentialStore credentialStore,
  required OAuthTokenClient tokenClient,
}) {
  final endpoints = OAuthProviderEndpoints.of(target.providerType);
  return OAuthAccessTokenProvider(
    credentialStore: credentialStore,
    tokenClient: tokenClient,
    credentialRef: target.credentialRef,
    clientId: target.clientId,
    tokenEndpoint: endpoints.tokenEndpoint,
    // The build secret belongs to the build's own app; a connection made
    // with the user's registration refreshes with the secret kept beside its
    // tokens instead.
    clientSecret:
        OAuthPublicClientConfiguration.isBuiltInClientId(
          target.providerType,
          target.clientId,
        )
        ? endpoints.clientSecret
        : null,
    tokenRequestFormat: endpoints.tokenRequestFormat,
  );
}
