import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_baseline.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// Conservative, list-only continuity check for one producer's commit names.
///
/// Requires exactly one commit after the verified full-snapshot boundary (or 0)
/// through the requested
/// boundary. This is NOT signature/content proof: it does not read commits or
/// check referenced envelopes, operations or blobs, nor provide a remote
/// snapshot under concurrent writes. Normal import verification is still needed.
/// Legitimate GC can remove history; without separately verified snapshot proof
/// this guard blocks it too. Progress checkpoints never substitute for history.
///
/// Work is bounded to 1,000 pages and 100,000 listed items (including unrelated
/// names). A missing commit collection fails as incomplete history; other
/// provider operational errors propagate. Validation failures expose
/// only a fixed privacy-safe failure. A zero boundary requires no remote I/O.
Future<void> verifyVelockRemoteHistory({
  required RemoteObjectStore remote,
  required String vaultId,
  required String producerDeviceId,
  required int requiredThroughSequence,
  VerifiedVelockSnapshotBaseline? baseline,
}) async {
  const maxPages = 1000;
  const maxItems = 100000;
  const pageSize = 1000;
  if (requiredThroughSequence < 0 || requiredThroughSequence > maxItems) {
    throw const VelockRemoteHistoryIncomplete();
  }
  final String prefix;
  try {
    prefix = LogicalKeys.deviceCommitsPrefix(vaultId, producerDeviceId);
  } on ArgumentError {
    throw const VelockRemoteHistoryIncomplete();
  }
  final coveredThrough =
      baseline?.coveredThrough(
        remote: remote,
        vaultId: vaultId,
        producerId: producerDeviceId,
      ) ??
      0;
  if (requiredThroughSequence <= coveredThrough) return;

  final pattern = RegExp(r'^(\d{20})-([^/\\]+)\.commit$');
  final sequences = <int>{};
  final cursors = <String>{};
  String? cursor;
  var itemCount = 0;
  for (var pageNumber = 0; pageNumber < maxPages; pageNumber++) {
    final RemoteObjectPage page;
    try {
      page = await remote.list(prefix: prefix, cursor: cursor, limit: pageSize);
    } on RemoteObjectNotFoundException {
      // A positive local boundary requires historical commits. WebDAV returns
      // 404 when their collection has never been created in a new location.
      // Fail closed with the same repair route as an empty/incomplete listing;
      // this says nothing about whether the selected backup folder exists.
      throw const VelockRemoteHistoryIncomplete();
    }
    itemCount += page.items.length;
    if (page.items.length > pageSize || itemCount > maxItems) {
      throw const VelockRemoteHistoryIncomplete();
    }
    for (final item in page.items) {
      if (!item.logicalKey.startsWith(prefix)) continue;
      final suffix = item.logicalKey.substring(prefix.length);
      final match = pattern.firstMatch(suffix);
      if (match == null || match.end != suffix.length) continue;
      if (match.group(2)!.contains('..')) continue;
      final sequence = int.tryParse(match.group(1)!);
      if (sequence == null ||
          sequence <= coveredThrough ||
          sequence > requiredThroughSequence) {
        continue;
      }
      if (!sequences.add(sequence)) throw const VelockRemoteHistoryIncomplete();
    }
    cursor = page.nextCursor;
    if (cursor == null) {
      if (sequences.length != requiredThroughSequence - coveredThrough) {
        throw const VelockRemoteHistoryIncomplete();
      }
      return;
    }
    // Scan to exhaustion even after coverage, to detect later duplicates.
    if (cursor.isEmpty || !cursors.add(cursor)) {
      throw const VelockRemoteHistoryIncomplete();
    }
  }
  throw const VelockRemoteHistoryIncomplete();
}

class VelockRemoteHistoryIncomplete implements SyncFailureException {
  const VelockRemoteHistoryIncomplete();

  @override
  String toString() => 'Remote Velock history is incomplete.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.velock_history_incomplete',
    category: SyncErrorCategory.userActionRequired,
    retryable: false,
    suggestedAction: '远端备份不完整，备份尚未完成。请选择原来的完整备份，或用本机当前内容建立新备份。',
  );
}
