import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/domain/sync_task.dart';

part '../../../generated/features/dashboard/state/dashboard_provider.g.dart';

@riverpod
class SyncTasks extends _$SyncTasks {
  @override
  FutureOr<List<SyncTask>> build() {
    return ref.watch(dashboardRepositoryProvider).syncTasks ?? [];
  }

  Future<void> addSyncTask(SyncTask task) async {
    final dashboardRepository = ref.read(dashboardRepositoryProvider);
    final previousTasks = await future;
    state = AsyncData([...previousTasks, task]);
    try {
      await dashboardRepository.setSyncTasks(state.value!);
    } catch (e, s) {
      state = AsyncData(previousTasks);
      rethrow;
    }
  }

  Future<void> removeSyncTask(SyncTask task) async {
    final dashboardRepository = ref.read(dashboardRepositoryProvider);
    final previousTasks = await future;
    final updatedTasks = previousTasks.where((t) => t.id != task.id).toList();
    state = AsyncData(updatedTasks);
    try {
      await dashboardRepository.setSyncTasks(updatedTasks);
    } catch (e, s) {
      state = AsyncData(previousTasks);
      rethrow;
    }
  }
}
