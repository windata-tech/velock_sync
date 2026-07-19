import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_change_planner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';

void main() {
  group('SelectedFolderScanner', () {
    late SyncStateDatabase database;
    late Directory root;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
      root = await Directory.systemTemp.createTemp('velock-selected-folder-');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      await database.close();
    });

    test(
      'keeps identities across a rename and only tombstones after a full scan',
      () async {
        final file = File('${root.path}${Platform.pathSeparator}draft.txt');
        await file.writeAsString('first');
        final scanner = SelectedFolderScanner(
          database,
          fileIdentityResolver: (entry) async =>
              entry is File ? 'inode-1' : null,
          deletionPolicy: const DeletionProtectionPolicy(maxDeletedFraction: 1),
        );

        final first = await scanner.scan(datasetId: 'folder-1', root: root);
        expect(first.upsertedEntries, hasLength(1));
        final original = first.entries.singleWhere(
          (entry) => entry.relativePath == 'draft.txt',
        );
        await file.rename('${root.path}${Platform.pathSeparator}renamed.txt');

        final second = await scanner.scan(datasetId: 'folder-1', root: root);
        final renamed = second.entries.singleWhere(
          (entry) => entry.relativePath == 'renamed.txt',
        );
        expect(renamed.entityId, original.entityId);
        expect(second.upsertedEntries.single.entityId, original.entityId);
        expect(second.deletedEntries, isEmpty);

        await File('${root.path}${Platform.pathSeparator}renamed.txt').delete();
        final third = await scanner.scan(datasetId: 'folder-1', root: root);
        expect(third.deletedEntries.single.entityId, original.entityId);
        expect(
          await database.readFolderScanEntries(datasetId: 'folder-1'),
          isEmpty,
        );
      },
    );

    test(
      'does not create deletion tombstones when the folder is unavailable',
      () async {
        final file = File('${root.path}${Platform.pathSeparator}keep.txt');
        await file.writeAsString('keep');
        final scanner = SelectedFolderScanner(database);
        await scanner.scan(datasetId: 'folder-1', root: root);
        await root.delete(recursive: true);

        await expectLater(
          scanner.scan(datasetId: 'folder-1', root: root),
          throwsA(isA<FolderRootUnavailableException>()),
        );
        final indexed = await database.readFolderScanEntries(
          datasetId: 'folder-1',
        );
        expect(indexed.single.relativePath, 'keep.txt');
      },
    );

    test('pauses an anomalously large deletion set for confirmation', () async {
      for (var index = 0; index < 6; index++) {
        await File(
          '${root.path}${Platform.pathSeparator}$index.txt',
        ).writeAsString('$index');
      }
      final scanner = SelectedFolderScanner(database);
      await scanner.scan(datasetId: 'folder-1', root: root);
      await File('${root.path}${Platform.pathSeparator}0.txt').delete();
      await File('${root.path}${Platform.pathSeparator}1.txt').delete();

      final result = await scanner.scan(datasetId: 'folder-1', root: root);
      expect(result.deletionRequiresConfirmation, isTrue);
      expect(result.deletedEntries, isEmpty);
      expect(
        (await database.readFolderScanEntries(datasetId: 'folder-1')).length,
        6,
      );
    });

    test('excludes engine state directories from the user dataset', () async {
      final internal = Directory(
        '${root.path}${Platform.pathSeparator}.velock-sync',
      );
      await internal.create();
      await File(
        '${internal.path}${Platform.pathSeparator}state',
      ).writeAsString('x');
      await File(
        '${root.path}${Platform.pathSeparator}user.txt',
      ).writeAsString('x');

      final result = await SelectedFolderScanner(
        database,
      ).scan(datasetId: 'folder-1', root: root);
      expect(result.entries.map((entry) => entry.relativePath), ['user.txt']);
      expect(result.entries.single.type, FolderEntryType.file);
    });

    test(
      'scans a platform-neutral storage without a local Directory',
      () async {
        final storage = _MemoryStorage([
          SelectedFolderStorageEntry(
            relativePath: 'document.txt',
            type: FolderEntryType.file,
            size: 4,
            modifiedAt: DateTime.utc(2026, 7, 15),
            fileIdentity: 'saf-document-1',
          ),
        ]);

        final result = await SelectedFolderScanner(
          database,
        ).scan(datasetId: 'folder-1', storage: storage);

        expect(result.entries.single.relativePath, 'document.txt');
        expect(result.entries.single.fileIdentity, 'saf-document-1');
      },
    );

    test(
      'plans local upserts and tombstones without exposing them remotely',
      () async {
        await File(
          '${root.path}${Platform.pathSeparator}note.txt',
        ).writeAsString('note');
        await Directory('${root.path}${Platform.pathSeparator}empty').create();
        final scanner = SelectedFolderScanner(
          database,
          deletionPolicy: const DeletionProtectionPolicy(maxDeletedFraction: 1),
        );
        final planner = const SelectedFolderChangePlanner();

        final firstPlan = planner.plan(
          root: root,
          scan: await scanner.scan(datasetId: 'folder-1', root: root),
        );
        expect(firstPlan.changes, hasLength(2));
        final fileChange = firstPlan.changes.singleWhere(
          (change) => change.entry.relativePath == 'note.txt',
        );
        expect(fileChange.type, SelectedFolderChangeType.upsert);
        expect(fileChange.blobSource, isNotNull);
        final content = await fileChange.blobSource!.openRead().fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        expect(String.fromCharCodes(content), 'note');
        expect(
          firstPlan.changes
              .singleWhere((change) => change.entry.relativePath == 'empty')
              .blobSource,
          isNull,
        );

        await File('${root.path}${Platform.pathSeparator}note.txt').delete();
        final secondPlan = planner.plan(
          root: root,
          scan: await scanner.scan(datasetId: 'folder-1', root: root),
        );
        final deletion = secondPlan.changes.singleWhere(
          (change) => change.type == SelectedFolderChangeType.delete,
        );
        expect(deletion.entry.relativePath, 'note.txt');
        expect(deletion.blobSource, isNull);
      },
    );
  });
}

class _MemoryStorage implements SelectedFolderStorage {
  const _MemoryStorage(this.entries);

  final List<SelectedFolderStorageEntry> entries;

  @override
  String get rootReference => 'content://authority/tree/documents';

  @override
  Future<bool> checkAccess() async => true;

  @override
  Stream<SelectedFolderStorageEntry> listRecursively() =>
      Stream.fromIterable(entries);

  @override
  SelectedFolderReadableFile file(String relativePath) =>
      throw UnimplementedError();

  @override
  Future<void> createDirectory(String relativePath) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String relativePath) => throw UnimplementedError();

  @override
  Future<void> writeFileAtomically(String relativePath, List<int> bytes) =>
      throw UnimplementedError();
}
