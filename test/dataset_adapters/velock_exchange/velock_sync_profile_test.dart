import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

void main() {
  test(
    'round-trips a typed Velock profile with lifecycle policy unchanged',
    () {
      final profile = _profile(
        backgroundPolicy: const SyncProfileBackgroundPolicy(
          enabled: true,
          allowCellular: true,
          requiresCharging: true,
          cellularMaxTransferBytes: 123456,
        ),
        state: SyncProfileState.paused,
      );

      final restored = VelockSyncProfile.fromEnvelope(profile.toEnvelope());

      expect(restored.profileId, profile.profileId);
      expect(restored.pairedProducerId, profile.pairedProducerId);
      expect(
        restored.pairedProducerPublicKeyId,
        profile.pairedProducerPublicKeyId,
      );
      expect(restored.exchangeBindingId, profile.exchangeBindingId);
      expect(restored.backgroundPolicy.enabled, isTrue);
      expect(restored.backgroundPolicy.allowCellular, isTrue);
      expect(restored.backgroundPolicy.requiresCharging, isTrue);
      expect(restored.backgroundPolicy.cellularMaxTransferBytes, 123456);
      expect(restored.state, SyncProfileState.paused);
      expect(restored.createdAt, DateTime.utc(2026, 7, 17));
      expect(profile.toEnvelope().dataset, {
        'pairedProducerId': 'producer-1',
        'pairedProducerPublicKeyId': 'producer-key-1',
        'exchangeBindingId': 'exchange-1',
      });
    },
  );

  test('rejects a profile envelope with another dataset kind', () {
    final envelope = _profile().toEnvelope();
    final wrongKind = SyncProfileEnvelope(
      kind: SyncDatasetKind.selectedFolder,
      profileId: envelope.profileId,
      datasetId: envelope.datasetId,
      vaultId: envelope.vaultId,
      deviceId: envelope.deviceId,
      displayName: envelope.displayName,
      connectionId: envelope.connectionId,
      state: envelope.state,
      backgroundPolicy: envelope.backgroundPolicy,
      dataset: envelope.dataset,
      createdAt: envelope.createdAt,
    );

    expect(
      () => VelockSyncProfile.fromEnvelope(wrongKind),
      throwsFormatException,
    );
  });

  test('rejects missing or extra pairing payload fields', () {
    final envelope = _profile().toEnvelope();
    final missing = SyncProfileEnvelope(
      kind: envelope.kind,
      profileId: envelope.profileId,
      datasetId: envelope.datasetId,
      vaultId: envelope.vaultId,
      deviceId: envelope.deviceId,
      displayName: envelope.displayName,
      connectionId: envelope.connectionId,
      state: envelope.state,
      backgroundPolicy: envelope.backgroundPolicy,
      dataset: const {
        'pairedProducerId': 'producer-1',
        'exchangeBindingId': 'exchange-1',
      },
      createdAt: envelope.createdAt,
    );
    final extra = SyncProfileEnvelope(
      kind: envelope.kind,
      profileId: envelope.profileId,
      datasetId: envelope.datasetId,
      vaultId: envelope.vaultId,
      deviceId: envelope.deviceId,
      displayName: envelope.displayName,
      connectionId: envelope.connectionId,
      state: envelope.state,
      backgroundPolicy: envelope.backgroundPolicy,
      dataset: const {
        'pairedProducerId': 'producer-1',
        'pairedProducerPublicKeyId': 'producer-key-1',
        'exchangeBindingId': 'exchange-1',
        'syncKey': 'must-never-be-persisted',
      },
      createdAt: envelope.createdAt,
    );

    expect(
      () => VelockSyncProfile.fromEnvelope(missing),
      throwsFormatException,
    );
    expect(() => VelockSyncProfile.fromEnvelope(extra), throwsFormatException);
  });

  test('rejects blank identity fields before persistence', () {
    expect(
      () => _profile(pairedProducerPublicKeyId: ' ').toEnvelope(),
      throwsFormatException,
    );
  });
}

VelockSyncProfile _profile({
  String pairedProducerPublicKeyId = 'producer-key-1',
  SyncProfileBackgroundPolicy backgroundPolicy =
      const SyncProfileBackgroundPolicy(),
  SyncProfileState state = SyncProfileState.accessRequired,
}) => VelockSyncProfile(
  profileId: 'profile-1',
  datasetId: 'dataset-1',
  vaultId: 'vault-1',
  deviceId: 'device-1',
  displayName: 'Velock vault',
  connectionId: 'connection-1',
  pairedProducerId: 'producer-1',
  pairedProducerPublicKeyId: pairedProducerPublicKeyId,
  exchangeBindingId: 'exchange-1',
  backgroundPolicy: backgroundPolicy,
  state: state,
  createdAt: DateTime.utc(2026, 7, 17),
);
