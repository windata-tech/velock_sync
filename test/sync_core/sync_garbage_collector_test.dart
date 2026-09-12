import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:uuid/data.dart' show V4Options;
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_garbage_collector.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  group('SyncGarbageCollector', () {
    test(
      'only plans tombstones covered by checkpoint and every active ACK',
      () {
        final collector = SyncGarbageCollector(
          uuid: _FixedUuid(),
          now: () => DateTime.utc(2026, 7, 15),
        );

        final plan = collector.plan(
          vaultId: 'vault-1',
          evidence: _evidence(),
          candidates: [
            _candidate('eligible'),
            _candidate('missing-ack', sequence: 8),
            _candidate('referenced', isReferencedByActiveRevision: true),
            _candidate('retention-hold', isReferencedByRetentionHold: true),
            _candidate('recent', tombstoneAt: DateTime.utc(2026, 7, 14)),
          ],
        );

        expect(plan.candidates.map((candidate) => candidate.candidateId), [
          'eligible',
        ]);
        expect(plan.planId, 'plan-1');
      },
    );

    test(
      'dry-run writes an immutable audit manifest without deletion',
      () async {
        final remote = InMemoryObjectStore();
        final collector = SyncGarbageCollector(
          uuid: _FixedUuid(),
          now: () => DateTime.utc(2026, 7, 15),
        );
        final plan = collector.plan(
          vaultId: 'vault-1',
          evidence: _evidence(),
          candidates: [_candidate('eligible')],
        );

        final result = await collector.publishAndExecute(
          plan: plan,
          remote: remote,
        );

        expect(result.isDryRun, isTrue);
        expect(result.deletedObjectCount, 0);
        final manifest = await remote
            .read(result.manifestKey)
            .expand((bytes) => bytes)
            .toList();
        expect(jsonDecode(utf8.decode(manifest))['dryRun'], isTrue);
        expect(await remote.stat(plan.logicalKeys.single), isNull);
      },
    );

    test('does not require a producer to ACK its own batch', () {
      final collector = SyncGarbageCollector(
        uuid: _FixedUuid(),
        now: () => DateTime.utc(2026, 7, 15),
      );
      final plan = collector.plan(
        vaultId: 'vault-1',
        evidence: GarbageCollectionEvidence(
          checkpointId: 'checkpoint-1',
          checkpointCoveredSequences: {'producer-1': 7},
          activeDeviceIds: {'producer-1'},
          acknowledgedSequences: {'producer-1': <String, int>{}},
          tombstoneRetentionCutoff: DateTime.utc(2026, 7, 1),
        ),
        candidates: [_candidate('producer-owned')],
      );

      expect(plan.candidates.map((candidate) => candidate.candidateId), [
        'producer-owned',
      ]);
    });

    test('publishes the manifest before explicit deletion', () async {
      final remote = _RecordingStore();
      final collector = SyncGarbageCollector(
        uuid: _FixedUuid(),
        now: () => DateTime.utc(2026, 7, 15),
      );
      final plan = collector.plan(
        vaultId: 'vault-1',
        evidence: _evidence(),
        candidates: [_candidate('eligible')],
      );

      final result = await collector.publishAndExecute(
        plan: plan,
        remote: remote,
        dryRun: false,
      );

      expect(result.deletedObjectCount, 1);
      expect(remote.events.first, startsWith('put:${result.manifestKey}'));
      expect(remote.events.last, 'delete:${plan.logicalKeys.single}');
    });
  });
}

GarbageCollectionEvidence _evidence() => GarbageCollectionEvidence(
  checkpointId: 'checkpoint-1',
  checkpointCoveredSequences: {'producer-1': 7},
  activeDeviceIds: {'consumer-a', 'consumer-b'},
  acknowledgedSequences: {
    'consumer-a': {'producer-1': 7},
    'consumer-b': {'producer-1': 7},
  },
  tombstoneRetentionCutoff: DateTime.utc(2026, 7, 1),
);

GarbageCollectionCandidate _candidate(
  String id, {
  int sequence = 7,
  bool isReferencedByActiveRevision = false,
  bool isReferencedByRetentionHold = false,
  DateTime? tombstoneAt,
}) => GarbageCollectionCandidate(
  candidateId: id,
  logicalKeys: [
    LogicalKeys.commit('vault-1', 'producer-1', sequence, 'batch-$id'),
  ],
  producerDeviceId: 'producer-1',
  sequence: sequence,
  tombstoneAt: tombstoneAt ?? DateTime.utc(2026, 6, 1),
  isReferencedByActiveRevision: isReferencedByActiveRevision,
  isReferencedByRetentionHold: isReferencedByRetentionHold,
  isReferencedByCheckpoint: false,
);

class _FixedUuid extends Uuid {
  @override
  String v4({Map<String, dynamic>? options, V4Options? config}) => 'plan-1';
}

class _RecordingStore extends InMemoryObjectStore {
  final events = <String>[];

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) {
    events.add('delete:$logicalKey');
    return super.delete(logicalKey, cancellation: cancellation);
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) {
    events.add('put:$logicalKey');
    return super.put(
      logicalKey,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }
}
