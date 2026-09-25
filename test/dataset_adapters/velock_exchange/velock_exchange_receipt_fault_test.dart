import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

const _reference = IncomingBatchReference(
  vaultId: 'vault-1',
  sourceDeviceId: 'remote-peer',
  sequence: 1,
  batchId: 'batch-1',
);
const _ackPath = 'ack/remote-peer-00000000000000000001.ack';
Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Map<String, Object?> _receipt() => {
  'protocolVersion': 1,
  'batchId': 'batch-1',
  'vaultId': 'vault-1',
  'sourceDeviceId': 'remote-peer',
  'sequence': 1,
  'status': 'imported',
  'ackArtifactRelativePath': _ackPath,
};

void main() {
  for (final platform in ['apple', 'android']) {
    group(platform, () {
      late Directory root;
      late VelockExchangeStore store;
      late _InboxChannel channel;
      late SyncDatasetAdapter adapter;
      DeferredIncomingBatchAdapter getDeferred() =>
          adapter as DeferredIncomingBatchAdapter;
      Future<void> receipt(Uint8List value) async {
        if (platform == 'apple') {
          await store.writeInboxReceipt(batchId: 'batch-1', receipt: value);
        } else {
          channel.receipt = value;
        }
      }

      Future<void> ack(List<int> value, {String path = _ackPath}) async {
        if (platform == 'apple') {
          final file = File('${root.path}/Inbox/Ready/batch-1/$path');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(value);
        } else {
          channel.artifacts[path] = Uint8List.fromList(value);
        }
      }

      Future<ImportResult?> reconcile() =>
          getDeferred().reconcileIncomingBatch(_reference);

      setUp(() async {
        root = await Directory.systemTemp.createTemp('exchange-receipt-fault-');
        store = VelockExchangeStore(root);
        channel = _InboxChannel();
        adapter = platform == 'apple'
            ? VelockExchangeDatasetAdapter(
                datasetId: 'dataset-1',
                vaultId: 'vault-1',
                producerDeviceId: 'local-peer',
                displayName: 'test',
                exchange: store,
              )
            : AndroidVelockExchangeDatasetAdapter(
                datasetId: 'dataset-1',
                vaultId: 'vault-1',
                producerDeviceId: 'local-peer',
                displayName: 'test',
                exchange: channel,
              );
      });
      tearDown(() => root.delete(recursive: true));

      test(
        'unconsumed inbox stays unapplied across delivery retries',
        () async {
          final batch = IncomingBatch(
            vaultId: 'vault-1',
            sourceDeviceId: 'remote-peer',
            sequence: 1,
            batchId: 'batch-1',
            envelope: _json({'opaque': true}),
            operations: Uint8List.fromList([2]),
            blobs: const {},
          );
          for (var i = 0; i < 2; i++) {
            final result = await adapter.acceptIncomingBatch(batch);
            expect(result.isApplied, isFalse);
            expect(result.acknowledgementArtifact, isNull);
            expect(await reconcile(), isNull);
          }
          await ack([9]);
          expect(
            await reconcile(),
            isNull,
            reason: 'ACK alone is not a consumption receipt',
          );
          await receipt(_json(_receipt()));
          for (var i = 0; i < 2; i++) {
            final result = await reconcile();
            expect(result!.isApplied, isTrue);
            expect(
              await (await result.acknowledgementArtifact!.openRead())
                  .expand((chunk) => chunk)
                  .toList(),
              [9],
            );
          }
        },
      );

      test('rejects a reference belonging to a different vault', () async {
        await receipt(_json(_receipt()));
        await ack([9]);
        await expectLater(
          getDeferred().reconcileIncomingBatch(
            const IncomingBatchReference(
              vaultId: 'other-vault',
              sourceDeviceId: 'remote-peer',
              sequence: 1,
              batchId: 'batch-1',
            ),
          ),
          throwsFormatException,
        );
      });

      final mutations = <String, Object?>{
        'protocolVersion': 1.0,
        'batchId': 'other-batch',
        'vaultId': 'other-vault',
        'sourceDeviceId': 'other-peer',
        'sequence': 1.0,
        'status': 'pending',
      };
      for (final entry in mutations.entries) {
        test(
          'rejects invalid receipt ${entry.key}; corrected receipt retries',
          () async {
            await ack([9]);
            await receipt(_json(_receipt()..[entry.key] = entry.value));
            await expectLater(reconcile(), throwsFormatException);
            await receipt(_json(_receipt()));
            expect((await reconcile())!.isApplied, isTrue);
          },
        );
      }

      for (final path in [
        'ack/../operations.enc',
        'ack//peer.ack',
        r'ack/..\peer.ack',
        'ack/',
      ]) {
        test('rejects unsafe ACK path $path before reading artifact', () async {
          await receipt(_json(_receipt()..['ackArtifactRelativePath'] = path));
          // Android fake deliberately returns bytes for any supplied key: the
          // adapter must enforce the boundary, not delegate it to the provider.
          channel.artifacts[path] = Uint8List.fromList([9]);
          await expectLater(reconcile(), throwsFormatException);
          expect(channel.reads, 0);
        });
      }

      test('missing ACK is retryable and empty ACK is not applied', () async {
        await receipt(_json(_receipt()));
        await expectLater(reconcile(), throwsStateError);
        await ack([]);
        await expectLater(reconcile(), throwsFormatException);
        await ack([9]);
        expect((await reconcile())!.isApplied, isTrue);
      });

      test(
        'malformed JSON is rejected; legacy receipt without vault remains supported',
        () async {
          await receipt(Uint8List.fromList([123]));
          await expectLater(reconcile(), throwsFormatException);
          await ack([9]);
          await receipt(_json(_receipt()..remove('vaultId')));
          expect((await reconcile())!.isApplied, isTrue);
        },
      );
    });
  }
}

class _InboxChannel implements AndroidExchangeChannel {
  Uint8List? receipt;
  final artifacts = <String, Uint8List>{};
  int reads = 0;

  @override
  Future<Uint8List?> readInboxReceipt(String batchId) async => receipt;
  @override
  Future<Uint8List> readInboxArtifact({
    required String batchId,
    required String relativePath,
  }) async {
    reads++;
    final bytes = artifacts[relativePath];
    if (bytes == null) throw StateError('missing ACK');
    return bytes;
  }

  @override
  Future<void> createInbox(String batchId) async {}
  @override
  Future<void> commitInbox(String batchId) async {}
  @override
  Future<void> writeInboxArtifact({
    required String batchId,
    required String relativePath,
    required ImmutableArtifact artifact,
  }) async {
    await (await artifact.openRead()).drain<void>();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
