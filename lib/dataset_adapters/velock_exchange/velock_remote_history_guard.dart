import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// Conservative, list-only continuity check for one producer's commit names.
///
/// Requires exactly one commit for each sequence from 1 through the requested
/// boundary. This is NOT signature/content proof: it does not read commits or
/// check referenced envelopes, operations or blobs, nor provide a remote
/// snapshot under concurrent writes. Normal import verification is still needed.
/// Legitimate GC can remove history; without separately verified snapshot proof
/// this guard blocks it too. Progress checkpoints never substitute for history.
///
/// Work is bounded to 1,000 pages and 100,000 listed items (including unrelated
/// names). Providers' operational errors propagate; validation failures expose
/// only a fixed privacy-safe failure. A zero boundary requires no remote I/O.
Future<void> verifyVelockRemoteHistory({
  required RemoteObjectStore remote,
  required String vaultId,
  required String producerDeviceId,
  required int requiredThroughSequence,
}) async {
  const maxPages = 1000;
  const maxItems = 100000;
  const pageSize = 1000;
  if (requiredThroughSequence < 0 || requiredThroughSequence > maxItems) {
    throw const _HistoryIncomplete();
  }
  final String prefix;
  try {
    prefix = LogicalKeys.deviceCommitsPrefix(vaultId, producerDeviceId);
  } on ArgumentError {
    throw const _HistoryIncomplete();
  }
  if (requiredThroughSequence == 0) return;

  final pattern = RegExp(r'^(\d{20})-([^/\\]+)\.commit$');
  final sequences = <int>{};
  final cursors = <String>{};
  String? cursor;
  var itemCount = 0;
  for (var pageNumber = 0; pageNumber < maxPages; pageNumber++) {
    final page = await remote.list(
      prefix: prefix,
      cursor: cursor,
      limit: pageSize,
    );
    itemCount += page.items.length;
    if (page.items.length > pageSize || itemCount > maxItems) {
      throw const _HistoryIncomplete();
    }
    for (final item in page.items) {
      if (!item.logicalKey.startsWith(prefix)) continue;
      final suffix = item.logicalKey.substring(prefix.length);
      final match = pattern.firstMatch(suffix);
      if (match == null || match.end != suffix.length) continue;
      if (match.group(2)!.contains('..')) continue;
      final sequence = int.tryParse(match.group(1)!);
      if (sequence == null ||
          sequence < 1 ||
          sequence > requiredThroughSequence) {
        continue;
      }
      if (!sequences.add(sequence)) throw const _HistoryIncomplete();
    }
    cursor = page.nextCursor;
    if (cursor == null) {
      if (sequences.length != requiredThroughSequence) {
        throw const _HistoryIncomplete();
      }
      return;
    }
    // Scan to exhaustion even after coverage, to detect later duplicates.
    if (cursor.isEmpty || !cursors.add(cursor)) {
      throw const _HistoryIncomplete();
    }
  }
  throw const _HistoryIncomplete();
}

class _HistoryIncomplete implements SyncFailureException {
  const _HistoryIncomplete();

  @override
  String toString() => 'Remote Velock history is incomplete.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.velock_history_incomplete',
    category: SyncErrorCategory.userActionRequired,
    retryable: false,
    suggestedAction: '远端缺少历史备份，同步未完成。请连接原来的完整备份目录；不要删除旧备份或重置同步数据。',
  );
}
