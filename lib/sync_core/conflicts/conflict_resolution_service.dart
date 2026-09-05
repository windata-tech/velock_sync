import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

abstract interface class ConflictResolutionService {
  Future<ConflictResolutionResult> resolve({
    required String conflictId,
    required ConflictResolutionStrategy strategy,
  });
}

enum ConflictResolutionStatus {
  completed,
  alreadyCompleted,
  missing,
  inProgress,
  strategyMismatch,
  rejected,
  failed,
}

class ConflictResolutionResult {
  const ConflictResolutionResult._(this.status, {this.errorCode});
  const ConflictResolutionResult.completed()
    : this._(ConflictResolutionStatus.completed);
  const ConflictResolutionResult.alreadyCompleted()
    : this._(ConflictResolutionStatus.alreadyCompleted);
  const ConflictResolutionResult.missing()
    : this._(ConflictResolutionStatus.missing);
  const ConflictResolutionResult.inProgress()
    : this._(ConflictResolutionStatus.inProgress);
  const ConflictResolutionResult.strategyMismatch()
    : this._(ConflictResolutionStatus.strategyMismatch);
  const ConflictResolutionResult.rejected(String c)
    : this._(ConflictResolutionStatus.rejected, errorCode: c);
  const ConflictResolutionResult.failed(String c)
    : this._(ConflictResolutionStatus.failed, errorCode: c);
  final ConflictResolutionStatus status;
  final String? errorCode;
}

class VelockConflictResolutionReceipt {
  const VelockConflictResolutionReceipt(this.artifact);
  final String artifact;
}

abstract interface class VelockConflictOpener {
  Future<VelockConflictResolutionReceipt> open({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
  });
  Future<void> acknowledge({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  });
}

abstract interface class VelockConflictReceiptVerifier {
  Future<bool> verify({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  });
}

class FailClosedVelockConflictOpener implements VelockConflictOpener {
  const FailClosedVelockConflictOpener();
  @override
  Future<VelockConflictResolutionReceipt> open({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
  }) => throw const ConflictResolutionFailure('velock-resolution-unavailable');
  @override
  Future<void> acknowledge({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  }) async {}
}

class RejectingVelockConflictReceiptVerifier
    implements VelockConflictReceiptVerifier {
  const RejectingVelockConflictReceiptVerifier();
  @override
  Future<bool> verify({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  }) async => false;
}

class ConflictResolutionFailure implements Exception {
  const ConflictResolutionFailure(this.code);
  final String code;
}

class DurableConflictResolutionService implements ConflictResolutionService {
  DurableConflictResolutionService({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required VelockConflictOpener velockOpener,
    required VelockConflictReceiptVerifier velockReceiptVerifier,
    Uuid? uuid,
    DateTime Function()? now,
    this.lease = const Duration(minutes: 2),
  }) : _database = database,
       _profiles = profiles,
       _velockOpener = velockOpener,
       _velockReceiptVerifier = velockReceiptVerifier,
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;
  final SyncStateDatabase _database;
  final SyncProfileRepository _profiles;
  final VelockConflictOpener _velockOpener;
  final VelockConflictReceiptVerifier _velockReceiptVerifier;
  final Uuid _uuid;
  final DateTime Function() _now;
  final Duration lease;
  final Map<String, Future<ConflictResolutionResult>> _inFlight = {};
  @override
  Future<ConflictResolutionResult> resolve({
    required String conflictId,
    required ConflictResolutionStrategy strategy,
  }) {
    final key = '$conflictId:${strategy.persistedValue}';
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _resolve(conflictId: conflictId, strategy: strategy);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<ConflictResolutionResult> _resolve({
    required String conflictId,
    required ConflictResolutionStrategy strategy,
  }) async {
    final conflict = await _database.readUnresolvedConflict(conflictId);
    if (conflict == null) return const ConflictResolutionResult.missing();
    final profile = await _profiles.read(conflict.profileId);
    if (profile == null) {
      return const ConflictResolutionResult.rejected('profile-unavailable');
    }
    if (profile.kind != SyncDatasetKind.velockManaged ||
        strategy != ConflictResolutionStrategy.openInVelock) {
      return const ConflictResolutionResult.rejected('invalid-strategy');
    }
    final owner = _uuid.v4();
    final a = await _database.acquireConflictResolutionIntent(
      conflictId: conflictId,
      strategy: strategy.persistedValue,
      owner: owner,
      now: _now().toUtc(),
      lease: lease,
    );
    switch (a.status) {
      case ConflictResolutionIntentAcquisitionStatus.completed:
        return const ConflictResolutionResult.alreadyCompleted();
      case ConflictResolutionIntentAcquisitionStatus.inProgress:
        return const ConflictResolutionResult.inProgress();
      case ConflictResolutionIntentAcquisitionStatus.strategyMismatch:
        return const ConflictResolutionResult.strategyMismatch();
      case ConflictResolutionIntentAcquisitionStatus.missing:
        return const ConflictResolutionResult.missing();
      case ConflictResolutionIntentAcquisitionStatus.acquired:
        break;
    }
    try {
      final receipt = await _velockOpener.open(
        profile: profile,
        conflict: conflict,
      );
      if (!await _velockReceiptVerifier.verify(
        profile: profile,
        conflict: conflict,
        receipt: receipt,
      )) {
        throw const ConflictResolutionFailure('untrusted-velock-receipt');
      }
      if (receipt.artifact.isEmpty) {
        throw const ConflictResolutionFailure('missing-resolution-artifact');
      }
      await _database.completeConflictResolution(
        conflictId: conflictId,
        owner: owner,
        completionArtifact: receipt.artifact,
      );
      try {
        await _velockOpener.acknowledge(
          profile: profile,
          conflict: conflict,
          receipt: receipt,
        );
      } on Object {
        // The durable local completion is authoritative; acknowledgement is best effort.
      }
      return const ConflictResolutionResult.completed();
    } on Object catch (e) {
      final c = e is ConflictResolutionFailure
          ? e.code
          : 'conflict-resolution-failed';
      await _database.failConflictResolutionIntent(
        conflictId: conflictId,
        owner: owner,
        errorCode: c,
      );
      return ConflictResolutionResult.failed(c);
    }
  }
}
