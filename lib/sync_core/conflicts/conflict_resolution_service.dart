import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// The only domain entry point permitted to complete a durable conflict.
///
/// A conflict stays unresolved until this service has acquired its durable
/// intent and then receives either a selected-folder durable publication
/// artifact or a Velock receipt verified by a trusted verifier.
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
  const ConflictResolutionResult.rejected(String errorCode)
    : this._(ConflictResolutionStatus.rejected, errorCode: errorCode);
  const ConflictResolutionResult.failed(String errorCode)
    : this._(ConflictResolutionStatus.failed, errorCode: errorCode);

  final ConflictResolutionStatus status;

  /// Stable, sanitised local diagnostic code. Never contains protected data.
  final String? errorCode;
}

class ConflictResolutionArtifact {
  const ConflictResolutionArtifact(this.value);

  /// Opaque reference proving that a selected-folder resolver has durably
  /// applied and published the resolution through the normal sync path.
  final String value;
}

class VelockConflictResolutionReceipt {
  const VelockConflictResolutionReceipt(this.artifact);

  /// Opaque receipt artifact from the Velock owner. It must be verified before
  /// it can cause the generic database conflict to complete.
  final String artifact;
}

abstract interface class SelectedFolderConflictResolver {
  Future<ConflictResolutionArtifact> resolve({
    required SyncConflictRecord conflict,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  });
}

abstract interface class VelockConflictOpener {
  Future<VelockConflictResolutionReceipt> open({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
  });

  /// Best-effort cleanup after the generic conflict and receipt artifact are
  /// durably committed. Failure must not roll that completion back.
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

/// Safe fallback for environments that do not wire the production Selected
/// Folder resolver. Completing without durable storage and publication steps
/// would lose data after a crash, so this intentionally fails closed.
class FailClosedSelectedFolderConflictResolver
    implements SelectedFolderConflictResolver {
  const FailClosedSelectedFolderConflictResolver();

  @override
  Future<ConflictResolutionArtifact> resolve({
    required SyncConflictRecord conflict,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  }) => throw const ConflictResolutionFailure(
    'selected-folder-resolution-unavailable',
  );
}

/// Production placeholder until Velock exposes an opaque, trusted
/// conflict-resolution receipt contract. Merely opening another app can never
/// resolve a generic Sync conflict.
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

/// Strictly validated local-only metadata made by SelectedFolderIncomingApplier.
/// It has no content bytes and never crosses into generic UI or Velock paths.
class SelectedFolderConflictDetails {
  const SelectedFolderConflictDetails({
    required this.target,
    this.incomingConflictCopy,
    required this.incomingWasDelete,
    required this.entryType,
    required this.localRevisionId,
    required this.incomingRevisionId,
    required this.localVector,
    required this.incomingVector,
  });

  final String target;
  final String? incomingConflictCopy;
  final bool incomingWasDelete;
  final String entryType;
  final String localRevisionId;
  final String incomingRevisionId;
  final Map<String, int> localVector;
  final Map<String, int> incomingVector;

  static SelectedFolderConflictDetails? tryParse(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        return null;
      }
      final incomingWasDelete = decoded['incomingWasDelete'];
      if (incomingWasDelete is! bool ||
          decoded.length != (incomingWasDelete ? 8 : 9)) {
        return null;
      }
      final target = _relativePath(decoded['target']);
      final copy = incomingWasDelete
          ? null
          : _relativePath(decoded['incomingConflictCopy']);
      final entryType = decoded['entryType'];
      final localRevisionId = _opaqueId(decoded['localRevisionId']);
      final incomingRevisionId = _opaqueId(decoded['incomingRevisionId']);
      final localVector = _vector(decoded['localVector']);
      final incomingVector = _vector(decoded['incomingVector']);
      if (target == null ||
          (!incomingWasDelete &&
              (copy == null || !copy.startsWith('$target.velock-conflict-'))) ||
          entryType != 'file' ||
          localRevisionId == null ||
          incomingRevisionId == null ||
          localVector == null ||
          incomingVector == null) {
        return null;
      }
      return SelectedFolderConflictDetails(
        target: target,
        incomingConflictCopy: copy,
        incomingWasDelete: incomingWasDelete,
        entryType: entryType,
        localRevisionId: localRevisionId,
        incomingRevisionId: incomingRevisionId,
        localVector: localVector,
        incomingVector: incomingVector,
      );
    } on Object {
      return null;
    }
  }

  static String? _relativePath(Object? value) {
    if (value is! String || value.isEmpty || value.startsWith('/')) return null;
    final normalised = value.replaceAll('\\', '/');
    final parts = normalised.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    return normalised;
  }

  static String? _opaqueId(Object? value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  static Map<String, int>? _vector(Object? value) {
    if (value is! Map<String, dynamic> || value.isEmpty) return null;
    final entries = <String, int>{};
    for (final entry in value.entries) {
      final id = _opaqueId(entry.key);
      final counter = entry.value;
      if (id == null || counter is! int || counter <= 0) return null;
      entries[id] = counter;
    }
    return Map<String, int>.unmodifiable(entries);
  }
}

