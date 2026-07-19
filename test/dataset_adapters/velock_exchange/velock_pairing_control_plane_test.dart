import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

void main() {
  group('Velock pairing control plane', () {
    late SimpleKeyPair signingKey;
    late String publicKey;
    late DateTime now;
    late VelockPairingDescriptor descriptor;
    late VelockPairingControlRequest request;

    setUp(() async {
      signingKey = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 7));
      publicKey = base64UrlEncode((await signingKey.extractPublicKey()).bytes);
      now = DateTime.utc(2026, 7, 18, 8);
      descriptor = VelockPairingDescriptor.parse(
        _bytes({
          'controlVersion': 1,
          'exchangeBindingId': 'binding-1',
          'exchangeVersion': 1,
          'producerId': 'producer-1',
          'producerPublicKeyId': 'key-1',
          'producerSigningPublicKey': publicKey,
          'protocol': 'velock-sync',
          'protocolVersion': 1,
          'publishedAt': now.toIso8601String(),
          'signatureAlgorithm': 'Ed25519',
        }),
      );
      request = VelockPairingControlRequest(
        requestId: 'request-1',
        challenge: 'challenge-1',
        producerId: descriptor.producerId,
        producerPublicKeyId: descriptor.producerPublicKeyId,
        exchangeBindingId: descriptor.exchangeBindingId,
        syncAppInstanceId: 'sync-instance-1',
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
    });

    test('strictly parses descriptor and rejects schema extension', () {
      expect(descriptor.producerId, 'producer-1');
      final json =
          jsonDecode(utf8.decode(_descriptorBytes(publicKey, now)))
              as Map<String, dynamic>;
      json['unexpected'] = true;
      expect(
        () => VelockPairingDescriptor.parse(_bytes(json)),
        throwsFormatException,
      );
    });

    test(
      'verifies identity-bound response signed by existing Velock key',
      () async {
        final unsigned = _unsignedResponse(publicKey, now);
        final signature = await Ed25519().sign(
          _bytes(unsigned),
          keyPair: signingKey,
        );
        final response = VelockPairingControlResponse.parse(
          _bytes({...unsigned, 'signature': base64UrlEncode(signature.bytes)}),
        );

        expect(
          await response.verify(
            descriptor: descriptor,
            request: request,
            now: () => now.add(const Duration(minutes: 1)),
          ),
          isTrue,
        );

        final tampered = Map<String, Object>.from(unsigned)
          ..['vaultDisplayName'] = 'Other vault';
        final tamperedResponse = VelockPairingControlResponse.parse(
          _bytes({...tampered, 'signature': base64UrlEncode(signature.bytes)}),
        );
        expect(
          await tamperedResponse.verify(
            descriptor: descriptor,
            request: request,
            now: () => now.add(const Duration(minutes: 1)),
          ),
          isFalse,
        );
      },
    );

    test(
      'fails closed for expired response and mismatched challenge',
      () async {
        final unsigned = _unsignedResponse(publicKey, now);
        final signature = await Ed25519().sign(
          _bytes(unsigned),
          keyPair: signingKey,
        );
        final response = VelockPairingControlResponse.parse(
          _bytes({...unsigned, 'signature': base64UrlEncode(signature.bytes)}),
        );

        expect(
          await response.verify(
            descriptor: descriptor,
            request: request,
            now: () => now.add(const Duration(minutes: 5)),
          ),
          isFalse,
        );
        final otherRequest = VelockPairingControlRequest(
          requestId: request.requestId,
          challenge: 'challenge-2',
          producerId: request.producerId,
          producerPublicKeyId: request.producerPublicKeyId,
          exchangeBindingId: request.exchangeBindingId,
          syncAppInstanceId: request.syncAppInstanceId,
          createdAt: request.createdAt,
          expiresAt: request.expiresAt,
        );
        expect(
          await response.verify(
            descriptor: descriptor,
            request: otherRequest,
            now: () => now.add(const Duration(minutes: 1)),
          ),
          isFalse,
        );
      },
    );
  });
}

Uint8List _descriptorBytes(String publicKey, DateTime now) => _bytes({
  'controlVersion': 1,
  'exchangeBindingId': 'binding-1',
  'exchangeVersion': 1,
  'producerId': 'producer-1',
  'producerPublicKeyId': 'key-1',
  'producerSigningPublicKey': publicKey,
  'protocol': 'velock-sync',
  'protocolVersion': 1,
  'publishedAt': now.toIso8601String(),
  'signatureAlgorithm': 'Ed25519',
});

Map<String, Object> _unsignedResponse(String publicKey, DateTime now) => {
  'approvedAt': now.add(const Duration(seconds: 10)).toIso8601String(),
  'challenge': 'challenge-1',
  'deviceDisplayName': 'Pixel',
  'exchangeBindingId': 'binding-1',
  'expiresAt': now.add(const Duration(minutes: 5)).toIso8601String(),
  'producerId': 'producer-1',
  'producerPublicKeyId': 'key-1',
  'producerSigningPublicKey': publicKey,
  'requestId': 'request-1',
  'vaultDisplayName': 'Personal vault',
  'vaultId': 'vault-1',
};

Uint8List _bytes(Map<String, Object?> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
