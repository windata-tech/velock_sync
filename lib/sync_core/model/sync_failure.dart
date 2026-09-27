import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Stable, privacy-safe error representation for sync state and telemetry.
///
/// It deliberately excludes exception messages, logical keys, provider
/// response bodies and credentials. Callers may use [errorCode] as the only
/// persisted error value when their storage schema does not need the optional
/// recovery metadata.
enum SyncErrorCategory {
  transientNetwork,
  rateLimited,
  authenticationRequired,
  permissionRequired,
  remoteNotFound,
  remoteConflict,
  localAccessLost,
  insufficientSpace,
  integrityFailure,
  unsupportedProtocol,
  datasetRejected,
  userActionRequired,
  permanent,
}

class SyncFailure {
  const SyncFailure({
    required this.errorCode,
    required this.category,
    required this.retryable,
    required this.suggestedAction,
    this.retryAfter,
    this.providerStatusCode,
  });

  final String errorCode;
  final SyncErrorCategory category;
  final bool retryable;
  final String suggestedAction;
  final Duration? retryAfter;
  final int? providerStatusCode;
}

/// Exceptions may opt into a stable failure without leaking their diagnostic
/// text into the persistent sync history.
abstract interface class SyncFailureException implements Exception {
  SyncFailure get syncFailure;
}

/// Transport-level codes that carry no provider payload.
///
/// They exist so a plain "there is no network" or "the server never answered"
/// reaches the user as its own cause instead of the `sync.unexpected` bucket,
/// which used to describe a wrong password, an offline device and a full disk
/// with the same sentence.
abstract final class SyncFailureCodes {
  /// The device itself has no usable connection.
  static const networkOffline = 'network.offline';

  /// A request to the remote started but never completed in time.
  static const networkTimeout = 'network.timeout';

  /// The engine could not attribute the error to any known cause.
  static const unexpected = 'sync.unexpected';
}

abstract final class SyncFailureClassifier {
  static SyncFailure classify(Object error) {
    if (error case final SyncFailureException classified) {
      return classified.syncFailure;
    }
    return _classifyTransport(error) ?? _unexpected;
  }

  /// Names the transport failure a provider rethrows before it can attach a
  /// status code.
  ///
  /// Providers convert an HTTP response into `ProviderRequestException`; what
  /// reaches this classifier is the Dio failure that never got a response (no
  /// network, DNS, TLS, connect/receive timeout, a cancelled request). All of
  /// them used to collapse into `sync.unexpected`, so the message a user read
  /// blamed their configuration for what was really their connection.
  static SyncFailure? _classifyTransport(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) return _httpFailure(statusCode);
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.transformTimeout => _timeout,
        DioExceptionType.connectionError => _offline,
        DioExceptionType.cancel => _cancelled,
        DioExceptionType.badCertificate => _certificate,
        DioExceptionType.badResponse => null,
        DioExceptionType.unknown => _classifyCause(error.error),
      };
    }
    return _classifyCause(error);
  }

  /// A bare socket or timeout error, e.g. from a store that streams bytes
  /// without wrapping them.
  static SyncFailure? _classifyCause(Object? cause) => switch (cause) {
    SocketException() => _offline,
    TimeoutException() => _timeout,
    _ => null,
  };

  /// Mirrors `ProviderRequestException.fromStatus` for the transports that
  /// rethrow the raw Dio failure; only these fields are ever persisted.
  static SyncFailure _httpFailure(int statusCode) => SyncFailure(
    errorCode: 'provider.http.$statusCode',
    category: switch (statusCode) {
      401 => SyncErrorCategory.authenticationRequired,
      403 => SyncErrorCategory.permissionRequired,
      404 => SyncErrorCategory.remoteNotFound,
      409 || 412 => SyncErrorCategory.remoteConflict,
      429 => SyncErrorCategory.rateLimited,
      507 => SyncErrorCategory.insufficientSpace,
      >= 500 && <= 599 => SyncErrorCategory.transientNetwork,
      _ => SyncErrorCategory.permanent,
    },
    retryable: statusCode == 429 || statusCode >= 500,
    providerStatusCode: statusCode,
    suggestedAction: switch (statusCode) {
      401 => '请重新登录云端账号。',
      403 => '请检查云端目录权限。',
      404 => '请确认远端同步空间仍存在。',
      409 || 412 => '请稍后重试同步。',
      429 => '请等待后自动重试。',
      507 => '请释放云端空间后重试。',
      >= 500 && <= 599 => '网络恢复后将自动重试。',
      _ => '请检查 Provider 配置。',
    },
  );

  static const _offline = SyncFailure(
    errorCode: SyncFailureCodes.networkOffline,
    category: SyncErrorCategory.transientNetwork,
    retryable: true,
    suggestedAction: '请连接网络后重试。',
  );

  static const _timeout = SyncFailure(
    errorCode: SyncFailureCodes.networkTimeout,
    category: SyncErrorCategory.transientNetwork,
    retryable: true,
    suggestedAction: '请检查网络与远端服务后重试。',
  );

  static const _cancelled = SyncFailure(
    errorCode: 'remote.operation_cancelled',
    category: SyncErrorCategory.userActionRequired,
    retryable: true,
    suggestedAction: '重新开始同步以继续传输。',
  );

  static const _certificate = SyncFailure(
    errorCode: 'network.certificate',
    category: SyncErrorCategory.transientNetwork,
    retryable: false,
    suggestedAction: '请检查服务器证书或改用可信地址。',
  );

  static const _unexpected = SyncFailure(
    errorCode: SyncFailureCodes.unexpected,
    category: SyncErrorCategory.permanent,
    retryable: false,
    suggestedAction: '检查同步配置后重试。',
  );
}
