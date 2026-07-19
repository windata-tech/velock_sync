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
class LocalSelectedFolderStorage implements SelectedFolderStorage {
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
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
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
