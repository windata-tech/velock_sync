import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';

SelectedFolderSyncProfile _profile({List<String> segments = const []}) =>
    SelectedFolderSyncProfile(
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Documents',
      rootPath: '/safe/documents',
      connectionId: 'connection-1',
      remoteRootSegments: segments,
      keyId: 'key-1',
      rootKeyRef: 'velock-sync/vault-root/opaque',
      signingKeyRef: 'velock-sync/device-signing/opaque',
      createdAt: DateTime.utc(2026, 9, 26),
    );

void main() {
  test('keeps the connection root when no folder was chosen', () {
    final decoded = SelectedFolderSyncProfile.fromJson(_profile().toJson());

    expect(decoded.remoteRootSegments, isEmpty);
    expect(
      (decoded.toJson()['dataset']! as Map<String, Object?>)[
          'remoteRootSegments'],
      isEmpty,
    );
  });

  test('round-trips a chosen folder as decoded relative segments', () {
    final decoded = SelectedFolderSyncProfile.fromJson(
      _profile(segments: const ['USB_HDD_8T', '可写 文件夹', "it's"]).toJson(),
    );

    expect(decoded.remoteRootSegments, ['USB_HDD_8T', '可写 文件夹', "it's"]);
  });

  test('legacy flat profile without segments keeps the connection root', () {
    final decoded = SelectedFolderSyncProfile.fromJson({
      'connectionId': 'connection-1',
      'createdAt': '2026-09-26T00:00:00.000Z',
      'datasetId': 'dataset-1',
      'deviceId': 'device-1',
      'displayName': 'Legacy Documents',
      'keyId': 'key-1',
      'kind': 'selected-folder',
      'profileId': 'legacy-profile',
      'rootKeyRef': 'velock-sync/vault-root/opaque',
      'rootPath': '/safe/documents',
      'signingKeyRef': 'velock-sync/device-signing/opaque',
      'vaultId': 'vault-1',
    });

    expect(decoded.remoteRootSegments, isEmpty);
  });

  test('rejects traversal, separators and control characters', () {
    for (final invalid in const [
      ['..'],
      ['.'],
      [''],
      ['a/b'],
      [r'a\b'],
      ['a\u0000b'],
      ['tail ', '\u007f'],
    ]) {
      expect(
        () => _profile(segments: invalid).toJson(),
        throwsA(isA<FormatException>()),
        reason: 'expected $invalid to be rejected',
      );
      expect(
        () => SelectedFolderSyncProfile.fromJson({
          ..._profile().toJson(),
          'dataset': {
            ...(_profile().toJson()['dataset']! as Map<String, Object?>),
            'remoteRootSegments': invalid,
          },
        }),
        throwsA(isA<FormatException>()),
        reason: 'expected stored $invalid to be rejected',
      );
    }
  });

  test('rejects a non-list stored scope instead of defaulting to the root', () {
    expect(
      () => SelectedFolderSyncProfile.fromJson({
        ..._profile().toJson(),
        'dataset': {
          ...(_profile().toJson()['dataset']! as Map<String, Object?>),
          'remoteRootSegments': '111',
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('copyWith preserves the chosen folder while changing settings', () {
    final updated = _profile(
      segments: const ['111'],
    ).copyWith(backgroundEnabled: true, state: SelectedFolderProfileState.paused);

    expect(updated.remoteRootSegments, ['111']);
    expect(updated.backgroundEnabled, isTrue);
    expect(updated.rootPath, '/safe/documents');
  });

  test('saving and reopening a file-sync task keeps its own folder', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    await repository.save(_profile(segments: const ['USB_HDD_8T', '111']));

    final reopened = await repository.read('profile-1');

    expect(reopened!.remoteRootSegments, ['USB_HDD_8T', '111']);
    expect(reopened.rootPath, '/safe/documents');
    expect(
      reopened.toJson()['kind'],
      SyncDatasetKind.selectedFolder.persistedValue,
    );
    expect(reopened.toJson()['profileId'], 'profile-1');
  });

  test('only a user-confirmed relocation changes one task scope', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    final original = _profile(segments: const ['USB_HDD_8T', '111']);
    await repository.save(original);

    final stored = (await repository.read('profile-1'))!;
    final updated = await repository.selectSyncFolder(
      expected: stored,
      segments: const ['USB_HDD_8T', '111', '文件同步'],
    );

    expect(updated.remoteRootSegments, ['USB_HDD_8T', '111', '文件同步']);
    expect(
      (await repository.read('profile-1'))!.remoteRootSegments,
      ['USB_HDD_8T', '111', '文件同步'],
    );
    expect(updated.rootKeyRef, stored.rootKeyRef);
    expect(updated.rootPath, stored.rootPath);
  });

  test('rejects a stale page instead of overwriting a newer scope', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    await repository.save(_profile(segments: const ['111']));
    final pageCopy = (await repository.read('profile-1'))!;
    await repository.selectSyncFolder(
      expected: pageCopy,
      segments: const ['222'],
    );

    expect(
      () => repository.selectSyncFolder(
        expected: pageCopy,
        segments: const ['333'],
      ),
      throwsA(isA<StateError>()),
    );
    expect((await repository.read('profile-1'))!.remoteRootSegments, ['222']);
  });

  test('rejects a relocation while this task is running', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    final original = _profile();
    await repository.save(original);
    await database.startSyncRun(
      runId: 'run-1',
      profileId: 'profile-1',
      startedAt: DateTime.utc(2026, 9, 26),
    );
    final pageCopy = (await repository.read('profile-1'))!;

    expect(
      () => repository.selectSyncFolder(
        expected: pageCopy,
        segments: const ['111'],
      ),
      throwsA(isA<StateError>()),
    );
    expect((await repository.read('profile-1'))!.remoteRootSegments, isEmpty);
  });

  test('relocation is blocked while another page holds the location lock', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SelectedFolderSyncProfileRepository(database);
    await repository.save(_profile());
    final pageCopy = (await repository.read('profile-1'))!;
    // A fresh heartbeat: a genuinely held location lock must not be stolen.
    await database.tryAcquireProfileLock(
      profileId: 'velock-location:profile-1',
      owner: 'other-page',
      now: DateTime.now().toUtc(),
      staleAfter: const Duration(minutes: 5),
    );

    expect(
      () => repository.selectSyncFolder(
        expected: pageCopy,
        segments: const ['111'],
      ),
      throwsA(isA<SyncRunBusyException>()),
    );
  });

  test('a stored scope survives an unrelated envelope key order', () async {
    final encoded = jsonEncode(_profile(segments: const ['111']).toJson());
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    final reordered = Map<String, dynamic>.fromEntries(
      decoded.entries.toList().reversed,
    );

    expect(
      SelectedFolderSyncProfile.fromJson(reordered).remoteRootSegments,
      ['111'],
    );
  });
}
