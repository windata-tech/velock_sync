import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Android counterpart of the Apple App Group adapter. It communicates only
/// through Velock's signature-protected ContentProvider via [AndroidExchangeChannel].
class AndroidVelockExchangeDatasetAdapter
    implements
        SyncDatasetAdapter,
        DeferredIncomingBatchAdapter,
        StreamingIncomingBatchAdapter {
  AndroidVelockExchangeDatasetAdapter({
    required this.datasetId,
    required this.vaultId,
    required this.producerDeviceId,
    required this.displayName,
    required AndroidExchangeChannel exchange,
    Uuid? uuid,
  }) : _exchange = exchange,
       _uuid = uuid ?? const Uuid();

  final String datasetId;
  final String vaultId;
  final String producerDeviceId;
  final String displayName;
  final AndroidExchangeChannel _exchange;
  final Uuid _uuid;
  String? _claimedBatchId;

  @override
  Future<DatasetDescriptor> describe() async => DatasetDescriptor(
    datasetId: datasetId,
    vaultId: vaultId,
    kind: DatasetKind.velockManaged,
    displayName: displayName,
    accessState: await checkAccess(),
    encryptionMode: EncryptionMode.velockManaged,
  );

  @override
  Future<DatasetAccessState> checkAccess() async {
    try {
      await _exchange.readyOutboxIds();
      return DatasetAccessState.available;
    } on Object {
      return DatasetAccessState.unavailable;
    }
  }

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async {
    var batchId = _claimedBatchId;
    if (batchId == null) {
      for (final candidate in await _exchange.readyOutboxIds()) {
        if (await _exchange.claimOutbox(
          batchId: candidate,
          leaseId: _uuid.v4(),
        )) {
          batchId = candidate;
          _claimedBatchId = candidate;
          break;
        }
      }
    }
    if (batchId == null) return null;
    final envelope = await _exchange.stageOutboxArtifact(
      batchId: batchId,
      relativePath: 'envelope.json',
    );
    final envelopeBytes = await File(envelope.path).readAsBytes();
    final ready = await _exchange.stageOutboxArtifact(
      batchId: batchId,
      relativePath: 'READY',
    );
    final marker = jsonDecode(
      utf8.decode(await File(ready.path).readAsBytes()),
    );
    if (marker is! Map<String, dynamic> ||
        marker['batchId'] != batchId ||
        marker['exchangeVersion'] != VelockExchangeV1Contract.exchangeVersion ||
        marker['envelopeSha256'] != sha256.convert(envelopeBytes).toString() ||
        !_isUtcTimestamp(marker['publishedAt'])) {
      throw const FormatException(
        'Claimed Android exchange READY marker is invalid.',
      );
    }
    final identity = VelockExchangeV1Contract.parseEnvelope(envelopeBytes);
    if (identity.vaultId != vaultId ||
        identity.sourceDeviceId != producerDeviceId ||
        identity.batchId != batchId) {
      throw const FormatException(
        'Claimed Android exchange identity is invalid.',
      );
    }
    final operations = await _exchange.stageOutboxArtifact(
      batchId: batchId,
      relativePath: 'operations.enc',
    );
    if (operations.length != identity.operationsCipherSize ||
        await _sha256File(operations.path) != identity.operationsCipherSha256) {
      throw const FormatException(
        'Android exchange operations integrity is invalid.',
      );
    }
    final blobs = <PreparedBlob>[];
    for (final blob in identity.blobs) {
      final artifact = await _exchange.stageOutboxArtifact(
        batchId: batchId,
        relativePath: 'blobs/${blob.blobId}.blob',
      );
      if (artifact.length != blob.cipherSize ||
          await _sha256File(artifact.path) != blob.cipherSha256) {
        throw const FormatException(
          'Android exchange blob integrity is invalid.',
        );
      }
      blobs.add(
        PreparedBlob(descriptor: blob, content: _privateArtifact(artifact)),
      );
    }
    return PreparedOutgoingBatch(
      vaultId: identity.vaultId,
      sourceDeviceId: identity.sourceDeviceId,
      sequence: identity.sequence,
      batchId: identity.batchId,
      envelope: _privateArtifact(envelope),
      operations: _privateArtifact(operations),
      commit: ImmutableArtifact.fromBytes(
        Uint8List.fromList(utf8.encode(_commit(identity, envelopeBytes))),
      ),
      blobs: blobs,
    );
  }

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {
    if (_claimedBatchId != batchId) {
      throw StateError('No matching Android exchange claim.');
    }
    await _exchange.writeOutboxReceipt(
      batchId: batchId,
      receipt: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': 1,
            'batchId': batchId,
            'vaultId': vaultId,
            'sourceDeviceId': producerDeviceId,
            'sequence': sequence,
            'remoteCommitKey': LogicalKeys.commit(
              vaultId,
              producerDeviceId,
              sequence,
              batchId,
            ),
            'completedAt': DateTime.now().toUtc().toIso8601String(),
            'status': 'published',
          }),
        ),
      ),
    );
    await _exchange.releaseStagedOutbox(batchId);
    _claimedBatchId = null;
  }

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    return acceptIncomingArtifactBatch(
      IncomingArtifactBatch(
        vaultId: batch.vaultId,
        sourceDeviceId: batch.sourceDeviceId,
        sequence: batch.sequence,
        batchId: batch.batchId,
        envelope: batch.envelope,
        operations: batch.operations,
        blobs: {
          for (final blob in batch.blobs.entries)
            blob.key: ImmutableArtifact.fromBytes(blob.value),
        },
      ),
    );
  }

  @override
  Future<ImportResult> acceptIncomingArtifactBatch(
    IncomingArtifactBatch batch,
  ) async {
    if (batch.vaultId != vaultId) {
      throw const FormatException('Vault mismatch.');
    }
    await _exchange.createInbox(batch.batchId);
    try {
      await _exchange.writeInboxArtifact(
        batchId: batch.batchId,
        relativePath: 'envelope.json',
        artifact: ImmutableArtifact.fromBytes(batch.envelope),
      );
      await _exchange.writeInboxArtifact(
        batchId: batch.batchId,
        relativePath: 'operations.enc',
        artifact: ImmutableArtifact.fromBytes(batch.operations),
      );
      for (final entry in batch.blobs.entries) {
        await _exchange.writeInboxArtifact(
          batchId: batch.batchId,
          relativePath: 'blobs/${entry.key}.blob',
          artifact: entry.value,
        );
      }
      await _exchange.commitInbox(batch.batchId);
      return const ImportResult(isApplied: false);
    } on Object {
      // The provider retains staging for trusted Velock to inspect/retry; no
      // partial package is ever exposed in Inbox/Ready.
      rethrow;
    }
  }

  @override
  Future<ImportResult?> reconcileIncomingBatch(
    IncomingBatchReference batch,
  ) async {
    final bytes = await _exchange.readInboxReceipt(batch.batchId);
    if (bytes == null) return null;
    final receipt = jsonDecode(utf8.decode(bytes));
    if (receipt is! Map<String, dynamic> ||
        receipt['protocolVersion'] != 1 ||
        receipt['batchId'] != batch.batchId ||
        receipt['sourceDeviceId'] != batch.sourceDeviceId ||
        receipt['sequence'] != batch.sequence ||
        receipt['status'] != 'imported') {
      throw const FormatException('Android inbox receipt is invalid.');
    }
    final ack = receipt['ackArtifactRelativePath'];
    if (ack is! String || !ack.startsWith('ack/')) {
      throw const FormatException('Android inbox receipt has no ACK artifact.');
    }
    return ImportResult(
      acknowledgementArtifact: ImmutableArtifact.fromBytes(
        await _exchange.readInboxArtifact(
          batchId: batch.batchId,
          relativePath: ack,
        ),
      ),
    );
  }

  String _commit(VelockExchangeEnvelopeMetadata value, Uint8List envelope) =>
      jsonEncode({
        'batchId': value.batchId,
        'committedAt': DateTime.now().toUtc().toIso8601String(),
        'envelopeSha256': sha256.convert(envelope).toString(),
        'sequence': value.sequence,
        'sourceDeviceId': value.sourceDeviceId,
        'vaultId': value.vaultId,
      });

  bool _isUtcTimestamp(Object? value) {
    if (value is! String || value.isEmpty) return false;
    try {
      return DateTime.parse(value).isUtc;
    } on FormatException {
      return false;
    }
  }

  ImmutableArtifact _privateArtifact(AndroidExchangeArtifact artifact) =>
      ImmutableArtifact(
        length: artifact.length,
        openRead: () async => File(artifact.path).openRead(),
      );

  Future<String> _sha256File(String path) async =>
      (await sha256.bind(File(path).openRead()).single).toString();
}
