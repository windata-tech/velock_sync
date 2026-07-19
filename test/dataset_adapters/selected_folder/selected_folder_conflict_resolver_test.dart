import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_conflict_resolver.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  for (final scenario in [
    (
      strategy: ConflictResolutionStrategy.keepLocal,
      expectedTarget: 'local',
      keepsConflictCopy: false,
    ),
    (
      strategy: ConflictResolutionStrategy.keepRemote,
      expectedTarget: 'remote',
      keepsConflictCopy: false,
    ),
    (
      strategy: ConflictResolutionStrategy.keepBoth,
      expectedTarget: 'local',
      keepsConflictCopy: true,
    ),
  ]) {
    test(
      '${scenario.strategy.name} publishes a dominating normal folder revision',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);

        final artifact = await fixture.resolver().resolve(
          conflict: fixture.conflict,
          details: fixture.details,
          strategy: scenario.strategy,
        );

        expect(await fixture.target.readAsString(), scenario.expectedTarget);
        expect(await fixture.conflictCopy.exists(), scenario.keepsConflictCopy);
        expect(fixture.syncCalls, 1);
        expect(
          fixture.pendingPathsAtSync,
          scenario.keepsConflictCopy
              ? containsAll([fixture.targetName, fixture.conflictCopyName])
              : [fixture.targetName],
        );
        final state = await fixture.database.readFolderEntitySyncState(
          datasetId: fixture.profile.datasetId,
          entityId: fixture.conflict.entityId,
        );
        expect(
          state!.versionVector,
          VersionVector({'device-local': 2, 'device-remote': 1}),
        );
        expect(
          artifact.value,
          'selected-folder:${fixture.profile.profileId}:published-1',
        );
      },
    );
  }

  for (final scenario in [
    (
      strategy: ConflictResolutionStrategy.keepLocal,
      targetExists: true,
      preservedCopyCount: 0,
      expectedTombstone: false,
    ),
    (
      strategy: ConflictResolutionStrategy.keepRemote,
      targetExists: false,
      preservedCopyCount: 0,
      expectedTombstone: true,
    ),
    (
      strategy: ConflictResolutionStrategy.keepBoth,
      targetExists: false,
      preservedCopyCount: 1,
      expectedTombstone: true,
    ),
  ]) {
    test(
      'incoming delete ${scenario.strategy.name} publishes durable semantics',
      () async {
        final fixture = await _Fixture.create(incomingDelete: true);
        addTearDown(fixture.dispose);

        await fixture.resolver().resolve(
          conflict: fixture.conflict,
          details: fixture.details,
          strategy: scenario.strategy,
        );

        expect(await fixture.target.exists(), scenario.targetExists);
        final preserved = await fixture.root
            .list()
            .where((entry) => entry.path.contains('.velock-conflict-local-'))
            .toList();
        expect(preserved, hasLength(scenario.preservedCopyCount));
        if (preserved.isNotEmpty) {
          expect(await File(preserved.single.path).readAsString(), 'local');
        }
        final state = await fixture.database.readFolderEntitySyncState(
          datasetId: fixture.profile.datasetId,
          entityId: fixture.conflict.entityId,
        );
        expect(state!.isTombstone, scenario.expectedTombstone);
        expect(
          state.versionVector,
          VersionVector({'device-local': 2, 'device-remote': 1}),
        );
      },
    );
  }

  test(
    'accepts an already-published delete after a pre-completion crash',
    () async {
      final fixture = await _Fixture.create(incomingDelete: true);
      addTearDown(fixture.dispose);
      final resolver = fixture.resolver();

      final first = await resolver.resolve(
        conflict: fixture.conflict,
        details: fixture.details,
        strategy: ConflictResolutionStrategy.keepRemote,
      );
      final recovered = await resolver.resolve(
        conflict: fixture.conflict,
        details: fixture.details,
        strategy: ConflictResolutionStrategy.keepRemote,
      );

      expect(fixture.syncCalls, 1);
      expect(recovered.value, first.value);
      expect(await fixture.target.exists(), isFalse);
    },
  );

  test(
    'a failed publication remains queued and resumes without the conflict copy',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final first = fixture.resolver(publish: false);

      await expectLater(
        first.resolve(
          conflict: fixture.conflict,
          details: fixture.details,
          strategy: ConflictResolutionStrategy.keepRemote,
        ),
        throwsA(
          isA<ConflictResolutionFailure>().having(
            (error) => error.code,
            'code',
            'selected-folder-resolution-not-published',
          ),
        ),
      );

      expect(await fixture.target.readAsString(), 'remote');
      expect(await fixture.conflictCopy.exists(), isFalse);
      var state = await fixture.database.readFolderEntitySyncState(
        datasetId: fixture.profile.datasetId,
        entityId: fixture.conflict.entityId,
      );
      expect(
        state!.versionVector,
        VersionVector({'device-local': 1, 'device-remote': 1}),
      );

      final artifact = await fixture.resolver().resolve(
        conflict: fixture.conflict,
        details: fixture.details,
        strategy: ConflictResolutionStrategy.keepRemote,
      );

      state = await fixture.database.readFolderEntitySyncState(
        datasetId: fixture.profile.datasetId,
        entityId: fixture.conflict.entityId,
      );
      expect(
        state!.versionVector,
        VersionVector({'device-local': 2, 'device-remote': 1}),
      );
      expect(artifact.value, contains('published-2'));
      expect(fixture.syncCalls, 2);
    },
  );

  test(
    'durable service leaves failed publication unresolved and completes retry',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.database.recordFolderConflict(
        conflictId: fixture.conflict.conflictId,
        profileId: fixture.profile.profileId,
        entityId: fixture.conflict.entityId,
        sourceDeviceId: fixture.conflict.sourceDeviceId!,
        localRevisionId: fixture.details.localRevisionId,
        incomingRevisionId: fixture.details.incomingRevisionId,
        type: 'modify-modify',
        protectedDetails: jsonEncode({
          'version': 1,
          'target': fixture.details.target,
          if (fixture.details.incomingConflictCopy != null)
            'incomingConflictCopy': fixture.details.incomingConflictCopy,
          'entryType': fixture.details.entryType,
          'localRevisionId': fixture.details.localRevisionId,
          'incomingRevisionId': fixture.details.incomingRevisionId,
          'localVector': fixture.details.localVector,
          'incomingVector': fixture.details.incomingVector,
          'incomingWasDelete': fixture.details.incomingWasDelete,
        }),
      );

      final failed = await fixture
          .service(publish: false)
          .resolve(
            conflictId: fixture.conflict.conflictId,
            strategy: ConflictResolutionStrategy.keepRemote,
          );
      expect(failed.status, ConflictResolutionStatus.failed);
      expect(
        await fixture.database.readUnresolvedConflict(
          fixture.conflict.conflictId,
        ),
        isNotNull,
      );

      final recovered = await fixture.service().resolve(
        conflictId: fixture.conflict.conflictId,
        strategy: ConflictResolutionStrategy.keepRemote,
      );
      expect(recovered.status, ConflictResolutionStatus.completed);
      expect(
        await fixture.database.readUnresolvedConflict(
          fixture.conflict.conflictId,
        ),
        isNull,
      );
      final intent = await fixture.database.readConflictResolutionIntent(
        fixture.conflict.conflictId,
      );
      expect(intent!.state, ConflictResolutionIntentState.completed);
      expect(intent.receiptArtifact, contains('published-2'));
    },
  );
}

