import 'dart:developer';

import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

Future<void> main() async {
  log('db');
  final db = await SyncStateDatabase.inMemory();
  final repo = SyncProfileRepository(db);
  final profile = SyncProfileEnvelope(
    kind: SyncDatasetKind.selectedFolder,
    profileId: 'a',
    datasetId: 'd',
    vaultId: 'v',
    deviceId: 'dev',
    displayName: 'd',
    connectionId: 'c',
    state: SyncProfileState.active,
    backgroundPolicy: const SyncProfileBackgroundPolicy(),
    dataset: const {
      'rootKeyRef': 'secure/root',
      'signingKeyRef': 'secure/signing',
    },
    createdAt: DateTime.utc(2026, 7, 17),
  );
  log('save');
  await repo.save(profile);
  log('read');
  final p = await repo.read('a');
  log('${p?.profileId}');
  log('dispatcher');
  final result = await SyncProfileDispatcher(
    profiles: repo,
    executors: [_E()],
  ).dispatch('a');
  log('${result.status}');
  await db.close();
}

class _E implements SyncProfileExecutor {
  @override
  SyncDatasetKind get kind => SyncDatasetKind.selectedFolder;
  @override
  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request) async {
    log('executor');
    return const SyncProfileRunResult(
      runId: 'r',
      upload: UploadRunResult.idle(),
      download: DownloadRunResult(0),
    );
  }
}
