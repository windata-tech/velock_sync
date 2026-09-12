import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/remote_acknowledgement_reader.dart';
import 'package:velock_sync/sync_core/engine/sync_garbage_collector.dart';

class GarbageCollectionEvidenceBuilder {
  const GarbageCollectionEvidenceBuilder({
    RemoteAcknowledgementReader acknowledgementReader =
        const RemoteAcknowledgementReader(),
    DateTime Function()? now,
  }) : _acknowledgementReader = acknowledgementReader,
       _now = now ?? DateTime.now;

  final RemoteAcknowledgementReader _acknowledgementReader;
  final DateTime Function() _now;

  Future<GarbageCollectionEvidence> build({
    required String vaultId,
    required String checkpointId,
    required Map<String, int> checkpointCoveredSequences,
    required RemoteObjectStore remote,
    required Map<String, PublicKey> trustedDeviceKeys,
    Duration retention = const Duration(days: 30),
    Duration safetyBuffer = const Duration(days: 7),
  }) async {
    if (trustedDeviceKeys.isEmpty) {
      throw ArgumentError('trustedDeviceKeys must not be empty.');
    }
    final acknowledged = await _acknowledgementReader.read(
      vaultId: vaultId,
      remote: remote,
      trustedDeviceKeys: trustedDeviceKeys,
    );
    for (final deviceId in trustedDeviceKeys.keys) {
      acknowledged.putIfAbsent(deviceId, () => <String, int>{});
    }
    return GarbageCollectionEvidence(
      checkpointId: checkpointId,
      checkpointCoveredSequences: checkpointCoveredSequences,
      activeDeviceIds: trustedDeviceKeys.keys.toSet(),
      acknowledgedSequences: acknowledged,
      tombstoneRetentionCutoff: _now().toUtc().subtract(
        retention + safetyBuffer,
      ),
    );
  }
}
