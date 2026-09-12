import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/android_document_tree_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelAndroidDocumentTreeAccess', () {
    test('bridges authorization and per-entry SAF operations', () async {
      final cache = await Directory.systemTemp.createTemp('velock-saf-cache-');
      addTearDown(() => cache.delete(recursive: true));
      const channel = MethodChannel('tech.windata.velock.sync/document_tree');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'authorizeTree':
                return 'content://authority/tree/documents';
              case 'listTree':
                return [
                  {
                    'relativePath': 'reports',
                    'type': 'directory',
                    'size': -1,
                    'modifiedAt': 1000,
                  },
                  {
                    'relativePath': 'reports/today.txt',
                    'type': 'file',
                    'size': 5,
                    'modifiedAt': 2000,
                  },
                ];
              case 'copyFileToCache':
                final source = File('${cache.path}/source.txt');
                await source.writeAsString('hello');
                return source.path;
              case 'createDirectory':
              case 'writeFileFromPath':
              case 'deleteEntry':
                return null;
            }
            throw MissingPluginException();
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final access = MethodChannelAndroidDocumentTreeAccess(channel: channel);
      const treeUri = 'content://authority/tree/documents';

      expect(await access.authorizeTree(), treeUri);
      final entries = await access.listTree(treeUri);
      expect(entries, hasLength(2));
      expect(
        entries.singleWhere((entry) => entry.relativePath == 'reports').type,
        FolderEntryType.directory,
      );
      final cached = await access.copyFileToCache(
        treeUri: treeUri,
        relativePath: 'reports/today.txt',
      );
      expect(await cached.readAsString(), 'hello');
      await access.createDirectory(treeUri: treeUri, relativePath: 'archive');
      await access.writeFileFromPath(
        treeUri: treeUri,
        relativePath: 'archive/result.txt',
        localPath: cached.path,
      );
      await access.deleteEntry(treeUri: treeUri, relativePath: 'archive');

      expect(calls.map((call) => call.method), [
        'authorizeTree',
        'listTree',
        'copyFileToCache',
        'createDirectory',
        'writeFileFromPath',
        'deleteEntry',
      ]);
      expect(calls[3].arguments, {
        'treeUri': treeUri,
        'relativePath': 'archive',
      });
      expect(calls[4].arguments, {
        'treeUri': treeUri,
        'relativePath': 'archive/result.txt',
        'localPath': cached.path,
      });
    });

    test('storage streams one SAF file and removes its cache copy', () async {
      final cache = await Directory.systemTemp.createTemp('velock-saf-read-');
      addTearDown(() => cache.delete(recursive: true));
      final source = File('${cache.path}/source.txt');
      await source.writeAsString('payload');
      final access = _FakeDocumentTreeAccess(source);
      final storage = AndroidDocumentTreeStorage(
        treeUri: 'content://authority/tree/documents',
        access: access,
      );

      final file = storage.file('entry.txt');
      expect(await file.length(), 7);
      expect(
        await file.openRead().expand((bytes) => bytes).toList(),
        'payload'.codeUnits,
      );
      expect(await source.exists(), isFalse);
      expect(access.readPaths, ['entry.txt']);
    });

    test('storage rejects a path that escapes the granted tree', () {
      final storage = AndroidDocumentTreeStorage(
        treeUri: 'content://authority/tree/documents',
        access: _FakeDocumentTreeAccess(File('unused')),
      );

      expect(
        () => storage.file('../outside.txt'),
        throwsA(isA<FolderPathInvalidException>()),
      );
    });
  });
}

class _FakeDocumentTreeAccess implements AndroidDocumentTreeAccess {
  _FakeDocumentTreeAccess(this.source);

  final File source;
  final readPaths = <String>[];

  @override
  Future<String?> authorizeTree() async => null;

  @override
  Future<File> copyFileToCache({
    required String treeUri,
    required String relativePath,
  }) async {
    readPaths.add(relativePath);
    return source;
  }

  @override
  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  }) async {}

  @override
  Future<void> deleteEntry({
    required String treeUri,
    required String relativePath,
  }) async {}

  @override
  Future<List<SelectedFolderStorageEntry>> listTree(String treeUri) async => [];

  @override
  Future<void> writeFileFromPath({
    required String treeUri,
    required String relativePath,
    required String localPath,
  }) async {}
}
