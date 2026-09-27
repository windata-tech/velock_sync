import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/app_format.dart';

/// Runs one location in place, then reports exactly what moved.
///
/// Deletions never happen behind the user's back. A run that crosses the safety
/// threshold holds them, this function shows WHICH paths are held (not just how
/// many), and only the paths in that review are approved on the follow-up run
/// ([PlainFolderSyncService.runConfirmedDeletions]). A plan that grew between
/// the review and the deletion run is held again rather than deleted.
///
/// Returns true when the location was run at least once (so the caller
/// refreshes), false when nothing ran.
Future<bool> runPlainLocation(
  BuildContext context,
  WidgetRef ref,
  PlainLocationView view,
) async {
  final service = ref.read(plainFolderServiceProvider);
  // No modal progress dialog: the location card's own button shows the run
  // state (spinner + disabled) while this future is in flight.
  final first = await _plainRunOnce(context, view, () async {
    return await service.run(view.profile.profileId);
  });
  if (first == null) return false;
  if (!context.mounted) return true;
  var outcome = first;
  while (true) {
    // Checked at the top of every iteration: the review dialog is shown after
    // an await, and the page may have been popped meanwhile.
    if (!context.mounted) return true;
    final held = outcome.heldDeletions;
    if (held == null || held.isEmpty) return true;
    final confirmed = await reviewHeldDeletions(context, held, outcome);
    if (!confirmed || !context.mounted) return true;
    // Only the reviewed paths are approved; anything new is held again.
    final confirmedPaths = held.paths;
    final profileId = view.profile.profileId;
    // The closure only captures the id, so no BuildContext crosses the gap.
    final next = await _plainRunOnce(context, view, () async {
      return await service.runConfirmedDeletions(profileId, confirmedPaths);
    });
    if (next == null) return true;
    outcome = next;
  }
}

/// Runs one pass, reporting a failure as a dialog instead of an exception.
Future<MirrorRunOutcome?> _plainRunOnce(
  BuildContext context,
  PlainLocationView view,
  Future<MirrorRunOutcome> Function() pass,
) async {
  try {
    return await pass();
  } on Object catch (failure) {
    if (!context.mounted) return null;
    await showAdaptiveNotice(
      context: context,
      title: syncText(context, '同步没有完成', 'The sync did not finish'),
      message: plainFailureMessage(
        context,
        // Classify the raw exception: a dropped socket or a timeout must read
        // as a network problem, not as "cause unknown".
        SyncFailureClassifier.classify(failure).errorCode,
        connectionName: view.connection?.name,
      ),
      confirmLabel: syncText(context, '知道了', 'OK'),
    );
    return null;
  }
}

/// Shows exactly which files a held deletion pass would remove.
///
/// The count alone cannot be reviewed: the user is about to delete files, so
/// the review lists the paths themselves (the first [maxListedPaths], then a
/// remainder line) and keeps the confirm action destructive.
Future<bool> reviewHeldDeletions(
  BuildContext context,
  MirrorHeldDeletions held,
  MirrorRunOutcome outcome,
) async {
  const maxListedPaths = 20;
  final paths = held.actions
      .map((action) => action.relativePath)
      .where((path) => path.isNotEmpty)
      .toList(growable: false)
    ..sort();
  final listed = paths.take(maxListedPaths).join('\n');
  final remaining = paths.length - maxListedPaths;
  final detail = remaining > 0
      ? syncText(
          context,
          '$listed\n…还有 $remaining 项',
          '$listed\n…and $remaining more',
        )
      : listed;
  final confirm = await showAdaptiveConfirmation(
    context,
    title: syncText(
      context,
      '确认删除这 ${held.actions.length} 项？',
      'Delete these ${held.actions.length} items?',
    ),
    message: syncText(
      context,
      '删除数量超过安全阈值，本次一项都没有删除。\n\n将删除：\n$detail\n\n${plainRunResultMessage(context, outcome)}\n\n删除的是本地和远端对应的文件，无法从这个页面撤销。',
      'The number of deletions passed the safety threshold, so nothing was deleted this time.\n\nWill delete:\n$detail\n\n${plainRunResultMessage(context, outcome)}\n\nThis removes the matching files locally and remotely and cannot be undone from this screen.',
    ),
    confirmLabel: syncText(context, '删除这些文件', 'Delete these items'),
    cancelLabel: syncText(context, '先不删除', 'Not now'),
    isDestructive: true,
    confirmKey: const Key('plain-confirm-deletions'),
  );
  return confirm;
}

/// Exact result wording: counts and time, never a vague "backed up".
String plainRunResultMessage(BuildContext context, MirrorRunOutcome outcome) {
  final stats = outcome.stats;
  if (stats.didFail) {
    return plainFailureMessage(context, stats.failureCode);
  }
  final lines = <String>[
    syncText(
      context,
      '上传 ${stats.uploadedFileCount} 个文件，下载 ${stats.downloadedFileCount} 个文件',
      'Uploaded ${stats.uploadedFileCount} files, downloaded ${stats.downloadedFileCount} files',
    ),
    if (stats.deletedLocalCount + stats.deletedRemoteCount > 0)
      syncText(
        context,
        '删除 ${stats.deletedLocalCount + stats.deletedRemoteCount} 项',
        'Deleted ${stats.deletedLocalCount + stats.deletedRemoteCount} items',
      ),
    if (outcome.heldDeletionCount > 0)
      syncText(
        context,
        '待确认删除 ${outcome.heldDeletionCount} 项（本次未删除）',
        '${outcome.heldDeletionCount} deletions held back (nothing deleted)',
      ),
    if (stats.conflictCount > 0)
      syncText(
        context,
        '冲突 ${stats.conflictCount} 个：已按当前冲突设置处理，两端都不会静默丢失。',
        '${stats.conflictCount} conflicts handled by your conflict setting; neither side was silently lost.',
      ),
    if (stats.changedCount == 0 &&
        stats.conflictCount == 0 &&
        stats.skippedCount == 0)
      syncText(context, '两边内容已经一致。', 'Both sides already match.'),
    if (stats.skippedCount > 0)
      syncText(
        context,
        '有 ${stats.skippedCount} 项这次没有比较（方向设置跳过，或文件较大需要下次继续），它们不会被改动。',
        '${stats.skippedCount} items were not compared in this run (skipped by the direction setting, or too large for this pass). Nothing about them was changed.',
      ),
    syncText(
      context,
      '传输 ${AppFormat.bytes(stats.bytesTransferred)}',
      'Transferred ${AppFormat.bytes(stats.bytesTransferred)}',
    ),
  ];
  return lines.join('\n');
}

