import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

void main() {
  group('ApplePairingControlChannel', () {
    late Directory root;
    late DateTime now;
    late List<Uri> launches;
    late ApplePairingControlChannel channel;
    late SimpleKeyPair descriptorKey;
    late String descriptorPublicKey;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('apple-pairing-control-');
      now = DateTime.utc(2026, 7, 18, 8);
      launches = [];
      descriptorKey = await Ed25519().newKeyPairFromSeed(
        List<int>.filled(32, 7),
      );
      descriptorPublicKey = base64UrlEncode(
        (await descriptorKey.extractPublicKey()).bytes,
      );
      channel = ApplePairingControlChannel(
        rootLocator: AppleExchangeRootLocator(
          channel: _RootChannel(root.path),
          isApplePlatform: () => true,
        ),
        launchVelock: (uri) async {
          launches.add(uri);
          return true;
        },
        now: () => now,
      );
      await _writeJson(File('${root.path}/Control/descriptor.json'), {
        'controlVersion': 1,
        'exchangeBindingId': 'binding-1',
        'exchangeVersion': 1,
        'producerId': 'producer-1',
        'producerPublicKeyId': 'key-1',
        'producerSigningPublicKey': descriptorPublicKey,
        'protocol': 'velock-sync',
        'protocolVersion': 1,
        'publishedAt': now.toIso8601String(),
        'signatureAlgorithm': 'Ed25519',
      });
    });

    tearDown(() => root.delete(recursive: true));

    test(
      'reads descriptor and publishes one request before opening Velock',
      () async {
        final descriptor = await channel.pairingDescriptor();
        final request = _request(descriptor, now);

        final status = await channel.submitPairingRequest(request);

        expect(status, VelockPairingControlStatus.pending);
        expect(launches.single.scheme, 'velock');
        expect(launches.single.host, 'sync-pairing');
        expect(launches.single.queryParameters['requestId'], request.requestId);
        expect(
          jsonDecode(
            await File(
              '${root.path}/Control/Requests/request-1.json',
            ).readAsString(),
          ),
          request.toJson(),
        );
        expect(
          (await channel.queryPairingResponse(request.requestId)).status,
          VelockPairingControlStatus.pending,
        );
        await expectLater(
          channel.submitPairingRequest(request),
          throwsStateError,
        );
      },
    );

    test(
      'reads a decision and consumes an approved response after ACK',
      () async {
        final descriptor = await channel.pairingDescriptor();
        final request = _request(descriptor, now);
        await channel.submitPairingRequest(request);
        await _writeJson(
          File('${root.path}/Control/Responses/request-1.json'),
          _response(request, descriptor, now),
        );
        await _writeJson(
          File('${root.path}/Control/Decisions/request-1.json'),
          {
            'decidedAt': now.add(const Duration(seconds: 5)).toIso8601String(),
            'requestId': request.requestId,
            'status': 'approved',
          },
        );

        final result = await channel.queryPairingResponse(request.requestId);
        expect(result.status, VelockPairingControlStatus.approved);
        expect(result.response?.requestId, request.requestId);

        await channel.acknowledgePairing(request.requestId);

        expect(
          await File('${root.path}/Control/Consumed/request-1.json').exists(),
          isTrue,
        );
        expect(
          await File('${root.path}/Control/Requests/request-1.json').exists(),
          isFalse,
        );
        expect(
          await File('${root.path}/Control/Responses/request-1.json').exists(),
          isFalse,
        );
        await expectLater(
          channel.queryPairingResponse(request.requestId),
          throwsStateError,
        );
      },
    );

    test(
      'maps denied and expired decision markers without response bytes',
      () async {
        final descriptor = await channel.pairingDescriptor();
        for (final entry in {
          'denied-1': VelockPairingControlStatus.denied,
          'expired-1': VelockPairingControlStatus.expired,
        }.entries) {
          final request = _request(descriptor, now, requestId: entry.key);
          await channel.submitPairingRequest(request);
          await _writeJson(
            File('${root.path}/Control/Decisions/${entry.key}.json'),
            {
              'decidedAt': now.toIso8601String(),
              'requestId': entry.key,
              'status': entry.value.name,
            },
          );
          expect(
            (await channel.queryPairingResponse(entry.key)).status,
            entry.value,
          );
        }
      },
    );

    test('reports granted when no revocation marker exists', () async {
      expect(
        await channel.queryAuthorizationStatus('sync-instance-1'),
        VelockDeviceAuthorizationStatus.granted,
      );
    });

    test(
      'reports revoked only for a marker signed by the descriptor key',
      () async {
        final revokedAt = now.add(const Duration(hours: 1));
        final unsigned = {
          'deviceId': 'sync-instance-1',
          'revokedAt': revokedAt.toIso8601String(),
        };
        final signature = await Ed25519().sign(
          Uint8List.fromList(utf8.encode(jsonEncode(unsigned))),
          keyPair: descriptorKey,
        );
        await _writeJson(
          File('${root.path}/Control/Revocations/sync-instance-1.json'),
          {
            ...unsigned,
            'signatureAlgorithm': 'Ed25519',
            'signature': base64UrlEncode(signature.bytes),
          },
        );

        expect(
          await channel.queryAuthorizationStatus('sync-instance-1'),
          VelockDeviceAuthorizationStatus.revoked,
        );
      },
    );

    test('fails closed for a forged revocation marker', () async {
      await _writeJson(
        File('${root.path}/Control/Revocations/sync-instance-1.json'),
        {
          'deviceId': 'sync-instance-1',
          'revokedAt': now.add(const Duration(hours: 1)).toIso8601String(),
          'signatureAlgorithm': 'Ed25519',
          'signature': base64UrlEncode(Uint8List(64)),
        },
      );

      await expectLater(
        channel.queryAuthorizationStatus('sync-instance-1'),
        throwsFormatException,
      );
    });
  });
}

VelockPairingControlRequest _request(
  VelockPairingDescriptor descriptor,
  DateTime now, {
  String requestId = 'request-1',
}) => VelockPairingControlRequest(
  requestId: requestId,
  challenge: 'challenge-$requestId',
  producerId: descriptor.producerId,
  producerPublicKeyId: descriptor.producerPublicKeyId,
  exchangeBindingId: descriptor.exchangeBindingId,
  syncAppInstanceId: 'sync-instance-1',
  createdAt: now,
  expiresAt: now.add(const Duration(minutes: 5)),
);

Map<String, Object> _response(
  VelockPairingControlRequest request,
  VelockPairingDescriptor descriptor,
  DateTime now,
) => {
  'approvedAt': now.add(const Duration(seconds: 5)).toIso8601String(),
  'challenge': request.challenge,
  'deviceDisplayName': 'iPhone',
  'exchangeBindingId': request.exchangeBindingId,
  'expiresAt': request.expiresAt.toIso8601String(),
  'producerId': request.producerId,
  'producerPublicKeyId': request.producerPublicKeyId,
  'producerSigningPublicKey': descriptor.producerSigningPublicKey,
  'requestId': request.requestId,
  'signature': base64UrlEncode(Uint8List(64)),
  'vaultDisplayName': 'Personal vault',
  'vaultId': 'vault-1',
};

Future<void> _writeJson(File file, Map<String, Object> value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(value));
}

class _RootChannel implements AppleExchangeRootChannel {
  const _RootChannel(this.path);

  final String path;

  @override
  Future<String?> readExchangeRoot() async => path;
}
