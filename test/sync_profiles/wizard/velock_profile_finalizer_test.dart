import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';

void main() {
  group('VelockProfileFinalizationService', () {
    late DateTime now;
    late VelockPairingSession session;
    late VelockPairingControlResponse approval;
    late _PairingService pairing;
    late List<SyncProfileEnvelope> saved;
    late ConnectionModel? connection;
    late List<SyncProfileSummary> summaries;
    late List<String> events;
    late VelockProfileFinalizationService service;

    setUp(() async {
      now = DateTime.utc(2026, 7, 18, 8);
      final signingKey = await Ed25519().newKeyPairFromSeed(
        List<int>.filled(32, 8),
      );
      final publicKey = base64UrlEncode(
        (await signingKey.extractPublicKey()).bytes,
      );
      final descriptor = VelockPairingDescriptor.parse(
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
      final request = VelockPairingControlRequest(
        requestId: 'request-1',
        challenge: 'challenge-1',
        producerId: descriptor.producerId,
        producerPublicKeyId: descriptor.producerPublicKeyId,
        exchangeBindingId: descriptor.exchangeBindingId,
        syncAppInstanceId: 'sync-device-1',
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      session = VelockPairingSession(descriptor: descriptor, request: request);
      approval = await _approval(session, signingKey, now);
      pairing = _PairingService();
      saved = [];
      summaries = [];
      events = [];
      connection = _connection();
      service = VelockProfileFinalizationService(
        retainProducerTrust:
            ({
              required vaultId,
              required producerId,
              required signingPublicKey,
            }) async {
              expect(vaultId, 'vault-1');
              expect(producerId, 'producer-1');
              expect(signingPublicKey, hasLength(32));
              events.add('trust');
            },
        saveProfile: (profile) async {
          events.add('save');
          saved.add(profile);
        },
        readProfiles: () async => summaries,
        readConnection: (_) async => connection,
        pairing: pairing..events = events,
        nextId: () => 'profile-1',
        now: () => now,
      );
    });

    test('saves an active profile before acknowledging the response', () async {
      final result = await service.finalize(
        session: session,
        approval: approval,
        connectionId: 'connection-1',
        displayName: ' Personal vault ',
        backgroundPolicy: const SyncProfileBackgroundPolicy(
          enabled: true,
          requiresCharging: true,
        ),
        userConfirmed: true,
      );

      expect(events, ['trust', 'save', 'ack']);
      expect(result.pairingAcknowledged, isTrue);
      expect(saved, hasLength(1));
      final profile = saved.single;
      expect(profile.state, SyncProfileState.active);
      expect(profile.profileId, 'profile-1');
      expect(profile.datasetId, approval.vaultId);
      expect(profile.vaultId, approval.vaultId);
      expect(profile.deviceId, session.request.syncAppInstanceId);
      expect(profile.displayName, 'Personal vault');
      expect(profile.connectionId, 'connection-1');
      expect(profile.dataset, {
        'pairedProducerId': approval.producerId,
        'pairedProducerPublicKeyId': approval.producerPublicKeyId,
        'exchangeBindingId': approval.exchangeBindingId,
        'trustedProducerIds': [approval.producerId],
      });
      expect(profile.backgroundPolicy.enabled, isTrue);
      expect(profile.backgroundPolicy.requiresCharging, isTrue);
    });

    test('keeps the saved profile when acknowledgement needs retry', () async {
      pairing.failAcknowledgement = true;

      final result = await service.finalize(
        session: session,
        approval: approval,
        connectionId: 'connection-1',
        displayName: 'Personal vault',
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        userConfirmed: true,
      );

      expect(events, ['trust', 'save', 'ack']);
      expect(saved, hasLength(1));
      expect(result.pairingAcknowledged, isFalse);
      pairing.failAcknowledgement = false;
      expect(await service.retryAcknowledgement(session), isTrue);
      expect(events, ['trust', 'save', 'ack', 'ack']);
    });

    test(
      'fails closed before save for unavailable connection or duplicate',
      () async {
        connection = _connection(status: ConnectionStatus.inactive);
        await _expectCode(
          service.finalize(
            session: session,
            approval: approval,
            connectionId: 'connection-1',
            displayName: 'Personal vault',
            backgroundPolicy: const SyncProfileBackgroundPolicy(),
            userConfirmed: true,
          ),
          'connection_unavailable',
        );

        connection = _connection();
        summaries = [
          SyncProfileSummary(
            profileId: 'existing',
            kind: SyncDatasetKind.velockManaged,
            state: SyncProfileState.active,
            vaultId: approval.vaultId,
            deviceId: session.request.syncAppInstanceId,
            backgroundPolicy: const SyncProfileBackgroundPolicy(),
          ),
        ];
        await _expectCode(
          service.finalize(
            session: session,
            approval: approval,
            connectionId: 'connection-1',
            displayName: 'Personal vault',
            backgroundPolicy: const SyncProfileBackgroundPolicy(),
            userConfirmed: true,
          ),
          'duplicate_pairing',
        );
        expect(saved, isEmpty);
        expect(events, isEmpty);
      },
    );

    test(
      'requires final confirmation and a still-valid signed approval',
      () async {
        await _expectCode(
          service.finalize(
            session: session,
            approval: approval,
            connectionId: 'connection-1',
            displayName: 'Personal vault',
            backgroundPolicy: const SyncProfileBackgroundPolicy(),
            userConfirmed: false,
          ),
          'confirmation_required',
        );

        now = now.add(const Duration(minutes: 5));
        await _expectCode(
          service.finalize(
            session: session,
            approval: approval,
            connectionId: 'connection-1',
            displayName: 'Personal vault',
            backgroundPolicy: const SyncProfileBackgroundPolicy(),
            userConfirmed: true,
          ),
          'invalid_pairing_response',
        );
        expect(saved, isEmpty);
        expect(events, isEmpty);
      },
    );
  });
}

Future<VelockPairingControlResponse> _approval(
  VelockPairingSession session,
  SimpleKeyPair signingKey,
  DateTime now,
) async {
  final unsigned = {
    'approvedAt': now.add(const Duration(seconds: 5)).toIso8601String(),
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
  return VelockPairingControlResponse.parse(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          ...unsigned,
          'signature': base64UrlEncode(signature.bytes),
        }),
      ),
    ),
  );
}

ConnectionModel _connection({
  ConnectionStatus status = ConnectionStatus.active,
}) => ConnectionModel(
  id: 'connection-1',
  name: 'WebDAV',
  source: 'Velock',
  target: 'Remote',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.test',
    port: '443',
    path: '/velock',
  ),
  createdAt: DateTime.utc(2026, 7, 18),
  updatedAt: DateTime.utc(2026, 7, 18),
  status: status,
);

class _PairingService implements VelockPairingSessionService {
  List<String>? events;
  bool failAcknowledgement = false;

  @override
  Future<void> acknowledge(VelockPairingSession session) async {
    events?.add('ack');
    if (failAcknowledgement) throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _expectCode(Future<Object?> operation, String code) => expectLater(
  operation,
  throwsA(
    isA<VelockProfileFinalizationException>().having(
      (error) => error.code,
      'code',
      code,
    ),
  ),
);
