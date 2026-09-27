/// How one finished sync run is described to the user.
///
/// The stored run state stays `completed`: a run that had nothing to move did
/// finish. But a cold 「已完成」 printed above “上传对象 0 个 · 0 B” reads as if
/// data had been backed up, so the sentence a user reads is derived from the
/// objects the run itself moved. It never claims more than that: “nothing to
/// transfer” describes this run only, not that every local change has already
/// reached the cloud.
library;

import 'package:flutter/widgets.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

/// The transfers that completed inside [run]'s own window.
///
/// `transfer_jobs` holds one row per object and direction, so a later run
/// re-stamps the same row (`completed_at` is cleared when a transfer restarts).
/// Attribution therefore follows the completion timestamp window — exactly the
/// rule the run sheet already uses for its object counts, so the conclusion can
/// never contradict the numbers printed under it.
List<TransferJobRecord> runWindowTransfers(
  SyncRunRecord run,
  List<TransferJobRecord> history,
) {
  final end = run.completedAt;
  return [
    for (final transfer in history)
      if (transfer.completedAt != null &&
          transfer.profileId == run.profileId &&
          !transfer.completedAt!.isBefore(run.startedAt) &&
          (end == null || !transfer.completedAt!.isAfter(end)))
        transfer,
  ];
}

/// One-line conclusion for a run record.
///
/// [transfers] must be that run's own objects — pass
/// `runWindowTransfers(run, history)`. A completed run with none of them is
/// reported as “nothing to transfer” rather than “completed”, so a run that
/// moved no object is never presented as work that backed data up.
String syncRunConclusionLabel(
  SyncRunRecord run, {
  required List<TransferJobRecord> transfers,
  BuildContext? context,
}) => switch (run.state) {
  'running' => _runLabel(context, '运行中', 'Running'),
  'failed' => _runLabel(context, '失败', 'Failed'),
  'completed' when transfers.isEmpty => _runLabel(
    context,
    '无需传输',
    'Nothing to transfer',
  ),
  'completed' => _runLabel(context, '已完成', 'Completed'),
  // An unrecognised state is shown as it is, never smoothed into a conclusion.
  _ => run.state,
};

String _runLabel(BuildContext? context, String zh, String en) =>
    context == null ? zh : syncText(context, zh, en);
