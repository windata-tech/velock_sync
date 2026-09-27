import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:velock_sync/sync_core/model/sync_models.dart';

typedef FileIdentityResolver = Future<String?> Function(FileSystemEntity entry);

class FolderRootUnavailableException implements Exception {
  const FolderRootUnavailableException(this.rootPath);

  final String rootPath;

  @override
  String toString() => 'The selected folder is unavailable: $rootPath';
}

class FolderPathInvalidException implements Exception {
  const FolderPathInvalidException(this.path);

  final String path;

  @override
  String toString() => 'Invalid selected-folder relative path: $path';
}

class FolderCaseConflictException implements Exception {
  const FolderCaseConflictException(this.firstPath, this.secondPath);

  final String firstPath;
  final String secondPath;

  @override
  String toString() =>
      'Case-insensitive path conflict: $firstPath / $secondPath';
}

/// Platform-neutral view of one user-authorized folder. Implementations must
/// expose only names relative to that folder and never follow links outside it.
abstract interface class SelectedFolderStorage {
  String get rootReference;

  Future<bool> checkAccess();

  Stream<SelectedFolderStorageEntry> listRecursively();

  SelectedFolderReadableFile file(String relativePath);

  Future<void> createDirectory(String relativePath);

  Future<void> writeFileAtomically(String relativePath, List<int> bytes);

  Future<void> delete(String relativePath);
}

/// Optional capability of a [SelectedFolderStorage] that can write one file
/// from a replayable byte stream without buffering the whole payload in memory.
/// Storages that cannot stream - for example a platform channel that only
/// accepts a completed local file - deliberately do not implement it, so
/// callers must fall back to [SelectedFolderStorage.writeFileAtomically].
abstract interface class StreamingSelectedFolderStorage {
  Future<void> writeFileFromStream(String relativePath, Stream<List<int>> data);
}

abstract interface class SelectedFolderReadableFile {
  Future<int> length();

  Stream<List<int>> openRead();
}

class SelectedFolderStorageEntry {
  const SelectedFolderStorageEntry({
    required this.relativePath,
    required this.type,
    required this.size,
    required this.modifiedAt,
    this.fileIdentity,
  });

  final String relativePath;
  final FolderEntryType type;
  final int? size;
  final DateTime? modifiedAt;
  final String? fileIdentity;
}

/// Existing desktop and iOS/macOS directory implementation of the storage
/// contract. Android SAF deliberately has a separate implementation.
class LocalSelectedFolderStorage
    implements SelectedFolderStorage, StreamingSelectedFolderStorage {
  LocalSelectedFolderStorage(this.root, {FileIdentityResolver? fileIdentity})
    : _fileIdentity = fileIdentity ?? _noFileIdentity;

  final Directory root;
  final FileIdentityResolver _fileIdentity;

  @override
  String get rootReference => root.path;

  @override
  Future<bool> checkAccess() => root.exists();

  @override
  SelectedFolderReadableFile file(String relativePath) =>
      _LocalReadableFile(File(_path(relativePath)));

  @override
  Stream<SelectedFolderStorageEntry> listRecursively() async* {
    if (!await root.exists()) {
      throw FolderRootUnavailableException(root.path);
    }
    final rootPath = p.normalize(p.absolute(root.path));
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) continue;
      final relativePath = _relativePath(rootPath, entity.path);
      final stat = await entity.stat();
      final type = switch (stat.type) {
        FileSystemEntityType.file => FolderEntryType.file,
        FileSystemEntityType.directory => FolderEntryType.directory,
        _ => null,
      };
      if (type == null) continue;
      yield SelectedFolderStorageEntry(
        relativePath: relativePath,
        type: type,
        size: type == FolderEntryType.file ? stat.size : null,
        modifiedAt: stat.modified.toUtc(),
        fileIdentity: await _fileIdentity(entity),
      );
    }
  }

  @override
  Future<void> createDirectory(String relativePath) =>
      Directory(_path(relativePath)).create(recursive: true);

  @override
  Future<void> writeFileAtomically(String relativePath, List<int> bytes) async {
    final target = File(_path(relativePath));
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.velock-tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await _publishStagedFile(temporary, target);
  }

  @override
  Future<void> writeFileFromStream(
    String relativePath,
    Stream<List<int>> data,
  ) async {
    final target = File(_path(relativePath));
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.velock-tmp');
    var published = false;
    try {
      await streamIntoFile(temporary, data);
      await _publishStagedFile(temporary, target);
      published = true;
    } finally {
      // A failed or interrupted stream must keep the previous file and must
      // not leave a partially written staging file behind.
      if (!published && await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> delete(String relativePath) async {
    final path = _path(relativePath);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      return;
    }
    final directory = Directory(path);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  String _path(String relativePath) {
    final rootPath = p.normalize(p.absolute(root.path));
    final candidate = p.normalize(p.join(rootPath, relativePath));
    validateSelectedFolderRelativePath(relativePath);
    if (!p.isWithin(rootPath, candidate)) {
      throw FolderPathInvalidException(relativePath);
    }
    return candidate;
  }

  String _relativePath(String rootPath, String entityPath) {
    final absolutePath = p.normalize(p.absolute(entityPath));
    if (!p.isWithin(rootPath, absolutePath)) {
      throw FolderPathInvalidException(entityPath);
    }
    final relative = p
        .relative(absolutePath, from: rootPath)
        .replaceAll('\\', '/');
    validateSelectedFolderRelativePath(relative);
    return relative;
  }
}

Future<String?> _noFileIdentity(FileSystemEntity _) async => null;

/// Publishes the fully written [temporary] file under the real target name.
///
/// The destination must never be deleted first: `rename` already replaces an
/// existing file in one step - "if [newPath] identifies an existing file or
/// link, that entity is removed first" (dart:io `File.rename`, on every
/// platform this app ships, so no Windows-only delete is needed) - while a
/// separate `delete` leaves a window where the file has no name at all: a crash
/// or process kill inside it destroys the real name and keeps the payload only
/// under the staging name, which no scan treats as that file, so the next run
/// sees a local deletion and can remove the remote copy too.
Future<void> _publishStagedFile(File temporary, File target) =>
    temporary.rename(target.path);

/// Streams [data] into [file] and flushes it to disk. Errors of the source
/// stream and of the sink itself are both reported to the caller. The file is
/// closed before this future completes, so a caller may hand its path to
/// another process or platform channel.
Future<void> streamIntoFile(File file, Stream<List<int>> data) async {
  final sink = file.openWrite();
  try {
    await sink.addStream(data);
    await sink.flush();
  } catch (_) {
    // The sink is already failed; closing it must not mask that error.
    try {
      await sink.close();
    } catch (_) {}
    rethrow;
  }
  await sink.close();
}

class _LocalReadableFile implements SelectedFolderReadableFile {
  const _LocalReadableFile(this._file);

  final File _file;

  @override
  Future<int> length() => _file.length();

  @override
  Stream<List<int>> openRead() => _file.openRead();
}

bool isSelectedFolderIgnoredPath(String relativePath) {
  return relativePath
      .split('/')
      .any(
        (segment) =>
            segment == '.velock-sync' ||
            segment == '.velock-sync-tmp' ||
            segment.startsWith('.velock-tmp-'),
      );
}

void validateSelectedFolderRelativePath(String path) {
  if (!_isValidRelativePath(path)) throw FolderPathInvalidException(path);
}

bool _isValidRelativePath(String path) {
  if (path.isEmpty || path.startsWith('/')) return false;
  return path
      .replaceAll('\\', '/')
      .split('/')
      .every((part) => part.isNotEmpty && part != '.' && part != '..');
}
