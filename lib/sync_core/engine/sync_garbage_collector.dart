import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

/// Evidence supplied only after a trusted dataset has authenticated checkpoint
/// and acknowledgement artifacts. Sync Core never treats remote listing data
/// as proof that a device has applied a batch.
class GarbageCollectionEvidence {
  const GarbageCollectionEvidence({
    required this.checkpointId,
    required this.checkpointCoveredSequences,
    required this.activeDeviceIds,
    required this.acknowledgedSequences,
    required this.tombstoneRetentionCutoff,
  });

  final String checkpointId;
  final Map<String, int> checkpointCoveredSequences;
  final Set<String> activeDeviceIds;

  /// Consumer device -> producer device -> highest authenticated sequence.
  final Map<String, Map<String, int>> acknowledgedSequences;
  final DateTime tombstoneRetentionCutoff;
}

/// A candidate's metadata must be derived from authenticated local state.
/// [logicalKeys] may contain a batch artifact, tombstone or blob, but each key
/// is deleted only if the operation it belongs to is checkpoint-covered and
/// acknowledged by every active device.
class GarbageCollectionCandidate {
  const GarbageCollectionCandidate({
    required this.candidateId,
    required this.logicalKeys,
    required this.producerDeviceId,
    required this.sequence,
    required this.tombstoneAt,
    required this.isReferencedByActiveRevision,
    required this.isReferencedByCheckpoint,
    this.retentionManifestKey,
    this.isReferencedByRetentionHold = false,
    this.retentionHoldUntil,
  });

  final String candidateId;
  final List<String> logicalKeys;
  final String producerDeviceId;
  final int sequence;
  final DateTime? tombstoneAt;
  final bool isReferencedByActiveRevision;
  final bool isReferencedByCheckpoint;
  final String? retentionManifestKey;
  final bool isReferencedByRetentionHold;
  final DateTime? retentionHoldUntil;
}

class GarbageCollectionPlan {
  const GarbageCollectionPlan({
    required this.planId,
    required this.vaultId,
    required this.checkpointId,
    required this.createdAt,
    required this.candidates,
  });

  final String planId;
  final String vaultId;
  final String checkpointId;
  final DateTime createdAt;
  final List<GarbageCollectionCandidate> candidates;

  List<String> get logicalKeys => [
    for (final candidate in candidates) ...candidate.logicalKeys,
  ];
}

class GarbageCollectionResult {
  const GarbageCollectionResult({
    required this.plan,
    required this.manifestKey,
    required this.deletedObjectCount,
    required this.isDryRun,
  });

  final GarbageCollectionPlan plan;
  final String manifestKey;
  final int deletedObjectCount;
  final bool isDryRun;
}

/// Conservative V1 GC planner. Its default is dry-run: a manifest is made
/// durable for audit, but no remote object is removed. Execution requires the
/// same plan to have already passed all ACK, checkpoint, tombstone and
/// reference checks.
class SyncGarbageCollector {
  SyncGarbageCollector({Uuid? uuid, DateTime Function()? now})
    : _uuid = uuid ?? const Uuid(),
      _now = now ?? DateTime.now;

  final Uuid _uuid;
  final DateTime Function() _now;

  GarbageCollectionPlan plan({
    required String vaultId,
    required GarbageCollectionEvidence evidence,
    required Iterable<GarbageCollectionCandidate> candidates,
  }) {
    _validateEvidence(evidence);
    final prefix = LogicalKeys.vaultPrefix(vaultId);
    final eligible = <GarbageCollectionCandidate>[];
    final seenKeys = <String>{};
    for (final candidate in candidates) {
      if (!_isEligible(candidate, evidence)) continue;
      if (candidate.logicalKeys.isEmpty ||
          candidate.logicalKeys.any(
            (key) => !key.startsWith(prefix) || !seenKeys.add(key),
          )) {
        throw ArgumentError.value(candidate, 'candidates', 'has invalid keys');
      }
      eligible.add(candidate);
    }
    return GarbageCollectionPlan(
      planId: _uuid.v4(),
      vaultId: vaultId,
      checkpointId: evidence.checkpointId,
      createdAt: _now().toUtc(),
      candidates: List.unmodifiable(eligible),
    );
  }

  Future<GarbageCollectionResult> publishAndExecute({
    required GarbageCollectionPlan plan,
    required RemoteObjectStore remote,
    bool dryRun = true,
  }) async {
    final manifestKey = LogicalKeys.garbageCollectionManifest(
      plan.vaultId,
      plan.planId,
    );
    final manifest = Uint8List.fromList(
      utf8.encode(_manifestJson(plan, dryRun)),
    );
    try {
      await remote.put(
        manifestKey,
        Stream.value(manifest),
        contentLength: manifest.length,
        ifAbsent: true,
      );
    } on RemoteObjectAlreadyExistsException {
      throw StateError('Garbage collection plan ID already exists.');
    }
    if (dryRun) {
      return GarbageCollectionResult(
        plan: plan,
        manifestKey: manifestKey,
        deletedObjectCount: 0,
        isDryRun: true,
      );
    }
    for (final key in plan.logicalKeys) {
      await remote.delete(key);
    }
    return GarbageCollectionResult(
      plan: plan,
      manifestKey: manifestKey,
      deletedObjectCount: plan.logicalKeys.length,
      isDryRun: false,
    );
  }

  bool _isEligible(
    GarbageCollectionCandidate candidate,
    GarbageCollectionEvidence evidence,
  ) {
    if (candidate.candidateId.isEmpty ||
        candidate.producerDeviceId.isEmpty ||
        candidate.sequence < 1 ||
        candidate.isReferencedByActiveRevision ||
        candidate.isReferencedByCheckpoint ||
        candidate.isReferencedByRetentionHold ||
        (candidate.retentionHoldUntil != null &&
            candidate.retentionHoldUntil!.isAfter(
              evidence.tombstoneRetentionCutoff,
            )) ||
        candidate.tombstoneAt == null ||
        candidate.tombstoneAt!.isAfter(evidence.tombstoneRetentionCutoff)) {
      return false;
    }
    if ((evidence.checkpointCoveredSequences[candidate.producerDeviceId] ?? 0) <
        candidate.sequence) {
      return false;
    }
    return evidence.activeDeviceIds
        .where((consumer) => consumer != candidate.producerDeviceId)
        .every(
          (consumer) =>
              (evidence.acknowledgedSequences[consumer]?[candidate
                      .producerDeviceId] ??
                  0) >=
              candidate.sequence,
        );
  }

  void _validateEvidence(GarbageCollectionEvidence evidence) {
    if (evidence.checkpointId.isEmpty || evidence.activeDeviceIds.isEmpty) {
      throw ArgumentError.value(evidence, 'evidence', 'is incomplete');
    }
    for (final deviceId in evidence.activeDeviceIds) {
      if (deviceId.isEmpty ||
          !evidence.acknowledgedSequences.containsKey(deviceId)) {
        throw ArgumentError.value(
          evidence,
          'evidence',
          'is missing an active-device ACK map',
        );
      }
    }
  }

  String _manifestJson(GarbageCollectionPlan plan, bool dryRun) => jsonEncode({
    'candidateIds': plan.candidates
        .map((candidate) => candidate.candidateId)
        .toList(),
    'checkpointId': plan.checkpointId,
    'createdAt': plan.createdAt.toIso8601String(),
    'dryRun': dryRun,
    'logicalKeys': plan.logicalKeys,
    'planId': plan.planId,
    'protocolVersion': 1,
    'vaultId': plan.vaultId,
  });
}
