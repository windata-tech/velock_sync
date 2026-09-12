import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

/// Immutable, non-secret configuration for a Velock-managed dataset.
///
/// The pairing fields identify an already trusted Velock producer and its
/// dedicated exchange binding. They are identifiers only: this profile never
/// stores a Velock key, an authorization credential, or an Exchange path.
class VelockSyncProfile {
  VelockSyncProfile({
    required this.profileId,
    required this.datasetId,
    required this.vaultId,
    required this.deviceId,
    required this.displayName,
    required this.connectionId,
    required this.pairedProducerId,
    required this.pairedProducerPublicKeyId,
    required this.exchangeBindingId,
    List<String>? trustedProducerIds,
    required this.backgroundPolicy,
    required this.state,
    required this.createdAt,
  }) : trustedProducerIds = _canonicalTrustedProducerIds(
         trustedProducerIds ?? [pairedProducerId],
         pairedProducerId: pairedProducerId,
       );

  final String profileId;
  final String datasetId;
  final String vaultId;
  final String deviceId;
  final String displayName;
  final String connectionId;
  final String pairedProducerId;
  final String pairedProducerPublicKeyId;
  final String exchangeBindingId;

  /// Remote producer IDs this profile may download. The paired producer is
  /// always included; restored cards can authorize previous iPhones too.
  final List<String> trustedProducerIds;
  final SyncProfileBackgroundPolicy backgroundPolicy;
  final SyncProfileState state;
  final DateTime createdAt;

  SyncProfileEnvelope toEnvelope() {
    _validate();
    return SyncProfileEnvelope(
      kind: SyncDatasetKind.velockManaged,
      profileId: profileId,
      datasetId: datasetId,
      vaultId: vaultId,
      deviceId: deviceId,
      displayName: displayName,
      connectionId: connectionId,
      state: state,
      backgroundPolicy: backgroundPolicy,
      dataset: {
        'pairedProducerId': pairedProducerId,
        'pairedProducerPublicKeyId': pairedProducerPublicKeyId,
        'exchangeBindingId': exchangeBindingId,
        'trustedProducerIds': trustedProducerIds,
      },
      createdAt: createdAt.toUtc(),
    );
  }

  VelockSyncProfile copyWith({SyncProfileState? state}) => VelockSyncProfile(
    profileId: profileId,
    datasetId: datasetId,
    vaultId: vaultId,
    deviceId: deviceId,
    displayName: displayName,
    connectionId: connectionId,
    pairedProducerId: pairedProducerId,
    pairedProducerPublicKeyId: pairedProducerPublicKeyId,
    exchangeBindingId: exchangeBindingId,
    trustedProducerIds: trustedProducerIds,
    backgroundPolicy: backgroundPolicy,
    state: state ?? this.state,
    createdAt: createdAt,
  );

  factory VelockSyncProfile.fromEnvelope(SyncProfileEnvelope envelope) {
    if (envelope.kind != SyncDatasetKind.velockManaged) {
      throw const FormatException('Sync profile is not a Velock profile.');
    }
    const requiredDatasetFields = {
      'pairedProducerId',
      'pairedProducerPublicKeyId',
      'exchangeBindingId',
    };
    const allowedDatasetFields = {
      ...requiredDatasetFields,
      'trustedProducerIds',
    };
    if (!envelope.dataset.keys.toSet().containsAll(requiredDatasetFields) ||
        envelope.dataset.keys.any(
          (key) => !allowedDatasetFields.contains(key),
        )) {
      throw const FormatException('Velock profile payload is invalid.');
    }
    final profile = VelockSyncProfile(
      profileId: envelope.profileId,
      datasetId: envelope.datasetId,
      vaultId: envelope.vaultId,
      deviceId: envelope.deviceId,
      displayName: envelope.displayName,
      connectionId: envelope.connectionId,
      pairedProducerId: _requiredDatasetString(envelope, 'pairedProducerId'),
      pairedProducerPublicKeyId: _requiredDatasetString(
        envelope,
        'pairedProducerPublicKeyId',
      ),
      exchangeBindingId: _requiredDatasetString(envelope, 'exchangeBindingId'),
      trustedProducerIds: _trustedProducerIdsFromEnvelope(envelope),
      backgroundPolicy: envelope.backgroundPolicy,
      state: envelope.state,
      createdAt: envelope.createdAt,
    );
    profile._validate();
    return profile;
  }

  static String _requiredDatasetString(
    SyncProfileEnvelope envelope,
    String key,
  ) {
    final value = envelope.dataset[key];
    if (value is! String || value.isEmpty) {
      throw const FormatException('Velock profile pairing field is invalid.');
    }
    return value;
  }

  static List<String>? _trustedProducerIdsFromEnvelope(
    SyncProfileEnvelope envelope,
  ) {
    final value = envelope.dataset['trustedProducerIds'];
    if (value == null) return null; // Legacy profile: paired producer only.
    if (value is! List ||
        value.isEmpty ||
        value.any((item) => item is! String)) {
      throw const FormatException(
        'Velock profile trusted producers are invalid.',
      );
    }
    return value.cast<String>();
  }

  static List<String> _canonicalTrustedProducerIds(
    Iterable<String> ids, {
    required String pairedProducerId,
  }) {
    final values = ids.toSet().toList()..sort();
    if (values.isEmpty ||
        !values.contains(pairedProducerId) ||
        values.any((value) => value.trim().isEmpty)) {
      throw const FormatException(
        'Velock profile trusted producers are invalid.',
      );
    }
    return List.unmodifiable(values);
  }

  void _validate() {
    for (final value in [
      profileId,
      datasetId,
      vaultId,
      deviceId,
      displayName,
      connectionId,
      pairedProducerId,
      pairedProducerPublicKeyId,
      exchangeBindingId,
    ]) {
      if (value.trim().isEmpty) {
        throw const FormatException('Velock profile field is invalid.');
      }
    }
  }
}
