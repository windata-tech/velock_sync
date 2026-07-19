import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Bridges opaque, pre-signed Velock App Group packages to Sync Core. It
/// deliberately does not decrypt operations or construct a signed ACK.
class VelockExchangeDatasetAdapter
    implements
        SyncDatasetAdapter,
        DeferredIncomingBatchAdapter,
        StreamingIncomingBatchAdapter {
  VelockExchangeDatasetAdapter({
    required this.datasetId,
    required this.vaultId,
    required this.deviceId,
    required this.displayName,
    required VelockExchangeStore exchange,
    Uuid? uuid,
  }) : _exchange = exchange,
       _uuid = uuid ?? const Uuid();

  final String datasetId;
  final String vaultId;
  final String deviceId;
  final String displayName;
  final VelockExchangeStore _exchange;
  final Uuid _uuid;
  VelockClaimedOutbox? _claimed;

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
    await _exchange.initialize();
    return await _exchange.root.exists()
        ? DatasetAccessState.available
        : DatasetAccessState.unavailable;
  }

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async {
    // A prior process may have died after its atomic claim. Reclaiming only
    // expired leases makes the next sync attempt recoverable without stealing
    // work that is still owned by a live process.
    if (_claimed == null) {
      await _exchange.reclaimExpiredClaims();
    }
    final claimed =
        _claimed ?? await _exchange.claimNextOutbox(leaseId: _uuid.v4());
    if (claimed == null) return null;
    _claimed = claimed;
    final ready = File('${claimed.directory.path}/READY');
    if (!await ready.exists()) {
      throw StateError('Claimed package has no READY marker.');
    }
    final envelope = await _artifact(claimed.directory, 'envelope.json');
    final envelopeBytes = await _read(envelope);
    final readyMarker = jsonDecode(await ready.readAsString());
    if (readyMarker is! Map<String, dynamic> ||
        readyMarker['batchId'] != claimed.batchId ||
        readyMarker['exchangeVersion'] !=
            VelockExchangeV1Contract.exchangeVersion ||
        readyMarker['envelopeSha256'] !=
            sha256.convert(envelopeBytes).toString() ||
        !_isUtcTimestamp(readyMarker['publishedAt'])) {
      throw const FormatException('Claimed exchange READY marker is invalid.');
    }
    final identity = VelockExchangeV1Contract.parseEnvelope(envelopeBytes);
    if (identity.vaultId != vaultId ||
        identity.sourceDeviceId != deviceId ||
        identity.batchId != claimed.batchId) {
      throw const FormatException(
        'Claimed exchange package identity is invalid.',
      );
    }
    final operations = await _artifact(claimed.directory, 'operations.enc');
    if (operations.length != identity.operationsCipherSize ||
        await _sha256(operations) != identity.operationsCipherSha256) {
      throw const FormatException(
        'Claimed exchange operations integrity is invalid.',
      );
    }
    final blobs = <PreparedBlob>[];
    for (final blob in identity.blobs) {
      final artifact = await _artifact(
        claimed.directory,
        'blobs/${blob.blobId}.blob',
      );
      if (artifact.length != blob.cipherSize ||
          await _sha256(artifact) != blob.cipherSha256) {
        throw const FormatException(
          'Claimed exchange blob integrity is invalid.',
        );
      }
      blobs.add(PreparedBlob(descriptor: blob, content: artifact));
    }
    final commit = ImmutableArtifact.fromBytes(
      Uint8List.fromList(utf8.encode(_commit(identity, envelopeBytes))),
    );
    return PreparedOutgoingBatch(
      vaultId: identity.vaultId,
      sourceDeviceId: identity.sourceDeviceId,
      sequence: identity.sequence,
      batchId: identity.batchId,
      envelope: envelope,
      operations: operations,
      commit: commit,
      blobs: blobs,
    );
  }

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {
    final claimed = _claimed;
    if (claimed == null || claimed.batchId != batchId) {
      throw StateError('No matching claimed exchange package.');
    }
    await _exchange.writeOutboxReceipt(
      batchId: batchId,
      receipt: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'batchId': batchId,
            'completedAt': DateTime.now().toUtc().toIso8601String(),
            'protocolVersion': 1,
            'remoteCommitKey': LogicalKeys.commit(
              vaultId,
              deviceId,
              sequence,
              batchId,
            ),
            'sequence': sequence,
            'sourceDeviceId': deviceId,
            'status': 'published',
            'vaultId': vaultId,
          }),
        ),
      ),
    );
    _claimed = null;
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
    await _exchange.publishInboxPackage(
      batchId: batch.batchId,
      artifacts: {
        'envelope.json': ImmutableArtifact.fromBytes(batch.envelope),
        'operations.enc': ImmutableArtifact.fromBytes(batch.operations),
        for (final blob in batch.blobs.entries)
          'blobs/${blob.key}.blob': blob.value,
      },
    );
    return const ImportResult(isApplied: false);
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
      throw const FormatException('Inbox receipt is invalid.');
    }
    final ackPath = receipt['ackArtifactRelativePath'];
    if (ackPath is! String || !ackPath.startsWith('ack/')) {
      throw const FormatException('Inbox receipt has no ACK artifact.');
    }
    return ImportResult(
      acknowledgementArtifact: ImmutableArtifact.fromBytes(
        await _exchange.readInboxArtifact(
          batchId: batch.batchId,
          relativePath: ackPath,
        ),
      ),
    );
  }

  Future<ImmutableArtifact> _artifact(
    Directory root,
    String relativePath,
  ) async {
    final file = File('${root.path}/$relativePath');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Exchange artifact is missing or not a regular file.');
    }
    final length = await file.length();
    return ImmutableArtifact(
      length: length,
      openRead: () async => file.openRead(),
    );
  }

  Future<Uint8List> _read(ImmutableArtifact artifact) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in await artifact.openRead()) {
      buffer.add(chunk);
    }
    return buffer.takeBytes();
  }

  Future<String> _sha256(ImmutableArtifact artifact) async =>
      sha256.convert(await _read(artifact)).toString();

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
}
