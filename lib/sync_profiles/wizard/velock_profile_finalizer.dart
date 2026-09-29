import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
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
typedef VelockProfileReader =
    Future<SyncProfileEnvelope?> Function(String profileId);

/// Atomically retires [expected] and saves [replacement]; changes nothing on
/// failure.
typedef VelockProfileReplacer =
    Future<void> Function({
      required SyncProfileEnvelope expected,
      required SyncProfileEnvelope replacement,
    });

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
    List<String> remoteRootSegments = const [],
    bool restoring = false,
    String? replacingProfileId,
  });

  Future<bool> retryAcknowledgement(VelockPairingSession session);
}

/// Turns one already-approved control-plane session into a durable profile.
///
/// The signed approval is verified again at this final trust boundary. The
/// profile is saved before acknowledgement so a failed ACK can never consume
/// the one-time response while leaving no usable local profile.
///
/// Re-pairing passes `replacingProfileId`. The existing profile then stays
/// untouched until this final step, which retires it and saves the new one in
/// a single transaction. The new profile keeps the original cloud location;
/// any failure before or during that step leaves the original profile as it
/// was.
class VelockProfileFinalizationService implements VelockProfileFinalizer {
  VelockProfileFinalizationService({
    required VelockProfileSaver saveProfile,
    required VelockProducerTrustSaver retainProducerTrust,
    required VelockProfileSummaryReader readProfiles,
    required VelockConnectionReader readConnection,
    required VelockPairingSessionService pairing,
    VelockProfileReader? readProfile,
    VelockProfileReplacer? replaceProfile,
    String Function()? nextId,
    DateTime Function()? now,
  }) : _saveProfile = saveProfile,
       _readProfile = readProfile,
       _replaceProfile = replaceProfile,
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
  final VelockProfileReader? _readProfile;
  final VelockProfileReplacer? _replaceProfile;
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
    List<String> remoteRootSegments = const [],
    bool restoring = false,
    String? replacingProfileId,
  }) async {
    if (!userConfirmed) {
      throw const VelockProfileFinalizationException('confirmation_required');
    }
    final List<String> normalizedRemoteRootSegments;
    try {
      normalizedRemoteRootSegments =
          VelockSyncProfile.canonicalRemoteRootSegments(remoteRootSegments);
    } on FormatException {
      throw const VelockProfileFinalizationException(
        'invalid_remote_root_segments',
      );
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
    if (normalizedRemoteRootSegments.isNotEmpty &&
        connection.protocol is! WebDavProtocolModel) {
      throw const VelockProfileFinalizationException(
        'invalid_remote_root_segments',
      );
    }

    final replaced = replacingProfileId == null
        ? null
        : await _replacedProfile(
            replacingProfileId,
            vaultId: approval.vaultId,
            connectionId: connection.id,
            remoteRootSegments: normalizedRemoteRootSegments,
          );

    for (final existing in await _readProfiles()) {
      // The profile being replaced is retired by this very save.
      if (existing.profileId == replaced?.envelope.profileId) continue;
      if (existing.kind == SyncDatasetKind.velockManaged &&
          existing.vaultId == approval.vaultId &&
          existing.deviceId == session.request.syncAppInstanceId) {
        throw const VelockProfileFinalizationException('duplicate_pairing');
      }
    }

    // Connection/database reads may outlive the one-time approval. Check again
    // immediately before persisting any trust or profile, not just on entry.
    if (!await approval.verify(
      descriptor: session.descriptor,
      request: session.request,
      now: _now,
    )) {
      throw const VelockProfileFinalizationException(
        'invalid_pairing_response',
      );
    }

    final previous = replaced?.profile;
    final trustedProducerIds =
        approval.trustedProducerIds ?? [approval.producerId];
    // A restore that was still pending must finish before any upload. Its
    // request is bound to the old pairing key/binding, so it cannot be reused:
    // rediscover from the same folder instead. A settled snapshot reference is
    // kept only while the new approval still trusts its producer (every run
    // verifies it again); otherwise it is rediscovered under the new trust.
    final restorePending =
        restoring ||
        (previous != null &&
            (previous.snapshotDiscoveryPending ||
                previous.snapshotRestoreRequestId != null ||
                (previous.currentSnapshotProducerId != null &&
                    !trustedProducerIds.contains(
                      previous.currentSnapshotProducerId,
                    ))));
    final keepSnapshot = previous != null && !restorePending;
    final profileId = _requiredGeneratedId(_nextId(), 'profile_id_unavailable');
    if (profileId == replaced?.envelope.profileId) {
      throw const VelockProfileFinalizationException('profile_id_unavailable');
    }
    final profile = VelockSyncProfile(
      profileId: profileId,
      datasetId: approval.vaultId,
      vaultId: approval.vaultId,
      deviceId: session.request.syncAppInstanceId,
      displayName: normalizedDisplayName,
      connectionId: connection.id,
      pairedProducerId: approval.producerId,
      pairedProducerPublicKeyId: approval.producerPublicKeyId,
      exchangeBindingId: approval.exchangeBindingId,
      trustedProducerIds: trustedProducerIds,
      remoteRootSegments: normalizedRemoteRootSegments,
      snapshotDiscoveryPending: restorePending,
      currentSnapshotId: keepSnapshot ? previous.currentSnapshotId : null,
      currentSnapshotProducerId: keepSnapshot
          ? previous.currentSnapshotProducerId
          : null,
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
    // Trust retention can await storage too. The one-time approval must still
    // be valid when the durable profile save is initiated. Once saved, its
    // durable grant (and ACK retry) does not expire with the pairing response.
    if (!await approval.verify(
      descriptor: session.descriptor,
      request: session.request,
      now: _now,
    )) {
      throw const VelockProfileFinalizationException(
        'invalid_pairing_response',
      );
    }
    if (replaced == null) {
      await _saveProfile(profile.toEnvelope());
    } else {
      try {
        await _replaceProfile!(
          expected: replaced.envelope,
          replacement: profile.toEnvelope(),
        );
      } on SyncRunBusyException {
        throw const VelockProfileFinalizationException('replaced_profile_busy');
      } on StateError {
        throw const VelockProfileFinalizationException(
          'replaced_profile_changed',
        );
      }
    }
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

  /// The profile a re-pairing replaces, validated before anything is saved.
  Future<({SyncProfileEnvelope envelope, VelockSyncProfile profile})>
  _replacedProfile(
    String profileId, {
    required String vaultId,
    required String connectionId,
    required List<String> remoteRootSegments,
  }) async {
    final read = _readProfile;
    if (read == null || _replaceProfile == null) {
      throw const VelockProfileFinalizationException('replacement_unavailable');
    }
    final envelope = await read(profileId);
    // Removed profiles are not readable; that includes one already replaced.
    if (envelope == null || envelope.kind != SyncDatasetKind.velockManaged) {
      throw const VelockProfileFinalizationException(
        'replaced_profile_missing',
      );
    }
    final VelockSyncProfile profile;
    try {
      profile = VelockSyncProfile.fromEnvelope(envelope);
    } on FormatException {
      throw const VelockProfileFinalizationException(
        'replaced_profile_missing',
      );
    }
    // Re-pairing continues the same account in the same folder. Another
    // account, connection or folder is a new setup, not a replacement.
    if (profile.vaultId != vaultId) {
      throw const VelockProfileFinalizationException(
        'replacement_vault_mismatch',
      );
    }
    if (profile.connectionId != connectionId ||
        !_sameSegments(profile.remoteRootSegments, remoteRootSegments)) {
      throw const VelockProfileFinalizationException(
        'replacement_location_mismatch',
      );
    }
    return (envelope: envelope, profile: profile);
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

bool _sameSegments(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

String _requiredGeneratedId(String value, String code) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw VelockProfileFinalizationException(code);
  }
  return normalized;
}
