import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/retention_manifest.dart';

/// Reads and authenticates a producer-signed retention manifest.
class RemoteRetentionManifestService {
  const RemoteRetentionManifestService();

  Future<RetentionManifest?> read({
    required String vaultId,
    required String trashBatchId,
    required RemoteObjectStore remote,
    required PublicKey trustedSigningKey,
  }) async {
    final key = LogicalKeys.retentionManifest(vaultId, trashBatchId);
    final metadata = await remote.stat(key);
    if (metadata == null) return null;
    final bytes = await remote.read(key).expand((chunk) => chunk).toList();
    if (bytes.length != metadata.size) {
      throw const FormatException(
        'Retention manifest size does not match remote metadata.',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Retention manifest JSON is invalid.');
    }
    final manifest = RetentionManifest.fromJson(decoded);
    final signature = _base64(manifest.signature);
    final valid = await Ed25519().verify(
      Uint8List.fromList(utf8.encode(manifest.signatureCanonicalJson())),
      signature: Signature(signature, publicKey: trustedSigningKey),
    );
    if (!valid) {
      throw const FormatException('Retention manifest signature is invalid.');
    }
    if (manifest.vaultId != vaultId || manifest.trashBatchId != trashBatchId) {
      throw const FormatException('Retention manifest identity is invalid.');
    }
    return manifest;
  }

  List<int> _base64(String value) {
    try {
      return base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '='));
    } on FormatException {
      throw const FormatException('Retention manifest signature is invalid.');
    }
  }
}
