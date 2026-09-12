import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

class GenericVaultBatchCompiler {
  GenericVaultBatchCompiler({
    required GenericVaultOperationsCipher operationsCipher,
    required GenericVaultBatchEnvelopeSigner envelopeSigner,
    DateTime Function()? now,
  }) : _operationsCipher = operationsCipher,
       _envelopeSigner = envelopeSigner,
       _now = now ?? DateTime.now;

  final GenericVaultOperationsCipher _operationsCipher;
  final GenericVaultBatchEnvelopeSigner _envelopeSigner;
  final DateTime Function() _now;

  /// Compiles fully encrypted/hashed artifacts for a caller-reserved batch.
  /// Blob content must already use the selected protection format (VLSB1 for
  /// Generic Vault); it is verified before becoming part of the envelope.
  Future<PreparedOutgoingBatch> compile({
    required OperationsCipherContext context,
    required List<SyncOperation> operations,
    required List<PreparedBlob> blobs,
    required KeyPair signingKey,
    String? previousBatchId,
    int? previousSequence,
  }) async {
    final blobReferences = <BatchBlobReference>[];
    for (final blob in blobs) {
      final digest = await _sha256(blob.content);
      if (blob.content.length != blob.descriptor.cipherSize ||
          digest != blob.descriptor.cipherSha256) {
        throw StateError(
          'Prepared blob descriptor does not match its content.',
        );
      }
      blobReferences.add(
        BatchBlobReference(
          blobId: blob.descriptor.blobId,
          logicalKey: LogicalKeys.blob(context.vaultId, blob.descriptor.blobId),
          cipherSize: blob.descriptor.cipherSize,
          cipherSha256: digest,
          chunkSize: blob.descriptor.chunkSize,
          protection: blob.descriptor.chunkSize == 0
              ? 'source-opaque'
              : 'vlsb1',
        ),
      );
    }
    final operationsPlaintext = Uint8List.fromList(
      utf8.encode(_operationsJson(context, operations)),
    );
    final operationsEncrypted = await _operationsCipher.encrypt(
      context: context,
      plaintext: operationsPlaintext,
    );
    final draft = GenericVaultBatchEnvelopeDraft(
      vaultId: context.vaultId,
      sourceDeviceId: context.sourceDeviceId,
      sequence: context.sequence,
      batchId: context.batchId,
      keyId: context.keyId,
      createdAt: _now().toUtc(),
      operationsCipherSize: operationsEncrypted.length,
      operationsCipherSha256: sha256.convert(operationsEncrypted).toString(),
      operationCount: operations.length,
      blobs: blobReferences,
      previousBatchId: previousBatchId,
      previousSequence: previousSequence,
    );
    final signed = await _envelopeSigner.sign(
      draft: draft,
      keyPair: signingKey,
    );
    final commit = _envelopeSigner.commitMarker(
      draft: draft,
      envelope: signed.bytes,
      committedAt: _now().toUtc(),
    );
    return PreparedOutgoingBatch(
      vaultId: context.vaultId,
      sourceDeviceId: context.sourceDeviceId,
      sequence: context.sequence,
      batchId: context.batchId,
      envelope: ImmutableArtifact.fromBytes(signed.bytes),
      operations: ImmutableArtifact.fromBytes(operationsEncrypted),
      commit: ImmutableArtifact.fromBytes(commit),
      blobs: blobs,
    );
  }

  String _operationsJson(
    OperationsCipherContext context,
    List<SyncOperation> operations,
  ) => jsonEncode({
    'protocolVersion': 1,
    'vaultId': context.vaultId,
    'batchId': context.batchId,
    'sourceDeviceId': context.sourceDeviceId,
    'sequence': context.sequence,
    'operations': operations
        .map(
          (operation) => {
            'operationId': operation.operationId,
            'entityId': operation.entityId,
            'entityKind': operation.entityKind,
            'operationType': operation.type.name,
            'revisionId': operation.revisionId,
            'previousRevisionIds': operation.previousRevisionId == null
                ? const []
                : [operation.previousRevisionId],
            'versionVector': operation.versionVector.values,
            'payload': base64UrlEncode(
              operation.protectedPayload,
            ).replaceAll('=', ''),
            'blobRefs': operation.blobIds,
            'timestamp': operation.createdAt.toUtc().toIso8601String(),
          },
        )
        .toList(growable: false),
  });

  Future<String> _sha256(ImmutableArtifact artifact) async {
    var length = 0;
    final source = Stream<List<int>>.multi((controller) async {
      try {
        await for (final chunk in await artifact.openRead()) {
          length += chunk.length;
          controller.add(chunk);
        }
        await controller.close();
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
        await controller.close();
      }
    });
    final digest = await sha256.bind(source).single;
    if (length != artifact.length) {
      throw StateError(
        'Artifact stream length does not match its declared length.',
      );
    }
    return digest.toString();
  }
}
