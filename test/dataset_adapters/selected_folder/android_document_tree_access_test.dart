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

    test('storage streams a payload through app cache into the tree', () async {
      final cache = await Directory.systemTemp.createTemp('velock-saf-cache-');
      addTearDown(() => cache.delete(recursive: true));
      final access = _RecordingDocumentTreeAccess();
      final storage = AndroidDocumentTreeStorage(
        treeUri: 'content://authority/tree/documents',
        access: access,
        cacheDirectory: cache,
      );
      final payload = List<int>.generate(1024 * 1024, (index) => index % 251);

      expect(storage, isA<StreamingSelectedFolderStorage>());
      await storage.writeFileFromStream(
        'reports/big.bin',
        Stream.fromIterable(_chunks(payload, 64 * 1024)),
      );

      final write = access.writes.single;
      expect(write.relativePath, 'reports/big.bin');
      expect(write.localPath, startsWith('${cache.path}/'));
      // The channel only ever sees a completed file, so the recorded bytes also
      // prove the stream was flushed and closed before the hand-off.
      expect(write.bytes, payload);
      expect(
        await cache.list().toList(),
        isEmpty,
        reason: 'the app cache payload goes away once the SAF copy is done',
      );
    });

    test(
      'a streamed write stores the same bytes as the buffered write',
      () async {
        final cache = await Directory.systemTemp.createTemp(
          'velock-saf-cache-',
        );
        addTearDown(() => cache.delete(recursive: true));
        final access = _RecordingDocumentTreeAccess();
        final storage = AndroidDocumentTreeStorage(
          treeUri: 'content://authority/tree/documents',
          access: access,
          cacheDirectory: cache,
        );
        final payload = List<int>.generate(
          512 * 1024,
          (index) => (index * 7) % 256,
        );

        await storage.writeFileAtomically('report.bin', payload);
        await storage.writeFileFromStream(
          'report.bin',
          Stream.fromIterable(_chunks(payload, 32 * 1024)),
        );

        expect(access.writes.map((write) => write.relativePath), [
          'report.bin',
          'report.bin',
        ]);
        expect(access.writes.first.bytes, payload);
        expect(access.writes.last.bytes, access.writes.first.bytes);
        expect(
          access.writes.map((write) => write.localPath).toSet(),
          hasLength(2),
          reason: 'every write stages its own cache file',
        );
        expect(await cache.list().toList(), isEmpty);
      },
    );

    test(
      'a rejected document tree write still removes the cache payload',
      () async {
        final cache = await Directory.systemTemp.createTemp(
          'velock-saf-cache-',
        );
        addTearDown(() => cache.delete(recursive: true));
        final access = _RecordingDocumentTreeAccess(rejectWrites: true);
        final storage = AndroidDocumentTreeStorage(
          treeUri: 'content://authority/tree/documents',
          access: access,
          cacheDirectory: cache,
        );

        await expectLater(
          storage.writeFileFromStream('report.bin', Stream.value([1, 2, 3])),
          throwsA(isA<PlatformException>()),
        );

        expect(access.writes.single.bytes, [1, 2, 3]);
        expect(await cache.list().toList(), isEmpty);
      },
    );

    test(
      'a failing source stream never reaches the tree and caches nothing',
      () async {
        final cache = await Directory.systemTemp.createTemp(
          'velock-saf-cache-',
        );
        addTearDown(() => cache.delete(recursive: true));
        final access = _RecordingDocumentTreeAccess();
        final storage = AndroidDocumentTreeStorage(
          treeUri: 'content://authority/tree/documents',
          access: access,
          cacheDirectory: cache,
        );

        await expectLater(
          storage.writeFileFromStream(
            'report.bin',
            Stream<List<int>>.error(StateError('source failed')),
          ),
          throwsA(isA<StateError>()),
        );

        expect(access.writes, isEmpty);
        expect(await cache.list().toList(), isEmpty);
      },
    );
  });
}

/// Splits [payload] into chunks of at most [size] bytes.
Iterable<List<int>> _chunks(List<int> payload, int size) sync* {
  for (var offset = 0; offset < payload.length; offset += size) {
    yield payload.sublist(offset, (offset + size).clamp(0, payload.length));
  }
}

class _RecordedWrite {
  const _RecordedWrite({
    required this.relativePath,
    required this.localPath,
    required this.bytes,
  });

  final String relativePath;
  final String localPath;
  final List<int> bytes;
}

class _RecordingDocumentTreeAccess implements AndroidDocumentTreeAccess {
  _RecordingDocumentTreeAccess({this.rejectWrites = false});

  final bool rejectWrites;
  final writes = <_RecordedWrite>[];

  @override
  Future<String?> authorizeTree() async => null;

  @override
  Future<File> copyFileToCache({
    required String treeUri,
    required String relativePath,
  }) async => throw UnimplementedError();

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
  }) async {
    final staged = File(localPath);
    if (!await staged.exists()) {
      throw StateError('The staged payload was not handed over as a file.');
    }
    writes.add(
      _RecordedWrite(
        relativePath: relativePath,
        localPath: localPath,
        bytes: await staged.readAsBytes(),
      ),
    );
    if (rejectWrites) {
      throw PlatformException(code: 'provider.saf.replace_failed');
    }
  }
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
