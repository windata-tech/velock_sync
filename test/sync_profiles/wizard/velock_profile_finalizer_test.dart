import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
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
    var expireDuringConnectionRead = false;
    var expireDuringTrustSave = false;

    setUp(() async {
      now = DateTime.utc(2026, 7, 18, 8);
      expireDuringConnectionRead = false;
      expireDuringTrustSave = false;
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
              if (expireDuringTrustSave) now = session.request.expiresAt;
            },
        saveProfile: (profile) async {
          events.add('save');
          saved.add(profile);
        },
        readProfiles: () async => summaries,
        readConnection: (_) async {
          if (expireDuringConnectionRead) now = session.request.expiresAt;
          return connection;
        },
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

    test('persists restore discovery before acknowledging pairing', () async {
      final result = await service.finalize(
        session: session,
        approval: approval,
        connectionId: 'connection-1',
        displayName: 'Recovered vault',
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        userConfirmed: true,
        restoring: true,
      );
      expect(events, ['trust', 'save', 'ack']);
      expect(saved.single.dataset['snapshotDiscoveryPending'], isTrue);
      expect(result.profile.snapshotDiscoveryPending, isTrue);
      expect(result.profile.snapshotRestoreRequestId, isNull);
    });

    test('persists a per-profile remote root scope', () async {
      const remoteRootSegments = ['中文 空格', '%', '#', '?'];
      final result = await service.finalize(
        session: session,
        approval: approval,
        connectionId: 'connection-1',
        displayName: 'Personal vault',
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        userConfirmed: true,
        remoteRootSegments: remoteRootSegments,
      );

      expect(result.profile.remoteRootSegments, remoteRootSegments);
      expect(saved.single.dataset['remoteRootSegments'], remoteRootSegments);
    });

    test('rejects a scope for an OAuth connection before saving', () async {
      connection = _oauthConnection();

      await _expectCode(
        service.finalize(
          session: session,
          approval: approval,
          connectionId: 'connection-1',
          displayName: 'Personal vault',
          backgroundPolicy: const SyncProfileBackgroundPolicy(),
          userConfirmed: true,
          remoteRootSegments: const ['folder'],
        ),
        'invalid_remote_root_segments',
      );

      expect(saved, isEmpty);
      expect(events, isEmpty);
    });

    test('rejects malformed remote root segments before saving', () async {
      await _expectCode(
        service.finalize(
          session: session,
          approval: approval,
          connectionId: 'connection-1',
          displayName: 'Personal vault',
          backgroundPolicy: const SyncProfileBackgroundPolicy(),
          userConfirmed: true,
          remoteRootSegments: const ['..'],
        ),
        'invalid_remote_root_segments',
      );

      expect(saved, isEmpty);
      expect(events, isEmpty);
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

    test('rechecks expiry after asynchronous connection reads', () async {
      expireDuringConnectionRead = true;
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
      expect(events, isEmpty); // No trusted key, profile, or ACK is persisted.
    });

    test(
      'expiry during trust storage never saves or acknowledges a profile',
      () async {
        expireDuringTrustSave = true;
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
        expect(events, [
          'trust',
        ]); // An orphan public key grants no dataset access.
      },
    );

    test(
      'a later response deadline cannot extend the original request',
      () async {
        final signingKey = await Ed25519().newKeyPairFromSeed(
          List<int>.filled(32, 8),
        );
        final unsigned = approval.unsignedJson();
        unsigned['expiresAt'] = now
            .add(const Duration(minutes: 10))
            .toIso8601String();
        final signature = await Ed25519().sign(
          utf8.encode(jsonEncode(unsigned)),
          keyPair: signingKey,
        );
        final extended = VelockPairingControlResponse.parse(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                ...unsigned,
                'signature': base64UrlEncode(signature.bytes),
              }),
            ),
          ),
        );
        expect(
          await extended.verify(
            descriptor: session.descriptor,
            request: session.request,
            now: () => now,
          ),
          isTrue,
        );
        now = session.request.expiresAt;
        expect(
          await extended.verify(
            descriptor: session.descriptor,
            request: session.request,
            now: () => now,
          ),
          isFalse,
        );
      },
    );

    test(
      'requires confirmation and rejects an approval that expires',
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

        expect(
          await approval.verify(
            descriptor: session.descriptor,
            request: session.request,
            now: () => now,
          ),
          isTrue,
        );

        now = session.request.expiresAt;
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

    group('re-pairing', () {
      late SyncStateDatabase database;
      late SyncProfileRepository profiles;
      late VelockProfileFinalizationService replacing;
      const folder = ['USB_HDD_8T', '111'];

      Future<SyncProfileEnvelope> saveOriginal({
        String vaultId = 'vault-1',
        String snapshotProducerId = 'producer-1',
        String? snapshotRestoreRequestId,
      }) async {
        final original = VelockSyncProfile(
          profileId: 'old-profile',
          datasetId: vaultId,
          vaultId: vaultId,
          deviceId: 'sync-device-1',
          displayName: 'Personal vault',
          connectionId: 'connection-1',
          pairedProducerId: 'producer-old',
          pairedProducerPublicKeyId: 'key-old',
          exchangeBindingId: 'binding-old',
          remoteRootSegments: folder,
          // The producer ID belongs to Velock and survives a re-pairing.
          trustedProducerIds: ['producer-old', snapshotProducerId],
          currentSnapshotId: 'snapshot-1',
          currentSnapshotProducerId: snapshotProducerId,
          snapshotRestoreRequestId: snapshotRestoreRequestId,
          backgroundPolicy: const SyncProfileBackgroundPolicy(),
          state: SyncProfileState.active,
          createdAt: now,
        ).toEnvelope();
        await profiles.save(original);
        return (await profiles.read('old-profile'))!;
      }

      Future<VelockProfileFinalizationResult> finalizeReplacement({
        List<String> remoteRootSegments = folder,
      }) => replacing.finalize(
        session: session,
        approval: approval,
        connectionId: 'connection-1',
        displayName: 'Personal vault',
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        userConfirmed: true,
        remoteRootSegments: remoteRootSegments,
        replacingProfileId: 'old-profile',
      );

      setUp(() async {
        database = await SyncStateDatabase.inMemory();
        profiles = SyncProfileRepository(database);
        replacing = VelockProfileFinalizationService(
          retainProducerTrust:
              ({
                required vaultId,
                required producerId,
                required signingPublicKey,
              }) async {},
          saveProfile: (_) async => fail('re-pairing must not insert beside'),
          readProfiles: () =>
              profiles.listSummaries(kind: SyncDatasetKind.velockManaged),
          readConnection: (_) async => connection,
          readProfile: profiles.read,
          replaceProfile: profiles.replaceVelockProfile,
          pairing: pairing..events = events,
          nextId: () => 'new-profile',
          now: () => now,
        );
      });
      tearDown(() => database.close());

      test('keeps the original until finalization, then swaps atomically '
          'with the same cloud folder', () async {
        await saveOriginal();
        // Starting (or abandoning) a pairing never touches the original.
        expect(await profiles.read('old-profile'), isNotNull);

        final result = await finalizeReplacement();

        expect(await profiles.read('old-profile'), isNull);
        final replacement = await profiles.read('new-profile');
        expect(replacement, isNotNull);
        final profile = VelockSyncProfile.fromEnvelope(replacement!);
        expect(profile.remoteRootSegments, folder);
        expect(profile.connectionId, 'connection-1');
        expect(profile.pairedProducerId, approval.producerId);
        // A settled snapshot reference is carried over and re-verified later.
        expect(profile.currentSnapshotId, 'snapshot-1');
        expect(profile.snapshotDiscoveryPending, isFalse);
        expect(result.pairingAcknowledged, isTrue);
        final visible = await profiles.listSummaries(
          kind: SyncDatasetKind.velockManaged,
        );
        expect(visible.map((item) => item.profileId), ['new-profile']);
      });

      test('a pending restore is rediscovered instead of reused', () async {
        await saveOriginal(
          snapshotProducerId: 'producer-restored',
          snapshotRestoreRequestId: 'restore-old',
        );

        await finalizeReplacement();

        final profile = VelockSyncProfile.fromEnvelope(
          (await profiles.read('new-profile'))!,
        );
        expect(profile.snapshotDiscoveryPending, isTrue);
        expect(profile.snapshotRestoreRequestId, isNull);
        expect(profile.currentSnapshotId, isNull);
      });

      test('another account or folder leaves the original unchanged', () async {
        final original = await saveOriginal();

        await _expectCode(
          finalizeReplacement(remoteRootSegments: const ['elsewhere']),
          'replacement_location_mismatch',
        );
        expect(
          (await profiles.read('old-profile'))!.toJson(),
          original.toJson(),
        );
        expect(await profiles.read('new-profile'), isNull);

        await profiles.remove('old-profile');
        final otherVault = await saveOriginalAs('vault-2', profiles, now);
        await _expectCode(finalizeReplacement(), 'replacement_vault_mismatch');
        expect(
          (await profiles.read('old-profile'))!.toJson(),
          otherVault.toJson(),
        );
        expect(events, isNot(contains('ack')));
      });

      test('a running backup blocks the swap and keeps the original', () async {
        final original = await saveOriginal();
        await database.startSyncRun(
          runId: 'run-1',
          profileId: 'old-profile',
          startedAt: now,
        );

        await _expectCode(finalizeReplacement(), 'replaced_profile_changed');
        expect(
          (await profiles.read('old-profile'))!.toJson(),
          original.toJson(),
        );
        expect(await profiles.read('new-profile'), isNull);
        expect(events, isNot(contains('ack')));
      });

      test('an untrusted snapshot producer is rediscovered', () async {
        await saveOriginal(snapshotProducerId: 'producer-gone');

        await finalizeReplacement();

        final profile = VelockSyncProfile.fromEnvelope(
          (await profiles.read('new-profile'))!,
        );
        expect(profile.snapshotDiscoveryPending, isTrue);
        expect(profile.currentSnapshotId, isNull);
      });

      test('a removed original is not silently recreated', () async {
        await saveOriginal();
        await profiles.remove('old-profile');

        await _expectCode(finalizeReplacement(), 'replaced_profile_missing');
        expect(await profiles.read('new-profile'), isNull);
      });
    });
  });
}

