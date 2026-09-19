import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

/// Read-only inventory of what a profile already stored on its remote.
///
/// The scan lists the vault prefix and only reports counts, sizes, timestamps
/// and content categories; logical keys stay in memory and never reach the UI.

String remoteInventoryKind(String logicalKey) {
  if (logicalKey.contains('/blobs/')) return 'blobs';
  if (logicalKey.contains('/batches/')) return 'batches';
  if (logicalKey.contains('/commits/')) return 'commits';
  if (logicalKey.contains('/checkpoints/')) return 'checkpoints';
  if (logicalKey.contains('/acknowledgements/')) return 'acknowledgements';
  if (logicalKey.contains('/members/') ||
      logicalKey.contains('/join-') ||
      logicalKey.endsWith('/protocol.json')) {
    return 'protocol';
  }
  if (logicalKey.contains('/retention/') || logicalKey.contains('/gc/')) {
    return 'maintenance';
  }
  return 'other';
}

class RemoteInventoryEntry {
  const RemoteInventoryEntry({
    required this.kind,
    required this.count,
    required this.bytes,
    this.lastUpdatedAt,
  });

  final String kind;
  final int count;
  final int bytes;
  final DateTime? lastUpdatedAt;
}

class RemoteInventorySnapshot {
  const RemoteInventorySnapshot({
    required this.entries,
    required this.totalCount,
    required this.totalBytes,
    required this.truncated,
    required this.scannedAt,
    this.lastUpdatedAt,
  });

  final List<RemoteInventoryEntry> entries;
  final int totalCount;
  final int totalBytes;

  /// True when the scan stopped before the listing was exhausted.
  final bool truncated;
  final DateTime scannedAt;
  final DateTime? lastUpdatedAt;
}

class RemoteInventoryService {
  RemoteInventoryService({
    required ConnectionRepository connections,
    this.pageLimit = 100,
    this.maxObjects = 600,
    this.timeout = const Duration(seconds: 25),
  }) : _connections = connections;

  final ConnectionRepository _connections;
  final int pageLimit;
  final int maxObjects;
  final Duration timeout;

  Future<RemoteInventorySnapshot> scan({
    required String connectionId,
    required String vaultId,
  }) async {
    final connection = await _connections.getConnectionById(connectionId);
    if (connection == null) {
      throw StateError('远端连接已不存在。');
    }
    final store = await RemoteObjectStoreFactory.create(
      connections: _connections,
      protocol: connection.protocol,
    );
    final prefix = LogicalKeys.vaultPrefix(vaultId);
    final buckets = <String, _RemoteInventoryBucket>{};
    final deadline = DateTime.now().add(timeout);
    var scanned = 0;
    String? cursor;
    var truncated = false;
    while (true) {
      final page = await store.list(
        prefix: prefix,
        cursor: cursor,
        limit: pageLimit,
      );
      for (final item in page.items) {
        final bucket = buckets.putIfAbsent(
          remoteInventoryKind(item.logicalKey),
          _RemoteInventoryBucket.new,
        );
        bucket.add(item.size, item.updatedAt);
        scanned++;
      }
      cursor = page.nextCursor;
      if (cursor == null) break;
      if (scanned >= maxObjects || DateTime.now().isAfter(deadline)) {
        truncated = true;
        break;
      }
    }

    var totalBytes = 0;
    DateTime? lastUpdatedAt;
    final entries = <RemoteInventoryEntry>[];
    for (final entry in buckets.entries) {
      totalBytes += entry.value.bytes;
      final bucketLast = entry.value.lastUpdatedAt;
      if (bucketLast != null &&
          (lastUpdatedAt == null || bucketLast.isAfter(lastUpdatedAt))) {
        lastUpdatedAt = bucketLast;
      }
      entries.add(
        RemoteInventoryEntry(
          kind: entry.key,
          count: entry.value.count,
          bytes: entry.value.bytes,
          lastUpdatedAt: entry.value.lastUpdatedAt,
        ),
      );
    }
    entries.sort((a, b) => b.bytes.compareTo(a.bytes));
    return RemoteInventorySnapshot(
      entries: entries,
      totalCount: scanned,
      totalBytes: totalBytes,
      truncated: truncated,
      scannedAt: DateTime.now(),
      lastUpdatedAt: lastUpdatedAt,
    );
  }
}

class _RemoteInventoryBucket {
  int count = 0;
  int bytes = 0;
  DateTime? lastUpdatedAt;

  void add(int size, DateTime updatedAt) {
    count++;
    bytes += size;
    if (lastUpdatedAt == null || updatedAt.isAfter(lastUpdatedAt!)) {
      lastUpdatedAt = updatedAt;
    }
  }
}
