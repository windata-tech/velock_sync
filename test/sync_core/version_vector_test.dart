import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  group('VersionVector', () {
    test('distinguishes equal, causal, and concurrent revisions', () {
      final base = VersionVector({'device-a': 2, 'device-b': 1});

      expect(
        base.compareTo(VersionVector({'device-a': 2, 'device-b': 1})),
        VersionVectorComparison.equal,
      );
      expect(
        base.compareTo(VersionVector({'device-a': 1, 'device-b': 1})),
        VersionVectorComparison.dominates,
      );
      expect(
        base.compareTo(VersionVector({'device-a': 3, 'device-b': 1})),
        VersionVectorComparison.dominated,
      );
      expect(
        base.compareTo(VersionVector({'device-a': 1, 'device-b': 2})),
        VersionVectorComparison.concurrent,
      );
    });

    test(
      'merges both branches before emitting a conflict resolution revision',
      () {
        final local = VersionVector({'device-a': 5, 'device-b': 2});
        final incoming = VersionVector({'device-a': 4, 'device-b': 3});

        expect(local.mergedAndIncremented(incoming, 'device-a').values, {
          'device-a': 6,
          'device-b': 3,
        });
      },
    );
  });
}
