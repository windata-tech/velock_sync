import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/providers/oauth/oauth_provider_endpoints.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// OAuth app registrations. A build may carry one per provider (Client IDs
/// are public; the Baidu SecretKey and optional Aliyun secret come from
/// build-time defines via [OAuthProviderEndpoints] and are never stored).
/// The repository itself ships none: official builds inject them, and anyone
/// else can use [fromUserRegistration] with an app they registered.
abstract final class OAuthPublicClientConfiguration {
  static final redirectUri = Uri(
    scheme: 'velocksync',
    host: 'oauth',
    path: '/callback',
  );

  static OAuthAuthorizationConfig forProvider(
    RemoteProviderType providerType,
  ) => fromClientId(
    providerType: providerType,
    clientId: builtInClientId(providerType),
  );

  /// The Client ID/AppKey compiled into this build, or empty.
  static String builtInClientId(RemoteProviderType providerType) {
    return switch (providerType) {
      RemoteProviderType.googleDrive => const String.fromEnvironment(
        'GOOGLE_OAUTH_CLIENT_ID',
      ),
      RemoteProviderType.oneDrive => const String.fromEnvironment(
        'ONEDRIVE_OAUTH_CLIENT_ID',
      ),
      RemoteProviderType.baiduNetdisk => const String.fromEnvironment(
        'BAIDU_NETDISK_APP_KEY',
      ),
      RemoteProviderType.aliyunDrive => const String.fromEnvironment(
        'ALIYUN_DRIVE_CLIENT_ID',
      ),
      _ => throw UnsupportedError(
        '${providerType.name} is not a public-client OAuth provider.',
      ),
    };
  }

  /// Whether [clientId] is this build's own registration, i.e. whether the
  /// build-time secret belongs to it. A user's registration never gets it.
  static bool isBuiltInClientId(
    RemoteProviderType providerType,
    String clientId,
  ) {
    try {
      final builtIn = builtInClientId(providerType);
      return builtIn.isNotEmpty && builtIn == clientId;
    } on UnsupportedError {
      return false;
    }
  }

  /// Sign-in with the user's own app. Only its own secret is used; the
  /// build's secret belongs to a different app and is never mixed in.
  static OAuthAuthorizationConfig fromUserRegistration({
    required RemoteProviderType providerType,
    required OAuthClientRegistration registration,
  }) {
    if (OAuthClientRegistration.requiresSecret(providerType) &&
        registration.clientSecret == null) {
      throw OAuthClientRegistrationMissingException(providerType);
    }
    final base = switch (providerType) {
      RemoteProviderType.googleDrive => OAuthAuthorizationConfig.googleDrive(
        clientId: registration.clientId,
        redirectUri: redirectUri,
      ),
      RemoteProviderType.oneDrive => OAuthAuthorizationConfig.oneDrive(
        clientId: registration.clientId,
        redirectUri: redirectUri,
      ),
      RemoteProviderType.baiduNetdisk => OAuthAuthorizationConfig.baiduNetdisk(
        clientId: registration.clientId,
        redirectUri: redirectUri,
      ),
      RemoteProviderType.aliyunDrive => OAuthAuthorizationConfig.aliyunDrive(
        clientId: registration.clientId,
        redirectUri: redirectUri,
      ),
      _ => throw UnsupportedError(
        '${providerType.name} is not a public-client OAuth provider.',
      ),
    };
    return OAuthClientRegistration.acceptsSecret(providerType)
        ? base.withUserSecret(registration.clientSecret)
        : base;
  }

  /// Whether this build was given a public client ID for [providerType].
  /// Non-OAuth types are never configured here.
  static bool hasBuiltInRegistration(RemoteProviderType providerType) {
    try {
      forProvider(providerType);
      return true;
    } on OAuthClientRegistrationMissingException {
      return false;
    } on UnsupportedError {
      return false;
    }
  }

  static OAuthAuthorizationConfig fromClientId({
    required RemoteProviderType providerType,
    required String clientId,
  }) {
    if (clientId.trim().isEmpty) {
      throw OAuthClientRegistrationMissingException(providerType);
    }
    // Baidu cannot exchange or refresh a code without its SecretKey, so an
    // AppKey alone is not a usable registration.
    if (providerType == RemoteProviderType.baiduNetdisk &&
        OAuthProviderEndpoints.of(providerType).clientSecret == null) {
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
      RemoteProviderType.baiduNetdisk => OAuthAuthorizationConfig.baiduNetdisk(
        clientId: clientId,
        redirectUri: redirectUri,
        clientSecret: OAuthProviderEndpoints.of(providerType).clientSecret,
      ),
      RemoteProviderType.aliyunDrive => OAuthAuthorizationConfig.aliyunDrive(
        clientId: clientId,
        redirectUri: redirectUri,
        clientSecret: OAuthProviderEndpoints.of(providerType).clientSecret,
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
