import 'dart:typed_data';

import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

class CheckpointRecoveryLimits {
  const CheckpointRecoveryLimits({
    this.maxCandidates = 1000,
    this.maxListedEntries = 10000,
    this.maxParts = 1000,
    this.maxCommitBytes = 1024 * 1024,
    this.maxEnvelopeBytes = 4 * 1024 * 1024,
    this.maxPartBytes = 512 * 1024 * 1024,
    this.maxTotalPartBytes = 512 * 1024 * 1024,
  });

  final int maxCandidates;
  final int maxListedEntries;
  final int maxParts;
  final int maxCommitBytes;
  final int maxEnvelopeBytes;
  final int maxPartBytes;
  final int maxTotalPartBytes;
}

class CheckpointRecoveryResult {
  const CheckpointRecoveryResult({
    required this.consideredCheckpointCount,
    this.checkpointId,
    this.importResult,
  });

  final int consideredCheckpointCount;
  final String? checkpointId;
  final CheckpointImportResult? importResult;

  bool get didRecover =>
      importResult?.disposition == CheckpointImportDisposition.applied;

  bool get didRestoreCursor => importResult?.isAccepted ?? false;

  Map<String, int> get coveredSequences =>
      importResult?.coveredSequences ?? const {};
}

class CheckpointIntegrityException implements Exception {
  const CheckpointIntegrityException(this.code);

  final String code;

  @override
  String toString() => 'Checkpoint integrity verification failed: $code';
}

/// Locates only checkpoints that have their final commit marker, applies
/// transfer limits, then gives the opaque artifacts to the trusted dataset
/// owner. The engine never parses or trusts the checkpoint's business state.
class SyncCheckpointRecovery {
  const SyncCheckpointRecovery();

  Future<CheckpointRecoveryResult> recoverLatest({
    required String vaultId,
    required CheckpointRecoveringDatasetAdapter dataset,
    required RemoteObjectStore remote,
    CheckpointRecoveryLimits limits = const CheckpointRecoveryLimits(),
  }) async {
    _validateLimits(limits);
    final candidates = await _committedCandidates(
      vaultId: vaultId,
      remote: remote,
      limits: limits,
    );
    var considered = 0;
    for (final candidate in candidates) {
      considered++;
      IncomingCheckpoint checkpoint;
      try {
        checkpoint = await _readCheckpoint(
          vaultId: vaultId,
          checkpointId: candidate.checkpointId,
          remote: remote,
          limits: limits,
        );
      } on RemoteObjectNotFoundException {
        continue;
      } on CheckpointIntegrityException {
        continue;
      }
      final result = await dataset.acceptIncomingCheckpoint(checkpoint);
      if (result.isAccepted) {
        return CheckpointRecoveryResult(
          consideredCheckpointCount: considered,
          checkpointId: candidate.checkpointId,
          importResult: result,
        );
      }
    }
    return CheckpointRecoveryResult(consideredCheckpointCount: considered);
  }

  Future<List<_CheckpointCandidate>> _committedCandidates({
    required String vaultId,
    required RemoteObjectStore remote,
    required CheckpointRecoveryLimits limits,
  }) async {
    final prefix = LogicalKeys.checkpointsPrefix(vaultId);
    final ids = <String>{};
    var listed = 0;
    String? cursor;
    do {
      final page = await remote.list(prefix: prefix, cursor: cursor);
      for (final item in page.items) {
        if (++listed > limits.maxListedEntries) {
          throw const CheckpointIntegrityException('listing-limit');
        }
        final suffix = item.logicalKey.startsWith(prefix)
            ? item.logicalKey.substring(prefix.length)
            : '';
        final checkpointId = suffix.split('/').first;
        if (_isOpaqueId(checkpointId)) ids.add(checkpointId);
      }
      cursor = page.nextCursor;
    } while (cursor != null);

    final candidates = <_CheckpointCandidate>[];
    for (final checkpointId in ids) {
      if (candidates.length >= limits.maxCandidates) {
        throw const CheckpointIntegrityException('candidate-limit');
      }
      final commit = await remote.stat(
        LogicalKeys.checkpointCommit(vaultId, checkpointId),
      );
      if (commit != null) {
        if (commit.size > limits.maxCommitBytes) {
          continue;
        }
        candidates.add(
          _CheckpointCandidate(
            checkpointId: checkpointId,
            committedAt: commit.updatedAt,
          ),
        );
      }
    }
    candidates.sort((left, right) {
      final timestamp = right.committedAt.compareTo(left.committedAt);
      return timestamp != 0
          ? timestamp
          : right.checkpointId.compareTo(left.checkpointId);
    });
    return candidates;
  }

