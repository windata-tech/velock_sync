import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';

part '../../../generated/features/connection/state/connection_provider.g.dart';

// Connections is app-global state that methods mutate after awaits. With the
// default autoDispose lifecycle, Riverpod 3 throws UnmountedRefException when a
// provider is disposed while one of these awaits is pending (e.g. `await
// future` inside addConnection/refreshStatuses). Keeping it alive for the app
// session makes those mutations race-free.
@Riverpod(keepAlive: true)
class Connections extends _$Connections {
  @override
  FutureOr<List<ConnectionModel>> build() async {
    final connections = await ref
        .watch(connectionRepositoryProvider)
        .loadConnections();
    // A microtask here runs before this build's data state is committed, so
    // the initial sweep used to always see an empty list. Schedule it on the
    // next event-loop turn instead, once `state.value` is populated.
    Future<void>.delayed(Duration.zero, _refreshAfterLoad);
    return connections;
  }

  Future<void> _refreshAfterLoad() async {
    if (!ref.mounted) return;
    try {
      await refreshStatuses();
    } on Object catch (e) {
      logw('Initial connection status refresh failed with ${e.runtimeType}.');
    }
  }

  Future<void> addConnection(CreateConnectionDto createConnectionDto) async {
    final connectionModel = ConnectionModel.fromCreateDto(createConnectionDto);
    final connectionRepository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    state = AsyncData([...previousConnections, connectionModel]);
    try {
      await connectionRepository.setConnections(state.value!);
    } catch (e) {
      state = AsyncData(previousConnections);
      rethrow;
    }
    // A failed status probe must not roll back a connection that is already
    // durably saved; the UI keeps the pending state until the next refresh.
    try {
      await refreshStatuses();
    } on Object {
      logw('Saved connection but could not refresh its status.');
    }
  }

  Future<void> removeConnection(ConnectionModel connectionModel) async {
    final connectionRepository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    final updatedTasks = previousConnections
        .where((t) => t.id != connectionModel.id)
        .toList();
    state = AsyncData(updatedTasks);
    try {
      await connectionRepository.setConnections(updatedTasks);
      await connectionRepository.disconnectProtocol(connectionModel.protocol);
      await refreshStatuses(); // 删除后立即刷新状态
    } catch (e) {
      state = AsyncData(previousConnections);
      // Keep the persisted connection when remote grant revocation or secure
      // credential deletion fails, so the user can retry safely.
      try {
        await connectionRepository.setConnections(previousConnections);
      } on Object {
        // The original failure remains the actionable error for the caller.
      }
      rethrow;
    }
  }

  /// Atomically points an existing OAuth connection at freshly authorised
  /// secure credentials. The previous local credential is removed only after
  /// the replacement connection has been persisted.
  Future<void> replaceOAuthConnection({
    required String connectionId,
    required OAuthProtocolModel protocol,
  }) async {
    final repository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    final index = previousConnections.indexWhere(
      (connection) => connection.id == connectionId,
    );
    if (index < 0) throw StateError('Connection no longer exists.');
    final previous = previousConnections[index];
    if (previous.protocol is! OAuthProtocolModel) {
      throw StateError('Only OAuth connections can be re-authorized.');
    }
    final replacement = reauthorizedOAuthConnection(previous, protocol);
    final updatedConnections = [...previousConnections]..[index] = replacement;
    state = AsyncData(updatedConnections);
    try {
      await repository.setConnections(updatedConnections);
      await repository.deleteCredential(previous.protocol.credentialReference);
      await refreshStatuses();
    } on Object {
      state = AsyncData(previousConnections);
      try {
        await repository.setConnections(previousConnections);
      } on Object {
        // Preserve the primary persistence/credential error for the caller.
      }
      rethrow;
    }
  }

  /// Replaces a WebDAV connection without ever serializing its password.
  ///
  /// The new configuration is durable before its superseded credential is
  /// cleaned up. A cleanup failure leaves an unreachable old secure-storage
  /// entry, which is safe and does not invalidate the saved connection.
  Future<void> replaceWebDavConnection({
    required String connectionId,
    required WebDavProtocolModel protocol,
  }) async {
    final repository = ref.read(connectionRepositoryProvider);
    final previousConnections = await future;
    final index = previousConnections.indexWhere(
      (connection) => connection.id == connectionId,
    );
    if (index < 0) throw StateError('Connection no longer exists.');
    final previous = previousConnections[index];
    if (previous.protocol is! WebDavProtocolModel) {
      throw StateError('Only WebDAV connections can be reconfigured.');
    }

    final replacement = reconfiguredWebDavConnection(previous, protocol);
    final updatedConnections = [...previousConnections]..[index] = replacement;
    state = AsyncData(updatedConnections);
    try {
      await repository.setConnections(updatedConnections);
    } on Object {
      state = AsyncData(previousConnections);
      try {
        await repository.setConnections(previousConnections);
      } on Object {
        // Preserve the original persistence error for the caller.
      }
      rethrow;
    }

    final previousCredentialRef =
        (previous.protocol as WebDavProtocolModel).credentialRef;
    if (previousCredentialRef != null &&
        previousCredentialRef != protocol.credentialRef) {
      try {
        await repository.deleteCredential(previousCredentialRef);
      } on Object {
        logw('Saved WebDAV replacement but could not remove old credential.');
      }
    }

    try {
      await refreshStatuses();
    } on Object {
      logw('Saved WebDAV replacement but could not refresh its status.');
    }
  }

