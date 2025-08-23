import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';

part '../../../generated/features/connection/state/connection_provider.g.dart';

@riverpod
class Connections extends _$Connections {
  @override
  FutureOr<List<ConnectionModel>> build() {
    final connections = ref.watch(connectionRepositoryProvider).connections;
    if (connections != null) {
      Future.microtask(() => refreshStatuses());
      return connections;
    } else {
      return [];
    }
  }

  Future<void> addConnection(CreateConnectionDto createConnectionDto) async {
    final connectionModel = ConnectionModel.fromCreateDto(createConnectionDto);
    final connectionRepository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    state = AsyncData([...previousConnections, connectionModel]);
    try {
      await connectionRepository.setConnections(state.value!);
      await refreshStatuses(); // 添加后立即刷新状态
    } catch (e, s) {
      state = AsyncData(previousConnections);
      rethrow;
    }
  }

  Future<void> removeConnection(ConnectionModel connectionModel) async {
    final connectionRepository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    final updatedTasks = previousConnections.where((t) => t.id != connectionModel.id).toList();
    state = AsyncData(updatedTasks);
    try {
      await connectionRepository.setConnections(updatedTasks);
      await refreshStatuses(); // 删除后立即刷新状态
    } catch (e, s) {
      state = AsyncData(previousConnections);
      rethrow;
    }
  }

  /// ✨ 1. 新增一个公开的刷新方法
  Future<void> refreshStatuses() async {
    final currentConnections = state.value;
    if (currentConnections == null || currentConnections.isEmpty) {
      return; // 如果没有连接，则无需刷新
    }

    // ✨ 2. 并行检查所有连接的状态
    // 使用 Future.wait 可以最高效地同时发起所有网络请求
    final results = await Future.wait(currentConnections.map((conn) {
      // 这里使用 ref.read，因为我们是在一个方法内部执行一次性读取操作
      // .future 会返回底层的 Future<bool>
      return ref.read(protocolConnectCheckerProvider(conn.protocol).future);
    }).toList());

    // ✨ 3. 构建包含最新状态的新列表
    final updatedConnections = <ConnectionModel>[];
    for (int i = 0; i < currentConnections.length; i++) {
      final connection = currentConnections[i];
      final isConnected = results[i];
      final newStatus = isConnected ? ConnectionStatus.active : ConnectionStatus.inactive;

      // 只有在状态确实发生变化时才更新，避免不必要的重建
      if (connection.status != newStatus) {
        updatedConnections.add(
          connection.copyWith(
            status: newStatus,
            updatedAt: DateTime.now(),
          ),
        );
      } else {
        updatedConnections.add(connection);
      }
    }

    // ✨ 4. 用新列表更新状态，并持久化
    state = AsyncData(updatedConnections);
    try {
      await ref.read(connectionRepositoryProvider).setConnections(updatedConnections);
    } catch (e, s) {
      // 如果持久化失败，可以考虑回滚状态，或者显示错误提示
      logw('Failed to persist updated connections! $e',stackTrace: s);
      state = AsyncData(currentConnections); // 可选：回滚状态
    }
  }
}

@riverpod
class ConnectionCreation extends _$ConnectionCreation {
  @override
  CreateConnectionDto? build() {
    return null;
  }

  void prepareNewConnection({required String name, required String? source, required String? target}) {
    state = CreateConnectionDto.empty(name: name).copyWith(name: name, source: source, target: target);
  }

  Future<void> setProtocolAndFinalize({required ProtocolModel protocolModel}) async {
    if (state == null) {
      loge('state is null. please call prepareNewConnection first.');
      return;
    }
    final completeConnection = state!.copyWith(
      target: protocolModel.address,
      targetDescription: 'runtimeType=${protocolModel.runtimeType}',
      protocol: protocolModel,
    );

    await ref.read(connectionsProvider.notifier).addConnection(completeConnection);
    state = null; // Clear the state after adding the connection
  }

  void cancelCreation() {
    state = null; // Clear the state to cancel the creation
  }
}
