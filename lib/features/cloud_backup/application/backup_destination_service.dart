import 'dart:async';
import 'dart:convert';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

final backupDestinationServiceProvider = Provider<BackupDestinationService>((
  ref,
) {
  final connections = ref.watch(connectionRepositoryProvider);
  Future<RemoteObjectStore> open(
    String id,
    List<String> remoteRootSegments,
  ) async {
    final connection = await connections.getConnectionById(id);
    if (connection == null) {
      throw const BackupDestinationException('connection_missing');
    }
    return RemoteObjectStoreFactory.create(
      connections: connections,
      protocol: connection.protocol,
      remoteRootSegments: remoteRootSegments,
    );
  }

  return BackupDestinationService(
    open: (id) => open(id, const []),
    openScoped: open,
  );
});

class BackupDestinationException implements Exception {
  const BackupDestinationException(this.code);
  final String code;
  @override
  String toString() => 'Backup destination check: $code';
}

/// Setup-only checks. A discovered commit is NOT a verified or restored backup;
/// signatures, complete history and blobs still go through the existing runner.
class BackupDestinationService {
  BackupDestinationService({
    required this.open,
    this.openScoped,
    String Function()? nextId,
    this.timeout = const Duration(seconds: 25),
  }) : nextId = nextId ?? const Uuid().v4;
  final Future<RemoteObjectStore> Function(String connectionId) open;
  final Future<RemoteObjectStore> Function(
    String connectionId,
    List<String> remoteRootSegments,
  )?
  openScoped;
  final String Function() nextId;
  final Duration timeout;

  Future<void> check({
    required String connectionId,
    required String vaultId,
    required Iterable<String> trustedProducerIds,
    required bool restoring,
    List<String> remoteRootSegments = const [],
  }) async {
    final cancellation = RemoteOperationCancellation();
    final timer = Timer(timeout, cancellation.cancel);
    try {
      final Future<RemoteObjectStore> remoteFuture;
      if (remoteRootSegments.isEmpty) {
        remoteFuture = open(connectionId);
      } else {
        final scopedOpen = openScoped;
        if (scopedOpen == null) {
          throw const BackupDestinationException('scoped_open_unavailable');
        }
        remoteFuture = scopedOpen(connectionId, remoteRootSegments);
      }
      final remote = await remoteFuture.timeout(timeout);
      if (restoring) {
        // Only locally trusted producers from the signed Velock approval.
        // Never scan other accounts or let an empty folder become a new vault.
        for (final producer in trustedProducerIds.toSet()) {
          cancellation.throwIfCancelled();
          final prefix = LogicalKeys.deviceCommitsPrefix(vaultId, producer);
          final page = await remote
              .list(prefix: prefix, limit: 1, cancellation: cancellation)
              .timeout(timeout);
          if (page.items.any(
            (item) =>
                item.logicalKey.startsWith(prefix) &&
                item.logicalKey.endsWith('.commit'),
          )) {
            return;
          }
        }
        throw const BackupDestinationException('backup_not_found');
      }
      final id = nextId();
      if (!RegExp(r'^[a-zA-Z0-9-]{1,128}$').hasMatch(id)) {
        throw const BackupDestinationException('invalid_probe_id');
      }
      final key = 'velock-sync/preflight/$id.probe';
      final payload = utf8.encode('Velock storage check $id');
      var owned = false;
      try {
        await remote
            .put(
              key,
              Stream.value(payload),
              contentLength: payload.length,
              ifAbsent: true,
              cancellation: cancellation,
            )
            .timeout(timeout);
        owned = true;
        final received = <int>[];
        await for (final chunk
            in remote.read(key, cancellation: cancellation).timeout(timeout)) {
          cancellation.throwIfCancelled();
          if (received.length + chunk.length > payload.length) {
            throw const BackupDestinationException('readback_failed');
          }
          received.addAll(chunk);
        }
        if (received.length != payload.length ||
            Iterable<int>.generate(
              payload.length,
            ).any((i) => received[i] != payload[i])) {
          throw const BackupDestinationException('readback_failed');
        }
      } finally {
        // Delete only a key we successfully created, never a collision. The
        // cleanup gets its own bound so cancelling a transfer cannot orphan it.
        if (owned) await remote.delete(key).timeout(timeout);
      }
    } finally {
      timer.cancel();
      cancellation.cancel();
    }
  }
}
