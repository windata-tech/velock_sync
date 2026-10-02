import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_provisioner.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_local_folder_guard.dart';
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

  Future<PlainFolderSyncProfile> createAt(
    Directory folder, {
    String name = '照片',
    List<String> segments = const ['photos'],
  }) => provisioner().create(
    grant: FolderAccessGrant.localPath(folder),
    displayName: name,
    localDisplayName: p.basename(folder.path),
    connectionId: 'conn-1',
    deviceId: 'device-1',
    remoteRootSegments: segments,
    direction: MirrorDirection.bidirectional,
    conflictPolicy: MirrorConflictPolicy.keepBoth,
  );

  Matcher inUse(PlainLocalFolderRelation relation, {bool paused = false}) =>
      throwsA(
        isA<PlainLocalFolderInUseException>()
            .having((e) => e.relation, 'relation', relation)
            .having((e) => e.existingDisplayName, 'existingDisplayName', '照片')
            .having((e) => e.existingPaused, 'existingPaused', paused),
      );

  test('refuses the exact same binding twice', () async {
    final first = await create();

    await expectLater(
      create(name: '手机照片'),
      inUse(PlainLocalFolderRelation.same),
    );
    // Nothing was written, so the list still holds only the first location.
    final all = await profiles.list();
    expect(all, hasLength(1));
    expect(all.single.profileId, first.profileId);
  });

  test('refuses the same local folder on a different remote folder', () async {
    await create();

    // One local folder fanned out to two remotes would replay a deletion that
    // arrives through one remote to the other, and forward conflict copies.
    await expectLater(
      create(name: '另一个远端', segments: const ['backup']),
      inUse(PlainLocalFolderRelation.same),
    );
    expect(await profiles.list(), hasLength(1));
  });

  test('refuses a local folder inside or around another location', () async {
    await create();
    final inner = await Directory(p.join(localFolder.path, '2026')).create();
    await expectLater(
      createAt(inner, name: '子文件夹', segments: const ['inner']),
      inUse(PlainLocalFolderRelation.inside),
    );

    final parent = await Directory.systemTemp.createTemp('plain-parent');
    addTearDown(() => parent.delete(recursive: true));
    final child = await Directory(p.join(parent.path, 'child')).create();
    await profiles.remove((await profiles.list()).single.profileId);
    await createAt(child, segments: const ['child']);
    await expectLater(
      createAt(parent, name: '上级', segments: const ['parent']),
      inUse(PlainLocalFolderRelation.contains),
    );
    // A sibling folder is fine.
    final sibling = await Directory(p.join(parent.path, 'sibling')).create();
    await createAt(sibling, name: '兄弟', segments: const ['sibling']);
    expect(await profiles.list(), hasLength(2));
  });

  test('a paused location still owns its local folder', () async {
    final first = await create();
    await profiles.pause(first.profileId);

    // Resuming it would run both locations over the same files.
    await expectLater(
      create(name: '重新添加', segments: const ['other']),
      inUse(PlainLocalFolderRelation.same, paused: true),
    );
    expect(await profiles.list(), hasLength(1));
  });

  test('re-picking its own folder never blocks a location', () async {
    final first = await create();

    await provisioner().assertLocalFolderUnused(
      FolderAccessGrant.localPath(localFolder),
      selfProfileId: first.profileId,
    );
  });

  test('allows the same remote folder from a different local folder', () async {
    await create();
    final second = await Directory.systemTemp.createTemp('plain-provision-2');
    addTearDown(() => second.delete(recursive: true));

    // Documented multi-device usage: two local folders keep the same remote
    // folder in step. Each side sees the other's uploads as remote changes, so
    // both local folders converge — that is the intent, not corruption.
    final profile = await createAt(second, name: '另一台设备');

    expect(profile.remoteRootSegments, const ['photos']);
    expect(await profiles.list(), hasLength(2));
  });

  test('refuses a remote scope nested inside another location', () async {
    await create(segments: const ['photos']);
    final second = await Directory.systemTemp.createTemp('plain-provision-3');
    addTearDown(() => second.delete(recursive: true));

    await expectLater(
      createAt(second, name: '子目录', segments: const ['photos', '2026']),
      throwsA(isA<PlainLocationOverlapException>()),
    );
    await expectLater(
      createAt(second, name: '父目录', segments: const []),
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
}
