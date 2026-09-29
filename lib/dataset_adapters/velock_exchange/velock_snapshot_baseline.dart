import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Coverage proof created only after a locally trusted signature AND every
/// remotely stored ciphertext object have been verified. A profile field,
/// progress checkpoint, upload count or manifest alone cannot construct it.
/// Bound to the exact scoped client used for verification, never reusable for
/// another destination. Revalidate on each run; do not serialize this proof.
///
/// The signed manifest and commit are always re-read and re-verified. Reading
/// every part and blob again is the expensive step (a photo backup can be
/// gigabytes, on every resume and background run), so a caller may skip it for
/// the exact inventory it fully verified recently ([skipObjectCheck]).
class VerifiedVelockSnapshotBaseline {
  VerifiedVelockSnapshotBaseline._(this.inventory, this._remote);
  final VelockSnapshotInventory inventory;
  final RemoteObjectStore _remote;

  static Future<VerifiedVelockSnapshotBaseline> verify({
    required RemoteObjectStore remote,
    required String snapshotId,
    required String vaultId,
    required String producerId,
    required String keyId,
    required PublicKey trustedSigningKey,
    RemoteOperationCancellation? cancellation,
    Future<bool> Function(VelockSnapshotInventory inventory)? skipObjectCheck,
    Future<void> Function(VelockSnapshotInventory inventory)? onObjectsVerified,
  }) async {
    for (final id in [snapshotId, vaultId, producerId, keyId]) {
      snapshotIdentifier(id);
    }
    final prefix = 'vaults/$vaultId/current-snapshots/$snapshotId/';
    // A final commit must be present before reading a candidate.
    final commit = await readSnapshotObject(
      remote.read('${prefix}commit.json', cancellation: cancellation),
      4096,
    );
    final manifest = await readSnapshotObject(
      remote.read('${prefix}manifest.json', cancellation: cancellation),
      VelockSnapshotInventory.maxManifestBytes,
    );
    final inventory = await VelockSnapshotInventory.verify(
      manifest: manifest,
      commit: commit,
      snapshotId: snapshotId,
      vaultId: vaultId,
      producerId: producerId,
      keyId: keyId,
      trustedSigningKey: trustedSigningKey,
    );
    if (skipObjectCheck == null || !await skipObjectCheck(inventory)) {
      await const VelockCurrentSnapshotTransport().verifyRemote(
        inventory: inventory,
        remote: remote,
        cancellation: cancellation,
      );
      await onObjectsVerified?.call(inventory);
    }
    return VerifiedVelockSnapshotBaseline._(inventory, remote);
  }

  int coveredThrough({
    required RemoteObjectStore remote,
    required String vaultId,
    required String producerId,
  }) {
    if (!identical(remote, _remote) || vaultId != inventory.vaultId) {
      throw StateError(
        'Snapshot baseline belongs to a different remote scope.',
      );
    }
    return inventory.heads[producerId]?.sequence ?? 0;
  }
}
