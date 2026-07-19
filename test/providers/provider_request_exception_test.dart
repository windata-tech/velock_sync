import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

void main() {
  test('classifies documented provider HTTP failure statuses', () {
    final cases = <int, ProviderRequestErrorKind>{
      401: ProviderRequestErrorKind.authenticationRequired,
      403: ProviderRequestErrorKind.permissionRequired,
      404: ProviderRequestErrorKind.remoteNotFound,
      409: ProviderRequestErrorKind.conflict,
      412: ProviderRequestErrorKind.conflict,
      429: ProviderRequestErrorKind.rateLimited,
      503: ProviderRequestErrorKind.transient,
      507: ProviderRequestErrorKind.quotaExceeded,
      400: ProviderRequestErrorKind.permanent,
    };

    for (final entry in cases.entries) {
      final error = ProviderRequestException.fromStatus(entry.key);
      expect(error.kind, entry.value, reason: 'HTTP ${entry.key}');
      expect(error.errorCode, 'provider.http.${entry.key}');
    }
  });

  test('marks only throttling and server errors retryable', () {
    expect(ProviderRequestException.fromStatus(429).retryable, isTrue);
    expect(ProviderRequestException.fromStatus(503).retryable, isTrue);
    expect(ProviderRequestException.fromStatus(403).retryable, isFalse);
  });

  test('maps quota exhaustion to a stable insufficient-space SyncFailure', () {
    final error = ProviderRequestException.fromStatus(507);

    expect(error.retryable, isFalse);
    expect(error.syncFailure.category, SyncErrorCategory.insufficientSpace);
    expect(error.syncFailure.suggestedAction, '请释放云端空间后重试。');
    expect(error.toString(), 'ProviderRequestException(provider.http.507)');
  });
}
