import 'dart:convert';
import 'dart:typed_data';

import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Strictly decodes the authenticated plaintext carried by VLSO operations.
/// It deliberately leaves [SyncOperation.protectedPayload] opaque: dataset
/// adapters decide how their private paths and metadata are interpreted.
class GenericVaultOperationsCodec {
  const GenericVaultOperationsCodec();

  List<SyncOperation> decode({
    required OperationsCipherContext context,
    required Uint8List plaintext,
  }) {
    final decoded = jsonDecode(utf8.decode(plaintext, allowMalformed: false));
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != 1 ||
        decoded['vaultId'] != context.vaultId ||
        decoded['batchId'] != context.batchId ||
        decoded['sourceDeviceId'] != context.sourceDeviceId ||
        decoded['sequence'] != context.sequence) {
      throw const FormatException('Operations plaintext identity is invalid.');
    }
    final operations = decoded['operations'];
    if (operations is! List) {
      throw const FormatException('Operations list is invalid.');
    }
    final seenOperationIds = <String>{};
    return List.unmodifiable(
      operations.map((value) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Operation is invalid.');
        }
        final operationId = _string(value, 'operationId');
        if (!seenOperationIds.add(operationId)) {
          throw const FormatException('Duplicate operation ID.');
        }
        final vectorValue = value['versionVector'];
        if (vectorValue is! Map<String, dynamic>) {
          throw const FormatException('Operation version vector is invalid.');
        }
        final vector = <String, int>{};
        for (final entry in vectorValue.entries) {
          if (entry.key.isEmpty || entry.value is! int || entry.value < 1) {
            throw const FormatException('Operation version vector is invalid.');
          }
          vector[entry.key] = entry.value as int;
        }
        final blobValues = value['blobRefs'];
        if (blobValues is! List || blobValues.any((item) => item is! String)) {
          throw const FormatException('Operation blob IDs are invalid.');
        }
        final previousRevisionIds = value['previousRevisionIds'];
        if (previousRevisionIds is! List ||
            previousRevisionIds.length > 1 ||
            previousRevisionIds.any((item) => item is! String)) {
          throw const FormatException(
            'Operation previous revision is invalid.',
          );
        }
        try {
          return SyncOperation(
            operationId: operationId,
            entityId: _string(value, 'entityId'),
            entityKind: _string(value, 'entityKind'),
            type: SyncOperationType.values.byName(
              _string(value, 'operationType'),
            ),
            versionVector: VersionVector(vector),
            revisionId: _string(value, 'revisionId'),
            previousRevisionId: previousRevisionIds.isEmpty
                ? null
                : previousRevisionIds.single as String,
            protectedPayload: _base64(_string(value, 'payload')),
            blobIds: List.unmodifiable(blobValues.cast<String>()),
            createdAt: DateTime.parse(_string(value, 'timestamp')).toUtc(),
          );
        } on FormatException {
          rethrow;
        } on Object {
          throw const FormatException('Operation fields are invalid.');
        }
      }),
    );
  }

  String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Operation $key is invalid.');
    }
    return field;
  }

  Uint8List _base64(String value) {
    try {
      final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
      return Uint8List.fromList(base64Url.decode(padded));
    } on FormatException {
      throw const FormatException('Operation protected payload is invalid.');
    }
  }
}
