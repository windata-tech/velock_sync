import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_change_planner.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Turns a completed Selected Folder scan into staged, encrypted V1 artifacts.
/// The caller supplies a durably reserved [OperationsCipherContext].
class SelectedFolderBatchPreparer {
  SelectedFolderBatchPreparer({
    required GenericVaultBlobCipher blobCipher,
    required GenericVaultBatchCompiler compiler,
    required BatchStagingStore staging,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _blobCipher = blobCipher,
       _compiler = compiler,
       _staging = staging,
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final GenericVaultBlobCipher _blobCipher;
  final GenericVaultBatchCompiler _compiler;
  final BatchStagingStore _staging;
  final Uuid _uuid;
  final DateTime Function() _now;

  Future<PreparedOutgoingBatch?> prepare({
    required SelectedFolderChangePlan plan,
    required OperationsCipherContext context,
    required KeyPair signingKey,
    required int scanGeneration,
    required Map<String, VersionVector> baseVersionVectors,
    String? previousBatchId,
    int? previousSequence,
  }) async {
    if (plan.isEmpty) return null;
    if (_blobCipher.keyId != context.keyId) {
      throw ArgumentError('Blob and operations key IDs must match.');
    }
    final operations = <SyncOperation>[];
    final blobs = <PreparedBlob>[];
    for (final change in plan.changes) {
      String? blobId;
      if (change.blobSource != null) {
        blobId = _uuid.v4();
        final plaintextLength = await change.blobSource!.length();
        final staged = await _staging.stage(
          batchId: context.batchId,
          artifactName: 'blobs/$blobId.blob',
          content: _blobCipher.encrypt(
            vaultId: context.vaultId,
            blobId: blobId,
            plaintextLength: plaintextLength,
            plaintext: change.blobSource!.openRead(),
          ),
          contentLength: _blobCipher.encryptedLengthFor(plaintextLength),
        );
        blobs.add(
          PreparedBlob(
            descriptor: BlobDescriptor(
              blobId: blobId,
              cipherSize: staged.length,
              cipherSha256: await _hash(staged),
              chunkSize: _blobCipher.chunkSize,
            ),
            content: staged,
          ),
        );
      }
      operations.add(
        SyncOperation(
          operationId: _uuid.v4(),
          entityId: change.entry.entityId,
          entityKind: 'file',
          type: change.type == SelectedFolderChangeType.delete
              ? SyncOperationType.delete
              : SyncOperationType.upsert,
          versionVector:
              (baseVersionVectors[change.entry.entityId] ??
                      VersionVector(const {}))
                  .incremented(context.sourceDeviceId),
          revisionId: _uuid.v4(),
          protectedPayload: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'entryType': change.entry.type.name,
                'relativePath': change.entry.relativePath,
                'size': change.entry.size,
                'modifiedAt': change.entry.modifiedAt
                    ?.toUtc()
                    .toIso8601String(),
                'deletedAt': change.entry.deletedAt?.toUtc().toIso8601String(),
              }),
            ),
          ),
          blobIds: blobId == null ? const [] : [blobId],
          createdAt: _now().toUtc(),
        ),
      );
    }
    final compiled = await _compiler.compile(
      context: context,
      operations: operations,
      blobs: blobs,
      signingKey: signingKey,
      previousBatchId: previousBatchId,
      previousSequence: previousSequence,
    );
    final operationsArtifact = await _stageArtifact(
      context.batchId,
      'operations.enc',
      compiled.operations,
    );
    final envelopeArtifact = await _stageArtifact(
      context.batchId,
      'envelope.json',
      compiled.envelope,
    );
    final commitArtifact = await _stageArtifact(
      context.batchId,
      'commit.json',
      compiled.commit,
    );
    final batch = PreparedOutgoingBatch(
      vaultId: compiled.vaultId,
      sourceDeviceId: compiled.sourceDeviceId,
      sequence: compiled.sequence,
      batchId: compiled.batchId,
      envelope: envelopeArtifact,
      operations: operationsArtifact,
      commit: commitArtifact,
      blobs: blobs,
    );
    try {
      await _stageManifest(
        batch,
        scanGeneration: scanGeneration,
        entityRevisions: operations
            .map(
              (operation) => StagedEntityRevision(
                entityId: operation.entityId,
                revisionId: operation.revisionId,
                versionVector: operation.versionVector,
                isTombstone: operation.type == SyncOperationType.delete,
              ),
            )
            .toList(growable: false),
      );
      return batch;
    } on Object {
      await _staging.discard(context.batchId);
      rethrow;
    }
  }

  /// Reopens the immutable artifacts from a previously completed local stage.
  /// A missing manifest means the former attempt never became recoverable and
  /// can be discarded and regenerated by the caller. A malformed manifest or
  /// missing listed artifact is an integrity failure and is never regenerated.
  Future<StagedBatchRecovery?> recover(String batchId) async {
    final manifest = await _staging.read(
      batchId: batchId,
      artifactName: 'manifest.json',
    );
    if (manifest == null) return null;
    final bytes = await (await manifest.openRead()).fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('Unsupported staged-batch manifest.');
    }
    final manifestBatchId = value['batchId'];
    if (manifestBatchId != batchId) {
      throw const FormatException('Staged-batch manifest identity mismatch.');
    }
    final vaultId = _requiredString(value, 'vaultId');
    final sourceDeviceId = _requiredString(value, 'sourceDeviceId');
    final sequence = _requiredInt(value, 'sequence');
    final scanGeneration = _requiredInt(value, 'scanGeneration');
    final entityRevisions = _entityRevisions(value);
    final blobValues = value['blobs'];
    if (blobValues is! List) {
      throw const FormatException('Staged-batch blob list is invalid.');
    }
    final blobs = <PreparedBlob>[];
    for (final item in blobValues) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Staged-batch blob is invalid.');
      }
      final blobId = _requiredString(item, 'blobId');
      final cipherSize = _requiredInt(item, 'cipherSize');
      final cipherSha256 = _requiredString(item, 'cipherSha256');
      final chunkSize = _requiredInt(item, 'chunkSize');
      final content = await _requiredArtifact(
        batchId,
        'blobs/$blobId.blob',
        expectedLength: cipherSize,
      );
      blobs.add(
        PreparedBlob(
          descriptor: BlobDescriptor(
            blobId: blobId,
            cipherSize: cipherSize,
            cipherSha256: cipherSha256,
            chunkSize: chunkSize,
          ),
          content: content,
        ),
      );
    }
    return StagedBatchRecovery(
      scanGeneration: scanGeneration,
      entityRevisions: entityRevisions,
      batch: PreparedOutgoingBatch(
        vaultId: vaultId,
        sourceDeviceId: sourceDeviceId,
        sequence: sequence,
        batchId: batchId,
        envelope: await _requiredArtifact(batchId, 'envelope.json'),
        operations: await _requiredArtifact(batchId, 'operations.enc'),
        commit: await _requiredArtifact(batchId, 'commit.json'),
        blobs: List.unmodifiable(blobs),
      ),
    );
  }

  Future<ImmutableArtifact> _stageArtifact(
    String batchId,
    String name,
    ImmutableArtifact artifact,
  ) async => _staging.stage(
    batchId: batchId,
    artifactName: name,
    content: await artifact.openRead(),
    contentLength: artifact.length,
  );

  Future<String> _hash(ImmutableArtifact artifact) async {
    final digest = await sha256.bind(await artifact.openRead()).single;
    return digest.toString();
  }

  Future<void> _stageManifest(
    PreparedOutgoingBatch batch, {
    required int scanGeneration,
    required List<StagedEntityRevision> entityRevisions,
  }) async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'vaultId': batch.vaultId,
          'sourceDeviceId': batch.sourceDeviceId,
          'sequence': batch.sequence,
          'batchId': batch.batchId,
          'scanGeneration': scanGeneration,
          'entityRevisions': entityRevisions
              .map(
                (entity) => {
                  'entityId': entity.entityId,
                  'revisionId': entity.revisionId,
                  'versionVector': entity.versionVector.values,
                  'isTombstone': entity.isTombstone,
                },
              )
              .toList(growable: false),
          'blobs': batch.blobs
              .map(
                (blob) => {
                  'blobId': blob.descriptor.blobId,
                  'cipherSize': blob.descriptor.cipherSize,
                  'cipherSha256': blob.descriptor.cipherSha256,
                  'chunkSize': blob.descriptor.chunkSize,
                },
              )
              .toList(growable: false),
        }),
      ),
    );
    await _staging.stage(
      batchId: batch.batchId,
      artifactName: 'manifest.json',
      content: Stream.value(bytes),
      contentLength: bytes.length,
    );
  }

  Future<ImmutableArtifact> _requiredArtifact(
    String batchId,
    String artifactName, {
    int? expectedLength,
  }) async {
    final artifact = await _staging.read(
      batchId: batchId,
      artifactName: artifactName,
    );
    if (artifact == null ||
        (expectedLength != null && artifact.length != expectedLength)) {
      throw StateError('Recoverable batch is missing $artifactName.');
    }
    return artifact;
  }

  String _requiredString(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Manifest $key is invalid.');
    }
    return field;
  }

  int _requiredInt(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 0) {
      throw FormatException('Manifest $key is invalid.');
    }
    return field;
  }

  List<StagedEntityRevision> _entityRevisions(Map<String, dynamic> value) {
    final raw = value['entityRevisions'];
    if (raw is! List) {
      throw const FormatException('Manifest entity revisions are invalid.');
    }
    return List.unmodifiable(
      raw.map((item) {
        if (item is! Map<String, dynamic> || item['isTombstone'] is! bool) {
          throw const FormatException('Manifest entity revision is invalid.');
        }
        final vector = item['versionVector'];
        if (vector is! Map<String, dynamic>) {
          throw const FormatException('Manifest version vector is invalid.');
        }
        final values = <String, int>{};
        for (final entry in vector.entries) {
          if (entry.key.isEmpty || entry.value is! int || entry.value < 1) {
            throw const FormatException('Manifest version vector is invalid.');
          }
          values[entry.key] = entry.value as int;
        }
        return StagedEntityRevision(
          entityId: _requiredString(item, 'entityId'),
          revisionId: _requiredString(item, 'revisionId'),
          versionVector: VersionVector(values),
          isTombstone: item['isTombstone'] as bool,
        );
      }),
    );
  }
}

class StagedBatchRecovery {
  const StagedBatchRecovery({
    required this.batch,
    required this.scanGeneration,
    required this.entityRevisions,
  });

  final PreparedOutgoingBatch batch;
  final int scanGeneration;
  final List<StagedEntityRevision> entityRevisions;
}

class StagedEntityRevision {
  const StagedEntityRevision({
    required this.entityId,
    required this.revisionId,
    required this.versionVector,
    required this.isTombstone,
  });

  final String entityId;
  final String revisionId;
  final VersionVector versionVector;
  final bool isTombstone;
}
