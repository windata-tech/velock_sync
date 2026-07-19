import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_checkpoint_publisher.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test(
    'publishes checkpoint commit only after its parts and envelope',
    () async {
      final remote = _RecordingStore();
      final checkpoint = _checkpoint();

      final result = await const SyncCheckpointPublisher().publish(
        checkpoint: checkpoint,
        remote: remote,
      );

      expect(result.uploadedPartCount, 2);
      expect(result.didUploadEnvelope, isTrue);
      expect(result.didPublishCommit, isTrue);
      expect(remote.puts, [
        LogicalKeys.checkpointPart('vault-1', 'checkpoint-1', 1),
        LogicalKeys.checkpointPart('vault-1', 'checkpoint-1', 2),
        LogicalKeys.checkpointEnvelope('vault-1', 'checkpoint-1'),
        LogicalKeys.checkpointCommit('vault-1', 'checkpoint-1'),
      ]);
    },
  );

  test(
    'resumes an incomplete checkpoint without rewriting immutable parts',
    () async {
      final remote = _RecordingStore();
      final checkpoint = _checkpoint();
      await remote.put(
        LogicalKeys.checkpointPart('vault-1', 'checkpoint-1', 1),
        Stream.value(<int>[1]),
        contentLength: 1,
        ifAbsent: true,
      );
      remote.puts.clear();

      final result = await const SyncCheckpointPublisher().publish(
        checkpoint: checkpoint,
        remote: remote,
      );

      expect(result.uploadedPartCount, 1);
      expect(remote.puts, [
        LogicalKeys.checkpointPart('vault-1', 'checkpoint-1', 2),
        LogicalKeys.checkpointEnvelope('vault-1', 'checkpoint-1'),
        LogicalKeys.checkpointCommit('vault-1', 'checkpoint-1'),
      ]);
    },
  );

  test('rejects duplicate checkpoint part numbers before publishing', () async {
    final remote = _RecordingStore();
    final duplicate = PreparedCheckpoint(
      vaultId: 'vault-1',
      checkpointId: 'checkpoint-1',
      envelope: _artifact([1]),
      parts: [
        CheckpointPart(partNumber: 1, content: _artifact([1])),
        CheckpointPart(partNumber: 1, content: _artifact([2])),
      ],
      commit: _artifact([3]),
    );

    await expectLater(
      const SyncCheckpointPublisher().publish(
        checkpoint: duplicate,
        remote: remote,
      ),
      throwsArgumentError,
    );
    expect(remote.puts, isEmpty);
  });
}

PreparedCheckpoint _checkpoint() => PreparedCheckpoint(
  vaultId: 'vault-1',
  checkpointId: 'checkpoint-1',
  envelope: _artifact([3]),
  parts: [
    CheckpointPart(partNumber: 1, content: _artifact([1])),
    CheckpointPart(partNumber: 2, content: _artifact([2])),
  ],
  commit: _artifact([4]),
);

ImmutableArtifact _artifact(List<int> bytes) =>
    ImmutableArtifact.fromBytes(Uint8List.fromList(bytes));

class _RecordingStore extends InMemoryObjectStore {
  final List<String> puts = [];

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) {
    puts.add(logicalKey);
    return super.put(
      logicalKey,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }
}
