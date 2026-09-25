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
