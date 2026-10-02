import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_local_folder_guard.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

/// iOS hands out a different bookmark every time the same folder is picked;
/// this fake resolves each bookmark to the path it was minted for.
class _AppleFolders implements AppleSecurityScopedFolderAccess {
  _AppleFolders(this.paths);

  final Map<String, String> paths;
  final released = <String>[];
  var acquired = 0;

  @override
  Future<String?> authorizeDirectory() async => null;

  @override
  Future<AppleSecurityScopedFolderSession> acquire(String bookmark) async {
    final path = paths[bookmark];
    if (path == null) {
      throw AppleSecurityScopedFolderAccessLostException(bookmark);
    }
    acquired++;
    return AppleSecurityScopedFolderSession(token: 't$acquired', path: path);
  }

  @override
  Future<void> release(String token) async => released.add(token);
}

String _bookmark(String seed) => base64Encode(utf8.encode('bookmark-$seed'));

void main() {
  late SyncStateDatabase database;
  late PlainFolderSyncProfileRepository profiles;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = PlainFolderSyncProfileRepository(database);
  });

  tearDown(() => database.close());

  Future<void> saveExisting({
    required FolderAccessKind kind,
    required String reference,
    String id = 'existing',
  }) => profiles.save(
    PlainFolderSyncProfile(
      profileId: id,
      datasetId: 'dataset-$id',
      deviceId: 'device',
      displayName: '相册',
      localRootReference: reference,
      localDisplayName: 'aaa',
      accessKind: kind,
      connectionId: 'cloud',
      remoteRootSegments: const ['USB', '1001'],
      createdAt: DateTime.utc(2026, 10, 1),
    ),
  );

  group('iOS bookmarks', () {
    const root =
        '/private/var/mobile/Containers/Shared/AppGroup/X/'
        'File Provider Storage';

    test(
      'a fresh bookmark for the same folder is still the same folder',
      () async {
        final first = _bookmark('first');
        final second = _bookmark('second');
        final apple = _AppleFolders({
          first: '$root/aaa',
          // Same folder, reported without the /private alias and with a
          // trailing separator: still one folder.
          second: '${root.substring('/private'.length)}/aaa/',
        });
        await saveExisting(
          kind: FolderAccessKind.appleSecurityScopedBookmark,
          reference: first,
        );

        expect(second, isNot(first));
        await expectLater(
          assertPlainLocalFolderUnused(
            profiles: profiles,
            kind: FolderAccessKind.appleSecurityScopedBookmark,
            rootReference: second,
            appleFolders: apple,
          ),
          throwsA(
            isA<PlainLocalFolderInUseException>()
                .having(
                  (e) => e.relation,
                  'relation',
                  PlainLocalFolderRelation.same,
                )
                .having((e) => e.existingDisplayName, 'name', '相册')
                .having((e) => e.existingLocalName, 'folder', 'aaa'),
          ),
        );
        // Every security-scoped session opened for the check is closed again.
        expect(apple.released, hasLength(apple.acquired));
      },
    );

    test('nested folders are refused both ways, siblings are not', () async {
      final existing = _bookmark('existing');
      final inner = _bookmark('inner');
      final outer = _bookmark('outer');
      final sibling = _bookmark('sibling');
      final prefixTwin = _bookmark('prefix');
      final apple = _AppleFolders({
        existing: '$root/aaa',
        inner: '$root/aaa/photos',
        outer: root,
        sibling: '$root/bbb',
        prefixTwin: '$root/aaa2',
      });
      await saveExisting(
        kind: FolderAccessKind.appleSecurityScopedBookmark,
        reference: existing,
      );

      Future<void> check(String bookmark) => assertPlainLocalFolderUnused(
        profiles: profiles,
        kind: FolderAccessKind.appleSecurityScopedBookmark,
        rootReference: bookmark,
        appleFolders: apple,
      );

      await expectLater(
        check(inner),
        throwsA(
          isA<PlainLocalFolderInUseException>().having(
            (e) => e.relation,
            'relation',
            PlainLocalFolderRelation.inside,
          ),
        ),
      );
      await expectLater(
        check(outer),
        throwsA(
          isA<PlainLocalFolderInUseException>().having(
            (e) => e.relation,
            'relation',
            PlainLocalFolderRelation.contains,
          ),
        ),
      );
      await check(sibling);
      // `aaa2` only shares a string prefix with `aaa`; it is not inside it.
      await check(prefixTwin);
      // The location itself may re-pick its own folder.
      await assertPlainLocalFolderUnused(
        profiles: profiles,
        kind: FolderAccessKind.appleSecurityScopedBookmark,
        rootReference: inner,
        appleFolders: apple,
        selfProfileId: 'existing',
      );
    });

    test(
      'an existing bookmark that no longer opens falls back to equality',
      () async {
        final stale = _bookmark('stale');
        final picked = _bookmark('picked');
        final apple = _AppleFolders({picked: '$root/aaa'});
        await saveExisting(
          kind: FolderAccessKind.appleSecurityScopedBookmark,
          reference: stale,
        );

        // Nothing can be compared with an unresolvable folder, so it does not
        // block a new pick ...
        await assertPlainLocalFolderUnused(
          profiles: profiles,
          kind: FolderAccessKind.appleSecurityScopedBookmark,
          rootReference: picked,
          appleFolders: apple,
        );
        // ... but the identical reference is still recognised.
        await expectLater(
          assertPlainLocalFolderUnused(
            profiles: profiles,
            kind: FolderAccessKind.appleSecurityScopedBookmark,
            rootReference: stale,
            appleFolders: apple,
          ),
          throwsA(isA<PlainLocalFolderInUseException>()),
        );
      },
    );
  });

  group('Android document trees', () {
    const base = 'content://com.android.externalstorage.documents/tree/';

    PlainLocalFolderIdentity tree(String documentId) =>
        PlainLocalFolderIdentity.androidTree(
          '$base${Uri.encodeComponent(documentId)}',
        )!;

    test('external storage trees compare as paths', () {
      expect(
        tree('primary:Photos').relationTo(tree('primary:Photos/')),
        PlainLocalFolderRelation.same,
      );
      expect(
        tree('primary:Photos/2026').relationTo(tree('primary:Photos')),
        PlainLocalFolderRelation.inside,
      );
      expect(
        tree('primary:').relationTo(tree('primary:Photos')),
        PlainLocalFolderRelation.contains,
      );
      expect(
        tree('primary:Photos2').relationTo(tree('primary:Photos')),
        isNull,
      );
      // Another volume is another folder.
      expect(
        tree('1234-5678:Photos').relationTo(tree('primary:Photos')),
        isNull,
      );
    });

    test('other providers only compare for equality', () {
      PlainLocalFolderIdentity other(String id) =>
          PlainLocalFolderIdentity.androidTree(
            'content://com.example.cloud/tree/${Uri.encodeComponent(id)}',
          )!;

      expect(
        other('abc').relationTo(other('abc')),
        PlainLocalFolderRelation.same,
      );
      expect(other('abc/def').relationTo(other('abc')), isNull);
      expect(other('abc').relationTo(tree('abc')), isNull);
      expect(PlainLocalFolderIdentity.androidTree('content://x'), isNull);
    });

    test('the guard refuses the same tree picked again', () async {
      await saveExisting(
        kind: FolderAccessKind.androidDocumentTree,
        reference: '${base}primary%3APhotos',
      );

      await expectLater(
        assertPlainLocalFolderUnused(
          profiles: profiles,
          kind: FolderAccessKind.androidDocumentTree,
          rootReference: '${base}primary%3APhotos%2F2026',
          appleFolders: _AppleFolders(const {}),
        ),
        throwsA(
          isA<PlainLocalFolderInUseException>().having(
            (e) => e.relation,
            'relation',
            PlainLocalFolderRelation.inside,
          ),
        ),
      );
    });
  });
}
