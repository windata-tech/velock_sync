import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';

part '../../../generated/features/connection/state/connection_provider.g.dart';

@riverpod
class Connections extends _$Connections {
  @override
  FutureOr<List<ConnectionModel>> build() {
    return ref.watch(connectionRepositoryProvider).connections ?? [];
  }

  Future<void> addConnection(CreateConnectionDto createConnectionDto) async {
    final connectionModel = ConnectionModel.fromCreateDto(createConnectionDto);
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

  Future<void> removeConnection(ConnectionModel connectionModel) async {
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
    final completeConnection = state!.copyWith(target: protocolModel.address, targetDescription: 'runtimeType=${protocolModel.runtimeType}', protocol: protocolModel);

    await ref.read(connectionsProvider.notifier).addConnection(completeConnection);
    state = null; // Clear the state after adding the connection
  }

  void cancelCreation() {
    state = null; // Clear the state to cancel the creation
  }
}
