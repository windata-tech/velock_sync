import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_codec.dart';

void main() {
  const context = OperationsCipherContext(
    vaultId: 'vault-1',
    batchId: 'batch-1',
    sourceDeviceId: 'device-1',
    sequence: 1,
    keyId: 'key-1',
  );

  test(
    'decodes authenticated operation metadata without decoding its payload',
    () {
      final decoded = const GenericVaultOperationsCodec().decode(
        context: context,
        plaintext: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'protocolVersion': 1,
              'vaultId': 'vault-1',
              'batchId': 'batch-1',
              'sourceDeviceId': 'device-1',
              'sequence': 1,
              'operations': [
                {
                  'operationId': 'op-1',
                  'entityId': 'entity-1',
                  'entityKind': 'file',
                  'operationType': 'upsert',
                  'revisionId': 'revision-1',
                  'previousRevisionIds': [],
                  'versionVector': {'device-1': 1},
                  'payload': base64UrlEncode(
                    utf8.encode('secret-path'),
                  ).replaceAll('=', ''),
                  'blobRefs': ['blob-1'],
                  'timestamp': '2026-07-15T00:00:00.000Z',
                },
              ],
            }),
          ),
        ),
      );

      expect(decoded.single.entityId, 'entity-1');
      expect(utf8.decode(decoded.single.protectedPayload), 'secret-path');
    },
  );

  test('rejects duplicate operation IDs and mismatched plaintext identity', () {
    final codec = const GenericVaultOperationsCodec();
    final invalid = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocolVersion': 1,
          'vaultId': 'other-vault',
          'batchId': 'batch-1',
          'sourceDeviceId': 'device-1',
          'sequence': 1,
          'operations': [],
        }),
      ),
    );
    expect(
      () => codec.decode(context: context, plaintext: invalid),
      throwsFormatException,
    );
  });
}
