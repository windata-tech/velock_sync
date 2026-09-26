import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

/// A consumer-facing projection, never a new source of sync truth.
/// In particular, a saved configuration, uploaded object or staged batch is
/// not evidence that all business data is safely backed up or restored.
enum BackupStage {
  notStarted,
  transferring,
  needsAttention,
  needsVelock,
  paused,
  pending,
  waitingForRestore,
  lastTransferCompleted,
}

enum BackupAction {
  transfer,
  openVelock,
  resume,
  manage,
  resolve,
  reviewHistory,
}

class BackupPresentation {
  const BackupPresentation(
    this.stage,
    this.action, {
    this.errorCode,
    this.completedAt,
    this.availability,
  });
  final BackupStage stage;
  final BackupAction action;
  final String? errorCode;
  final DateTime? completedAt;
  final VelockWizardAvailability? availability;

  factory BackupPresentation.from({
    required SyncProfileState state,
    SyncProfileActivitySummary? activity,
    VelockWizardAvailability? availability,
    int pendingIncoming = 0,
    int pendingOutgoing = 0,
    bool isolated = false,
    bool running = false,
  }) {
    final run = activity?.latestRun;
    if (isolated) {
      return const BackupPresentation(
        BackupStage.needsAttention,
        BackupAction.manage,
      );
    }
    if (running || run?.state == 'running') {
      return const BackupPresentation(
        BackupStage.transferring,
        BackupAction.transfer,
      );
    }
    if (state == SyncProfileState.accessRequired ||
        (availability != null &&
            availability != VelockWizardAvailability.ready)) {
      final canOpen =
          state != SyncProfileState.accessRequired &&
          (availability == null ||
              availability == VelockWizardAvailability.authorizationRequired ||
              availability == VelockWizardAvailability.temporarilyUnavailable ||
              availability == VelockWizardAvailability.configurationMissing);
      return BackupPresentation(
        BackupStage.needsVelock,
        canOpen ? BackupAction.openVelock : BackupAction.manage,
        availability: availability,
      );
    }
    if ((activity?.unresolvedConflictCount ?? 0) > 0) {
      return const BackupPresentation(
        BackupStage.needsAttention,
        BackupAction.resolve,
      );
    }
    if (state == SyncProfileState.reauthorizationRequired ||
        state == SyncProfileState.blockedByConfiguration ||
        state == SyncProfileState.error) {
      return BackupPresentation(
        BackupStage.needsAttention,
        run?.errorCode == 'remote.velock_history_incomplete'
            ? BackupAction.reviewHistory
            : BackupAction.manage,
        errorCode: run?.errorCode,
      );
    }
    if (state == SyncProfileState.paused) {
      return const BackupPresentation(BackupStage.paused, BackupAction.resume);
    }
    if (run?.state == 'failed') {
      final code = run?.errorCode ?? '';
      final needsStorage =
          code.contains('atomic_create_unsupported') ||
          code.contains('history_incomplete') ||
          code.contains('unauthor') ||
          code.contains('401') ||
          code.contains('403') ||
          code.contains('404');
      return BackupPresentation(
        BackupStage.needsAttention,
        code == 'remote.velock_history_incomplete'
            ? BackupAction.reviewHistory
            : needsStorage
            ? BackupAction.manage
            : BackupAction.transfer,
        errorCode: code,
      );
    }
    if (pendingIncoming > 0) {
      return const BackupPresentation(
        BackupStage.waitingForRestore,
        BackupAction.openVelock,
      );
    }
    if (pendingOutgoing > 0 ||
        (activity?.pendingUploadCount ?? 0) > 0 ||
        (activity?.pendingDownloadCount ?? 0) > 0) {
      return const BackupPresentation(
        BackupStage.pending,
        BackupAction.transfer,
      );
    }
    if (run?.state == 'completed' && run?.completedAt != null) {
      return BackupPresentation(
        BackupStage.lastTransferCompleted,
        BackupAction.transfer,
        completedAt: run!.completedAt,
      );
    }
    return const BackupPresentation(
      BackupStage.notStarted,
      BackupAction.transfer,
    );
  }
}
