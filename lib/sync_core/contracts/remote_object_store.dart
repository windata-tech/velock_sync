import 'dart:async';
import 'dart:typed_data';

import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Provider-neutral object storage contract. Provider-native IDs stay inside
/// implementations; the sync engine only ever handles protocol logical keys.
abstract interface class RemoteObjectStore {
  RemoteCapabilities get capabilities;

  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  });

  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  });

  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  });

  /// Creates an immutable protocol object. [ifAbsent] must not overwrite an
  /// existing object and is the primitive used for blobs and commit markers.
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  });

  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  });
}

/// Cooperative cancellation owned by the sync engine rather than any one HTTP
/// client. Adapters use it to cancel in-flight requests and retry backoff.
class RemoteOperationCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const RemoteOperationCancelledException();
  }
}

class RemoteOperationCancelledException implements SyncFailureException {
  const RemoteOperationCancelledException();

  @override
  String toString() => 'Remote operation was cancelled.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.operation_cancelled',
    category: SyncErrorCategory.userActionRequired,
    retryable: true,
    suggestedAction: '重新开始同步以继续传输。',
  );
}

class RemoteObjectMetadata {
  const RemoteObjectMetadata({
    required this.logicalKey,
    required this.size,
    required this.updatedAt,
    this.etag,
  });

  final String logicalKey;
  final int size;
  final DateTime updatedAt;
  final String? etag;
}

class RemoteObjectPage {
  const RemoteObjectPage({required this.items, this.nextCursor});

  final List<RemoteObjectMetadata> items;
  final String? nextCursor;
}

class RemoteObjectAlreadyExistsException implements SyncFailureException {
  const RemoteObjectAlreadyExistsException(this.logicalKey);

  final String logicalKey;

  @override
  String toString() => 'Remote object already exists.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.object_exists',
    category: SyncErrorCategory.remoteConflict,
    retryable: true,
    suggestedAction: '重新检查远端对象后重试。',
  );
}

class RemoteObjectNotFoundException implements SyncFailureException {
  const RemoteObjectNotFoundException(this.logicalKey);

  final String logicalKey;

  @override
  String toString() => 'Remote object was not found.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.object_not_found',
    category: SyncErrorCategory.remoteNotFound,
    retryable: false,
    suggestedAction: '请确认远端同步空间未被删除。',
  );
}

typedef ByteStream = Stream<Uint8List>;