  Future<IncomingCheckpoint> _readCheckpoint({
    required String vaultId,
    required String checkpointId,
    required RemoteObjectStore remote,
    required CheckpointRecoveryLimits limits,
  }) async {
    final commitKey = LogicalKeys.checkpointCommit(vaultId, checkpointId);
    final commit = await _readLimited(remote, commitKey, limits.maxCommitBytes);
    final envelope = await _readLimited(
      remote,
      LogicalKeys.checkpointEnvelope(vaultId, checkpointId),
      limits.maxEnvelopeBytes,
    );
    final parts = await _readParts(
      vaultId: vaultId,
      checkpointId: checkpointId,
      remote: remote,
      limits: limits,
    );
    return IncomingCheckpoint(
      vaultId: vaultId,
      checkpointId: checkpointId,
      commit: commit,
      envelope: envelope,
      parts: parts,
    );
  }

  Future<List<IncomingCheckpointPart>> _readParts({
    required String vaultId,
    required String checkpointId,
    required RemoteObjectStore remote,
    required CheckpointRecoveryLimits limits,
  }) async {
    final prefix =
        '${LogicalKeys.checkpointPrefix(vaultId, checkpointId)}/parts/';
    final partNumbers = <int>{};
    var listed = 0;
    String? cursor;
    do {
      final page = await remote.list(prefix: prefix, cursor: cursor);
      for (final item in page.items) {
        if (++listed > limits.maxListedEntries) {
          throw const CheckpointIntegrityException('parts-listing-limit');
        }
        final suffix = item.logicalKey.startsWith(prefix)
            ? item.logicalKey.substring(prefix.length)
            : '';
        final match = RegExp(r'^(\d{8})\.enc$').firstMatch(suffix);
        if (match == null) continue;
        final partNumber = int.parse(match.group(1)!);
        if (partNumber < 1 || !partNumbers.add(partNumber)) {
          throw const CheckpointIntegrityException('part-number');
        }
        if (partNumbers.length > limits.maxParts ||
            item.size > limits.maxPartBytes) {
          throw const CheckpointIntegrityException('part-limit');
        }
      }
      cursor = page.nextCursor;
    } while (cursor != null);

    var totalBytes = 0;
    final parts = <IncomingCheckpointPart>[];
    for (final partNumber in partNumbers.toList()..sort()) {
      final content = await _readLimited(
        remote,
        LogicalKeys.checkpointPart(vaultId, checkpointId, partNumber),
        limits.maxPartBytes,
      );
      totalBytes += content.length;
      if (totalBytes > limits.maxTotalPartBytes) {
        throw const CheckpointIntegrityException('total-part-limit');
      }
      parts.add(
        IncomingCheckpointPart(partNumber: partNumber, content: content),
      );
    }
    return parts;
  }

  Future<Uint8List> _readLimited(
    RemoteObjectStore remote,
    String key,
    int maximumBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in remote.read(key)) {
      bytes.add(chunk);
      if (bytes.length > maximumBytes) {
        throw const CheckpointIntegrityException('size-limit');
      }
    }
    return bytes.takeBytes();
  }

  void _validateLimits(CheckpointRecoveryLimits limits) {
    if (limits.maxCandidates < 1 ||
        limits.maxListedEntries < 1 ||
        limits.maxParts < 0 ||
        limits.maxCommitBytes < 1 ||
        limits.maxEnvelopeBytes < 1 ||
        limits.maxPartBytes < 1 ||
        limits.maxTotalPartBytes < 0) {
      throw ArgumentError.value(limits, 'limits', 'contains an invalid bound');
    }
  }

  bool _isOpaqueId(String value) {
    if (value.isEmpty || value.contains('..') || value.contains('\\')) {
      return false;
    }
    try {
      LogicalKeys.checkpointCommit('vault', value);
      return true;
    } on ArgumentError {
      return false;
    }
  }
}

class _CheckpointCandidate {
  const _CheckpointCandidate({
    required this.checkpointId,
    required this.committedAt,
  });

  final String checkpointId;
  final DateTime committedAt;
}
