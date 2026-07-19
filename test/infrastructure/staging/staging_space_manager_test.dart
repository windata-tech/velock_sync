import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';

void main() {
  test(
    'reports staging usage and removes only safe orphan artifacts',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'velock-staging-space-',
      );
      final database = await SyncStateDatabase.inMemory();
      addTearDown(() async {
        await root.delete(recursive: true);
        await database.close();
      });
      final recoverable = Directory('${root.path}/recoverable')..createSync();
      await File('${recoverable.path}/manifest.json').writeAsBytes([1, 2]);
      await File('${recoverable.path}/blob.tmp-crash').writeAsBytes([3, 4, 5]);
      final orphan = Directory('${root.path}/orphan')..createSync();
      await File('${orphan.path}/operations.enc').writeAsBytes([6, 7, 8, 9]);
      final manager = StagingSpaceManager(database);

      final before = await manager.inspect(root);
      final result = await manager.safelyCleanup(
        profileId: 'profile-1',
        profileStagingRoot: root,
      );
      final after = await manager.inspect(root);

      expect(before.totalBytes, 9);
      expect(before.batchCount, 2);
      expect(result.freedBytes, 7);
      expect(result.removedBatchCount, 1);
      expect(result.removedTemporaryFileCount, 1);
      expect(result.preservedRecoverableBatchCount, 1);
      expect(await File('${recoverable.path}/manifest.json').exists(), isTrue);
      expect(await orphan.exists(), isFalse);
      expect(after.totalBytes, 2);
    },
  );

  test('refuses cleanup while the profile has a live sync lock', () async {
    final root = await Directory.systemTemp.createTemp('velock-staging-space-');
    final database = await SyncStateDatabase.inMemory();
    final now = DateTime.utc(2026, 7, 15, 12);
    addTearDown(() async {
      await root.delete(recursive: true);
      await database.close();
    });
    await database.tryAcquireProfileLock(
      profileId: 'profile-1',
      owner: 'running-sync',
      now: now,
      staleAfter: const Duration(minutes: 5),
    );
    final manager = StagingSpaceManager(database, now: () => now);

    await expectLater(
      manager.safelyCleanup(profileId: 'profile-1', profileStagingRoot: root),
      throwsA(isA<StagingMaintenanceBusyException>()),
    );
  });
}
