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

abstract final class SyncFailureClassifier {
  static SyncFailure classify(Object error) {
    if (error case final SyncFailureException classified) {
      return classified.syncFailure;
    }
    return const SyncFailure(
      errorCode: 'sync.unexpected',
      category: SyncErrorCategory.permanent,
      retryable: false,
      suggestedAction: '检查同步配置后重试。',
    );
  }
}
