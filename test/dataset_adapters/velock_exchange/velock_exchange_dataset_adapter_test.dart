import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_garbage_collector.dart';

void main() {
  test('uploads only a READY pre-signed opaque outbox package', () async {
    final root = await Directory.systemTemp.createTemp('velock-adapter-');
    addTearDown(() => root.delete(recursive: true));
    final store = VelockExchangeStore(root);
    final package = Directory('${root.path}/Outbox/Ready/batch-1');
    await package.create(recursive: true);
    final envelope = _validEnvelope([1]);
    await File('${package.path}/envelope.json').writeAsBytes(envelope);
    await File('${package.path}/operations.enc').writeAsBytes([1]);
    await File('${package.path}/READY').writeAsString(
      jsonEncode({
        'batchId': 'batch-1',
        'envelopeSha256': sha256.convert(envelope).toString(),
        'exchangeVersion': VelockExchangeV1Contract.exchangeVersion,
        'publishedAt': '2026-07-15T00:00:00.000Z',
      }),
    );
    final adapter = VelockExchangeDatasetAdapter(
      datasetId: 'velock-1',
      vaultId: 'vault-1',
      producerDeviceId: 'device-1',
      displayName: 'Velock',
      exchange: store,
    );

    final batch = await adapter.prepareNextBatch(
      cursor: ExportCursor.empty,
      limits: const BatchLimits(),
    );
    await adapter.acknowledgePublishedBatch(batchId: 'batch-1', sequence: 1);

    expect(batch!.sourceDeviceId, 'device-1');
    expect(
      await File('${root.path}/Outbox/Receipts/batch-1.json').exists(),
      isTrue,
    );
    expect(
      await Directory('${root.path}/Outbox/Claimed/batch-1').exists(),
      isFalse,
    );
  });

  test(
    'rejects a READY package whose operations do not match its envelope',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-adapter-');
      addTearDown(() => root.delete(recursive: true));
      final store = VelockExchangeStore(root);
      final package = Directory('${root.path}/Outbox/Ready/batch-1');
      await package.create(recursive: true);
      final envelope = _validEnvelope([1]);
      await File('${package.path}/envelope.json').writeAsBytes(envelope);
      await File('${package.path}/operations.enc').writeAsBytes([2]);
      await File('${package.path}/READY').writeAsString(
        jsonEncode({
          'batchId': 'batch-1',
          'envelopeSha256': sha256.convert(envelope).toString(),
          'exchangeVersion': VelockExchangeV1Contract.exchangeVersion,
          'publishedAt': '2026-07-15T00:00:00.000Z',
        }),
      );
      final adapter = VelockExchangeDatasetAdapter(
        datasetId: 'velock-1',
        vaultId: 'vault-1',
        producerDeviceId: 'device-1',
        displayName: 'Velock',
        exchange: store,
      );

      await expectLater(
        adapter.prepareNextBatch(
          cursor: ExportCursor.empty,
          limits: const BatchLimits(),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'reclaims an expired outbox lease after a previous process crash',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-adapter-');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime.utc(2026, 7, 15, 1);
      final store = VelockExchangeStore(
        root,
        now: () => now,
        leaseDuration: const Duration(minutes: 1),
      );
      final package = Directory('${root.path}/Outbox/Ready/batch-1');
      await package.create(recursive: true);
      final envelope = _validEnvelope([1]);
      await File('${package.path}/envelope.json').writeAsBytes(envelope);
      await File('${package.path}/operations.enc').writeAsBytes([1]);
      await File('${package.path}/READY').writeAsString(
        jsonEncode({
          'batchId': 'batch-1',
          'envelopeSha256': sha256.convert(envelope).toString(),
          'exchangeVersion': VelockExchangeV1Contract.exchangeVersion,
          'publishedAt': '2026-07-15T00:00:00.000Z',
        }),
      );
      await store.claimNextOutbox(
        leaseId: 'crashed-process',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
      );
      now = now.add(const Duration(minutes: 2));
      final adapter = VelockExchangeDatasetAdapter(
        datasetId: 'velock-1',
        vaultId: 'vault-1',
        producerDeviceId: 'device-1',
        displayName: 'Velock',
        exchange: store,
      );

      final batch = await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: const BatchLimits(),
      );

      expect(batch!.batchId, 'batch-1');
    },
  );

  test('waits for a peer-created inbox ACK receipt', () async {
    final root = await Directory.systemTemp.createTemp('velock-adapter-');
    addTearDown(() => root.delete(recursive: true));
    final store = VelockExchangeStore(root);
    final adapter = VelockExchangeDatasetAdapter(
      datasetId: 'velock-1',
      vaultId: 'vault-1',
      producerDeviceId: 'producer-1',
      displayName: 'Velock',
      exchange: store,
    );
    await adapter.acceptIncomingBatch(
      IncomingBatch(
        vaultId: 'vault-1',
        sourceDeviceId: 'producer-1',
        sequence: 1,
        batchId: 'batch-1',
        envelope: Uint8List.fromList([1]),
        operations: Uint8List.fromList([2]),
        blobs: const {},
      ),
    );
    final ack = File(
      '${root.path}/Inbox/Ready/batch-1/ack/producer-1-00000000000000000001.ack',
    );
    await ack.parent.create(recursive: true);
    await ack.writeAsBytes([9]);
    await store.writeInboxReceipt(
      batchId: 'batch-1',
      receipt: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': 1,
            'batchId': 'batch-1',
            'sourceDeviceId': 'producer-1',
            'sequence': 1,
            'status': 'imported',
            'ackArtifactRelativePath':
                'ack/producer-1-00000000000000000001.ack',
          }),
        ),
      ),
    );

    final result = await adapter.reconcileIncomingBatch(
      const IncomingBatchReference(
        vaultId: 'vault-1',
        sourceDeviceId: 'producer-1',
        sequence: 1,
        batchId: 'batch-1',
      ),
    );

    expect(result!.isApplied, isTrue);
    expect(
      await _read(result.acknowledgementArtifact!),
      Uint8List.fromList([9]),
    );
  });

  test(
    'verifies a signed GC candidate manifest before returning blobs',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-adapter-');
      addTearDown(() => root.delete(recursive: true));
      final store = VelockExchangeStore(root);
      final keyPair = await Ed25519().newKeyPair();
      final payload = <String, Object?>{
        'schemaVersion': 1,
        'vaultId': 'vault-1',
        'producerDeviceId': 'device-1',
        'generatedAt': '2026-09-11T00:00:00.000Z',
        'candidates': [
          {
            'candidateId': 'batch-1:blob:blob-1',
            'logicalKeys': ['velock-sync/v1/vault-1/blobs/bl/blob-1.blob'],
            'producerDeviceId': 'device-1',
            'sequence': 7,
            'tombstoneAt': '2026-06-01T00:00:00.000Z',
            'retentionHoldUntil': '2026-07-01T00:00:00.000Z',
            'retentionManifestKey':
                'velock-sync/v1/vault-1/retention/exchange-batch-1.json',
            'isReferencedByActiveRevision': false,
            'isReferencedByCheckpoint': false,
            'isReferencedByRetentionHold': false,
          },
        ],
        'signatureAlgorithm': 'Ed25519',
        'keyId': 'key-1',
      };
      final signature = await Ed25519().sign(
        utf8.encode(jsonEncode(payload)),
        keyPair: keyPair,
      );
      await File('${root.path}/gc-candidates.json').writeAsBytes(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              ...payload,
              'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
            }),
          ),
        ),
      );
      final adapter = VelockExchangeDatasetAdapter(
        datasetId: 'velock-1',
        vaultId: 'vault-1',
        producerDeviceId: 'device-1',
        displayName: 'Velock',
        exchange: store,
      );
      final candidates = await adapter.garbageCollectionCandidates(
        vaultId: 'vault-1',
        evidence: GarbageCollectionEvidence(
          checkpointId: 'checkpoint-1',
          checkpointCoveredSequences: const {'device-1': 7},
          activeDeviceIds: const {'device-1'},
          acknowledgedSequences: const {
            'device-1': {'device-1': 7},
          },
          tombstoneRetentionCutoff: DateTime.utc(2026, 7, 1),
        ),
        trustedDeviceKeys: {'device-1': await keyPair.extractPublicKey()},
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.sequence, 7);
      expect(
        candidates.single.retentionManifestKey,
        'velock-sync/v1/vault-1/retention/exchange-batch-1.json',
      );
      expect(candidates.single.logicalKeys, [
        'velock-sync/v1/vault-1/blobs/bl/blob-1.blob',
      ]);
    },
  );
}

List<int> _validEnvelope(List<int> operations) => utf8.encode(
  jsonEncode({
    'batchId': 'batch-1',
    'batchKind': 'incremental',
    'blobs': [],
    'createdAt': '2026-07-15T00:00:00.000Z',
    'keyId': 'key-1',
    'operations': {
      'cipherSha256': sha256.convert(operations).toString(),
      'cipherSize': operations.length,
      'compression': 'none',
      'logicalName': 'operations.enc',
      'operationCount': 1,
    },
    'previousBatchId': null,
    'previousSequence': null,
    'protocol': 'velock-sync',
    'protocolVersion': 1,
    'sequence': 1,
    'signature': 'fixture-signature',
    'signatureAlgorithm': 'Ed25519',
    'sourceDeviceId': 'device-1',
    'vaultId': 'vault-1',
  }),
);

Future<Uint8List> _read(ImmutableArtifact artifact) async {
  final result = BytesBuilder(copy: false);
  await for (final bytes in await artifact.openRead()) {
    result.add(bytes);
  }
  return result.takeBytes();
}