class _Fixture {
  _Fixture._({
    required this.database,
    required this.profiles,
    required this.root,
    required this.profile,
    required this.target,
    required this.conflictCopy,
    required this.conflict,
    required this.details,
  });

  final SyncStateDatabase database;
  final SelectedFolderSyncProfileRepository profiles;
  final Directory root;
  final SelectedFolderSyncProfile profile;
  final File target;
  final File conflictCopy;
  final SyncConflictRecord conflict;
  final SelectedFolderConflictDetails details;
  int syncCalls = 0;
  List<String> pendingPathsAtSync = const [];

  String get targetName => 'note.txt';
  String get conflictCopyName => '$targetName.velock-conflict-copy';

  static Future<_Fixture> create({bool incomingDelete = false}) async {
    final database = await SyncStateDatabase.inMemory();
    final profiles = SelectedFolderSyncProfileRepository(database);
    final root = await Directory.systemTemp.createTemp(
      'selected-conflict-resolver-',
    );
    final target = File('${root.path}/note.txt');
    final conflictCopy = File('${root.path}/note.txt.velock-conflict-copy');
    await target.writeAsString('local', flush: true);
    if (!incomingDelete) {
      await conflictCopy.writeAsString('remote', flush: true);
    }
    final profile = SelectedFolderSyncProfile(
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-local',
      displayName: 'Folder',
      rootPath: root.path,
      connectionId: 'connection-1',
      keyId: 'key-1',
      rootKeyRef: 'secure-root-ref',
      signingKeyRef: 'secure-signing-ref',
      createdAt: DateTime.utc(2026, 7, 18),
    );
    await profiles.save(profile);
    final stat = await target.stat();
    await database.upsertFolderScanEntries(
      datasetId: profile.datasetId,
      entries: [
        FolderScanEntry(
          entityId: 'entity-1',
          relativePath: 'note.txt',
          type: FolderEntryType.file,
          size: stat.size,
          modifiedAt: stat.modified.toUtc(),
          scanGeneration: 1,
        ),
      ],
    );
    await database.upsertFolderEntitySyncState(
      datasetId: profile.datasetId,
      entityId: 'entity-1',
      revisionId: 'local-revision',
      versionVector: VersionVector({'device-local': 1}),
      isTombstone: false,
    );
    return _Fixture._(
      database: database,
      profiles: profiles,
      root: root,
      profile: profile,
      target: target,
      conflictCopy: conflictCopy,
      conflict: SyncConflictRecord(
        conflictId: 'conflict-1',
        profileId: profile.profileId,
        entityId: 'entity-1',
        sourceDeviceId: 'device-remote',
        type: incomingDelete
            ? 'delete-modify:local-revision:incoming-revision'
            : 'modify-modify:local-revision:incoming-revision',
        protectedDetails: null,
        createdAt: DateTime.utc(2026, 7, 18),
      ),
      details: SelectedFolderConflictDetails(
        target: 'note.txt',
        incomingConflictCopy: incomingDelete
            ? null
            : 'note.txt.velock-conflict-copy',
        incomingWasDelete: incomingDelete,
        entryType: 'file',
        localRevisionId: 'local-revision',
        incomingRevisionId: 'incoming-revision',
        localVector: const {'device-local': 1},
        incomingVector: const {'device-remote': 1},
      ),
    );
  }

