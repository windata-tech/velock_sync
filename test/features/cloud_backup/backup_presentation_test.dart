import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

void main() {
  BackupPresentation state({
    SyncProfileState state = SyncProfileState.active,
    String? run,
    String? error,
    bool completedAt = true,
    int upload = 0,
    int download = 0,
    int incoming = 0,
    int outgoing = 0,
    int conflicts = 0,
    bool isolated = false,
    bool running = false,
    VelockWizardAvailability? availability,
  }) => BackupPresentation.from(
    state: state,
    isolated: isolated,
    running: running,
    availability: availability,
    pendingIncoming: incoming,
    pendingOutgoing: outgoing,
    activity: SyncProfileActivitySummary(
      latestRun: run == null
          ? null
          : SyncRunRecord(
              runId: 'run',
              profileId: 'p',
              state: run,
              startedAt: DateTime.utc(2026, 9, 25),
              completedAt: completedAt ? DateTime.utc(2026, 9, 25, 12) : null,
              errorCode: error,
              errorCategory: null,
              retryable: null,
              retryAfter: null,
              suggestedAction: null,
              providerStatusCode: null,
            ),
      pendingUploadCount: upload,
      pendingDownloadCount: download,
      transferredBytes: 1234,
      unresolvedConflictCount: conflicts,
    ),
  );

  test('a saved connection and bytes never prove completed backup', () {
    expect(state().stage, BackupStage.notStarted);
  });
  test('completed transfer is explicitly not full business backup proof', () {
    final result = state(run: 'completed');
    expect(result.stage, BackupStage.lastTransferCompleted);
    expect(result.completedAt, DateTime.utc(2026, 9, 25, 12));
    expect(
      state(run: 'completed', completedAt: false).stage,
      BackupStage.notStarted,
    );
  });
  test('pending input needs Velock even after successful download', () {
    final result = state(run: 'completed', incoming: 2);
    expect(result.stage, BackupStage.waitingForRestore);
    expect(result.action, BackupAction.openVelock);
    expect(result.completedAt, isNull);
  });
  test('pending output or queued transfers override last success', () {
    for (final value in [
      state(run: 'completed', outgoing: 1),
      state(run: 'completed', upload: 1),
      state(run: 'completed', download: 1),
    ]) {
      expect(value.stage, BackupStage.pending);
    }
  });
  test('conflicts remain actionable, not hidden by a completed transfer', () {
    expect(state(run: 'completed', conflicts: 1).action, BackupAction.resolve);
  });
  test('failed completeness gate cannot be masked by downloaded content', () {
    final result = state(
      run: 'failed',
      error: 'remote.velock_history_incomplete',
      incoming: 1,
    );
    expect(result.stage, BackupStage.needsAttention);
    expect(result.action, BackupAction.manage);
  });
  test('unsafe cloud storage asks for repair, not endless retries', () {
    expect(
      state(
        run: 'failed',
        error: 'provider.webdav.atomic_create_unsupported',
      ).action,
      BackupAction.manage,
    );
  });
  test('network failure remains retryable', () {
    expect(
      state(run: 'failed', error: 'network.timeout').action,
      BackupAction.transfer,
    );
  });
  test(
    'revoked access offers management while locked Velock can be opened',
    () {
      expect(
        state(state: SyncProfileState.accessRequired).action,
        BackupAction.manage,
      );
      expect(
        state(availability: VelockWizardAvailability.accessRevoked).action,
        BackupAction.manage,
      );
      expect(
        state(
          availability: VelockWizardAvailability.authorizationRequired,
        ).action,
        BackupAction.openVelock,
      );
    },
  );
  test('paused, blocked, isolated and running are separate states', () {
    expect(state(state: SyncProfileState.paused).action, BackupAction.resume);
    expect(
      state(state: SyncProfileState.blockedByConfiguration).action,
      BackupAction.manage,
    );
    expect(
      state(isolated: true, run: 'completed').stage,
      BackupStage.needsAttention,
    );
    expect(state(running: true).stage, BackupStage.transferring);
    expect(state(run: 'running').stage, BackupStage.transferring);
  });
}
