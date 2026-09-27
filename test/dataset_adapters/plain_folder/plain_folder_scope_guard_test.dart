/// A plaintext mirror must never be pointed at a Velock backup's folder.
///
/// The mirror treats every remote file as user data: over a backup folder it
/// would upload, download and (once a baseline exists) delete the encrypted
/// objects the Velock app needs to restore. Equal, ancestor and descendant
/// scopes are all refused, on the same connection only, and case differences do
/// not count as different folders.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

Future<SyncStateDatabase> _database() => SyncStateDatabase.inMemory();

SyncProfileEnvelope _backup({
  required String profileId,
  required List<String> segments,
  String connectionId = 'cloud',
  String displayName = '我的格间备份',
}) => VelockSyncProfile(
  profileId: profileId,
  datasetId: 'dataset-$profileId',
  vaultId: 'vault-$profileId',
  deviceId: 'device-$profileId',
  displayName: displayName,
  connectionId: connectionId,
  pairedProducerId: 'producer',
  pairedProducerPublicKeyId: 'key',
  exchangeBindingId: 'binding',
  remoteRootSegments: segments,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  state: SyncProfileState.active,
  createdAt: DateTime.utc(2026, 9, 27),
).toEnvelope();

void main() {
  test('equality, ancestors and descendants are refused', () async {
    final database = await _database();
    addTearDown(database.close);
    final backups = SyncProfileRepository(database);
    await backups.save(_backup(profileId: 'b1', segments: const ['USB', '111']));

    for (final scope in <List<String>>[
      const ['USB', '111'],
      const ['USB'],
      const <String>[],
      const ['USB', '111', 'velock-sync'],
    ]) {
      await expectLater(
        assertPlainScopeAvoidsBackups(
          backups: backups,
          connectionId: 'cloud',
          segments: scope,
        ),
        throwsA(isA<BackupFolderOverlapException>()),
        reason: 'scope $scope overlaps the backup folder',
      );
    }
  });

  test('case differences still count as the same folder', () async {
    final database = await _database();
    addTearDown(database.close);
    final backups = SyncProfileRepository(database);
    await backups.save(_backup(profileId: 'b1', segments: const ['USB_HDD_8T']));

    await expectLater(
      assertPlainScopeAvoidsBackups(
        backups: backups,
        connectionId: 'cloud',
        segments: const ['usb_hdd_8t', 'photos'],
      ),
      throwsA(isA<BackupFolderOverlapException>()),
    );
  });

  test('other folders and other connections stay usable', () async {
    final database = await _database();
    addTearDown(database.close);
    final backups = SyncProfileRepository(database);
    await backups.save(_backup(profileId: 'b1', segments: const ['USB', '111']));

    // A sibling folder.
    await assertPlainScopeAvoidsBackups(
      backups: backups,
      connectionId: 'cloud',
      segments: const ['USB', '222'],
    );
    // The same path on a different connection is a different server folder.
    await assertPlainScopeAvoidsBackups(
      backups: backups,
      connectionId: 'other-connection',
      segments: const ['USB', '111'],
    );
  });

  test('a deleted backup no longer blocks its old folder', () async {
    final database = await _database();
    addTearDown(database.close);
    final backups = SyncProfileRepository(database);
    await backups.save(_backup(profileId: 'b1', segments: const ['USB', '111']));
    await backups.remove('b1', forceRunning: true);

    await assertPlainScopeAvoidsBackups(
      backups: backups,
      connectionId: 'cloud',
      segments: const ['USB', '111'],
    );
  });

  test('the guard reports the backup it collided with', () async {
    final database = await _database();
    addTearDown(database.close);
    final backups = SyncProfileRepository(database);
    await backups.save(
      _backup(
        profileId: 'b1',
        segments: const ['USB'],
        displayName: 'test1 的 Velock',
      ),
    );

    await expectLater(
      assertPlainScopeAvoidsBackups(
        backups: backups,
        connectionId: 'cloud',
        segments: const ['USB'],
      ),
      throwsA(
        isA<BackupFolderOverlapException>().having(
          (error) => error.backupName,
          'backupName',
          'test1 的 Velock',
        ),
      ),
    );
  });
  test('two plain locations may not cover each other', () async {
    final database = await _database();
    addTearDown(database.close);
    final profiles = PlainFolderSyncProfileRepository(database);
    await profiles.save(
      PlainFolderSyncProfile(
        profileId: 'plain-a',
        datasetId: 'dataset-a',
        deviceId: 'device',
        displayName: '照片',
        localRootReference: '/tmp/photos',
        localDisplayName: '照片',
        connectionId: 'cloud',
        remoteRootSegments: const ['USB', '111'],
        createdAt: DateTime.utc(2026, 9, 27),
      ),
    );

    // The same local folder bound twice to an overlapping remote scope is what
    // the guard exists for.
    for (final scope in <List<String>>[
      const ['USB', '111'],
      const ['USB'],
      const ['USB', '111', 'inner'],
    ]) {
      await expectLater(
        assertPlainScopeAvoidsOtherLocations(
          profiles: profiles,
          connectionId: 'cloud',
          segments: scope,
          localRootReference: '/tmp/photos',
        ),
        throwsA(
          isA<PlainLocationOverlapException>().having(
            (error) => error.existingDisplayName,
            'existingDisplayName',
            '照片',
          ),
        ),
      );
    }

    // A sibling folder is fine, and so is the same path on another connection.
    await assertPlainScopeAvoidsOtherLocations(
      profiles: profiles,
      connectionId: 'cloud',
      segments: const ['USB', '222'],
      localRootReference: '/tmp/photos',
    );
    // Exactly the same remote folder from a DIFFERENT local folder stays
    // allowed: that is the documented multi-device / two-local-folders usage.
    await assertPlainScopeAvoidsOtherLocations(
      profiles: profiles,
      connectionId: 'cloud',
      segments: const ['USB', '111'],
      localRootReference: '/tmp/other-device',
    );
    // One scope inside another is refused even when the local folders differ:
    // both locations would mirror each other's files.
    await expectLater(
      assertPlainScopeAvoidsOtherLocations(
        profiles: profiles,
        connectionId: 'cloud',
        segments: const ['USB', '111', 'inner'],
        localRootReference: '/tmp/other-device',
      ),
      throwsA(isA<PlainLocationOverlapException>()),
    );
    await assertPlainScopeAvoidsOtherLocations(
      profiles: profiles,
      connectionId: 'other',
      segments: const ['USB', '111'],
    );

    // Re-saving the same location is never blocked by itself, and a Velock
    // backup scope is not this guard's business.
    await assertPlainScopeAvoidsOtherLocations(
      profiles: profiles,
      connectionId: 'cloud',
      segments: const ['USB', '111'],
      selfProfileId: 'plain-a',
    );
    expect(await profiles.list(), hasLength(1));
  });

}
