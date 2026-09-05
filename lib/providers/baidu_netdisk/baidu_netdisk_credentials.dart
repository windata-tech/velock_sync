/// Credentials returned by, or manually copied from, Baidu Netdisk OAuth.
///
/// This bundle is deliberately separate from [ProtocolModel]. It is kept in
/// platform secure storage and must never be serialized into a connection,
/// sync package, diagnostic log, or export file.
class BaiduNetdiskCredentialBundle {
  const BaiduNetdiskCredentialBundle({
    required this.appKey,
    required this.accessToken,
    this.secretKey,
    this.refreshToken,
    this.expiresAt,
    this.scopes = const {'basic', 'netdisk'},
  });

  final String appKey;
  final String? secretKey;
  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final Set<String> scopes;

  Map<String, Object?> toSecureJson() => {
    'appKey': appKey,
    'secretKey': secretKey,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'scopes': scopes.toList(growable: false),
  };

  static BaiduNetdiskCredentialBundle? fromSecureJson(
    Map<String, dynamic> json,
  ) {
    final appKey = json['appKey'];
    final accessToken = json['accessToken'];
    if (appKey is! String ||
        appKey.trim().isEmpty ||
        accessToken is! String ||
        accessToken.trim().isEmpty) {
      return null;
    }

    final secretKey = json['secretKey'];
    final refreshToken = json['refreshToken'];
    final encodedExpiry = json['expiresAt'];
    final expiresAt = encodedExpiry is String && encodedExpiry.isNotEmpty
        ? DateTime.tryParse(encodedExpiry)?.toUtc()
        : null;
    final scopes = json['scopes'];

    return BaiduNetdiskCredentialBundle(
      appKey: appKey,
      secretKey: secretKey is String && secretKey.isNotEmpty ? secretKey : null,
      accessToken: accessToken,
      refreshToken: refreshToken is String && refreshToken.isNotEmpty
          ? refreshToken
          : null,
      expiresAt: expiresAt,
      scopes: scopes is List
          ? scopes.whereType<String>().toSet()
          : const {'basic', 'netdisk'},
    );
  }
}
