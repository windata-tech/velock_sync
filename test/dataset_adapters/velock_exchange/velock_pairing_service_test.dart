import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_service.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  late SyncStateDatabase database;
  late SyncProfileRepository profiles;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = SyncProfileRepository(database);
  });

  tearDown(() => database.close());

  test(
    'requires explicit confirmation before discovery, authorization, or save',
    () async {
      var discoveryCalls = 0;
      final service = _service(
        profiles: profiles,
        database: database,
        discovery: _FakeDiscovery(() async {
          discoveryCalls++;
          return _available();
        }),
      );

      await _expectPairingFailure(
        service.pair(_request(userConfirmed: false)),
        'confirmation_required',
      );

      expect(discoveryCalls, 0);
      expect(await profiles.read('profile-1'), isNull);
    },
  );

  test(
    'does not save a profile when authorization is required or revoked',
    () async {
      for (final status in [
        VelockAuthorizationStatus.authorizationRequired,
        VelockAuthorizationStatus.accessRevoked,
      ]) {
        final service = _service(
          profiles: profiles,
          database: database,
          authorization: _FakeAuthorization(status),
        );

        await _expectPairingFailure(
          service.pair(_request()),
          status == VelockAuthorizationStatus.accessRevoked
              ? 'access_revoked'
              : 'authorization_required',
        );
        expect(await profiles.read('profile-1'), isNull);
      }
    },
  );

  test(
    'rejects mismatched responses and untrusted producers without saving',
    () async {
      final badResponse = _response(challenge: 'another-challenge');
      final mismatch = _service(
        profiles: profiles,
        database: database,
        pairing: _FakePairing((candidate, challenge) async => badResponse),
      );
      await _expectPairingFailure(
        mismatch.pair(_request()),
        'invalid_pairing_response',
      );
      expect(await profiles.read('profile-1'), isNull);

      final untrusted = _service(
        profiles: profiles,
        database: database,
        verifier: _FakeVerifier(false),
        challengeFactory: () => 'challenge-untrusted',
      );
      await _expectPairingFailure(
        untrusted.pair(_request()),
        'untrusted_producer',
      );
      expect(await profiles.read('profile-1'), isNull);
    },
  );

  test(
    'saves only a verified active profile with the paired trust identity',
    () async {
      final service = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'challenge-success',
      );

      final paired = await service.pair(_request());
      final persisted = await profiles.read('profile-1');

      expect(paired.state, SyncProfileState.active);
      expect(persisted, isNotNull);
      final profile = VelockSyncProfile.fromEnvelope(persisted!);
      expect(profile.state, SyncProfileState.active);
      expect(profile.pairedProducerId, 'producer-1');
      expect(profile.pairedProducerPublicKeyId, 'producer-key-1');
      expect(profile.exchangeBindingId, 'exchange-1');
      expect(
        await database.readSyncProfilePayload('profile-1'),
        isNot(contains('challenge-success')),
      );
    },
  );

  test(
    'rejects a duplicate vault/device pairing unless explicitly repairing the same profile',
    () async {
      final initial = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'challenge-initial',
      );
      await initial.pair(_request());

      final duplicate = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'challenge-duplicate',
      );
      await _expectPairingFailure(
        duplicate.pair(_request(profile: _profile(profileId: 'profile-2'))),
        'duplicate_pairing',
      );

      final repair = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'challenge-repair',
      );
      await repair.pair(_request(allowRepair: true));
      expect(
        (await profiles.read('profile-1'))!.state,
        SyncProfileState.active,
      );
    },
  );

  test(
    'consumes a challenge digest exactly once and never persists its plaintext',
    () async {
      final first = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'same-one-time-challenge',
      );
      await first.pair(_request());

      final replay = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'same-one-time-challenge',
      );
      await _expectPairingFailure(
        replay.pair(_request(allowRepair: true)),
        'challenge_replayed',
      );
      expect(
        await database.readSyncProfilePayload('profile-1'),
        isNot(contains('same-one-time-challenge')),
      );
    },
  );

  test(
    'moves a paired profile to access required after authorization is revoked',
    () async {
      final service = _service(
        profiles: profiles,
        database: database,
        challengeFactory: () => 'challenge-revoke',
      );
      await service.pair(_request());

      await service.markAuthorizationRevoked('profile-1');

      expect(
        (await profiles.read('profile-1'))!.state,
        SyncProfileState.accessRequired,
      );
    },
  );
}

