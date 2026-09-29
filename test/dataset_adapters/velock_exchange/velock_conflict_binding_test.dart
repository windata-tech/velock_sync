import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_conflict_control_plane.dart';

void main() {
  final now = DateTime.utc(2026, 9, 19);
  VelockConflictControlRequest request(String binding) =>
      VelockConflictControlRequest(
        requestId: 'request-1',
        challenge: 'challenge-1',
        conflictId: 'conflict-1',
        vaultId: 'vault-1',
        producerId: 'producer-1',
        producerPublicKeyId: 'key-1',
        exchangeBindingId: binding,
        syncAppInstanceId: 'instance-1',
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
      );

  for (final prefix in ['-', '_']) {
    test('conflict request and receipt accept base64url binding $prefix', () {
      final binding = prefix + 'A' * 42;
      expect(
        VelockConflictControlRequest.parse(
          request(binding).encode(),
        ).exchangeBindingId,
        binding,
      );
      final receipt = VelockConflictControlReceipt(
        requestId: 'request-1',
        challenge: 'challenge-1',
        conflictId: 'conflict-1',
        vaultId: 'vault-1',
        producerId: 'producer-1',
        producerPublicKeyId: 'key-1',
        exchangeBindingId: binding,
        syncAppInstanceId: 'instance-1',
        resolutionArtifactId: 'artifact-1',
        resolvedAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        signature: Uint8List(64),
      );
      expect(
        VelockConflictControlReceipt.parse(receipt.encode()).exchangeBindingId,
        binding,
      );
    });
  }
  test('receipt keeps and signs extensions through its artifact', () {
    final receipt = VelockConflictControlReceipt(
      requestId: 'request-1',
      challenge: 'challenge-1',
      conflictId: 'conflict-1',
      vaultId: 'vault-1',
      producerId: 'producer-1',
      producerPublicKeyId: 'key-1',
      exchangeBindingId: 'binding-1',
      syncAppInstanceId: 'instance-1',
      resolutionArtifactId: 'artifact-1',
      resolvedAt: now,
      expiresAt: now.add(const Duration(minutes: 1)),
      signature: Uint8List(64),
    );
    final v1Payload = receipt.signaturePayload();
    final json = jsonDecode(utf8.decode(receipt.encode())) as Map;
    json['laterField'] = {'z': 1, 'a': 2};
    final parsed = VelockConflictControlReceipt.parse(
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
    final reparsed = VelockConflictControlReceipt.fromArtifact(parsed.artifact);
    expect(reparsed.extensions, {
      'laterField': {'a': 2, 'z': 1},
    });
    final payload = utf8.decode(reparsed.signaturePayload());
    expect(
      payload,
      '${utf8.decode(v1Payload).substring(0, v1Payload.length - 1)}'
      ',"laterField":{"a":2,"z":1}}',
    );
    json.remove('resolvedAt');
    expect(
      () => VelockConflictControlReceipt.parse(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      ),
      throwsFormatException,
    );
  });

  test('rejects unsafe binding values and keeps path ID validation strict', () {
    for (final value in [
      '',
      '.',
      '..',
      '../binding',
      '/binding',
      '-short',
      '_short',
      'a b',
      'a' * 129,
    ]) {
      expect(
        () => VelockConflictControlRequest.parse(request(value).encode()),
        throwsFormatException,
      );
    }
    final json = request('binding-1').toJson()..['requestId'] = "-${'A' * 42}";
    expect(
      () => VelockConflictControlRequest.parse(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      ),
      throwsFormatException,
    );
  });
}
