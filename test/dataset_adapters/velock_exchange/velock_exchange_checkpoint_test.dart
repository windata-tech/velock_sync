import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  for (final missingCollectionsReturn404 in [false, true]) {
    test(
      'restart before owner receipt consumption retains published history boundary ($missingCollectionsReturn404)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'velock-restart-boundary-',
        );
        addTearDown(() => root.delete(recursive: true));
        final file = File('${root.path}/sync.db');
        var database = await SyncStateDatabase.open(file);
        await database.recordOutgoingBatch(
          profileId: 'history-profile',
          batchId: 'batch-2',
          sequence: 2,
          state: 'uploading',
        );
        await database.markOutgoingBatchPublished(
          profileId: 'history-profile',
          batchId: 'batch-2',
          publishedAt: DateTime.utc(2026, 9, 27),
        );
        await database.close();
        database = await SyncStateDatabase.open(file);
        addTearDown(database.close);
        // Fresh adapter and absent owner checkpoint, as when Sync restarts before
        // Velock has opened to consume its Outbox/Receipts publication message.
        final adapter = VelockExchangeDatasetAdapter(
          datasetId: 'dataset-1',
          vaultId: 'vault-1',
          producerDeviceId: 'producer-1',
          displayName: 'Velock',
          exchange: VelockExchangeStore(Directory('${root.path}/exchange')),
        );
        expect(await adapter.prepareCheckpoint(), isNull);
        await expectLater(
          SyncProfileRunner(database).run(
            profileId: 'history-profile',
            vaultId: 'vault-1',
            deviceId: 'consumer-1',
            dataset: adapter,
            remote: InMemoryObjectStore(
              answerNotFoundForMissingCollections: missingCollectionsReturn404,
            ),
            protocol: VaultProtocolDocument(
              vaultId: 'vault-1',
              createdAt: DateTime.utc(2026, 9, 27),
            ),
          ),
          throwsA(isA<Exception>()),
        );
        final run = (await database.latestSyncRun('history-profile'))!;
        expect(run.state, 'failed');
        expect(run.errorCode, 'remote.velock_history_incomplete');
      },
    );
  }

  for (final missingCollectionsReturn404 in [false, true]) {
    test(
      'signed checkpoint cannot replace missing history (collection 404: $missingCollectionsReturn404)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'velock-checkpoint-',
        );
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
        expect(
          imported.disposition,
          CheckpointImportDisposition.alreadyApplied,
        );
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

        // Real regression: the source has no pending outbox but a signed local
        // progress checkpoint. A replacement empty remote is NOT a full backup.
        final database = await SyncStateDatabase.inMemory();
        addTearDown(database.close);
        final remote = InMemoryObjectStore(
          answerNotFoundForMissingCollections: missingCollectionsReturn404,
        );
        final runner = SyncProfileRunner(database);
        Future<void> run() async {
          await runner.run(
            profileId: 'history-profile',
            vaultId: vaultId,
            deviceId: 'consumer-1',
            dataset: adapter,
            remote: remote,
            protocol: VaultProtocolDocument(
              vaultId: vaultId,
              createdAt: DateTime.utc(2026, 9, 19),
            ),
          );
        }

        await expectLater(run(), throwsA(isA<Exception>()));
        final failed = (await database.latestSyncRun('history-profile'))!;
        expect(failed.state, 'failed');
        expect(failed.errorCode, 'remote.velock_history_incomplete');
        expect(
          await remote.stat(
            LogicalKeys.checkpointCommit(vaultId, checkpointId),
          ),
          isNull,
          reason: 'A failed backup must not publish a progress-only checkpoint',
        );

        // A pre-existing progress checkpoint on the remote does not excuse the
        // missing commits either (the previously reproduced bad run did this).
        await remote.put(
          LogicalKeys.checkpointCommit(vaultId, checkpointId),
          Stream.value(commit),
          contentLength: commit.length,
        );
        await expectLater(run(), throwsA(isA<Exception>()));
        expect(
          (await database.latestSyncRun('history-profile'))!.state,
          'failed',
        );

        // This check proves commit-name continuity only; opaque body integrity
        // remains the importer's job, not a claim that these test bytes restore.
        for (var sequence = 1; sequence <= 4; sequence++) {
          await remote.put(
            LogicalKeys.commit(
              vaultId,
              producerId,
              sequence,
              'batch-$sequence',
            ),
            Stream.value([1]),
            contentLength: 1,
          );
        }
        await run();
        expect(
          (await database.latestSyncRun('history-profile'))!.state,
          'completed',
        );
      },
    );
  }
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
