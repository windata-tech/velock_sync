import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

void main() {
  test(
    'prepares and accepts only a locally trusted signed checkpoint',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-checkpoint-');
      addTearDown(() => root.delete(recursive: true));
      final keyPair = await Ed25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      const producerId = 'producer-1';
      const publicKeyId = 'key-1';
      const bindingId = 'binding-1';
      const vaultId = 'vault-1';
      await Directory('${root.path}/Control').create(recursive: true);
      await File('${root.path}/Control/descriptor.json').writeAsString(
        jsonEncode({
          'controlVersion': 1,
          'exchangeBindingId': bindingId,
          'exchangeVersion': 1,
          'producerId': producerId,
          'producerPublicKeyId': publicKeyId,
          'producerSigningPublicKey': base64UrlEncode(publicKey.bytes),
          'protocol': 'velock-sync',
          'protocolVersion': 1,
          'publishedAt': '2026-09-11T00:00:00.000Z',
          'signatureAlgorithm': 'Ed25519',
        }),
      );
      final envelope = await _checkpointEnvelope(
        keyPair: keyPair,
        vaultId: vaultId,
        producerId: producerId,
        publicKeyId: publicKeyId,
        sequence: 4,
      );
      final checkpointId =
          'v1-${sha256.convert(envelope).toString().substring(0, 32)}';
      final commit = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'checkpointId': checkpointId,
            'vaultId': vaultId,
            'envelopeSha256': sha256.convert(envelope).toString(),
          }),
        ),
      );
      final pointer = File(
        '${root.path}/Control/SyncCheckpoint/$vaultId/current.json',
      );
      await pointer.parent.create(recursive: true);
      await pointer.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'vaultId': vaultId,
          'checkpointId': checkpointId,
          'envelopeBase64': base64UrlEncode(envelope),
          'commitBase64': base64UrlEncode(commit),
        }),
      );
      final adapter = VelockExchangeDatasetAdapter(
        datasetId: 'dataset-1',
        vaultId: vaultId,
        producerDeviceId: producerId,
        displayName: 'Velock',
        exchange: VelockExchangeStore(root),
        expectedProducerPublicKeyId: publicKeyId,
        expectedExchangeBindingId: bindingId,
      );

      final prepared = await adapter.prepareCheckpoint();
      expect(prepared, isNotNull);
      expect(prepared!.checkpointId, checkpointId);
      expect(prepared.parts, isEmpty);
      expect(await _read(prepared.envelope), envelope);
      expect(await _read(prepared.commit), commit);

      final imported = await adapter.acceptIncomingCheckpoint(
        IncomingCheckpoint(
          vaultId: vaultId,
          checkpointId: checkpointId,
          commit: commit,
          envelope: envelope,
          parts: const [],
        ),
      );
      expect(imported.disposition, CheckpointImportDisposition.alreadyApplied);
      expect(imported.coveredSequences, {producerId: 4});

      final tampered = Uint8List.fromList(envelope);
      tampered[tampered.length - 2] ^= 1;
      final rejected = await adapter.acceptIncomingCheckpoint(
        IncomingCheckpoint(
          vaultId: vaultId,
          checkpointId: checkpointId,
          commit: commit,
          envelope: tampered,
          parts: const [],
        ),
      );
      expect(rejected.disposition, CheckpointImportDisposition.rejected);
    },
  );
}

Future<Uint8List> _checkpointEnvelope({
  required KeyPair keyPair,
  required String vaultId,
  required String producerId,
  required String publicKeyId,
  required int sequence,
}) async {
  final payload = <String, Object?>{
    'schemaVersion': 1,
    'vaultId': vaultId,
    'producerDeviceId': producerId,
    'createdAt': '2026-09-11T00:00:00.000Z',
    'coveredSequences': {producerId: sequence},
    'signatureAlgorithm': 'Ed25519',
    'keyId': publicKeyId,
  };
  final signature = await Ed25519().sign(
    utf8.encode(jsonEncode(payload)),
    keyPair: keyPair,
  );
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        ...payload,
        'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
      }),
    ),
  );
}

Future<Uint8List> _read(ImmutableArtifact artifact) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in await artifact.openRead()) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
