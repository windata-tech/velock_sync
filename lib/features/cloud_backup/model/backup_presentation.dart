import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

/// A consumer-facing projection, never a new source of sync truth.
/// In particular, a saved configuration, uploaded object or staged batch is
/// not evidence that all business data is safely backed up or restored.
enum BackupStage {
  notStarted,
  locationNeedsCheck,
  transferring,
  needsAttention,
  needsVelock,
  paused,
  pending,
  waitingForRestore,
  velockHoldsChanges,
  lastTransferCompleted,
}

enum BackupAction {
  transfer,
  openVelock,

  /// Velock is not installed: open its App Store page.
  getVelock,
  resume,
  manage,
  resolve,
  reviewHistory,
  checkStorage,

  /// The server rejected the saved login (401). Only the connection's
  /// username/password or authorization can fix it, so the action opens the
  /// connection editor rather than a page with nothing to change.
  fixConnection,
}

class BackupPresentation {
  const BackupPresentation(
    this.stage,
    this.action, {
    this.errorCode,
    this.completedAt,
    this.failedAt,
    this.availability,
  });
  final BackupStage stage;
  final BackupAction action;
  final String? errorCode;
  final DateTime? completedAt;
  final DateTime? failedAt;
  final VelockWizardAvailability? availability;

  factory BackupPresentation.from({
    required SyncProfileState state,
    SyncProfileActivitySummary? activity,
    VelockWizardAvailability? availability,
    int pendingIncoming = 0,
    int pendingOutgoing = 0,
    bool isolated = false,
    bool running = false,
    DateTime? locationChangedAt,
    bool velockHoldsChanges = false,
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
              availability == VelockWizardAvailability.velockUpdateRequired ||
              availability == VelockWizardAvailability.authorizationRequired ||
              availability == VelockWizardAvailability.temporarilyUnavailable ||
              availability == VelockWizardAvailability.configurationMissing);
      return BackupPresentation(
        BackupStage.needsVelock,
        availability == VelockWizardAvailability.appNotInstalled &&
                state != SyncProfileState.accessRequired
            ? BackupAction.getVelock
            : canOpen
            ? BackupAction.openVelock
            : BackupAction.manage,
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
            : _needsStorageCheck(run?.errorCode)
            ? BackupAction.checkStorage
            : _needsConnectionFix(run?.errorCode)
            ? BackupAction.fixConnection
            : BackupAction.manage,
        errorCode: run?.errorCode,
        failedAt: run?.state == 'failed'
            ? run?.completedAt ?? run?.startedAt
            : null,
      );
    }
    if (state == SyncProfileState.paused) {
      return const BackupPresentation(BackupStage.paused, BackupAction.resume);
    }
    if (run?.state == 'failed' &&
        run?.errorCode == 'local.velock_snapshot_application_required') {
      // The run stops here on purpose: the backup is downloaded and Velock
      // has to apply it. That is the next step, not a failure, so no
      // "last failure" time is shown for it.
      return BackupPresentation(
        BackupStage.waitingForRestore,
        BackupAction.openVelock,
        errorCode: run?.errorCode,
      );
    }
    if (run?.state == 'failed' &&
        run?.errorCode == 'local.velock_update_required') {
      // Only a newer Velock can fix this; retrying the backup cannot.
      return BackupPresentation(
        BackupStage.needsVelock,
        BackupAction.openVelock,
        errorCode: run?.errorCode,
        availability: VelockWizardAvailability.velockUpdateRequired,
      );
    }
    if (run?.state == 'failed' &&
        run?.errorCode == 'local.velock_recovery_required') {
      return BackupPresentation(
        BackupStage.needsAttention,
        BackupAction.openVelock,
        errorCode: run?.errorCode,
        failedAt: run?.completedAt ?? run?.startedAt,
      );
    }
    if (locationChangedAt != null &&
        (run == null || run.startedAt.isBefore(locationChangedAt))) {
      return const BackupPresentation(
        BackupStage.locationNeedsCheck,
        BackupAction.transfer,
      );
    }
    if (run?.state == 'failed') {
      final code = run?.errorCode ?? '';
      final needsStorage =
          code == 'remote.immutable_object_mismatch' ||
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
            : _needsStorageCheck(code)
            ? BackupAction.checkStorage
            : _needsConnectionFix(code)
            ? BackupAction.fixConnection
            : needsStorage
            ? BackupAction.manage
            : BackupAction.transfer,
        errorCode: code,
        failedAt: run?.completedAt ?? run?.startedAt,
      );
    }
    if (pendingIncoming > 0) {
      return const BackupPresentation(
        BackupStage.waitingForRestore,
        BackupAction.openVelock,
      );
    }
    // Velock still holds unhanded changes, a failed hand-off or conflicts
    // (Control/OutboxStatus.json). The last run finishing says nothing about
    // them, so do not show "last backup completed" as if all were safe.
    if (velockHoldsChanges) {
      return const BackupPresentation(
        BackupStage.velockHoldsChanges,
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

bool _needsConnectionFix(String? code) =>
    code != null && (code.contains('unauthor') || code.contains('401'));

bool _needsStorageCheck(String? code) =>
    code == 'provider.webdav.atomic_create_unsupported' ||
    code == 'provider.webdav.collection_not_writable';
