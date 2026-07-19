import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

void main() {
  test(
    'stores a Selected Folder sync profile with opaque key references only',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SelectedFolderSyncProfileRepository(database);
      final profile = SelectedFolderSyncProfile(
        profileId: 'profile-1',
        datasetId: 'dataset-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        displayName: 'Documents',
        rootPath: '/safe/documents',
        connectionId: 'connection-1',
        keyId: 'key-1',
        rootKeyRef: 'velock-sync/vault-root/opaque',
        signingKeyRef: 'velock-sync/device-signing/opaque',
        createdAt: DateTime.utc(2026, 7, 15),
      );

      await repository.save(profile);

      expect(await repository.read('profile-1'), isNotNull);
      expect(
        (await repository.read('profile-1'))!.rootKeyRef,
        'velock-sync/vault-root/opaque',
      );
      expect(
        await database.readSyncProfilePayload('profile-1'),
        isNot(contains('root-key-bytes')),
      );
      expect(
        (await repository.read('profile-1'))!.accessKind,
        FolderAccessKind.localPath,
      );
    },
  );

  test('upgrades a legacy flat profile to a typed envelope on save', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    final legacy = {
      'connectionId': 'connection-1',
      'createdAt': '2026-07-15T00:00:00.000Z',
      'datasetId': 'dataset-1',
      'deviceId': 'device-1',
      'displayName': 'Legacy Documents',
      'keyId': 'key-1',
      'kind': 'selected-folder',
      'profileId': 'legacy-profile',
      'rootKeyRef': 'velock-sync/vault-root/opaque',
      'rootPath': '/safe/legacy',
      'signingKeyRef': 'velock-sync/device-signing/opaque',
      'vaultId': 'vault-1',
    };

    await repository.save(SelectedFolderSyncProfile.fromJson(legacy));
    final persisted =
        jsonDecode((await database.readSyncProfilePayload('legacy-profile'))!)
            as Map<String, dynamic>;

    expect(persisted['schemaVersion'], 1);
    expect(persisted['dataset'], isA<Map<String, dynamic>>());
    expect(persisted, isNot(contains('rootPath')));
    expect(persisted, isNot(contains('rootKeyRef')));
    expect(persisted, isNot(contains('signingKeyRef')));
    expect(
      (persisted['dataset'] as Map<String, dynamic>)['rootKeyRef'],
      'velock-sync/vault-root/opaque',
    );
    expect(
      (persisted['dataset'] as Map<String, dynamic>)['signingKeyRef'],
      'velock-sync/device-signing/opaque',
    );
    expect(jsonEncode(persisted), isNot(contains('root-key-bytes')));
  });

  test(
    'round-trips an Android document tree profile without a filesystem path',
    () {
      final profile = SelectedFolderSyncProfile.fromJson({
        'accessKind': 'androidDocumentTree',
        'connectionId': 'connection-1',
        'createdAt': '2026-07-15T00:00:00.000Z',
        'datasetId': 'dataset-1',
        'deviceId': 'device-1',
        'displayName': 'Documents',
        'keyId': 'key-1',
        'kind': 'selected-folder',
        'profileId': 'profile-1',
        'rootKeyRef': 'velock-sync/vault-root/opaque',
        'rootPath':
            'content://com.android.externalstorage.documents/tree/primary%3ADocuments',
        'signingKeyRef': 'velock-sync/device-signing/opaque',
        'vaultId': 'vault-1',
      });

      expect(profile.accessKind, FolderAccessKind.androidDocumentTree);
      expect(profile.backgroundEnabled, isFalse);
      expect(profile.backgroundAllowCellular, isFalse);
      expect(profile.backgroundRequiresCharging, isFalse);
      expect(
        profile.backgroundCellularMaxTransferBytes,
        defaultBackgroundCellularMaxTransferBytes,
      );
      expect(
        (profile.toJson()['dataset'] as Map<String, Object?>)['rootPath'],
        startsWith('content://'),
      );
    },
  );

  test('round-trips an Apple bookmark without a raw external path', () {
    final bookmark = base64Encode([11, 12, 13, 14]);
    final profile = SelectedFolderSyncProfile.fromJson({
      'accessKind': 'appleSecurityScopedBookmark',
      'connectionId': 'connection-1',
      'createdAt': '2026-07-15T00:00:00.000Z',
      'datasetId': 'dataset-1',
      'deviceId': 'device-1',
      'displayName': 'Documents',
      'keyId': 'key-1',
      'kind': 'selected-folder',
      'profileId': 'profile-1',
      'rootKeyRef': 'velock-sync/vault-root/opaque',
      'rootPath': bookmark,
      'signingKeyRef': 'velock-sync/device-signing/opaque',
      'vaultId': 'vault-1',
    });

    expect(profile.accessKind, FolderAccessKind.appleSecurityScopedBookmark);
    final encoded = jsonEncode(profile.toJson());
    expect(encoded, contains(bookmark));
    expect(encoded, isNot(contains('/private/')));
  });

  test('round-trips the background-sync preference', () {
    final profile = SelectedFolderSyncProfile.fromJson({
      'backgroundEnabled': true,
      'backgroundAllowCellular': true,
      'backgroundRequiresCharging': true,
      'backgroundCellularMaxTransferBytes': 10 * 1024 * 1024,
      'connectionId': 'connection-1',
      'createdAt': '2026-07-15T00:00:00.000Z',
      'datasetId': 'dataset-1',
      'deviceId': 'device-1',
      'displayName': 'Documents',
      'keyId': 'key-1',
      'kind': 'selected-folder',
      'profileId': 'profile-1',
      'rootKeyRef': 'velock-sync/vault-root/opaque',
      'rootPath': '/safe/documents',
      'signingKeyRef': 'velock-sync/device-signing/opaque',
      'vaultId': 'vault-1',
    });

    expect(profile.backgroundEnabled, isTrue);
    expect(profile.backgroundAllowCellular, isTrue);
    expect(profile.backgroundRequiresCharging, isTrue);
    expect(profile.backgroundCellularMaxTransferBytes, 10 * 1024 * 1024);
    final updated = profile.copyWith(
      backgroundEnabled: false,
      backgroundAllowCellular: false,
      backgroundRequiresCharging: false,
      backgroundCellularMaxTransferBytes: 100 * 1024 * 1024,
    );
    expect(updated.backgroundEnabled, isFalse);
    expect(updated.backgroundAllowCellular, isFalse);
    expect(updated.backgroundRequiresCharging, isFalse);
    expect(updated.backgroundCellularMaxTransferBytes, 100 * 1024 * 1024);
  });

  test('lists active selected-folder profiles from sync state', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    final profile = SelectedFolderSyncProfile(
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Documents',
      rootPath: '/safe/documents',
      connectionId: 'connection-1',
      keyId: 'key-1',
      rootKeyRef: 'velock-sync/vault-root/opaque',
      signingKeyRef: 'velock-sync/device-signing/opaque',
      createdAt: DateTime.utc(2026, 7, 15),
    );

    await repository.save(profile);

    expect((await repository.list()).single.profileId, 'profile-1');
  });

  test('pauses, resumes, and removes a selected-folder profile', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    final profile = SelectedFolderSyncProfile(
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Documents',
      rootPath: '/safe/documents',
      connectionId: 'connection-1',
      keyId: 'key-1',
      rootKeyRef: 'velock-sync/vault-root/opaque',
      signingKeyRef: 'velock-sync/device-signing/opaque',
      createdAt: DateTime.utc(2026, 7, 15),
    );

    await repository.save(profile);
    await repository.pause(profile.profileId);
    expect(
      (await repository.read(profile.profileId))!.state,
      SelectedFolderProfileState.paused,
    );

    await repository.resume(profile.profileId);
    expect(
      (await repository.read(profile.profileId))!.state,
      SelectedFolderProfileState.active,
    );

    await repository.remove(profile.profileId);
    expect(await repository.read(profile.profileId), isNull);
    expect(await repository.list(), isEmpty);
    expect(await database.readSyncProfilePayload(profile.profileId), isNotNull);
  });
}
