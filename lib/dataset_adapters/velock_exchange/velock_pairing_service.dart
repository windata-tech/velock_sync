import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

class VelockPairingChallenge {
  const VelockPairingChallenge(this.value);

  final String value;
}

enum VelockAuthorizationStatus { granted, authorizationRequired, accessRevoked }

abstract interface class VelockAuthorizationGateway {
  Future<VelockAuthorizationStatus> requestAuthorization(
    VelockExchangeCandidate candidate,
  );
}

class VelockPairingResponse {
  const VelockPairingResponse({
    required this.challenge,
    required this.producerId,
    required this.producerPublicKeyId,
    required this.exchangeBindingId,
  });

  final String challenge;
  final String producerId;
  final String producerPublicKeyId;
  final String exchangeBindingId;
}

abstract interface class VelockPairingGateway {
  Future<VelockPairingResponse> pair({
    required VelockExchangeCandidate candidate,
    required VelockPairingChallenge challenge,
  });
}

/// Cryptographically verifies a response supplied by the already trusted
/// Velock platform. The implementation belongs to the platform integration;
/// Sync never owns or creates a Velock signing key.
abstract interface class VelockPairingVerifier {
  Future<bool> verify({
    required VelockExchangeCandidate candidate,
    required VelockPairingChallenge challenge,
    required VelockPairingResponse response,
  });
}

abstract interface class VelockPairingReplayGuard {
  Future<bool> consume(VelockPairingChallenge challenge);
}

class DatabaseVelockPairingReplayGuard implements VelockPairingReplayGuard {
  DatabaseVelockPairingReplayGuard(this._database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final DateTime Function() _now;

  @override
  Future<bool> consume(VelockPairingChallenge challenge) =>
      _database.consumeVelockPairingChallenge(
        challengeDigest: sha256
            .convert(utf8.encode(challenge.value))
            .toString(),
        consumedAt: _now(),
      );
}

class VelockPairingRequest {
  const VelockPairingRequest({
    required this.profile,
    required this.candidate,
    required this.userConfirmed,
    this.allowRepair = false,
  });

  final VelockSyncProfile profile;
  final VelockExchangeCandidate candidate;
  final bool userConfirmed;
  final bool allowRepair;
}

class VelockPairingException implements Exception {
  const VelockPairingException(this.code);

  /// Stable, privacy-safe code. Never includes an exception message, package,
  /// authority, public key, challenge, exchange path, or credential.
  final String code;

  @override
  String toString() => 'Velock pairing failed: $code';
}

/// Performs the only path which turns a discovered producer into a trusted
/// Velock Sync profile. Discovery and authorization alone never save a profile.
class VelockPairingService {
  VelockPairingService({
    required SyncProfileRepository profiles,
    required VelockExchangeDiscovery discovery,
    required VelockAuthorizationGateway authorization,
    required VelockPairingGateway pairing,
    required VelockPairingVerifier verifier,
    required VelockPairingReplayGuard replayGuard,
    String Function()? challengeFactory,
  }) : _profiles = profiles,
       _discovery = discovery,
       _authorization = authorization,
       _pairing = pairing,
       _verifier = verifier,
       _replayGuard = replayGuard,
       _challengeFactory = challengeFactory ?? const Uuid().v4;

  final SyncProfileRepository _profiles;
  final VelockExchangeDiscovery _discovery;
  final VelockAuthorizationGateway _authorization;
  final VelockPairingGateway _pairing;
  final VelockPairingVerifier _verifier;
  final VelockPairingReplayGuard _replayGuard;
  final String Function() _challengeFactory;

  Future<VelockSyncProfile> pair(VelockPairingRequest request) async {
    if (!request.userConfirmed) {
      throw const VelockPairingException('confirmation_required');
    }
    _requireCandidateMatchesProfile(request.candidate, request.profile);
    await _ensureNoDuplicateBinding(request);

    final discovered = await _discovery.discover();
    if (!discovered.isAvailable ||
        discovered.candidate == null ||
        !discovered.candidate!.sameIdentityAs(request.candidate)) {
      throw VelockPairingException(
        _discoveryFailureCode(discovered.availability),
      );
    }

    final authorization = await _authorization.requestAuthorization(
      request.candidate,
    );
    if (authorization != VelockAuthorizationStatus.granted) {
      throw VelockPairingException(
        authorization == VelockAuthorizationStatus.accessRevoked
            ? 'access_revoked'
            : 'authorization_required',
      );
    }

    final challenge = VelockPairingChallenge(_challengeFactory());
    if (challenge.value.trim().isEmpty ||
        !await _replayGuard.consume(challenge)) {
      throw const VelockPairingException('challenge_replayed');
    }

    final response = await _pairing.pair(
      candidate: request.candidate,
      challenge: challenge,
    );
    _requireResponseMatches(request.candidate, challenge, response);
    if (!await _verifier.verify(
      candidate: request.candidate,
      challenge: challenge,
      response: response,
    )) {
      throw const VelockPairingException('untrusted_producer');
    }

    // Pairing identity and trust fields are persisted in one atomic profile
    // upsert only after all checks pass. No partially trusted profile exists.
    final activeProfile = request.profile.copyWith(
      state: SyncProfileState.active,
    );
    await _profiles.save(activeProfile.toEnvelope());
    return activeProfile;
  }

  Future<void> markAuthorizationRevoked(String profileId) =>
      _profiles.setState(profileId, SyncProfileState.accessRequired);

  Future<void> _ensureNoDuplicateBinding(VelockPairingRequest request) async {
    final matching =
        (await _profiles.listSummaries(
          kind: SyncDatasetKind.velockManaged,
        )).where(
          (profile) =>
              profile.vaultId == request.profile.vaultId &&
              profile.deviceId == request.profile.deviceId,
        );
    for (final existing in matching) {
      if (existing.profileId == request.profile.profileId &&
          request.allowRepair) {
        continue;
      }
      throw const VelockPairingException('duplicate_pairing');
    }
  }

  void _requireCandidateMatchesProfile(
    VelockExchangeCandidate candidate,
    VelockSyncProfile profile,
  ) {
    if (!candidate.isWellFormed ||
        candidate.producerId != profile.pairedProducerId ||
        candidate.producerPublicKeyId != profile.pairedProducerPublicKeyId ||
        candidate.exchangeBindingId != profile.exchangeBindingId) {
      throw const VelockPairingException('candidate_mismatch');
    }
  }

  void _requireResponseMatches(
    VelockExchangeCandidate candidate,
    VelockPairingChallenge challenge,
    VelockPairingResponse response,
  ) {
    if (response.challenge != challenge.value ||
        response.producerId != candidate.producerId ||
        response.producerPublicKeyId != candidate.producerPublicKeyId ||
        response.exchangeBindingId != candidate.exchangeBindingId) {
      throw const VelockPairingException('invalid_pairing_response');
    }
  }

  String _discoveryFailureCode(VelockExchangeAvailability availability) =>
      switch (availability) {
        VelockExchangeAvailability.signatureMismatch => 'platform_untrusted',
        VelockExchangeAvailability.accessRevoked => 'access_revoked',
        VelockExchangeAvailability.authorizationRequired =>
          'authorization_required',
        _ => 'platform_unavailable',
      };
}
