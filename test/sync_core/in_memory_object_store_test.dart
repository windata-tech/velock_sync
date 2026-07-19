import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  group('InMemoryObjectStore provider contract baseline', () {
    test('stores, pages, reads and protects immutable objects', () async {
      final store = InMemoryObjectStore();
      await store.put(
        'vault/a',
        Stream.value(<int>[1, 2]),
        contentLength: 2,
        ifAbsent: true,
      );
      await store.put(
        'vault/b',
        Stream.value(<int>[3]),
        contentLength: 1,
        ifAbsent: true,
      );

      final page = await store.list(prefix: 'vault/', limit: 1);
      expect(page.items.single.logicalKey, 'vault/a');
      expect(page.nextCursor, isNotNull);

      final bytes = await store
          .read('vault/a')
          .expand((chunk) => chunk)
          .toList();
      expect(bytes, [1, 2]);
      await expectLater(
        store.put(
          'vault/a',
          Stream.value(<int>[9]),
          contentLength: 1,
          ifAbsent: true,
        ),
        throwsA(isA<RemoteObjectAlreadyExistsException>()),
      );
    });

    test(
      'rejects a cancelled operation before mutating remote state',
      () async {
        final store = InMemoryObjectStore();
        final cancellation = RemoteOperationCancellation()..cancel();

        await expectLater(
          store.put(
            'vault/cancelled',
            Stream.value(<int>[1]),
            contentLength: 1,
            cancellation: cancellation,
          ),
          throwsA(isA<RemoteOperationCancelledException>()),
        );
        expect(await store.stat('vault/cancelled'), isNull);
      },
    );
  });
}
