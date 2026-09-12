import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';

typedef VelockProfileSaver = Future<void> Function(SyncProfileEnvelope profile);
typedef VelockProducerTrustSaver =
    Future<void> Function({
      required String vaultId,
      required String producerId,
      required Uint8List signingPublicKey,
    });
typedef VelockProfileSummaryReader =
    Future<List<SyncProfileSummary>> Function();
typedef VelockConnectionReader =
    Future<ConnectionModel?> Function(String connectionId);

class VelockProfileFinalizationResult {
  const VelockProfileFinalizationResult({
    required this.profile,
    required this.pairingAcknowledged,
  });

  final VelockSyncProfile profile;
  final bool pairingAcknowledged;
}

class VelockProfileFinalizationException implements Exception {
  const VelockProfileFinalizationException(this.code);

  final String code;
}

abstract interface class VelockProfileFinalizer {
  Future<VelockProfileFinalizationResult> finalize({
    required VelockPairingSession session,
    required VelockPairingControlResponse approval,
    required String connectionId,
    required String displayName,
    required SyncProfileBackgroundPolicy backgroundPolicy,
    required bool userConfirmed,
  });

  Future<bool> retryAcknowledgement(VelockPairingSession session);
}

/// Turns one already-approved control-plane session into a durable profile.
///
/// The signed approval is verified again at this final trust boundary. The
/// profile is saved before acknowledgement so a failed ACK can never consume
/// the one-time response while leaving no usable local profile.
class VelockProfileFinalizationService implements VelockProfileFinalizer {
  VelockProfileFinalizationService({
    required VelockProfileSaver saveProfile,
    required VelockProducerTrustSaver retainProducerTrust,
    required VelockProfileSummaryReader readProfiles,
    required VelockConnectionReader readConnection,
    required VelockPairingSessionService pairing,
    String Function()? nextId,
    DateTime Function()? now,
  }) : _saveProfile = saveProfile,
       _retainProducerTrust = retainProducerTrust,
       _readProfiles = readProfiles,
       _readConnection = readConnection,
       _pairing = pairing,
       _nextId = nextId ?? const Uuid().v4,
       _now = now ?? DateTime.now;

  final VelockProfileSaver _saveProfile;
  final VelockProducerTrustSaver _retainProducerTrust;
  final VelockProfileSummaryReader _readProfiles;
  final VelockConnectionReader _readConnection;
  final VelockPairingSessionService _pairing;
  final String Function() _nextId;
  final DateTime Function() _now;

  @override
  Future<VelockProfileFinalizationResult> finalize({
    required VelockPairingSession session,
    required VelockPairingControlResponse approval,
    required String connectionId,
    required String displayName,
    required SyncProfileBackgroundPolicy backgroundPolicy,
    required bool userConfirmed,
  }) async {
    if (!userConfirmed) {
      throw const VelockProfileFinalizationException('confirmation_required');
    }
    final normalizedDisplayName = displayName.trim();
    if (normalizedDisplayName.isEmpty || normalizedDisplayName.length > 128) {
      throw const VelockProfileFinalizationException('invalid_display_name');
    }
    if (!await approval.verify(
      descriptor: session.descriptor,
      request: session.request,
      now: _now,
    )) {
      throw const VelockProfileFinalizationException(
        'invalid_pairing_response',
      );
    }

    final connection = await _readConnection(connectionId);
    if (connection == null) {
      throw const VelockProfileFinalizationException('connection_missing');
    }
    if (connection.status != ConnectionStatus.active) {
      throw const VelockProfileFinalizationException('connection_unavailable');
    }

    for (final existing in await _readProfiles()) {
      if (existing.kind == SyncDatasetKind.velockManaged &&
          existing.vaultId == approval.vaultId &&
          existing.deviceId == session.request.syncAppInstanceId) {
        throw const VelockProfileFinalizationException('duplicate_pairing');
      }
    }

    final profile = VelockSyncProfile(
      profileId: _requiredGeneratedId(_nextId(), 'profile_id_unavailable'),
      datasetId: approval.vaultId,
      vaultId: approval.vaultId,
      deviceId: session.request.syncAppInstanceId,
      displayName: normalizedDisplayName,
      connectionId: connection.id,
      pairedProducerId: approval.producerId,
      pairedProducerPublicKeyId: approval.producerPublicKeyId,
      exchangeBindingId: approval.exchangeBindingId,
      trustedProducerIds: approval.trustedProducerIds ?? [approval.producerId],
      backgroundPolicy: backgroundPolicy,
      state: SyncProfileState.active,
      createdAt: _now().toUtc(),
    );

    // Retaining the verified public key before the profile is safe: without a
    // profile an orphan key grants no dataset access, while a saved profile
    // must never lose the key needed to verify Velock batches and receipts.
    await _retainProducerTrust(
      vaultId: approval.vaultId,
      producerId: approval.producerId,
      signingPublicKey: Uint8List.fromList(session.descriptor.publicKey.bytes),
    );
    await _saveProfile(profile.toEnvelope());
    try {
      await _pairing.acknowledge(session);
      return VelockProfileFinalizationResult(
        profile: profile,
        pairingAcknowledged: true,
      );
    } on Object {
      return VelockProfileFinalizationResult(
        profile: profile,
        pairingAcknowledged: false,
      );
    }
  }

  @override
  Future<bool> retryAcknowledgement(VelockPairingSession session) async {
    try {
      await _pairing.acknowledge(session);
      return true;
    } on Object {
      return false;
    }
  }
}

String _requiredGeneratedId(String value, String code) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw VelockProfileFinalizationException(code);
  }
  return normalized;
}
