import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_checkpoint_recovery.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  group('SyncCheckpointRecovery', () {
    test(
      'only imports a checkpoint after its final commit is visible',
      () async {
        final remote = InMemoryObjectStore();
        await _putCheckpoint(remote, checkpointId: 'committed', commit: true);
        await _putCheckpoint(remote, checkpointId: 'incomplete', commit: false);
        final dataset = _CheckpointDataset();

        final result = await const SyncCheckpointRecovery().recoverLatest(
          vaultId: 'vault-1',
          dataset: dataset,
          remote: remote,
        );

        expect(result.didRecover, isTrue);
        expect(result.checkpointId, 'committed');
        expect(dataset.accepted.single.checkpointId, 'committed');
        expect(dataset.accepted.single.parts.map((part) => part.partNumber), [
          1,
          2,
        ]);
      },
    );

    test(
      'falls back when the trusted dataset rejects a newer checkpoint',
      () async {
        final remote = InMemoryObjectStore();
        await _putCheckpoint(
          remote,
          checkpointId: 'checkpoint-a',
          commit: true,
        );
        await _putCheckpoint(
          remote,
          checkpointId: 'checkpoint-z',
          commit: true,
        );
        final dataset = _CheckpointDataset(reject: {'checkpoint-z'});

        final result = await const SyncCheckpointRecovery().recoverLatest(
          vaultId: 'vault-1',
          dataset: dataset,
          remote: remote,
        );

        expect(result.didRecover, isTrue);
        expect(result.checkpointId, 'checkpoint-a');
        expect(dataset.accepted.map((checkpoint) => checkpoint.checkpointId), [
          'checkpoint-z',
          'checkpoint-a',
        ]);
      },
    );

    test(
      'skips a committed checkpoint whose part exceeds transfer limits',
      () async {
        final remote = InMemoryObjectStore();
        await _putCheckpoint(
          remote,
          checkpointId: 'checkpoint-a',
          commit: true,
        );
        await _putCheckpoint(
          remote,
          checkpointId: 'checkpoint-z',
          commit: true,
          part: List<int>.filled(8, 7),
        );
        final dataset = _CheckpointDataset();

        final result = await const SyncCheckpointRecovery().recoverLatest(
          vaultId: 'vault-1',
          dataset: dataset,
          remote: remote,
          limits: const CheckpointRecoveryLimits(maxPartBytes: 4),
        );

        expect(result.checkpointId, 'checkpoint-a');
        expect(dataset.accepted, hasLength(1));
      },
    );
  });
}

Future<void> _putCheckpoint(
  RemoteObjectStore remote, {
  required String checkpointId,
  required bool commit,
  List<int> part = const [1, 2, 3],
}) async {
  const vaultId = 'vault-1';
  await _put(remote, LogicalKeys.checkpointEnvelope(vaultId, checkpointId), [
    4,
  ]);
  await _put(
    remote,
    LogicalKeys.checkpointPart(vaultId, checkpointId, 1),
    part,
  );
  await _put(remote, LogicalKeys.checkpointPart(vaultId, checkpointId, 2), [5]);
  if (commit) {
    await _put(remote, LogicalKeys.checkpointCommit(vaultId, checkpointId), [
      6,
    ]);
  }
}

Future<void> _put(RemoteObjectStore remote, String key, List<int> value) =>
    remote.put(
      key,
      Stream.value(Uint8List.fromList(value)),
      contentLength: value.length,
      ifAbsent: true,
    );

class _CheckpointDataset implements CheckpointRecoveringDatasetAdapter {
  _CheckpointDataset({Set<String>? reject}) : _reject = reject ?? {};

  final Set<String> _reject;
  final accepted = <IncomingCheckpoint>[];

  @override
  Future<CheckpointImportResult> acceptIncomingCheckpoint(
    IncomingCheckpoint checkpoint,
  ) async {
    accepted.add(checkpoint);
    return _reject.contains(checkpoint.checkpointId)
        ? const CheckpointImportResult.rejected()
        : const CheckpointImportResult.applied(
            coveredSequences: {'device-1': 3},
          );
  }
}