Future<SyncProfileEnvelope> saveOriginalAs(
  String vaultId,
  SyncProfileRepository profiles,
  DateTime now,
) async {
  // Profile IDs are never reused in the store, so the other-account fixture
  // is written through the database directly under the same ID.
  final envelope = VelockSyncProfile(
    profileId: 'old-profile',
    datasetId: vaultId,
    vaultId: vaultId,
    deviceId: 'sync-device-1',
    displayName: 'Other vault',
    connectionId: 'connection-1',
    pairedProducerId: 'producer-old',
    pairedProducerPublicKeyId: 'key-old',
    exchangeBindingId: 'binding-old',
    remoteRootSegments: const ['USB_HDD_8T', '111'],
    backgroundPolicy: const SyncProfileBackgroundPolicy(),
    state: SyncProfileState.active,
    createdAt: now,
  ).toEnvelope();
  await profiles.save(envelope);
  return (await profiles.read('old-profile'))!;
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

ConnectionModel _oauthConnection() => ConnectionModel(
  id: 'connection-1',
  name: 'OAuth',
  source: 'Velock',
  target: 'Remote',
  protocol: const ProtocolModel.oauth(
    providerType: RemoteProviderType.googleDrive,
    clientId: 'public-client-id',
    credentialRef: 'opaque-ref',
    rootId: 'root',
  ),
  createdAt: DateTime.utc(2026, 7, 18),
  updatedAt: DateTime.utc(2026, 7, 18),
  status: ConnectionStatus.active,
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
