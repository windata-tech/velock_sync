import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/remote_retention_manifest_service.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test('reads and verifies a signed retention manifest', () async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final createdAt = DateTime.utc(2026, 9, 10);
    final retainUntil = DateTime.utc(2026, 10, 10);
    final payload = <String, Object?>{
      'schemaVersion': 1,
      'vaultId': 'vault-1',
      'trashBatchId': 'batch-1',
      'producerDeviceId': 'device-1',
      'createdAt': createdAt.toIso8601String(),
      'retainUntil': retainUntil.toIso8601String(),
      'blobRefs': ['blob-1'],
      'partCount': 1,
      'partDigests': ['digest-1'],
      'signatureAlgorithm': 'Ed25519',
      'keyId': 'key-1',
    };
    final signature = await Ed25519().sign(
      utf8.encode(jsonEncode(payload)),
      keyPair: keyPair,
    );
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          ...payload,
          'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
        }),
      ),
    );
    final remote = InMemoryObjectStore();
    await remote.put(
      LogicalKeys.retentionManifest('vault-1', 'batch-1'),
      Stream.value(manifest),
      contentLength: manifest.length,
      ifAbsent: true,
    );

    final read = await const RemoteRetentionManifestService().read(
      vaultId: 'vault-1',
      trashBatchId: 'batch-1',
      remote: remote,
      trustedSigningKey: publicKey,
    );

    expect(read, isNotNull);
    expect(read!.blobRefs, ['blob-1']);
    expect(read.referencesBlob('blob-1'), isTrue);
  });

  test('rejects a manifest signed by another key', () async {
    final signer = await Ed25519().newKeyPair();
    final verifier = await Ed25519().newKeyPair();
    final payload = <String, Object?>{
      'schemaVersion': 1,
      'vaultId': 'vault-1',
      'trashBatchId': 'batch-1',
      'producerDeviceId': 'device-1',
      'createdAt': DateTime.utc(2026, 9, 10).toIso8601String(),
      'retainUntil': DateTime.utc(2026, 10, 10).toIso8601String(),
      'blobRefs': <String>[],
      'partCount': 1,
      'partDigests': ['digest-1'],
      'signatureAlgorithm': 'Ed25519',
      'keyId': 'key-1',
    };
    final signature = await Ed25519().sign(
      utf8.encode(jsonEncode(payload)),
      keyPair: signer,
    );
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          ...payload,
          'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
        }),
      ),
    );
    final remote = InMemoryObjectStore();
    await remote.put(
      LogicalKeys.retentionManifest('vault-1', 'batch-1'),
      Stream.value(manifest),
      contentLength: manifest.length,
      ifAbsent: true,
    );

    await expectLater(
      const RemoteRetentionManifestService().read(
        vaultId: 'vault-1',
        trashBatchId: 'batch-1',
        remote: remote,
        trustedSigningKey: await verifier.extractPublicKey(),
      ),
      throwsFormatException,
    );
  });
}
