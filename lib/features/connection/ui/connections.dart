import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Connections extends HookConsumerWidget {
  const Connections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(connectionsProvider);
    final isRefreshing = useState(false);

    void createConnection() {
      context.pushNamed(AppRoutes.newConnection.name);
    }

    Future<void> refreshConnections() async {
      if (isRefreshing.value) return;
      isRefreshing.value = true;
      try {
        await ref.read(connectionsProvider.notifier).refreshStatuses();
        if (context.mounted) showPlatformMessage(context, '已更新连接状态。');
      } on Object {
        if (context.mounted) {
          showPlatformMessage(context, '无法测试连接，请检查网络和授权。');
        }
      } finally {
        if (context.mounted) isRefreshing.value = false;
      }
    }

    return AdaptiveSliverScaffold(
      title: '连接',
      showTitle: false,
      actions: [
        if (isApplePlatform(context))
          AdaptiveIconButton(
            tooltip: '新建连接',
            onPressed: createConnection,
            icon: const Icon(CupertinoIcons.add),
          ),
        AdaptiveIconButton(
          tooltip: '刷新连接状态',
          onPressed: isRefreshing.value ? null : refreshConnections,
          icon: isRefreshing.value
              ? (isApplePlatform(context)
                    ? const CupertinoActivityIndicator()
                    : const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ))
              : Icon(
                  adaptiveIcon(
                    context,
                    material: Icons.refresh_rounded,
                    cupertino: CupertinoIcons.refresh,
                  ),
                ),
        ),
      ],
      floatingActionButton: isApplePlatform(context)
          ? null
          : FloatingActionButton.extended(
              tooltip: '新建连接',
              onPressed: createConnection,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('新建连接'),
            ),
      slivers: connections.when(
        data: (values) => _connectionSlivers(
          context,
          ref,
          values,
          onCreate: createConnection,
        ),
        error: (_, _) => [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AdaptiveErrorState(
              message: '无法读取连接服务。',
              onRetry: refreshConnections,
            ),
          ),
        ],
        loading: () => const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AdaptiveLoadingState(label: '正在加载连接服务'),
          ),
        ],
      ),
    );
  }

  List<Widget> _connectionSlivers(
    BuildContext context,
    WidgetRef ref,
    List<ConnectionModel> connections, {
    required VoidCallback onCreate,
  }) {
    if (connections.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveEmptyState(
            icon: adaptiveIcon(
              context,
              material: Icons.cloud_outlined,
              cupertino: CupertinoIcons.cloud,
            ),
            title: '还没有远端连接',
            message: '添加 WebDAV、Google Drive 或 OneDrive，作为加密同步的远端空间。',
            action: isApplePlatform(context)
                ? CupertinoButton.filled(
                    onPressed: onCreate,
                    child: const Text('添加远端连接'),
                  )
                : FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_link_rounded),
                    label: const Text('添加远端连接'),
                  ),
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '已连接服务',
          children: [
            for (final connection in connections)
              _ConnectionTile(
                connection: connection,
                onOpen: () => context.goNamed(
                  AppRoutes.connection.name,
                  pathParameters: {'id': connection.id},
                ),
                onDelete: () => _removeConnection(context, ref, connection),
              ),
          ],
        ),
      ),
    ];
  }

  Future<void> _removeConnection(
    BuildContext context,
    WidgetRef ref,
    ConnectionModel connection,
  ) async {
    final confirmed = await showAdaptiveConfirmation(
      context,
      title: '删除连接？',
      message: '“${connection.name}”将从本机移除。已有同步配置可能需要重新选择远端连接。',
      confirmLabel: '删除',
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(connectionsProvider.notifier).removeConnection(connection);
      if (context.mounted) showPlatformMessage(context, '连接已删除。');
    } on Object {
      if (context.mounted) showPlatformMessage(context, '无法删除连接。');
    }
  }
}

enum _ConnectionAction { delete }

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.connection,
    required this.onOpen,
    required this.onDelete,
  });

  final ConnectionModel connection;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isOAuth = connection.protocol is OAuthProtocolModel;
    final statusColor = _connectionStatusColor(context, connection.status);
    final statusLabel = _connectionStatusLabel(connection.status);
    return AdaptiveListTile(
      leading: AdaptiveIconBadge(
        icon: adaptiveIcon(
          context,
          material: isOAuth ? Icons.cloud_outlined : Icons.dns_outlined,
          cupertino: isOAuth
              ? CupertinoIcons.cloud
              : CupertinoIcons.rectangle_stack,
        ),
        color: statusColor,
      ),
      title: Text(connection.name),
      subtitle: Text(connection.target),
      onTap: onOpen,
      trailing: AdaptiveTrailingGroup(
        children: [
          AdaptiveStatusBadge(label: statusLabel, color: statusColor),
          AdaptiveActionMenu<_ConnectionAction>(
            items: const [
              AdaptiveActionItem(
                value: _ConnectionAction.delete,
                label: '删除连接',
                icon: Icons.delete_outline_rounded,
                isDestructive: true,
              ),
            ],
            onSelected: (_) => onDelete(),
          ),
        ],
      ),
    );
  }
}

String _connectionStatusLabel(ConnectionStatus status) => switch (status) {
  ConnectionStatus.pending => '检查中',
  ConnectionStatus.active => '可用',
  ConnectionStatus.inactive => '未连接',
  ConnectionStatus.failed => '异常',
};

Color _connectionStatusColor(BuildContext context, ConnectionStatus status) =>
    switch (status) {
      ConnectionStatus.pending => context.appPrimary,
      ConnectionStatus.active => AppColors.success,
      ConnectionStatus.inactive => context.appSecondaryLabel,
      ConnectionStatus.failed => Theme.of(context).colorScheme.error,
    };
