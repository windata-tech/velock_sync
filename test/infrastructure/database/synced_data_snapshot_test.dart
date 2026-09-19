import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

void main() {
  group('readSyncedDataSnapshot', () {
    late SyncStateDatabase database;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'summarises completed transfers, batches and device cursors',
      () async {
        const profileId = 'profile-1';

        await database.beginTransferJob(
          transferId: 't-upload-blob',
          profileId: profileId,
          direction: TransferJobDirection.upload,
          logicalKey: 'velock-sync/v1/vault/blobs/ab/abcdef.blob',
          expectedSize: 2048,
        );
        await database.completeTransferJob(
          transferId: 't-upload-blob',
          completedBytes: 2048,
        );
        await database.beginTransferJob(
          transferId: 't-download-batch',
          profileId: profileId,
          direction: TransferJobDirection.download,
          logicalKey:
              'velock-sync/v1/vault/devices/d1/batches/0001/b1/envelope.json',
          expectedSize: 512,
        );
        await database.completeTransferJob(
          transferId: 't-download-batch',
          completedBytes: 512,
        );
        await database.beginTransferJob(
          transferId: 't-pending',
          profileId: profileId,
          direction: TransferJobDirection.upload,
          logicalKey: 'velock-sync/v1/vault/devices/d1/commits/0001.commit',
          expectedSize: 128,
        );

        await database.recordIncomingBatch(
          profileId: profileId,
          sourceDeviceId: 'device-a',
          sequence: 1,
          batchId: 'b1',
          state: 'imported',
        );
        await database.recordOutgoingBatch(
          profileId: profileId,
          batchId: 'b2',
          sequence: 1,
          state: 'published',
        );
        await database.advanceAppliedSequence(
          profileId: profileId,
          producerDeviceId: 'device-a',
          sequence: 1,
        );

        final snapshot = await database.readSyncedDataSnapshot(profileId);

        expect(snapshot.isEmpty, isFalse);
        expect(snapshot.uploadedCount, 1);
        expect(snapshot.uploadedBytes, 2048);
        expect(snapshot.downloadedCount, 1);
        expect(snapshot.downloadedBytes, 512);
        expect(snapshot.pendingUploadCount, 1);
        expect(snapshot.appliedIncomingCount, 1);
        expect(snapshot.publishedOutgoingCount, 1);
        expect(snapshot.devices.single.deviceId, 'device-a');
        expect(snapshot.devices.single.appliedSequence, 1);
        expect(snapshot.lastActivityAt, isNotNull);
        expect([
          ...snapshot.uploadedKinds.map((entry) => entry.kind),
          ...snapshot.downloadedKinds.map((entry) => entry.kind),
        ], containsAll(<String>['batches', 'blobs']));
      },
    );

    test('reports an empty snapshot for a profile without activity', () async {
      final snapshot = await database.readSyncedDataSnapshot('missing');

      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.totalBytes, 0);
    });
  });
}