  DurableSelectedFolderConflictResolver resolver({bool publish = true}) =>
      DurableSelectedFolderConflictResolver(
        database: database,
        profiles: profiles,
        sync: (profileId) async {
          syncCalls += 1;
          expect(profileId, profile.profileId);
          final pending = await database.readPendingFolderScanEntries(
            datasetId: profile.datasetId,
          );
          pendingPathsAtSync = pending
              .map((entry) => entry.relativePath)
              .toList(growable: false);
          if (!publish) return;
          for (final entry in pending) {
            final state = await database.readFolderEntitySyncState(
              datasetId: profile.datasetId,
              entityId: entry.entityId,
            );
            await database.upsertFolderEntitySyncState(
              datasetId: profile.datasetId,
              entityId: entry.entityId,
              revisionId: entry.entityId == conflict.entityId
                  ? 'published-$syncCalls'
                  : 'copy-published-$syncCalls',
              versionVector: (state?.versionVector ?? VersionVector(const {}))
                  .incremented(profile.deviceId),
              isTombstone: entry.deletedAt != null,
            );
          }
          await database.clearFolderPendingChanges(
            datasetId: profile.datasetId,
            entityIds: pending.map((entry) => entry.entityId),
            generation: pending
                .map((entry) => entry.pendingGeneration ?? 0)
                .fold(0, (maximum, value) => value > maximum ? value : maximum),
          );
        },
      );

  DurableConflictResolutionService service({bool publish = true}) =>
      DurableConflictResolutionService(
        database: database,
        profiles: SyncProfileRepository(database),
        selectedFolderResolver: resolver(publish: publish),
        velockOpener: const FailClosedVelockConflictOpener(),
        velockReceiptVerifier: const RejectingVelockConflictReceiptVerifier(),
      );

  Future<void> dispose() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
