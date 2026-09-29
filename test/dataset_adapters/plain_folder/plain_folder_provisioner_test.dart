import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_provisioner.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

class _Authorizer implements FolderAccessAuthorizer {
  _Authorizer(this.grant);

  final FolderAccessGrant? grant;

  @override
  Future<FolderAccessGrant?> authorizeDirectory() async => grant;
}

void main() {
  late SyncStateDatabase database;
  late PlainFolderSyncProfileRepository profiles;
  late Directory localFolder;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = PlainFolderSyncProfileRepository(database);
    localFolder = await Directory.systemTemp.createTemp('plain-provision');
  });

  tearDown(() async {
    await database.close();
    await localFolder.delete(recursive: true);
  });

  /// The provisioner refuses to create a location without the backup
  /// repository, so every test passes the real (here empty) one.
  PlainFolderProvisioner provisioner() => PlainFolderProvisioner(
    authorizer: _Authorizer(FolderAccessGrant.localPath(localFolder)),
    profiles: profiles,
    backups: SyncProfileRepository(database),
  );

  Future<PlainFolderSyncProfile> create({
    String name = '照片',
    List<String> segments = const ['photos'],
  }) => provisioner().create(
    grant: FolderAccessGrant.localPath(localFolder),
    displayName: name,
    localDisplayName: 'photos',
    connectionId: 'conn-1',
    deviceId: 'device-1',
    remoteRootSegments: segments,
    direction: MirrorDirection.bidirectional,
    conflictPolicy: MirrorConflictPolicy.keepBoth,
  );

  test('creates a location with the chosen binding', () async {
    final profile = await create();

    expect(profile.displayName, '照片');
    expect(profile.remoteRootSegments, ['photos']);
    expect(profile.localDisplayName, 'photos');
    expect(profile.accessKind, FolderAccessKind.localPath);
    expect(profile.state, PlainFolderProfileState.active);
    expect(await profiles.list(), hasLength(1));
  });

  test('refuses the exact same binding twice', () async {
    final first = await create();

    await expectLater(
      create(name: '手机照片'),
      throwsA(isA<DuplicatePlainLocationException>()),
    );
    // Nothing was written, so the list still holds only the first location.
    final all = await profiles.list();
    expect(all, hasLength(1));
    expect(all.single.profileId, first.profileId);
  });

  test('allows the same local folder on a different remote folder', () async {
    await create();
    final other = await create(name: '另一个远端', segments: ['backup']);

    expect(other.remoteRootSegments, ['backup']);
    expect(await profiles.list(), hasLength(2));
  });

  test('allows the same remote folder from a different local folder', () async {
    await create();
    final second = await Directory.systemTemp.createTemp('plain-provision-2');
    addTearDown(() => second.delete(recursive: true));

    // Documented multi-device usage: two local folders keep the same remote
    // folder in step. Each side sees the other's uploads as remote changes, so
    // both local folders converge — that is the intent, not corruption.
    final profile = await provisioner().create(
      grant: FolderAccessGrant.localPath(second),
      displayName: '另一台设备',
      localDisplayName: 'photos-2',
      connectionId: 'conn-1',
      deviceId: 'device-1',
      remoteRootSegments: const ['photos'],
      direction: MirrorDirection.bidirectional,
      conflictPolicy: MirrorConflictPolicy.keepBoth,
    );

    expect(profile.remoteRootSegments, const ['photos']);
    expect(await profiles.list(), hasLength(2));
  });

  test('refuses the same local folder twice on one remote folder', () async {
    await create();

    // Same local folder + same remote scope is a duplicate binding: two
    // baselines over the same files, and a deletion on one side would be
    // re-downloaded by the other for ever.
    await expectLater(
      provisioner().create(
        grant: FolderAccessGrant.localPath(localFolder),
        displayName: '重复',
        localDisplayName: 'photos',
        connectionId: 'conn-1',
        deviceId: 'device-1',
        remoteRootSegments: const ['photos'],
        direction: MirrorDirection.bidirectional,
        conflictPolicy: MirrorConflictPolicy.keepBoth,
      ),
      throwsA(isA<DuplicatePlainLocationException>()),
    );
    expect(await profiles.list(), hasLength(1));
  });

  test('refuses a remote scope nested inside another location', () async {
    await create(segments: const ['photos']);

    await expectLater(
      create(name: '子目录', segments: const ['photos', '2026']),
      throwsA(isA<PlainLocationOverlapException>()),
    );
    await expectLater(
      create(name: '父目录', segments: const []),
      throwsA(isA<PlainLocationOverlapException>()),
    );
    expect(await profiles.list(), hasLength(1));
  });

  test('the backup repository is a required argument, not an option', () {
    // Compile-time now: the constructor has no way to build a provisioner that
    // cannot run the folder-overlap check. Kept as a regression note so nobody
    // makes it optional again "for convenience".
    expect(
      () => PlainFolderProvisioner(
        authorizer: _Authorizer(FolderAccessGrant.localPath(localFolder)),
        profiles: profiles,
        backups: SyncProfileRepository(database),
      ),
      returnsNormally,
    );
  });

  test(
    'resolves a stored folder name and leaves the label to the UI',
    () async {
      final provisionerUnderTest = provisioner();

      expect(
        await provisionerUnderTest.resolveLocalDisplayName(
          FolderAccessGrant.localPath(localFolder),
        ),
        localFolder.uri.pathSegments.where((part) => part.isNotEmpty).last,
      );
      // The UI is localized, so an undecidable name is empty instead of a
      // hard-coded word.
      expect(
        await provisionerUnderTest.resolveLocalDisplayName(
          FolderAccessGrant.localPath(Directory('/')),
        ),
        isEmpty,
      );
      expect(
        await provisionerUnderTest.resolveLocalDisplayName(
          FolderAccessGrant.androidDocumentTree(
            'content://com.android.externalstorage.documents/tree/'
            'primary%3APhotos',
          ),
        ),
        'Photos',
      );
      expect(
        await provisionerUnderTest.resolveLocalDisplayName(
          FolderAccessGrant.androidDocumentTree('content://'),
        ),
        isEmpty,
      );
    },
  );

  test('a paused duplicate does not block a fresh location', () async {
    final first = await create();
    await profiles.pause(first.profileId);

    final again = await create(name: '重新添加');
    expect(again.profileId, isNot(first.profileId));
    expect(await profiles.list(), hasLength(2));
  });
}
