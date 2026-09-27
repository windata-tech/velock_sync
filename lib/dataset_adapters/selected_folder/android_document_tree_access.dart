import 'dart:io';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Platform boundary for a persisted Android SAF tree. Every operation is
/// relative to the granted tree URI; no raw device path is accepted.
abstract interface class AndroidDocumentTreeAccess {
  Future<String?> authorizeTree();

  Future<List<SelectedFolderStorageEntry>> listTree(String treeUri);

  Future<File> copyFileToCache({
    required String treeUri,
    required String relativePath,
  });

  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  });

  /// Copies one completed app-private file into the tree.
  ///
  /// An existing document with the same name is replaced without ever losing
  /// that name. When the replacement cannot be finished the platform channel
  /// fails with the `provider.saf.replace_failed` code and keeps the staged
  /// payload under a `.velock-tmp-` document name instead of deleting it.
  Future<void> writeFileFromPath({
    required String treeUri,
    required String relativePath,
    required String localPath,
  });

  Future<void> deleteEntry({
    required String treeUri,
    required String relativePath,
  });
}

class MethodChannelAndroidDocumentTreeAccess
    implements AndroidDocumentTreeAccess {
  MethodChannelAndroidDocumentTreeAccess({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'tech.windata.velock.sync/document_tree';

  final MethodChannel _channel;

  @override
  Future<String?> authorizeTree() =>
      _channel.invokeMethod<String>('authorizeTree');

  @override
  Future<List<SelectedFolderStorageEntry>> listTree(String treeUri) async {
    final raw = await _channel.invokeMethod<List<Object?>>('listTree', {
      'treeUri': treeUri,
    });
    if (raw == null) {
      throw StateError('Android document tree returned no list.');
    }
    return raw.map(_entry).toList(growable: false);
  }

  @override
  Future<File> copyFileToCache({
    required String treeUri,
    required String relativePath,
  }) async {
    final path = await _channel.invokeMethod<String>('copyFileToCache', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
    if (path == null || path.isEmpty) {
      throw StateError('Android document tree returned no file path.');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Android document tree temporary file is unavailable.');
    }
    return file;
  }

  @override
  Future<void> createDirectory({
    required String treeUri,
    required String relativePath,
  }) => _call('createDirectory', treeUri, relativePath);

  @override
  Future<void> deleteEntry({
    required String treeUri,
    required String relativePath,
  }) => _call('deleteEntry', treeUri, relativePath);

  @override
  Future<void> writeFileFromPath({
    required String treeUri,
    required String relativePath,
    required String localPath,
  }) => _channel.invokeMethod<void>('writeFileFromPath', {
    'treeUri': treeUri,
    'relativePath': relativePath,
    'localPath': localPath,
  });

  Future<void> _call(String method, String treeUri, String relativePath) =>
      _channel.invokeMethod<void>(method, {
        'treeUri': treeUri,
        'relativePath': relativePath,
      });

  SelectedFolderStorageEntry _entry(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Android document tree entry is invalid.');
    }
    final path = value['relativePath'];
    final type = value['type'];
    final size = value['size'];
    final modifiedAt = value['modifiedAt'];
    if (path is! String ||
        type is! String ||
        size is! int ||
        modifiedAt is! int) {
      throw const FormatException('Android document tree entry is invalid.');
    }
    return SelectedFolderStorageEntry(
      relativePath: path,
      type: FolderEntryType.values.byName(type),
      size: size < 0 ? null : size,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(modifiedAt, isUtc: true),
    );
  }
}

/// SAF implementation that copies at most one source file into app cache for
/// the duration of encryption. It never materializes the user-selected tree.
class AndroidDocumentTreeStorage
    implements SelectedFolderStorage, StreamingSelectedFolderStorage {
  AndroidDocumentTreeStorage({
    required this.treeUri,
    required AndroidDocumentTreeAccess access,
    Directory? cacheDirectory,
  }) : _access = access,
       _cacheDirectory = cacheDirectory ?? Directory.systemTemp;

  final String treeUri;
  final AndroidDocumentTreeAccess _access;
  final Directory _cacheDirectory;

  @override
  String get rootReference => treeUri;

  @override
  Future<bool> checkAccess() async {
    try {
      await _access.listTree(treeUri);
      return true;
    } on PlatformException {
      return false;
    } on StateError {
      return false;
    }
  }

  @override
  SelectedFolderReadableFile file(String relativePath) {
    validateSelectedFolderRelativePath(relativePath);
    return _AndroidDocumentTreeFile(
      access: _access,
      treeUri: treeUri,
      relativePath: relativePath,
    );
  }

  @override
  Stream<SelectedFolderStorageEntry> listRecursively() async* {
    yield* Stream.fromIterable(await _access.listTree(treeUri));
  }

  @override
  Future<void> createDirectory(String relativePath) {
    validateSelectedFolderRelativePath(relativePath);
    return _access.createDirectory(
      treeUri: treeUri,
      relativePath: relativePath,
    );
  }

  @override
  Future<void> delete(String relativePath) {
    validateSelectedFolderRelativePath(relativePath);
    return _access.deleteEntry(treeUri: treeUri, relativePath: relativePath);
  }

  @override
  Future<void> writeFileAtomically(String relativePath, List<int> bytes) {
    validateSelectedFolderRelativePath(relativePath);
    return _writeThroughCache(
      relativePath,
      (staged) => staged.writeAsBytes(bytes, flush: true),
    );
  }

  @override
  Future<void> writeFileFromStream(
    String relativePath,
    Stream<List<int>> data,
  ) {
    validateSelectedFolderRelativePath(relativePath);
    // The SAF channel only accepts a completed local file, so a streamed
    // payload is spooled to app-private cache instead of being collected in
    // Dart memory: the whole mirror download path, its keep-both conflict copy
    // and the channel's own copy then stay bounded by the file size on disk.
    return _writeThroughCache(
      relativePath,
      (staged) => streamIntoFile(staged, data),
    );
  }

  /// Materializes one payload in app cache - [Directory.systemTemp] is the
  /// application cache directory on Android, and the native side refuses any
  /// source outside it - and hands that path to the SAF copy. The cache file is
  /// removed on every path, successful or not.
  Future<void> _writeThroughCache(
    String relativePath,
    Future<void> Function(File staged) write,
  ) async {
    final temporaryDirectory = await _cacheDirectory.createTemp(
      'velock-saf-write-',
    );
    final temporary = File('${temporaryDirectory.path}/payload');
    try {
      await write(temporary);
      await _access.writeFileFromPath(
        treeUri: treeUri,
        relativePath: relativePath,
        localPath: temporary.path,
      );
    } finally {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }
}

class _AndroidDocumentTreeFile implements SelectedFolderReadableFile {
  _AndroidDocumentTreeFile({
    required AndroidDocumentTreeAccess access,
    required this.treeUri,
    required this.relativePath,
  }) : _access = access;

  final AndroidDocumentTreeAccess _access;
  final String treeUri;
  final String relativePath;
  Future<File>? _cached;

  Future<File> _materialize() => _cached ??= _access.copyFileToCache(
    treeUri: treeUri,
    relativePath: relativePath,
  );

  @override
  Future<int> length() async => (await _materialize()).length();

  @override
  Stream<List<int>> openRead() async* {
    final file = await _materialize();
    try {
      yield* file.openRead();
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}
