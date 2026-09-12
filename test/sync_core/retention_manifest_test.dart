import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/model/retention_manifest.dart';

void main() {
  test(
    'round-trips a retention manifest and excludes signature from payload',
    () {
      final manifest = RetentionManifest(
        vaultId: 'vault-1',
        trashBatchId: 'batch-1',
        producerDeviceId: 'device-1',
        createdAt: DateTime.utc(2026, 9, 10),
        retainUntil: DateTime.utc(2026, 10, 10),
        blobRefs: const ['blob-1', 'blob-2'],
        partCount: 2,
        partDigests: const ['digest-1', 'digest-2'],
        keyId: 'key-1',
        signature: 'signature-1',
      );

      final decoded = RetentionManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.vaultId, 'vault-1');
      expect(decoded.trashBatchId, 'batch-1');
      expect(decoded.blobRefs, ['blob-1', 'blob-2']);
      expect(decoded.partDigests, ['digest-1', 'digest-2']);
      expect(decoded.signature, 'signature-1');
      expect(decoded.signatureCanonicalJson(), isNot(contains('signature-1')));
    },
  );

  test('rejects a manifest whose part digest count is incomplete', () {
    expect(
      () => RetentionManifest.fromJson({
        'schemaVersion': 1,
        'vaultId': 'vault-1',
        'trashBatchId': 'batch-1',
        'producerDeviceId': 'device-1',
        'createdAt': '2026-09-10T00:00:00.000Z',
        'retainUntil': '2026-10-10T00:00:00.000Z',
        'blobRefs': ['blob-1'],
        'partCount': 2,
        'partDigests': ['digest-1'],
        'signatureAlgorithm': 'Ed25519',
        'keyId': 'key-1',
        'signature': 'signature-1',
      }),
      throwsFormatException,
    );
  });
}
