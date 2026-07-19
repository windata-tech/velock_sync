import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

void main() {
  group('SyncFailureClassifier', () {
    test(
      'keeps provider classifications stable and free of response content',
      () {
        final failure = SyncFailureClassifier.classify(
          ProviderRequestException.fromStatus(
            429,
            retryAfter: const Duration(seconds: 30),
          ),
        );

        expect(failure.errorCode, 'provider.http.429');
        expect(failure.category, SyncErrorCategory.rateLimited);
        expect(failure.retryable, isTrue);
        expect(failure.retryAfter, const Duration(seconds: 30));
        expect(failure.providerStatusCode, 429);
      },
    );

    test('classifies remote absence without retaining the logical key', () {
      final failure = SyncFailureClassifier.classify(
        const RemoteObjectNotFoundException('opaque/private/key'),
      );

      expect(failure.errorCode, 'remote.object_not_found');
      expect(failure.category, SyncErrorCategory.remoteNotFound);
      expect(failure.suggestedAction, isNot(contains('opaque/private/key')));
    });
  });
}
