import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';

/// Owner-signed evidence of full business application. A download, public
/// inventory or staged build receipt cannot create this token. Sync uses only
/// its covered heads; plaintext and private keys never cross the app boundary.
class AppliedVelockSnapshot {
  AppliedVelockSnapshot._(
    this.snapshotId,
    this.consumerId,
    this.coveredSequences,
  );
  final String snapshotId, consumerId;
  final Map<String, int> coveredSequences;
  static Future<AppliedVelockSnapshot> verify({
    required List<int> receipt,
    required VelockSnapshotInventory inventory,
    required String consumerId,
    required PublicKey trustedConsumerKey,
  }) async {
    if (receipt.isEmpty || receipt.length > 16384) {
      throw const FormatException('Snapshot receipt size limit.');
    }
    final m = jsonDecode(utf8.decode(receipt));
    const fields = {
      'kind',
      'version',
      'snapshotId',
      'vaultId',
      'producerId',
      'consumerId',
      'manifestSha256',
      'recordCount',
      'completedAt',
      'signature',
    };
    if (m is! Map<String, dynamic> ||
        m.length != fields.length ||
        !m.keys.toSet().containsAll(fields) ||
        m['kind'] != 'velock-current-state-snapshot-applied' ||
        m['version'] != 2 ||
        m['snapshotId'] != inventory.snapshotId ||
        m['vaultId'] != inventory.vaultId ||
        m['producerId'] != inventory.producerId ||
        m['consumerId'] != consumerId ||
        consumerId == inventory.producerId ||
        m['recordCount'] != inventory.recordCount ||
        m['manifestSha256'] != sha256.convert(inventory.manifest).toString() ||
        m['completedAt'] is! String ||
        DateTime.tryParse(m['completedAt'] as String)?.isUtc != true ||
        m['signature'] is! String) {
      throw const FormatException('Snapshot applied receipt mismatch.');
    }
    final encoded = snapshotJson(m);
    if (encoded.length != receipt.length) {
      throw const FormatException('Noncanonical applied receipt.');
    }
    for (var i = 0; i < encoded.length; i++) {
      if (encoded[i] != receipt[i]) {
        throw const FormatException('Noncanonical applied receipt.');
      }
    }
    final body = Map<String, dynamic>.from(m)..remove('signature');
    final signature = base64Url.decode(m['signature'] as String);
    if (signature.length != 64 ||
        !await Ed25519().verify([
          ...utf8.encode('VelockCurrentStateSnapshotApplied/2\n'),
          ...snapshotJson(body),
        ], signature: Signature(signature, publicKey: trustedConsumerKey))) {
      throw const FormatException('Invalid snapshot application signature.');
    }
    return AppliedVelockSnapshot._(
      inventory.snapshotId,
      consumerId,
      Map.unmodifiable(
        inventory.heads.map((id, head) => MapEntry(id, head.sequence)),
      ),
    );
  }
}
