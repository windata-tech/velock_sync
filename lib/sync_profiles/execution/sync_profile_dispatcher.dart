import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

enum SyncProfileDispatchStatus {
  completed,
  skippedNotRunnable,
  skippedUnsupported,
  failed,
}

class SyncProfileDispatchResult {
  const SyncProfileDispatchResult({
    required this.profileId,
    required this.status,
    this.run,
    this.error,
  });

  final String profileId;
  final SyncProfileDispatchStatus status;
  final SyncProfileRunResult? run;
  final Object? error;

  bool get didRun => status == SyncProfileDispatchStatus.completed;
  bool get didFail => status == SyncProfileDispatchStatus.failed;
}

/// Routes all foreground and background sync runs through the same executor
/// registry. Concurrent requests for a profile join its in-flight dispatch,
/// avoiding duplicate SyncProfileRunner executions.
class SyncProfileDispatcher {
  SyncProfileDispatcher({
    required SyncProfileRepository profiles,
    required Iterable<SyncProfileExecutor> executors,
  }) : _profiles = profiles,
       _executors = {for (final executor in executors) executor.kind: executor};

  final SyncProfileRepository _profiles;
  final Map<SyncDatasetKind, SyncProfileExecutor> _executors;
  final Map<String, Future<SyncProfileDispatchResult>> _inFlight = {};

  Future<SyncProfileDispatchResult> dispatch(
    String profileId, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
  }) {
    final existing = _inFlight[profileId];
    if (existing != null) return existing;
    late final Future<SyncProfileDispatchResult> run;
    run =
        _dispatch(
          profileId,
          uploadLimits: uploadLimits,
          downloadLimits: downloadLimits,
        ).whenComplete(() {
          _inFlight.remove(profileId);
        });
    _inFlight[profileId] = run;
    return run;
  }

  Future<List<SyncProfileDispatchResult>> dispatchAll(
    Iterable<SyncProfileSummary> profiles, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
  }) async {
    final results = <SyncProfileDispatchResult>[];
    for (final profile in profiles) {
      results.add(
        await dispatch(
          profile.profileId,
          uploadLimits: uploadLimits,
          downloadLimits: downloadLimits,
        ),
      );
    }
    return results;
  }

  Future<SyncProfileDispatchResult> _dispatch(
    String profileId, {
    required BatchLimits uploadLimits,
    required DownloadLimits downloadLimits,
  }) async {
    try {
      final profile = await _profiles.read(profileId);
      if (profile == null || profile.state != SyncProfileState.active) {
        return SyncProfileDispatchResult(
          profileId: profileId,
          status: SyncProfileDispatchStatus.skippedNotRunnable,
        );
      }
      final executor = _executors[profile.kind];
      if (executor == null) {
        return SyncProfileDispatchResult(
          profileId: profileId,
          status: SyncProfileDispatchStatus.skippedUnsupported,
        );
      }
      final run = await executor.run(
        SyncProfileExecutionRequest(
          profile: profile,
          uploadLimits: uploadLimits,
          downloadLimits: downloadLimits,
        ),
      );
      return SyncProfileDispatchResult(
        profileId: profileId,
        status: SyncProfileDispatchStatus.completed,
        run: run,
      );
    } on Object catch (error) {
      return SyncProfileDispatchResult(
        profileId: profileId,
        status: SyncProfileDispatchStatus.failed,
        error: error,
      );
    }
  }
}
