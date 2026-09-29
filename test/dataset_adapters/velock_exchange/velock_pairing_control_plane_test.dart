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

    for (final prefix in ['-', '_']) {
      test(
        'accepts a SHA-256 base64url binding beginning with $prefix',
        () async {
          final binding = prefix + List.filled(42, 'A').join();
          final descriptorJson =
              jsonDecode(utf8.decode(_descriptorBytes(publicKey, now)))
                  as Map<String, dynamic>;
          descriptorJson['exchangeBindingId'] = binding;
          final boundDescriptor = VelockPairingDescriptor.parse(
            _bytes(descriptorJson),
          );
          final boundRequest = VelockPairingControlRequest(
            requestId: request.requestId,
            challenge: request.challenge,
            producerId: request.producerId,
            producerPublicKeyId: request.producerPublicKeyId,
            exchangeBindingId: binding,
            syncAppInstanceId: request.syncAppInstanceId,
            createdAt: now,
            expiresAt: request.expiresAt,
          );
          expect(boundRequest.toJson()['exchangeBindingId'], binding);
          final unsigned = _unsignedResponse(publicKey, now)
            ..['exchangeBindingId'] = binding;
          final signature = await Ed25519().sign(
            _bytes(unsigned),
            keyPair: signingKey,
          );
          final response = VelockPairingControlResponse.parse(
            _bytes({
              ...unsigned,
              'signature': base64UrlEncode(signature.bytes),
            }),
          );
          expect(
            await response.verify(
              descriptor: boundDescriptor,
              request: boundRequest,
              now: () => now.add(const Duration(minutes: 1)),
            ),
            isTrue,
          );
        },
      );
    }

    test('still rejects unsafe binding and path identifiers', () {
      for (final invalid in [
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
        final json =
            jsonDecode(utf8.decode(_descriptorBytes(publicKey, now)))
                as Map<String, dynamic>;
        json['exchangeBindingId'] = invalid;
        expect(
          () => VelockPairingDescriptor.parse(_bytes(json)),
          throwsFormatException,
        );
      }
      final json =
          jsonDecode(utf8.decode(_descriptorBytes(publicKey, now)))
              as Map<String, dynamic>;
      json['producerId'] = "-${'A' * 42}";
      expect(
        () => VelockPairingDescriptor.parse(_bytes(json)),
        throwsFormatException,
      );
    });

    test('descriptor ignores extensions but requires every v1 field', () {
      expect(descriptor.producerId, 'producer-1');
      final json =
          jsonDecode(utf8.decode(_descriptorBytes(publicKey, now)))
              as Map<String, dynamic>;
      json['laterField'] = true;
      expect(
        VelockPairingDescriptor.parse(_bytes(json)).producerId,
        'producer-1',
      );
      json.remove('publishedAt');
      expect(
        () => VelockPairingDescriptor.parse(_bytes(json)),
        throwsFormatException,
      );
    });

    test('response extensions are signed after the v1 fields', () async {
      final unsigned = <String, Object?>{
        ..._unsignedResponse(publicKey, now),
        'laterField': {'z': 1, 'a': 2},
      };
      final ordered = {
        ..._unsignedResponse(publicKey, now),
        'laterField': {'a': 2, 'z': 1},
      };
      final signature = await Ed25519().sign(
        _bytes(ordered),
        keyPair: signingKey,
      );
      final signed = {
        ...unsigned,
        'signature': base64UrlEncode(signature.bytes),
      };
      final response = VelockPairingControlResponse.parse(_bytes(signed));
      expect(response.signaturePayload(), _bytes(ordered));
      expect(
        await response.verify(
          descriptor: descriptor,
          request: request,
          now: () => now.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
      final tampered = VelockPairingControlResponse.parse(
        _bytes({
          ...signed,
          'laterField': {'a': 3, 'z': 1},
        }),
      );
      expect(
        await tampered.verify(
          descriptor: descriptor,
          request: request,
          now: () => now.add(const Duration(minutes: 1)),
        ),
        isFalse,
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

    test('accepts a signed historical producer allow-list', () async {
      final unsigned = _unsignedResponse(publicKey, now)
        ..['trustedProducerIds'] = ['previous-iphone', 'producer-1'];
      final signature = await Ed25519().sign(
        _bytes(unsigned),
        keyPair: signingKey,
      );
      final response = VelockPairingControlResponse.parse(
        _bytes({...unsigned, 'signature': base64UrlEncode(signature.bytes)}),
      );
      expect(response.trustedProducerIds, ['previous-iphone', 'producer-1']);
      expect(
        await response.verify(
          descriptor: descriptor,
          request: request,
          now: () => now.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });

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

    test('parses and verifies a signed device revocation', () async {
      final revokedAt = now.add(const Duration(hours: 1));
      final unsigned = {
        'deviceId': 'sync-instance-1',
        'revokedAt': revokedAt.toIso8601String(),
      };
      final signature = await Ed25519().sign(
        _bytes(unsigned),
        keyPair: signingKey,
      );
      final revocation = VelockPairingRevocation.parse(
        _bytes({
          ...unsigned,
          'signatureAlgorithm': 'Ed25519',
          'signature': base64UrlEncode(signature.bytes),
        }),
      );

      expect(revocation.deviceId, 'sync-instance-1');
      expect(await revocation.verify(descriptor: descriptor), isTrue);

      final forged = VelockPairingRevocation.parse(
        _bytes({
          ...unsigned,
          'signatureAlgorithm': 'Ed25519',
          'signature': base64UrlEncode(Uint8List(64)),
        }),
      );
      expect(await forged.verify(descriptor: descriptor), isFalse);

      final extendedPayload = {...unsigned, 'reason': 'lost'};
      final extendedSignature = await Ed25519().sign(
        _bytes(extendedPayload),
        keyPair: signingKey,
      );
      final extended = {
        ...extendedPayload,
        'signatureAlgorithm': 'Ed25519',
        'signature': base64UrlEncode(extendedSignature.bytes),
      };
      expect(
        await VelockPairingRevocation.parse(
          _bytes(extended),
        ).verify(descriptor: descriptor),
        isTrue,
      );
      expect(
        await VelockPairingRevocation.parse(
          _bytes({...extended, 'reason': 'stolen'}),
        ).verify(descriptor: descriptor),
        isFalse,
      );
      expect(
        () => VelockPairingRevocation.parse(
          _bytes({
            ...unsigned,
            'signatureAlgorithm': 'Ed25519',
            'signature': base64UrlEncode(Uint8List(32)),
          }),
        ),
        throwsFormatException,
      );
    });
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
