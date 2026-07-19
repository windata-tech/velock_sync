import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

class BatchStagingStore {
  BatchStagingStore(this._root, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Directory _root;
  final Uuid _uuid;

  /// Writes an immutable staged artifact through a same-directory temporary
  /// file. Existing content is never overwritten or silently reused: a caller
  /// recovering a batch must read its persisted manifest and artifacts rather
  /// than regenerate potentially different ciphertext under the same key.
  Future<ImmutableArtifact> stage({
    required String batchId,
    required String artifactName,
    required Stream<List<int>> content,
    required int contentLength,
  }) async {
    if (contentLength < 0) {
      throw ArgumentError.value(contentLength, 'contentLength');
    }
    final destination = _artifactFile(batchId, artifactName);
    if (await destination.exists()) {
      throw StateError('Staged immutable artifact already exists.');
    }
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp-${_uuid.v4()}');
    var written = 0;
    final sink = temporary.openWrite();
    try {
      await for (final part in content) {
        written += part.length;
        if (written > contentLength) {
          throw StateError('Artifact stream exceeded its declared length.');
        }
        sink.add(part);
      }
      await sink.close();
      if (written != contentLength) {
        throw StateError('Artifact stream did not match its declared length.');
      }
      await temporary.rename(destination.path);
      return _asArtifact(destination);
    } on Object {
      await sink.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<ImmutableArtifact?> read({
    required String batchId,
    required String artifactName,
  }) async {
    final file = _artifactFile(batchId, artifactName);
    if (!await file.exists()) return null;
    return _asArtifact(file);
  }

  Future<void> discard(String batchId) async {
    final directory = Directory(p.join(_root.path, _id(batchId, 'batchId')));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  ImmutableArtifact _asArtifact(File file) => ImmutableArtifact(
    length: file.lengthSync(),
    openRead: () async => file.openRead(),
  );

  File _artifactFile(String batchId, String artifactName) {
    final parts = artifactName.split('/');
    if (parts.isEmpty ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.contains('\\'),
        )) {
      throw ArgumentError.value(artifactName, 'artifactName');
    }
    return File(p.joinAll([_root.path, _id(batchId, 'batchId'), ...parts]));
  }

  String _id(String value, String name) {
    if (value.isEmpty || value.contains('/') || value.contains('..')) {
      throw ArgumentError.value(value, name);
    }
    return value;
  }
}