  /// ✨ 1. 新增一个公开的刷新方法
  Future<void> refreshStatuses() async {
    final currentConnections = state.value;
    if (currentConnections == null || currentConnections.isEmpty) {
      return; // 如果没有连接，则无需刷新
    }

    // Surface the in-flight probe immediately so the connections page does
    // not appear unresponsive while a network check is running.
    state = AsyncData(
      currentConnections
          .map(
            (connection) =>
                connection.copyWith(status: ConnectionStatus.pending),
          )
          .toList(),
    );

    // ✨ 2. 并行检查所有连接的状态
    // 使用 Future.wait 可以最高效地同时发起所有网络请求。这里直接用普通
    // 探测函数，避免 autoDispose provider 在 await 期间被回收而抛
    // UnmountedRefException。
    late final List<bool> results;
    try {
      results = await Future.wait(
        currentConnections.map((conn) {
          return probeProtocolConnection(
            credentials: ref.read(credentialStoreProvider),
            protocol: conn.protocol,
          );
        }).toList(),
      );
    } on Object {
      state = AsyncData(currentConnections);
      rethrow;
    }

    // ✨ 3. 构建包含最新状态的新列表
    final updatedConnections = <ConnectionModel>[];
    for (int i = 0; i < currentConnections.length; i++) {
      final connection = currentConnections[i];
      final isConnected = results[i];
      final newStatus = isConnected
          ? ConnectionStatus.active
          : ConnectionStatus.inactive;

      // 只有在状态确实发生变化时才更新，避免不必要的重建
      if (connection.status != newStatus) {
        updatedConnections.add(
          connection.copyWith(status: newStatus, updatedAt: DateTime.now()),
        );
      } else {
        updatedConnections.add(connection);
      }
    }

    // ✨ 4. 用新列表更新状态，并持久化
    state = AsyncData(updatedConnections);
    try {
      await ref
          .read(connectionRepositoryProvider)
          .setConnections(updatedConnections);
    } on Object {
      // Keep diagnostics free of serialized connection data and underlying
      // storage payloads. The UI exposes a generic retryable state instead.
      logw('Failed to persist refreshed connection statuses.');
      state = AsyncData(currentConnections); // 可选：回滚状态
    }
  }
}

/// Produces the single safe persisted update for an OAuth re-authorization.
/// The credential is an opaque secure-storage reference, never token material.
ConnectionModel reauthorizedOAuthConnection(
  ConnectionModel current,
  OAuthProtocolModel protocol, {
  DateTime Function()? now,
}) {
  if (current.protocol is! OAuthProtocolModel) {
    throw ArgumentError.value(current, 'current', 'is not an OAuth connection');
  }
  return current.copyWith(
    protocol: protocol,
    target: protocol.targetLabel,
    targetDescription: 'provider=${protocol.providerType.name}',
    status: ConnectionStatus.pending,
    updatedAt: (now ?? DateTime.now)(),
  );
}

/// Produces the single safe persisted update for a WebDAV reconfiguration.
/// Credential values remain outside the model as secure-storage references.
ConnectionModel reconfiguredWebDavConnection(
  ConnectionModel current,
  WebDavProtocolModel protocol, {
  DateTime Function()? now,
}) {
  if (current.protocol is! WebDavProtocolModel) {
    throw ArgumentError.value(current, 'current', 'is not a WebDAV connection');
  }
  return current.copyWith(
    protocol: protocol,
    target: protocol.targetLabel,
    targetDescription: 'address=${protocol.address}',
    status: ConnectionStatus.pending,
    updatedAt: (now ?? DateTime.now)(),
  );
}

@Riverpod(keepAlive: true)
class ConnectionCreation extends _$ConnectionCreation {
  @override
  CreateConnectionDto? build() {
    return null;
  }

  void prepareNewConnection({
    required String name,
    required String? source,
    required String? target,
  }) {
    state = CreateConnectionDto.empty(
      name: name,
    ).copyWith(name: name, source: source, target: target);
  }

  Future<void> setProtocolAndFinalize({
    required ProtocolModel protocolModel,
  }) async {
    // The draft provider is kept alive for the session, but a save can still
    // arrive without a prepared draft (e.g. a direct wizard shortcut). Fall
    // back to the same defaults the new-connection page would have used.
    final base =
        state ??
        CreateConnectionDto.empty(
          name: '新建连接',
        ).copyWith(source: '格间', target: null);
    final completeConnection = base.copyWith(
      target: protocolModel.targetLabel,
      targetDescription: 'runtimeType=${protocolModel.runtimeType}',
      protocol: protocolModel,
    );

    await ref
        .read(connectionsProvider.notifier)
        .addConnection(completeConnection);
    state = null; // Clear the state after adding the connection
  }

  void cancelCreation() {
    state = null; // Clear the state to cancel the creation
  }
}

@riverpod
class ConnectionDetail extends _$ConnectionDetail {
  @override
  FutureOr<ConnectionModel?> build(String id) async {
    final provider = ref.watch(connectionRepositoryProvider);
    final connectionModel = await provider.getConnectionById(id);
    return connectionModel;
  }
}
