import 'dart:io';
import 'dart:typed_data';

/// Immutable bounded control artifacts in an app-owned Exchange directory.
/// A nonempty directory is renamed atomically, so a concurrent publisher cannot
/// replace the winner. All readers reject symlinks and partial publications.
/// Kept byte-identical in Sync and Velock.
class SnapshotControlFiles {
  SnapshotControlFiles(this.root);
  final Directory root;
  static const _collections = {
    'SnapshotRequests',
    'SnapshotReceipts',
    'SnapshotApplied',
  };

  Future<Directory> _collection(String name) async {
    if (!_collections.contains(name)) {
      throw ArgumentError('Invalid control collection.');
    }
    // The configured App Group root can be a platform symlink; descendants may not.
    final resolved = await root.resolveSymbolicLinks();
    var current = Directory(resolved);
    for (final segment in ['Control', name]) {
      current = Directory('${current.path}/$segment');
      if (await FileSystemEntity.type(current.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await current.create();
      }
      if (await FileSystemEntity.type(current.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException('Invalid control directory.');
      }
    }
    return current;
  }

  void _id(String id) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id) ||
        id.contains('..')) {
      throw const FormatException('Invalid control file identifier.');
    }
  }

  Future<Uint8List?> read(String collection, String id) async {
    _id(id);
    final base = await _collection(collection);
    final dir = Directory('${base.path}/$id');
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('Invalid control artifact directory.');
    }
    final file = File('${dir.path}/artifact.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Invalid control artifact.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > 16384) {
        throw const FormatException('Control size limit.');
      }
      bytes.add(chunk);
    }
    if (bytes.length == 0) {
      throw const FormatException('Empty control artifact.');
    }
    return bytes.takeBytes();
  }

  /// Existing exact bytes are reusable; an ID with different content is rejected.
  Future<void> publish(String collection, String id, List<int> input) async {
    _id(id);
    if (input.isEmpty || input.length > 16384) {
      throw const FormatException('Control size limit.');
    }
    final bytes = Uint8List.fromList(input);
    final existing = await read(collection, id);
    if (existing != null) {
      _same(existing, bytes);
      return;
    }
    final base = await _collection(collection);
    final pending = await base.createTemp('.pending-');
    try {
      await File(
        '${pending.path}/artifact.json',
      ).writeAsBytes(bytes, flush: true);
      try {
        await pending.rename('${base.path}/$id');
      } on FileSystemException {
        final winner = await read(collection, id);
        if (winner == null) rethrow;
        _same(winner, bytes);
      }
    } finally {
      if (await pending.exists()) await pending.delete(recursive: true);
    }
  }

  void _same(List<int> a, List<int> b) {
    if (a.length != b.length) {
      throw StateError('Control ID already contains different bytes.');
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        throw StateError('Control ID already contains different bytes.');
      }
    }
  }
}
