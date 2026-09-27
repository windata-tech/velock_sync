import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';

void main() {
  late Directory root;
  late LocalSelectedFolderStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('velock-stream-write-');
    storage = LocalSelectedFolderStorage(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('local storage advertises the optional streaming capability', () {
    expect(storage, isA<StreamingSelectedFolderStorage>());
  });

  test('streaming write creates parents and writes the exact bytes', () async {
    await storage.writeFileFromStream(
      'reports/2026/today.bin',
      Stream<List<int>>.fromIterable([
        [0, 1, 2],
        [3],
        [4, 5, 255],
      ]),
    );

    final written = File(p.join(root.path, 'reports', '2026', 'today.bin'));
    expect(await written.readAsBytes(), [0, 1, 2, 3, 4, 5, 255]);
    expect(await _stagingFiles(root), isEmpty);
  });

  test('streaming write publishes an empty file for an empty stream', () async {
    await storage.writeFileFromStream(
      'empty.bin',
      const Stream<List<int>>.empty(),
    );

    final written = File(p.join(root.path, 'empty.bin'));
    expect(await written.exists(), isTrue);
    expect(await written.length(), 0);
    expect(await _stagingFiles(root), isEmpty);
  });

  test(
    'streaming write stages a sibling temporary file inside the root',
    () async {
      final controller = StreamController<List<int>>();
      final write = storage.writeFileFromStream(
        'nested/file.bin',
        controller.stream,
      );
      final staged = File(p.join(root.path, 'nested', 'file.bin.velock-tmp'));
      final target = File(p.join(root.path, 'nested', 'file.bin'));

      controller.add([1, 2, 3]);
      await _waitFor(() => staged.existsSync());
      expect(await staged.exists(), isTrue);
      expect(
        await File(p.join(root.path, 'file.bin.velock-tmp')).exists(),
        isFalse,
        reason: 'the staging file must live beside the target',
      );
      expect(
        await target.exists(),
        isFalse,
        reason: 'the target is only published once the stream completed',
      );

      controller.add([4]);
      await controller.close();
      await write;

      expect(await target.readAsBytes(), [1, 2, 3, 4]);
      expect(await _stagingFiles(root), isEmpty);
    },
  );

  test('streaming write replaces an existing file', () async {
    final target = File(p.join(root.path, 'note.txt'));
    await target.writeAsString('previous content');

    await storage.writeFileFromStream(
      'note.txt',
      Stream.value(utf8.encode('streamed content')),
    );

    expect(await target.readAsString(), 'streamed content');
    expect(await _stagingFiles(root), isEmpty);
  });

  test('atomic byte write replaces an existing file', () async {
    final target = File(p.join(root.path, 'note.txt'));
    await target.writeAsString('previous content');

    await storage.writeFileAtomically(
      'note.txt',
      utf8.encode('atomic content'),
    );

    expect(await target.readAsString(), 'atomic content');
    expect(await _stagingFiles(root), isEmpty);
  });

  test(
    'replacing a file never publishes the new bytes before the rename',
    () async {
      final target = File(p.join(root.path, 'note.txt'));
      await target.writeAsString('previous content');
      final staged = File('${target.path}.velock-tmp');
      final controller = StreamController<List<int>>();
      final write = storage.writeFileFromStream('note.txt', controller.stream);

      controller.add(utf8.encode('staged '));
      await _waitFor(() => staged.existsSync());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // While the payload is still being staged the destination keeps both its
      // name and its previous content.
      expect(await target.exists(), isTrue);
      expect(await target.readAsString(), 'previous content');

      controller.add(utf8.encode('content'));
      await controller.close();
      await write;

      expect(await target.readAsString(), 'staged content');
      expect(await _stagingFiles(root), isEmpty);
    },
  );

  test(
    'a publish that cannot finish keeps the previous file under its real name',
    () async {
      final target = File(p.join(root.path, 'note.txt'));
      await target.writeAsString('previous content');
      final staged = File('${target.path}.velock-tmp');

      // Removing the staging file once the payload has been written makes the
      // final rename fail. Deleting the destination before that rename - the
      // old ordering - would then have destroyed the file's only real name and
      // kept the payload nowhere at all.
      Stream<List<int>> sabotaged() async* {
        yield utf8.encode('new ');
        await _waitFor(() => staged.existsSync());
        await staged.delete();
        yield utf8.encode('content');
      }

      await expectLater(
        storage.writeFileFromStream('note.txt', sabotaged()),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        await target.exists(),
        isTrue,
        reason: 'the real name must survive a failed publish',
      );
      expect(await target.readAsString(), 'previous content');
      expect(await _stagingFiles(root), isEmpty);
    },
  );

  test(
    'a stream error keeps the previous file and leaves no staging file',
    () async {
      final target = File(p.join(root.path, 'note.txt'));
      await target.writeAsString('previous content');
      final controller = StreamController<List<int>>();
      final write = storage.writeFileFromStream('note.txt', controller.stream);
      final failure = expectLater(write, throwsA(isA<StateError>()));

      controller.add(utf8.encode('partial'));
      controller.addError(StateError('source failed'));
      await controller.close();
      await failure;

      expect(await target.readAsString(), 'previous content');
      expect(await _stagingFiles(root), isEmpty);
    },
  );

  test(
    'a stream error on a new file creates neither target nor staging',
    () async {
      final controller = StreamController<List<int>>();
      final write = storage.writeFileFromStream('fresh.bin', controller.stream);
      final failure = expectLater(write, throwsA(isA<StateError>()));

      controller.add([1, 2, 3]);
      controller.addError(StateError('source failed'));
      await controller.close();
      await failure;

      expect(await File(p.join(root.path, 'fresh.bin')).exists(), isFalse);
      expect(await _stagingFiles(root), isEmpty);
    },
  );

  test('streaming write rejects relative paths that escape the root', () async {
    const rejected = [
      '../velock-escape-probe.bin',
      'nested/../../velock-escape-probe.bin',
      '/velock-escape-probe.bin',
      '',
      'nested/./file.bin',
    ];

    for (final relativePath in rejected) {
      await expectLater(
        storage.writeFileFromStream(relativePath, Stream.value([1])),
        throwsA(isA<FolderPathInvalidException>()),
        reason: 'expected "$relativePath" to be rejected',
      );
    }

    expect(
      await File(p.join(root.path, '..', 'velock-escape-probe.bin')).exists(),
      isFalse,
    );
    expect(await root.list().toList(), isEmpty);
  });
}

Future<void> _waitFor(bool Function() probe) async {
  for (var attempt = 0; attempt < 200 && !probe(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<List<FileSystemEntity>> _stagingFiles(Directory root) async {
  if (!await root.exists()) return const [];
  return root
      .list(recursive: true, followLinks: false)
      .where((entity) => entity.path.contains('.velock-tmp'))
      .toList();
}
