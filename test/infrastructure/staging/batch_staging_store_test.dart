import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';

void main() {
  group('BatchStagingStore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('velock-batch-staging-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('atomically stages and reopens an immutable batch artifact', () async {
      final store = BatchStagingStore(root);
      final staged = await store.stage(
        batchId: 'batch-1',
        artifactName: 'blobs/blob-1.blob',
        content: Stream.fromIterable([
          <int>[1, 2],
          <int>[3],
        ]),
        contentLength: 3,
      );
      final reopened = await BatchStagingStore(
        root,
      ).read(batchId: 'batch-1', artifactName: 'blobs/blob-1.blob');

      expect(staged.length, 3);
      expect(reopened, isNotNull);
      expect(
        Uint8List.fromList(await _collect(await reopened!.openRead())),
        Uint8List.fromList([1, 2, 3]),
      );
    });

    test('rejects traversal and length mismatches', () async {
      final store = BatchStagingStore(root);
      expect(
        () => store.stage(
          batchId: 'batch-1',
          artifactName: '../escape',
          content: Stream.value(<int>[]),
          contentLength: 0,
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.stage(
          batchId: 'batch-1',
          artifactName: 'operations.enc',
          content: Stream.value(<int>[1]),
          contentLength: 2,
        ),
        throwsStateError,
      );
      await store.stage(
        batchId: 'batch-1',
        artifactName: 'immutable',
        content: Stream.value(<int>[1]),
        contentLength: 1,
      );
      await expectLater(
        store.stage(
          batchId: 'batch-1',
          artifactName: 'immutable',
          content: Stream.value(<int>[1]),
          contentLength: 1,
        ),
        throwsStateError,
      );
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final part in stream) {
    bytes.addAll(part);
  }
  return bytes;
}
