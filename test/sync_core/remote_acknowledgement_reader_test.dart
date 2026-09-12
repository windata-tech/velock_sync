import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/remote_acknowledgement_reader.dart';
import 'package:velock_sync/sync_core/model/sync_acknowledgement.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test('reads the highest verified acknowledgement per producer', () async {
    final consumer = await Ed25519().newKeyPair();
    final payload = <String, Object?>{
      'appliedThroughSequence': 7,
      'consumerDeviceId': 'consumer-1',
      'createdAt': DateTime.utc(2026, 9, 10).toIso8601String(),
      'producerDeviceId': 'producer-1',
      'protocolVersion': 1,
      'signatureAlgorithm': 'Ed25519',
      'vaultId': 'vault-1',
    };
    final signature = await Ed25519().sign(
      utf8.encode(jsonEncode(payload)),
      keyPair: consumer,
    );
    final ack = SyncAcknowledgement(
      vaultId: 'vault-1',
      consumerDeviceId: 'consumer-1',
      producerDeviceId: 'producer-1',
      appliedThroughSequence: 7,
      createdAt: DateTime.utc(2026, 9, 10),
      signature: base64UrlEncode(signature.bytes).replaceAll('=', ''),
    );
    final remote = InMemoryObjectStore();
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({...ack.signaturePayload(), 'signature': ack.signature}),
      ),
    );
    await remote.put(
      LogicalKeys.acknowledgement('vault-1', 'consumer-1', 'producer-1', 7),
      Stream.value(bytes),
      contentLength: bytes.length,
      ifAbsent: true,
    );

    final result = await const RemoteAcknowledgementReader().read(
      vaultId: 'vault-1',
      remote: remote,
      trustedDeviceKeys: {'consumer-1': await consumer.extractPublicKey()},
    );

    expect(result['consumer-1']?['producer-1'], 7);
  });
}
