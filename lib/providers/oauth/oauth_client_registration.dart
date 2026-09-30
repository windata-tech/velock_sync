import 'package:velock_sync/sync_core/model/sync_models.dart';

/// An OAuth application the user registered themselves on a provider's open
/// platform. It replaces the registration built into this app, so forks and
/// self-built copies (and users who prefer their own quota) can sign in
/// without the official keys.
///
/// It lives only in platform secure storage: [clientSecret] is a real secret
/// for Baidu Netdisk and must never reach preferences, logs or sync payloads.
class OAuthClientRegistration {
  const OAuthClientRegistration({
    required this.clientId,
    this.clientSecret,
    this.appFolderName,
  });

  /// Google/Microsoft/Aliyun Client ID, or the Baidu AppKey.
  final String clientId;

  /// Baidu SecretKey (required there) or an optional Aliyun app secret.
  final String? clientSecret;

  /// Baidu only: the app name the user registered, which names the one folder
  /// Baidu lets that app write to (`/apps/<name>`).
  final String? appFolderName;

  /// What each provider asks the user for; everything else is rejected so a
  /// Google or Microsoft public client can never be paired with a secret.
  static bool acceptsSecret(RemoteProviderType type) =>
      type == RemoteProviderType.baiduNetdisk ||
      type == RemoteProviderType.aliyunDrive;

  static bool requiresSecret(RemoteProviderType type) =>
      type == RemoteProviderType.baiduNetdisk;

  static bool acceptsAppFolderName(RemoteProviderType type) =>
      type == RemoteProviderType.baiduNetdisk;

  /// Trims every field and rejects values that cannot work for [type].
  /// Throws [FormatException] with a stable code as its message.
  static OAuthClientRegistration normalized({
    required RemoteProviderType type,
    required String clientId,
    String? clientSecret,
    String? appFolderName,
  }) {
    final id = clientId.trim();
    final secret = clientSecret?.trim() ?? '';
    final folder = appFolderName?.trim() ?? '';
    if (id.isEmpty || _hasControlOrSpace(id)) {
      throw const FormatException('oauth.registration.client_id_invalid');
    }
    if (secret.isNotEmpty && !acceptsSecret(type)) {
      throw const FormatException('oauth.registration.secret_not_accepted');
    }
    if (secret.isEmpty && requiresSecret(type)) {
      throw const FormatException('oauth.registration.secret_missing');
    }
    if (secret.isNotEmpty && _hasControlOrSpace(secret)) {
      throw const FormatException('oauth.registration.secret_invalid');
    }
    if (folder.isNotEmpty &&
        (!acceptsAppFolderName(type) ||
            folder.contains('/') ||
            folder.contains(r'\') ||
            folder == '.' ||
            folder == '..' ||
            folder.length > 64 ||
            folder.runes.any((rune) => rune < 0x20 || rune == 0x7f))) {
      throw const FormatException('oauth.registration.app_folder_invalid');
    }
    return OAuthClientRegistration(
      clientId: id,
      clientSecret: secret.isEmpty ? null : secret,
      appFolderName: folder.isEmpty ? null : folder,
    );
  }

  Map<String, String> toSecureJson() => {
    'clientId': clientId,
    'clientSecret': ?clientSecret,
    'appFolderName': ?appFolderName,
  };

  /// Returns null for anything malformed; a damaged entry must look exactly
  /// like "no registration", never like a usable one.
  static OAuthClientRegistration? fromSecureJson(
    RemoteProviderType type,
    Object? json,
  ) {
    if (json is! Map) return null;
    final clientId = json['clientId'];
    final secret = json['clientSecret'];
    final folder = json['appFolderName'];
    if (clientId is! String ||
        (secret != null && secret is! String) ||
        (folder != null && folder is! String)) {
      return null;
    }
    try {
      return normalized(
        type: type,
        clientId: clientId,
        clientSecret: secret as String?,
        appFolderName: folder as String?,
      );
    } on FormatException {
      return null;
    }
  }

  static bool _hasControlOrSpace(String value) =>
      value.runes.any((rune) => rune <= 0x20 || rune == 0x7f);
}
