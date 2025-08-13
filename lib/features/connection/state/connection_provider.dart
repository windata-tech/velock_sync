import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';

part '../../../generated/features/connection/state/connection_provider.g.dart';

@riverpod
class Connections extends _$Connections {
  @override
  FutureOr<List<ConnectionModel>> build() {
    return ref.watch(connectionRepositoryProvider).connections ?? [];
  }

  Future<void> addSyncTask(ConnectionModel connectionModel) async {
    final connectionRepository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    state = AsyncData([...previousConnections, connectionModel]);
    try {
      await connectionRepository.setConnections(state.value!);
    } catch (e, s) {
      state = AsyncData(previousConnections);
      rethrow;
    }
  }

  Future<void> removeSyncTask(ConnectionModel connectionModel) async {
    final connectionRepository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    final updatedTasks = previousConnections.where((t) => t.id != connectionModel.id).toList();
    state = AsyncData(updatedTasks);
    try {
      await connectionRepository.setConnections(updatedTasks);
    } catch (e, s) {
      state = AsyncData(previousConnections);
      rethrow;
    }
  }
}