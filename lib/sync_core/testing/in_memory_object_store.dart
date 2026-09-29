import 'dart:async';
import 'dart:typed_data';

import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Deterministic provider implementation used by provider contract tests.
class InMemoryObjectStore implements RemoteObjectStore {
  InMemoryObjectStore({
    this.capabilities = const RemoteCapabilities(
      supportsConditionalCreate: true,
      supportsConditionalUpdate: true,
      supportsRangeDownload: true,
      supportsResumableUpload: false,
      supportsServerHash: false,
      supportsTrash: false,
      supportsHiddenAppFolder: false,
      hasStrongListConsistency: true,
    ),
    this.answerNotFoundForMissingCollections = false,
  });

  @override
  final RemoteCapabilities capabilities;

  /// Models providers that answer 404 for a collection that was never created
  /// (WebDAV does). Off by default so existing fixtures keep the lenient
  /// "unknown prefix lists empty" behaviour; discovery paths that must treat
  /// "never created" as a normal empty state opt in.
  final bool answerNotFoundForMissingCollections;

  final Map<String, Uint8List> _objects = {};
  final Map<String, DateTime> _updatedAt = {};

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final data = _objects[logicalKey];
    if (data == null) {
      return null;
    }
    return _metadata(logicalKey, data);
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit');
    }
    if (answerNotFoundForMissingCollections &&
        prefix.isNotEmpty &&
        !_objects.keys.any((key) => key.startsWith(prefix))) {
      throw RemoteObjectNotFoundException(prefix);
    }
    final keys = _objects.keys.where((key) => key.startsWith(prefix)).toList()
      ..sort();
    final start = cursor == null ? 0 : int.tryParse(cursor) ?? 0;
    final pageKeys = keys.skip(start).take(limit).toList();
    final next = start + pageKeys.length;
    return RemoteObjectPage(
      items: pageKeys.map((key) => _metadata(key, _objects[key]!)).toList(),
      nextCursor: next < keys.length ? '$next' : null,
    );
  }

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) async* {
    cancellation?.throwIfCancelled();
    final bytes = _objects[logicalKey];
    if (bytes == null) {
      throw RemoteObjectNotFoundException(logicalKey);
    }
    final first = start ?? 0;
    final last = endInclusive ?? bytes.length - 1;
    if (first < 0 || last < first || last >= bytes.length) {
      throw RangeError.range(first, 0, bytes.length - 1);
    }
    yield Uint8List.fromList(bytes.sublist(first, last + 1));
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (ifAbsent && _objects.containsKey(logicalKey)) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in content) {
      cancellation?.throwIfCancelled();
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    if (result.length != contentLength) {
      throw ArgumentError.value(
        contentLength,
        'contentLength',
        'does not match stream content',
      );
    }
    _objects[logicalKey] = result;
    _updatedAt[logicalKey] = DateTime.now().toUtc();
    return _metadata(logicalKey, result);
  }

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _objects.remove(logicalKey);
    _updatedAt.remove(logicalKey);
  }

  RemoteObjectMetadata _metadata(String key, Uint8List bytes) =>
      RemoteObjectMetadata(
        logicalKey: key,
        size: bytes.length,
        updatedAt: _updatedAt[key]!,
      );
}
