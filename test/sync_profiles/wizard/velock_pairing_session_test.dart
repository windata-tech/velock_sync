import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';

void main() {
  group('PlatformVelockPairingSessionService', () {
    late DateTime now;
    late _FakeControl control;
    late PlatformVelockPairingSessionService service;
    late VelockPairingDescriptor descriptor;

    setUp(() async {
      now = DateTime.utc(2026, 7, 18, 8);
      final key = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 4));
      control = _FakeControl(key);
      descriptor = _descriptor(
        base64UrlEncode((await key.extractPublicKey()).bytes),
        now,
      );
      var next = 0;
      service = PlatformVelockPairingSessionService(
        control: control,
        now: () => now,
        nextId: () => 'generated-${++next}',
      );
    });

    test(
      'submits one bounded request and verifies approved response',
      () async {
        final session = await service.begin(
          descriptor: descriptor,
          syncAppInstanceId: 'sync-instance-1',
        );
        expect(session.request.requestId, 'generated-1');
        expect(session.request.challenge, 'generated-2');
        expect(
          session.request.expiresAt.difference(session.request.createdAt),
          const Duration(minutes: 5),
        );

        await control.approve(session);
        final state = await service.inspect(session);
        expect(state.isApproved, isTrue);
        expect(state.response?.vaultId, 'vault-1');
        await service.acknowledge(session);
        expect(control.acknowledged, session.request.requestId);
      },
    );

    test(
      'rejects tampered approval and expires locally without querying',
      () async {
        final session = await service.begin(
          descriptor: descriptor,
          syncAppInstanceId: 'sync-instance-1',
        );
        await control.approve(session, vaultDisplayName: 'Tampered');
        await expectLater(
          service.inspect(session),
          throwsA(
            isA<VelockPairingSessionException>().having(
              (error) => error.code,
              'code',
              'invalid_pairing_response',
            ),
          ),
        );

        now = now.add(const Duration(minutes: 5));
        final state = await service.inspect(session);
        expect(state.status, VelockPairingControlStatus.expired);
        expect(control.queryCount, 1);
      },
    );
  });
}

VelockPairingDescriptor _descriptor(String publicKey, DateTime now) =>
    VelockPairingDescriptor.parse(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
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
        ),
      ),
    );

class _FakeControl implements AndroidPairingControlChannel {
  _FakeControl(this.signingKey);

  final SimpleKeyPair signingKey;
  VelockPairingControlRequest? submitted;
  VelockPairingControlResponse? response;
  String? acknowledged;
  int queryCount = 0;

  @override
  Future<VelockPairingControlStatus> submitPairingRequest(
    VelockPairingControlRequest request,
  ) async {
    submitted = request;
    return VelockPairingControlStatus.pending;
  }

  Future<void> approve(
    VelockPairingSession session, {
    String vaultDisplayName = 'Personal vault',
  }) async {
    final unsigned = {
      'approvedAt': session.request.createdAt
          .add(const Duration(seconds: 5))
          .toIso8601String(),
      'challenge': session.request.challenge,
      'deviceDisplayName': 'Pixel',
      'exchangeBindingId': session.request.exchangeBindingId,
      'expiresAt': session.request.expiresAt.toIso8601String(),
      'producerId': session.request.producerId,
      'producerPublicKeyId': session.request.producerPublicKeyId,
      'producerSigningPublicKey': session.descriptor.producerSigningPublicKey,
      'requestId': session.request.requestId,
      'vaultDisplayName': 'Personal vault',
      'vaultId': 'vault-1',
    };
    final signature = await Ed25519().sign(
      Uint8List.fromList(utf8.encode(jsonEncode(unsigned))),
      keyPair: signingKey,
    );
    final encoded = {
      ...unsigned,
      'vaultDisplayName': vaultDisplayName,
      'signature': base64UrlEncode(signature.bytes),
    };
    response = VelockPairingControlResponse.parse(
      Uint8List.fromList(utf8.encode(jsonEncode(encoded))),
    );
  }

  @override
  Future<VelockPairingControlResult> queryPairingResponse(
    String requestId,
  ) async {
    queryCount += 1;
    return response == null
        ? const VelockPairingControlResult(
            status: VelockPairingControlStatus.pending,
          )
        : VelockPairingControlResult(
            status: VelockPairingControlStatus.approved,
            response: response,
          );
  }

  @override
  Future<void> acknowledgePairing(String requestId) async {
    acknowledged = requestId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