class DurableConflictResolutionService implements ConflictResolutionService {
  DurableConflictResolutionService({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required SelectedFolderConflictResolver selectedFolderResolver,
    required VelockConflictOpener velockOpener,
    required VelockConflictReceiptVerifier velockReceiptVerifier,
    Uuid? uuid,
    DateTime Function()? now,
    this.lease = const Duration(minutes: 2),
  }) : _database = database,
       _profiles = profiles,
       _selectedFolderResolver = selectedFolderResolver,
       _velockOpener = velockOpener,
       _velockReceiptVerifier = velockReceiptVerifier,
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final SyncProfileRepository _profiles;
  final SelectedFolderConflictResolver _selectedFolderResolver;
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

    final profile = await _readProfile(conflict.profileId);
    if (profile == null) {
      return const ConflictResolutionResult.rejected('profile-unavailable');
    }
    if (!_isAllowed(profile.kind, strategy)) {
      return const ConflictResolutionResult.rejected('invalid-strategy');
    }

    final selectedFolderDetails = profile.kind == SyncDatasetKind.selectedFolder
        ? SelectedFolderConflictDetails.tryParse(conflict.protectedDetails)
        : null;
    if (profile.kind == SyncDatasetKind.selectedFolder &&
        selectedFolderDetails == null) {
      return const ConflictResolutionResult.rejected(
        'invalid-selected-folder-conflict-details',
      );
    }

    final owner = _uuid.v4();
    final acquisition = await _database.acquireConflictResolutionIntent(
      conflictId: conflictId,
      strategy: strategy.persistedValue,
      owner: owner,
      now: _now().toUtc(),
      lease: lease,
    );
    switch (acquisition.status) {
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
      VelockConflictResolutionReceipt? velockReceipt;
      final artifact = switch (profile.kind) {
        SyncDatasetKind.selectedFolder => await _resolveSelectedFolder(
          conflict: conflict,
          details: selectedFolderDetails!,
          strategy: strategy,
        ),
        SyncDatasetKind.velockManaged => (velockReceipt = await _resolveVelock(
          profile: profile,
          conflict: conflict,
        )).artifact,
      };
      if (artifact.isEmpty) {
        throw const ConflictResolutionFailure('missing-resolution-artifact');
      }
      await _database.completeConflictResolution(
        conflictId: conflictId,
        owner: owner,
        completionArtifact: artifact,
      );
      if (velockReceipt != null) {
        try {
          await _velockOpener.acknowledge(
            profile: profile,
            conflict: conflict,
            receipt: velockReceipt,
          );
        } on Object {
          // The receipt is already retained in the completed durable intent.
          // Cleanup can be retried independently and cannot undo resolution.
        }
      }
      return const ConflictResolutionResult.completed();
    } on Object catch (error) {
      final errorCode = _errorCode(error);
      await _database.failConflictResolutionIntent(
        conflictId: conflictId,
        owner: owner,
        errorCode: errorCode,
      );
      return ConflictResolutionResult.failed(errorCode);
    }
  }

  Future<String> _resolveSelectedFolder({
    required SyncConflictRecord conflict,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  }) async => (await _selectedFolderResolver.resolve(
    conflict: conflict,
    details: details,
    strategy: strategy,
  )).value;

  Future<VelockConflictResolutionReceipt> _resolveVelock({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
  }) async {
    final receipt = await _velockOpener.open(
      profile: profile,
      conflict: conflict,
    );
    final trusted = await _velockReceiptVerifier.verify(
      profile: profile,
      conflict: conflict,
      receipt: receipt,
    );
    if (!trusted) {
      throw const ConflictResolutionFailure('untrusted-velock-receipt');
    }
    return receipt;
  }

  Future<SyncProfileEnvelope?> _readProfile(String profileId) async {
    try {
      return await _profiles.read(profileId);
    } on Object {
      return null;
    }
  }

  bool _isAllowed(SyncDatasetKind kind, ConflictResolutionStrategy strategy) =>
      switch (kind) {
        SyncDatasetKind.selectedFolder =>
          strategy == ConflictResolutionStrategy.keepLocal ||
              strategy == ConflictResolutionStrategy.keepRemote ||
              strategy == ConflictResolutionStrategy.keepBoth,
        SyncDatasetKind.velockManaged =>
          strategy == ConflictResolutionStrategy.openInVelock,
      };

  String _errorCode(Object error) => switch (error) {
    ConflictResolutionFailure(:final code) => code,
    _ => 'conflict-resolution-failed',
  };
}
