import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

/// Privacy-safe first-run assessment used before a profile writes its baseline.
/// It intentionally reports no provider path or object name to the UI.
enum InitialSyncRemoteState { empty, expectedVault, unrelatedContent }

class InitialSyncAssessment {
  const InitialSyncAssessment(this.remoteState);

  final InitialSyncRemoteState remoteState;
}

class InitialSyncAssessor {
  const InitialSyncAssessor();

  Future<InitialSyncAssessment> assess({
    required String vaultId,
    required RemoteObjectStore remote,
  }) async {
    if (await remote.stat(LogicalKeys.protocol(vaultId)) != null) {
      return const InitialSyncAssessment(InitialSyncRemoteState.expectedVault);
    }
    final page = await remote.list(limit: 1);
    return InitialSyncAssessment(
      page.items.isEmpty
          ? InitialSyncRemoteState.empty
          : InitialSyncRemoteState.unrelatedContent,
    );
  }
}