VelockPairingService _service({
  required SyncProfileRepository profiles,
  required SyncStateDatabase database,
  VelockExchangeDiscovery? discovery,
  VelockAuthorizationGateway? authorization,
  VelockPairingGateway? pairing,
  VelockPairingVerifier? verifier,
  String Function()? challengeFactory,
}) => VelockPairingService(
  profiles: profiles,
  discovery: discovery ?? _FakeDiscovery(() async => _available()),
  authorization:
      authorization ?? _FakeAuthorization(VelockAuthorizationStatus.granted),
  pairing:
      pairing ??
      _FakePairing(
        (_, challenge) async => _response(challenge: challenge.value),
      ),
  verifier: verifier ?? _FakeVerifier(true),
  replayGuard: DatabaseVelockPairingReplayGuard(database),
  challengeFactory:
      challengeFactory ??
      () => 'challenge-${DateTime.now().microsecondsSinceEpoch}',
);

VelockPairingRequest _request({
  VelockSyncProfile? profile,
  bool userConfirmed = true,
  bool allowRepair = false,
}) => VelockPairingRequest(
  profile: profile ?? _profile(),
  candidate: _candidate,
  userConfirmed: userConfirmed,
  allowRepair: allowRepair,
);

const _candidate = VelockExchangeCandidate(
  producerId: 'producer-1',
  producerPublicKeyId: 'producer-key-1',
  exchangeBindingId: 'exchange-1',
);

VelockExchangeDiscoveryResult _available() =>
    const VelockExchangeDiscoveryResult(
      availability: VelockExchangeAvailability.available,
      candidate: _candidate,
    );

VelockPairingResponse _response({required String challenge}) =>
    VelockPairingResponse(
      challenge: challenge,
      producerId: _candidate.producerId,
      producerPublicKeyId: _candidate.producerPublicKeyId,
      exchangeBindingId: _candidate.exchangeBindingId,
    );

VelockSyncProfile _profile({String profileId = 'profile-1'}) =>
    VelockSyncProfile(
      profileId: profileId,
      datasetId: 'dataset-$profileId',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Velock vault',
      connectionId: 'connection-1',
      pairedProducerId: _candidate.producerId,
      pairedProducerPublicKeyId: _candidate.producerPublicKeyId,
      exchangeBindingId: _candidate.exchangeBindingId,
      backgroundPolicy: const SyncProfileBackgroundPolicy(),
      state: SyncProfileState.accessRequired,
      createdAt: DateTime.utc(2026, 7, 17),
    );

Future<void> _expectPairingFailure(Future<Object?> operation, String code) =>
    expectLater(
      operation,
      throwsA(
        isA<VelockPairingException>().having(
          (error) => error.code,
          'code',
          code,
        ),
      ),
    );

class _FakeDiscovery implements VelockExchangeDiscovery {
  _FakeDiscovery(this._discover);
  final Future<VelockExchangeDiscoveryResult> Function() _discover;
  @override
  Future<VelockExchangeDiscoveryResult> discover() => _discover();
}

class _FakeAuthorization implements VelockAuthorizationGateway {
  const _FakeAuthorization(this.status);
  final VelockAuthorizationStatus status;
  @override
  Future<VelockAuthorizationStatus> requestAuthorization(
    VelockExchangeCandidate candidate,
  ) async => status;
}

class _FakePairing implements VelockPairingGateway {
  _FakePairing(this._pair);
  final Future<VelockPairingResponse> Function(
    VelockExchangeCandidate,
    VelockPairingChallenge,
  )
  _pair;

  @override
  Future<VelockPairingResponse> pair({
    required VelockExchangeCandidate candidate,
    required VelockPairingChallenge challenge,
  }) => _pair(candidate, challenge);
}

class _FakeVerifier implements VelockPairingVerifier {
  const _FakeVerifier(this.result);
  final bool result;

  @override
  Future<bool> verify({
    required VelockExchangeCandidate candidate,
    required VelockPairingChallenge challenge,
    required VelockPairingResponse response,
  }) async => result;
}
