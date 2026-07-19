import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// Sanitized, provider-neutral classification for an HTTP request failure.
///
/// It intentionally contains no endpoint, response body, or authorization
/// data, so it is safe to surface to sync state and telemetry.
enum ProviderRequestErrorKind {
  authenticationRequired,
  permissionRequired,
  remoteNotFound,
  conflict,
  rateLimited,
  quotaExceeded,
  transient,
  permanent,
}

class ProviderRequestException implements SyncFailureException {
  const ProviderRequestException({
    required this.statusCode,
    required this.kind,
    required this.retryable,
    this.retryAfter,
  });

  factory ProviderRequestException.fromStatus(
    int statusCode, {
    Duration? retryAfter,
  }) {
    final kind = switch (statusCode) {
      401 => ProviderRequestErrorKind.authenticationRequired,
      403 => ProviderRequestErrorKind.permissionRequired,
      404 => ProviderRequestErrorKind.remoteNotFound,
      409 || 412 => ProviderRequestErrorKind.conflict,
      429 => ProviderRequestErrorKind.rateLimited,
      507 => ProviderRequestErrorKind.quotaExceeded,
      >= 500 && <= 599 => ProviderRequestErrorKind.transient,
      _ => ProviderRequestErrorKind.permanent,
    };
    return ProviderRequestException(
      statusCode: statusCode,
      kind: kind,
      retryable:
          kind == ProviderRequestErrorKind.rateLimited ||
          kind == ProviderRequestErrorKind.transient,
      retryAfter: retryAfter,
    );
  }

  final int statusCode;
  final ProviderRequestErrorKind kind;
  final bool retryable;
  final Duration? retryAfter;

  /// Stable code for UI state and telemetry. It contains no provider payload.
  String get errorCode => 'provider.http.$statusCode';

  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: errorCode,
    category: switch (kind) {
      ProviderRequestErrorKind.authenticationRequired =>
        SyncErrorCategory.authenticationRequired,
      ProviderRequestErrorKind.permissionRequired =>
        SyncErrorCategory.permissionRequired,
      ProviderRequestErrorKind.remoteNotFound =>
        SyncErrorCategory.remoteNotFound,
      ProviderRequestErrorKind.conflict => SyncErrorCategory.remoteConflict,
      ProviderRequestErrorKind.rateLimited => SyncErrorCategory.rateLimited,
      ProviderRequestErrorKind.quotaExceeded =>
        SyncErrorCategory.insufficientSpace,
      ProviderRequestErrorKind.transient => SyncErrorCategory.transientNetwork,
      ProviderRequestErrorKind.permanent => SyncErrorCategory.permanent,
    },
    retryable: retryable,
    retryAfter: retryAfter,
    providerStatusCode: statusCode,
    suggestedAction: switch (kind) {
      ProviderRequestErrorKind.authenticationRequired => '请重新登录云端账号。',
      ProviderRequestErrorKind.permissionRequired => '请检查云端目录权限。',
      ProviderRequestErrorKind.remoteNotFound => '请确认远端同步空间仍存在。',
      ProviderRequestErrorKind.conflict => '请稍后重试同步。',
      ProviderRequestErrorKind.rateLimited => '请等待后自动重试。',
      ProviderRequestErrorKind.quotaExceeded => '请释放云端空间后重试。',
      ProviderRequestErrorKind.transient => '网络恢复后将自动重试。',
      ProviderRequestErrorKind.permanent => '请检查 Provider 配置。',
    },
  );

  @override
  String toString() => 'ProviderRequestException($errorCode)';
}
