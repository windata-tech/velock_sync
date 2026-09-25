// PURE ENGINE MICROBENCHMARK: in-memory SQLite/store and synthetic opaque
// artifacts. Not App Group, real crypto, filesystem, UI, network or full E2E.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';

import 'engine_microbenchmark_fixture.dart';

void main() {
  final samples = <Map<String, Object>>[];
  late SyncStateDatabase database;
  late MeteredStore remote;
  late QueueDataset dataset;

  Future<Workload> measure(
    String scenario,
    Future<void> Function() action,
  ) async {
    remote.workload = Workload();
    final timer = Stopwatch()..start();
    await action();
    timer.stop();
    final workload = remote.workload;
    final sample = <String, Object>{
      'scenario': scenario,
      'elapsedMicros': timer.elapsedMicroseconds,
      ...workload.toJson(),
    };
    samples.add(sample);
    // Machine-readable even without an evidence directory.
    // ignore: avoid_print
    print('ENGINE_MICROBENCHMARK ${jsonEncode(sample)}');
    // Only a hang/severe slowdown guard, NOT a portable latency SLO.
    expect(timer.elapsed, lessThan(const Duration(seconds: 15)));
    return workload;
  }

  Future<SyncProfileRunResult> runProfile() => SyncProfileRunner(database).run(
    profileId: profileId,
    vaultId: vaultId,
    deviceId: producerId,
    protocol: VaultProtocolDocument(
      vaultId: vaultId,
      createdAt: DateTime.utc(2026, 9, 19),
    ),
    dataset: dataset,
    remote: remote,
    // Include a trusted, empty peer so idle runs exercise commit discovery.
    trustedProducerDeviceIds: const [consumerId],
  );

  Future<void> publish() async {
    final result = await SyncUploadEngine(database).publishNext(
      profileId: profileId,
      dataset: dataset,
      remote: remote,
      cursor: ExportCursor.empty,
      limits: const BatchLimits(),
    );
    expect(result.publishedBatchCount, 1);
  }

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    remote = MeteredStore();
    dataset = QueueDataset();
  });
  tearDown(() => database.close());
  tearDownAll(() async {
    final directory = Platform.environment['ENGINE_MICROBENCHMARK_OUTPUT_DIR'];
    if (directory == null || directory.isEmpty) return;
    await Directory(directory).create(recursive: true);
    await File('$directory/engine-microbenchmark.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'scope':
            'Pure engine microbenchmark; no real network, App Group, '
            'adapter crypto or full E2E. Request counts are store API calls.',
        'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'dartRuntime': Platform.version,
        'os': Platform.operatingSystem,
        'samples': samples,
      }),
    );
  });

  test(
    'profile: empty, unchanged and small delta never reupload history',
    () async {
      final cold = await measure('profile.empty.cold', () async {
        expect((await runProfile()).didTransfer, isFalse);
      });
      expectRequests(cold, stat: 1, list: 1, put: 1); // protocol only
      expect(cold.businessPutCount, 0);
      expect(cold.businessUploadBytes, 0);

      Future<void> unchanged(String label) async {
        final sample = await measure(label, () async {
          expect((await runProfile()).didTransfer, isFalse);
        });
        expectRequests(sample, stat: 1, list: 1, read: 1);
        expect(sample.businessPutCount, 0);
        expect(sample.businessUploadBytes, 0);
        expect(sample.readKeys, [LogicalKeys.protocol(vaultId)]);
      }

      for (var i = 1; i <= 3; i++) {
        await unchanged('profile.empty.warm.$i');
      }

      final history = List.generate(8, (i) => makeBlob(i, 16 * 1024));
      final initial = makeBatch(1, history);
      dataset.pending.add(initial);
      final first = await measure('profile.initial.128KiB', () async {
        final result = await runProfile();
        expect(result.upload.publishedBatchCount, 1);
        expect(result.upload.uploadedBlobCount, 8);
      });
      expectRequests(first, stat: 12, list: 1, read: 1, put: 11);
      expect(first.businessPutCount, 11);
      expect(first.businessUploadBytes, 128 * 1024 + batchBodyBytes(initial));
      expect(first.blobUploadBytes, 128 * 1024);
      for (var i = 1; i <= 3; i++) {
        await unchanged('profile.unchanged.after-initial.$i');
      }

      // Re-reference ALL history, not just the new blob: explicitly exercise
      // engine deduplication rather than relying on a pre-filtered dataset.
      final newBlob = makeBlob(8, 1024);
      final delta = makeBatch(2, [...history, newBlob]);
      dataset.pending.add(delta);
      final incremental = await measure('profile.delta.1KiB', () async {
        final result = await runProfile();
        expect(result.upload.publishedBatchCount, 1);
        expect(result.upload.uploadedBlobCount, 1);
      });
      expectRequests(incremental, stat: 13, list: 1, read: 1, put: 4);
      expect(incremental.businessUploadBytes, 1024 + batchBodyBytes(delta));
      expect(incremental.blobUploadBytes, 1024);
      expect(incremental.putKeys.where((key) => key.contains('/blobs/')), [
        LogicalKeys.blob(vaultId, newBlob.descriptor.blobId),
      ]);
      for (var i = 1; i <= 3; i++) {
        await unchanged('profile.unchanged.after-delta.$i');
      }
      expect(dataset.acknowledged, ['batch-1:1', 'batch-2:2']);
      expect(dataset.pending, isEmpty);
      expect((await database.latestSyncRun(profileId))!.state, 'completed');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'upload: committed batch retry and explicit replay upload zero bytes',
    () async {
      final batch = makeBatch(1, [makeBlob(0, 4096)]);
      dataset.pending.add(batch);
      dataset.failAcknowledgements = 1;
      final failed = await measure('upload.local-ack-failure', () async {
        await expectLater(publish(), throwsStateError);
      });
      expectRequests(failed, stat: 4, put: 4);
      expect(failed.businessUploadBytes, 4096 + batchBodyBytes(batch));
      expect(
        failed.putKeys.last,
        LogicalKeys.commit(vaultId, producerId, 1, 'batch-1'),
      );
      expect(dataset.acknowledged, isEmpty);

      for (var i = 1; i <= 3; i++) {
        if (i > 1) dataset.pending.add(batch);
        final replay = await measure('upload.same-batch-replay.$i', publish);
        expectRequests(replay, stat: 4);
        expect(replay.businessPutCount, 0);
        expect(replay.businessUploadBytes, 0);
        expect(dataset.pending, isEmpty);
        final jobs = await database.listTransferJobs(
          profileId: profileId,
          includeCompleted: true,
        );
        expect(jobs, hasLength(4)); // No duplicate transfer jobs on replay.
        expect(await database.listTransferJobs(profileId: profileId), isEmpty);
      }
      expect(dataset.acknowledged, List.filled(3, 'batch-1:1'));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'download: duplicate listing and repeated runs import exactly once',
    () async {
      final batch = makeBatch(1, [makeBlob(0, 4096)]);
      dataset.pending.add(batch);
      await publish(); // Setup is outside the measured download window.
      remote.duplicateListEntries = true;

      Future<void> download(int expected) async {
        // Recreate the engine: idempotence is backed by DB, not an instance cache.
        final result = await SyncDownloadEngine(database).importAvailable(
          profileId: 'consumer-profile',
          vaultId: vaultId,
          consumerDeviceId: consumerId,
          trustedProducerDeviceIds: const [producerId],
          dataset: dataset,
          remote: remote,
        );
        expect(result.importedBatchCount, expected);
        expect(result.pendingBatchCount, 0);
      }

      final first = await measure(
        'download.duplicate-list.first',
        () => download(1),
      );
      expect(first.duplicateItems, 1);
      expect(first.businessUploadBytes, 0);
      expect(first.readKeys.toSet(), hasLength(4));
      // One opaque ACK PUT/stat, four object reads and one commit listing.
      expectRequests(first, stat: 1, list: 1, read: 4, put: 1);
      expect(dataset.imported.single.blobs['blob-0'], hasLength(4096));

      for (var i = 1; i <= 3; i++) {
        final replay = await measure('download.repeated.$i', () => download(0));
        expectRequests(replay, list: 1);
        expect(replay.duplicateItems, 1);
        expect(replay.businessUploadBytes, 0);
        expect(replay.readKeys, isEmpty);
        expect(dataset.imported, hasLength(1));
        expect(
          await database.appliedSequence(
            profileId: 'consumer-profile',
            producerDeviceId: producerId,
          ),
          1,
        );
        expect(
          await database.listTransferJobs(
            profileId: 'consumer-profile',
            includeCompleted: true,
          ),
          hasLength(5),
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

void expectRequests(
  Workload sample, {
  int stat = 0,
  int list = 0,
  int read = 0,
  int put = 0,
  int delete = 0,
}) {
  expect(sample.requests, {
    'stat': stat,
    'list': list,
    'read': read,
    'put': put,
    'delete': delete,
  });
}
