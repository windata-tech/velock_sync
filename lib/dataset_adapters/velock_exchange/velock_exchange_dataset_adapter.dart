import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_checkpoint_publisher.dart';
import 'package:velock_sync/sync_core/engine/sync_garbage_collector.dart';
import 'package:velock_sync/sync_core/model/gc_candidate_manifest.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Bridges opaque, pre-signed Velock App Group packages to Sync Core. It
/// deliberately does not decrypt operations or construct a signed ACK.
class VelockExchangeDatasetAdapter
    implements
        SyncDatasetAdapter,
        OrderedDeferredIncomingBatchAdapter,
        StreamingIncomingBatchAdapter,
        GarbageCollectionCandidateProvider,
        CheckpointPreparingDatasetAdapter,
        CheckpointRecoveringDatasetAdapter {
  VelockExchangeDatasetAdapter({
    required this.datasetId,
    required this.vaultId,
    required this.producerDeviceId,
    required this.displayName,
    required VelockExchangeStore exchange,
    this.expectedProducerPublicKeyId,
    this.expectedExchangeBindingId,
    Uuid? uuid,
  }) : _exchange = exchange,
       _uuid = uuid ?? const Uuid();

  final String datasetId;
  final String vaultId;
  final String producerDeviceId;
  final String displayName;
  final String? expectedProducerPublicKeyId;
  final String? expectedExchangeBindingId;
  final VelockExchangeStore _exchange;

  /// Shared App Group directory that holds Velock's control artifacts.
  Directory get exchangeRoot => _exchange.root;
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
        _claimed ??
        await _exchange.claimNextOutbox(
          leaseId: _uuid.v4(),
          vaultId: vaultId,
          sourceDeviceId: producerDeviceId,
        );
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
        identity.sourceDeviceId != producerDeviceId ||
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
    final retentionFile = File('${claimed.directory.path}/retention.json');
    final retentionManifest = await retentionFile.exists()
        ? ImmutableArtifact.fromBytes(
            Uint8List.fromList(await retentionFile.readAsBytes()),
          )
        : null;
    if (retentionManifest != null) {
      final retentionBytes = await (await retentionManifest.openRead())
          .expand((e) => e)
          .toList();
      if (readyMarker['retentionSha256'] !=
          sha256.convert(retentionBytes).toString()) {
        throw const FormatException(
          'Claimed exchange retention manifest is invalid.',
        );
      }
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
      retentionManifest: retentionManifest,
      retentionManifestKey: retentionManifest == null
          ? null
          : LogicalKeys.retentionManifest(vaultId, identity.batchId),
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
              producerDeviceId,
              sequence,
              batchId,
            ),
            'sequence': sequence,
            'sourceDeviceId': producerDeviceId,
            'status': 'published',
            'vaultId': vaultId,
          }),
        ),
      ),
    );
    await _exchange.removeClaimedOutbox(batchId);
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

  @override
  Future<PreparedCheckpoint?> prepareCheckpoint() async {
    final file = File(
      '${_exchange.root.path}/Control/SyncCheckpoint/'
      '${Uri.encodeComponent(vaultId)}/current.json',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final pointerBytes = await file.readAsBytes();
    if (pointerBytes.isEmpty || pointerBytes.length > 64 * 1024) {
      throw const FormatException('Sync checkpoint pointer is invalid.');
    }
    final decoded = jsonDecode(
      utf8.decode(pointerBytes, allowMalformed: false),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().difference({
          'schemaVersion',
          'vaultId',
          'checkpointId',
          'envelopeBase64',
          'commitBase64',
        }).isNotEmpty ||
        decoded.length != 5 ||
        decoded['schemaVersion'] != 1 ||
        decoded['vaultId'] != vaultId) {
      throw const FormatException('Sync checkpoint pointer is invalid.');
    }
    final checkpointId = _opaqueCheckpointId(decoded['checkpointId']);
    final envelope = _base64Bytes(decoded['envelopeBase64']);
    final commit = _base64Bytes(decoded['commitBase64']);
    final descriptor = await _readTrustedDescriptor();
    await _verifyCheckpoint(
      checkpointId: checkpointId,
      envelope: envelope,
      commit: commit,
      descriptor: descriptor,
      requireSelfCoverage: true,
    );
    return PreparedCheckpoint(
      vaultId: vaultId,
      checkpointId: checkpointId,
      envelope: ImmutableArtifact.fromBytes(envelope),
      parts: const [],
      commit: ImmutableArtifact.fromBytes(commit),
    );
  }

  @override
  Future<CheckpointImportResult> acceptIncomingCheckpoint(
    IncomingCheckpoint checkpoint,
  ) async {
    try {
      if (checkpoint.vaultId != vaultId || checkpoint.parts.isNotEmpty) {
        return const CheckpointImportResult.rejected();
      }
      final descriptor = await _readTrustedDescriptor();
      final covered = await _verifyCheckpoint(
        checkpointId: checkpoint.checkpointId,
        envelope: checkpoint.envelope,
        commit: checkpoint.commit,
        descriptor: descriptor,
        requireSelfCoverage: true,
      );
      return CheckpointImportResult.alreadyApplied(coveredSequences: covered);
    } on Object {
      return const CheckpointImportResult.rejected();
    }
  }

  Future<VelockPairingDescriptor> _readTrustedDescriptor() async {
    final file = File('${_exchange.root.path}/Control/descriptor.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Velock pairing descriptor is unavailable.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Velock pairing descriptor is invalid.');
    }
    final descriptor = VelockPairingDescriptor.parse(bytes);
    if (descriptor.producerId != producerDeviceId ||
        (expectedProducerPublicKeyId != null &&
            descriptor.producerPublicKeyId != expectedProducerPublicKeyId) ||
        (expectedExchangeBindingId != null &&
            descriptor.exchangeBindingId != expectedExchangeBindingId)) {
      throw const FormatException('Velock pairing descriptor does not match.');
    }
    return descriptor;
  }

  Future<Map<String, int>> _verifyCheckpoint({
    required String checkpointId,
    required Uint8List envelope,
    required Uint8List commit,
    required VelockPairingDescriptor descriptor,
    required bool requireSelfCoverage,
  }) async {
    if (envelope.isEmpty ||
        envelope.length > 1024 * 1024 ||
        commit.isEmpty ||
        commit.length > 64 * 1024) {
      throw const FormatException('Sync checkpoint size is invalid.');
    }
    final envelopeJson = jsonDecode(
      utf8.decode(envelope, allowMalformed: false),
    );
    if (envelopeJson is! Map<String, dynamic> ||
        envelopeJson.keys.toSet().difference({
          'schemaVersion',
          'vaultId',
          'producerDeviceId',
          'createdAt',
          'coveredSequences',
          'signatureAlgorithm',
          'keyId',
          'signature',
        }).isNotEmpty ||
        envelopeJson.length != 8 ||
        envelopeJson['schemaVersion'] != 1 ||
        envelopeJson['vaultId'] != vaultId ||
        envelopeJson['producerDeviceId'] != producerDeviceId ||
        envelopeJson['signatureAlgorithm'] != 'Ed25519' ||
        envelopeJson['keyId'] != descriptor.producerPublicKeyId ||
        envelopeJson['createdAt'] is! String) {
      throw const FormatException('Sync checkpoint envelope is invalid.');
    }
    final createdAt = DateTime.tryParse(envelopeJson['createdAt'] as String);
    if (createdAt == null || !createdAt.isUtc) {
      throw const FormatException('Sync checkpoint timestamp is invalid.');
    }
    final coveredJson = envelopeJson['coveredSequences'];
    if (coveredJson is! Map ||
        coveredJson.length != 1 ||
        !requireSelfCoverage) {
      throw const FormatException('Sync checkpoint coverage is invalid.');
    }
    final sequence = coveredJson[producerDeviceId];
    if (sequence is! int || sequence < 1) {
      throw const FormatException('Sync checkpoint coverage is invalid.');
    }
    final signatureValue = envelopeJson['signature'];
    if (signatureValue is! String || signatureValue.isEmpty) {
      throw const FormatException('Sync checkpoint signature is invalid.');
    }
    final payload = Map<String, dynamic>.from(envelopeJson)
      ..remove('signature');
    final canonical = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final valid = await Ed25519().verify(
      canonical,
      signature: Signature(
        _base64Bytes(signatureValue),
        publicKey: descriptor.publicKey,
      ),
    );
    if (!valid) {
      throw const FormatException('Sync checkpoint signature is invalid.');
    }

    final commitJson = jsonDecode(utf8.decode(commit, allowMalformed: false));
    if (commitJson is! Map<String, dynamic> ||
        commitJson.keys.toSet().difference({
          'schemaVersion',
          'checkpointId',
          'vaultId',
          'envelopeSha256',
        }).isNotEmpty ||
        commitJson.length != 4 ||
        commitJson['schemaVersion'] != 1 ||
        commitJson['checkpointId'] != checkpointId ||
        commitJson['vaultId'] != vaultId ||
        commitJson['envelopeSha256'] != sha256.convert(envelope).toString()) {
      throw const FormatException('Sync checkpoint commit is invalid.');
    }
    return {producerDeviceId: sequence};
  }

  String _opaqueCheckpointId(Object? value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value) ||
        value.endsWith('.tmp')) {
      throw const FormatException('Sync checkpoint ID is invalid.');
    }
    return value;
  }

  Uint8List _base64Bytes(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('Sync checkpoint base64 is invalid.');
    }
    try {
      return Uint8List.fromList(
        base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '=')),
      );
    } on FormatException {
      throw const FormatException('Sync checkpoint base64 is invalid.');
    }
  }

  @override
  Future<List<GarbageCollectionCandidate>> garbageCollectionCandidates({
    required String vaultId,
    required GarbageCollectionEvidence evidence,
    required Map<String, PublicKey> trustedDeviceKeys,
  }) async {
    final bytes = await _exchange.readGcCandidateManifest();
    if (bytes == null) return const [];
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GC candidate manifest JSON is invalid.');
    }
    final manifest = GcCandidateManifest.fromJson(decoded);
    if (manifest.vaultId != vaultId) {
      throw const FormatException('GC candidate manifest vault is invalid.');
    }
    final key = trustedDeviceKeys[manifest.producerDeviceId];
    if (key == null) {
      throw const FormatException(
        'GC candidate manifest producer is not trusted.',
      );
    }
    await manifest.verify(key);
    return manifest.candidates;
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
}
