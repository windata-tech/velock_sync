import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile_executor.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  test(
    'dispatcher selects the Velock executor and forwards only profile ID and limits',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final profiles = SyncProfileRepository(database);
      await profiles.save(_velockProfile());
      final service = _RecordingVelockRunner();
      final dispatcher = SyncProfileDispatcher(
        profiles: profiles,
        executors: [VelockSyncProfileExecutor(service)],
      );
      const uploadLimits = BatchLimits(maxCipherBytes: 1234);
      const downloadLimits = DownloadLimits(maxEnvelopeBytes: 5678);

      final result = await dispatcher.dispatch(
        'velock-profile',
        uploadLimits: uploadLimits,
        downloadLimits: downloadLimits,
      );

      expect(result.status, SyncProfileDispatchStatus.completed);
      expect(service.profileIds, ['velock-profile']);
      expect(service.uploadLimits, [uploadLimits]);
      expect(service.downloadLimits, [downloadLimits]);
    },
  );
}

class _RecordingVelockRunner implements VelockSyncRunner {
  final List<String> profileIds = [];
  final List<BatchLimits> uploadLimits = [];
  final List<DownloadLimits> downloadLimits = [];

  @override
  Future<SyncProfileRunResult> run(
    String profileId, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
  }) async {
    profileIds.add(profileId);
    this.uploadLimits.add(uploadLimits);
    this.downloadLimits.add(downloadLimits);
    return SyncProfileRunResult(
      runId: 'velock-run',
      upload: UploadRunResult.idle(),
      download: DownloadRunResult(0),
    );
  }
}

SyncProfileEnvelope _velockProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: 'velock-profile',
  datasetId: 'velock-dataset',
  vaultId: 'velock-vault',
  deviceId: 'consumer-device',
  displayName: 'Velock',
  connectionId: 'connection-1',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'schemaVersion': 1,
    'pairedProducerId': 'producer-device',
    'pairedProducerPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  createdAt: DateTime.utc(2026, 7, 17),
);
