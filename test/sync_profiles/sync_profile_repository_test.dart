import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  test('projects profile activity without exposing payload fields', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(_profile('profile-1'));
    await database.startSyncRun(
      runId: 'run-1',
      profileId: 'profile-1',
      startedAt: DateTime.utc(2026, 7, 17),
    );
    await database.finishSyncRun(
      runId: 'run-1',
      state: 'completed',
      completedAt: DateTime.utc(2026, 7, 17, 0, 1),
    );

    final summary = (await repository.listSummaries()).single;

    expect(summary.profileId, 'profile-1');
    expect(summary.displayName, 'Profile profile-1');
    expect(summary.kind, SyncDatasetKind.selectedFolder);
    expect(summary.activity!.latestRun!.runId, 'run-1');
    expect(summary.activity!.latestRun!.state, 'completed');
    expect(summary.isIsolated, isFalse);
  });

  test(
    'isolates malformed and unsupported payloads without deleting them',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SyncProfileRepository(database);
      await repository.save(_profile('valid'));
      await database.upsertSyncProfilePayload(
        profileId: 'unknown-kind',
        datasetId: 'dataset',
        targetId: 'connection',
        vaultId: 'vault',
        state: 'active',
        payload: jsonEncode({
          ..._profile('unknown-kind').toJson(),
          'kind': 'future-kind',
        }),
      );
      await database.upsertSyncProfilePayload(
        profileId: 'malformed',
        datasetId: 'dataset',
        targetId: 'connection',
        vaultId: 'vault',
        state: 'active',
        payload: '{not-json',
      );

      final summaries = await repository.listSummaries();
      final byId = {
        for (final summary in summaries) summary.profileId: summary,
      };

      expect(byId['valid']!.isRunnable, isTrue);
      expect(byId['unknown-kind']!.isIsolated, isTrue);
      expect(byId['unknown-kind']!.isolationReason, 'unsupported');
      expect(byId['malformed']!.isIsolated, isTrue);
      expect(byId['malformed']!.isolationReason, 'invalid');
      expect(await database.readSyncProfilePayload('unknown-kind'), isNotNull);
      expect(await database.readSyncProfilePayload('malformed'), isNotNull);
    },
  );

  test('will not remove a profile while its sync run is active', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(_profile('profile-1'));
    await database.startSyncRun(
      runId: 'run-1',
      profileId: 'profile-1',
      startedAt: DateTime.utc(2026, 7, 17),
    );

    await expectLater(
      repository.remove('profile-1'),
      throwsA(isA<SyncProfileRemovalWhileRunningException>()),
    );
    expect(await repository.read('profile-1'), isNotNull);
  });
}

SyncProfileEnvelope _profile(
  String profileId, {
  SyncProfileState state = SyncProfileState.active,
}) => SyncProfileEnvelope(
  kind: SyncDatasetKind.selectedFolder,
  profileId: profileId,
  datasetId: 'dataset-$profileId',
  vaultId: 'vault-$profileId',
  deviceId: 'device-$profileId',
  displayName: 'Profile $profileId',
  connectionId: 'connection-$profileId',
  state: state,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'rootPath': '/safe/path',
    'rootKeyRef': 'secure/root',
    'signingKeyRef': 'secure/signing',
  },
  createdAt: DateTime.utc(2026, 7, 17),
);
