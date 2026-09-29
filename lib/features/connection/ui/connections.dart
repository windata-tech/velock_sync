import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/ui/connection_editor_entry.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/features/connection/ui/connection_info_sheet.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Connections extends HookConsumerWidget {
  const Connections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(connectionsProvider);
    final isRefreshing = useState(false);

    void createConnection() {
      // Prepare the draft from the user action, before pushing the route.
      // Updating a Riverpod notifier from NewConnection.build/useEffect causes
      // Riverpod 3 to throw "Tried to modify a provider while the widget tree
      // was building", which leaves the iOS page showing a red error overlay
      // and makes every button appear unresponsive.
      ref
          .read(connectionCreationProvider.notifier)
          .prepareNewConnection(
            name: syncText(context, '新建连接', 'New Connection'),
            source: syncText(context, '格间', 'Velock'),
            target: null,
          );
      context.pushNamed(AppRoutes.newConnection.name);
    }

    Future<void> refreshConnections() async {
      if (isRefreshing.value) return;
      isRefreshing.value = true;
      try {
        await ref.read(connectionsProvider.notifier).refreshStatuses();
        if (context.mounted) {
          showPlatformMessage(
            context,
            syncText(context, '已更新连接状态。', 'Connection status updated.'),
          );
        }
      } on Object {
        if (context.mounted) {
          showPlatformMessage(
            context,
            syncText(
              context,
              '无法测试连接，请检查网络和授权。',
              'Unable to test connections. Check your network and authorization.',
            ),
          );
        }
      } finally {
        if (context.mounted) isRefreshing.value = false;
      }
    }

    return AdaptiveSliverScaffold(
      title: syncText(context, '连接', 'Connections'),
      actions: [
        if (isApplePlatform(context))
          AdaptiveIconButton(
            tooltip: syncText(context, '新建连接', 'New Connection'),
            onPressed: createConnection,
            icon: const Icon(CupertinoIcons.add),
          ),
        AdaptiveIconButton(
          tooltip: syncText(context, '刷新连接状态', 'Refresh Connection Status'),
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
              tooltip: syncText(context, '新建连接', 'New Connection'),
              onPressed: createConnection,
              icon: const Icon(Icons.add_link_rounded),
              label: Text(syncText(context, '新建连接', 'New Connection')),
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
              title: syncText(context, '暂时无法加载', 'Unable to Load'),
              retryLabel: syncText(context, '重试', 'Retry'),
              message: syncText(
                context,
                '无法读取连接服务。',
                'Unable to load connections.',
              ),
              onRetry: refreshConnections,
            ),
          ),
        ],
        loading: () => [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AdaptiveLoadingState(
              label: syncText(context, '正在加载连接服务', 'Loading connections'),
            ),
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
      final availability = ref.read(remoteProviderAvailabilityProvider);
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveEmptyState(
            icon: adaptiveIcon(
              context,
              material: Icons.cloud_outlined,
              cupertino: CupertinoIcons.cloud,
            ),
            title: syncText(context, '还没有远端连接', 'No Remote Connections Yet'),
            message: syncText(
              context,
              '添加 ${availability.describe(chinese: true)} 连接，用于格间备份或文件同步。',
              'Add a ${availability.describe(chinese: false)} connection for Velock backup or file sync.',
            ),
            action: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              borderRadius: BorderRadius.circular(AppRadii.medium),
              onPressed: onCreate,
              child: Text(
                syncText(context, '添加远端连接', 'Add Remote Connection'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '已连接服务', 'Connected Services'),
          children: [
            for (final connection in connections)
              _ConnectionTile(
                connection: connection,
                onOpen: () => context.pushNamed(
                  AppRoutes.connection.name,
                  pathParameters: {'id': connection.id},
                ),
                onInfo: () =>
                    showConnectionInfoSheet(context, connection.protocol),
                onEdit: () => _editConnection(context, connection),
                onDelete: () => _removeConnection(context, ref, connection),
              ),
          ],
        ),
      ),
    ];
  }

  /// Editing a connection reopens the form it was created with, prefilled.
  void _editConnection(BuildContext context, ConnectionModel connection) {
    openConnectionEditor(context, connection);
  }

  Future<void> _removeConnection(
    BuildContext context,
    WidgetRef ref,
    ConnectionModel connection,
  ) async {
    final confirmed = await showAdaptiveConfirmation(
      context,
      title: syncText(context, '删除连接？', 'Delete Connection?'),
      message: syncText(
        context,
        '“${connection.name}”将从本机移除。已有同步配置可能需要重新选择远端连接。',
        '“${connection.name}” will be removed from this device. Existing sync profiles may need a new remote connection.',
      ),
      confirmLabel: syncText(context, '删除', 'Delete'),
      cancelLabel: syncText(context, '取消', 'Cancel'),
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(connectionsProvider.notifier).removeConnection(connection);
      if (context.mounted) {
        showPlatformMessage(
          context,
          syncText(context, '连接已删除。', 'Connection deleted.'),
        );
      }
    } on Object {
      if (context.mounted) {
        showPlatformMessage(
          context,
          syncText(context, '无法删除连接。', 'Unable to delete connection.'),
        );
      }
    }
  }
}

enum _ConnectionAction { info, edit, delete }

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.connection,
    required this.onOpen,
    required this.onInfo,
    required this.onEdit,
    required this.onDelete,
  });

  final ConnectionModel connection;
  final VoidCallback onOpen;
  final VoidCallback onInfo;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isOAuth = connection.protocol is OAuthProtocolModel;
    final tone = _connectionStatusTone(connection.status);
    final statusLabel = _connectionStatusLabel(context, connection.status);
    final target = connection.target.trim();
    return AdaptiveListTile(
      leading: AdaptiveIconBadge(
        icon: adaptiveIcon(
          context,
          material: isOAuth ? Icons.cloud_outlined : Icons.dns_outlined,
          cupertino: isOAuth
              ? CupertinoIcons.cloud
              : CupertinoIcons.rectangle_stack,
        ),
        color: tone.color(context),
      ),
      title: Text(
        connection.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppType.rowTitleStrong,
      ),
      subtitle: Text(
        '${_connectionProtocolLabel(context, connection)}'
        '${target.isEmpty ? '' : ' · $target'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onOpen,
      trailing: AdaptiveTrailingGroup(
        children: [
          AdaptiveStatusBadge(label: statusLabel, tone: tone),
          AdaptiveActionMenu<_ConnectionAction>(
            tooltip: syncText(context, '更多操作', 'More Actions'),
            items: [
              AdaptiveActionItem(
                value: _ConnectionAction.info,
                label: syncText(context, '连接说明', 'Connection info'),
                icon: Icons.info_outline,
              ),
              AdaptiveActionItem(
                value: _ConnectionAction.edit,
                label: syncText(context, '修改连接', 'Edit Connection'),
                icon: Icons.edit_outlined,
              ),
              AdaptiveActionItem(
                value: _ConnectionAction.delete,
                label: syncText(context, '删除连接', 'Delete Connection'),
                icon: Icons.delete_outline_rounded,
                isDestructive: true,
              ),
            ],
            onSelected: (action) => switch (action) {
              _ConnectionAction.info => onInfo(),
              _ConnectionAction.edit => onEdit(),
              _ConnectionAction.delete => onDelete(),
            },
          ),
        ],
      ),
    );
  }
}

String _connectionStatusLabel(BuildContext context, ConnectionStatus status) =>
    switch (status) {
      ConnectionStatus.pending => syncText(context, '检查中', 'Checking'),
      ConnectionStatus.active => syncText(context, '已连接', 'Connected'),
      ConnectionStatus.inactive => syncText(context, '未连接', 'Disconnected'),
      ConnectionStatus.failed => syncText(context, '连接失败', 'Connection Failed'),
    };

AppTone _connectionStatusTone(ConnectionStatus status) => switch (status) {
  ConnectionStatus.pending => AppTone.brand,
  ConnectionStatus.active => AppTone.ok,
  ConnectionStatus.inactive => AppTone.neutral,
  ConnectionStatus.failed => AppTone.danger,
};

String _connectionProtocolLabel(
  BuildContext context,
  ConnectionModel connection,
) {
  final protocol = connection.protocol;
  if (protocol is OAuthProtocolModel) {
    final name = protocol.providerType.name;
    if (name.toLowerCase().contains('google')) return 'Google Drive';
    if (name.toLowerCase().contains('one')) return 'OneDrive';
    return 'OAuth';
  }
  if (protocol is WebDavProtocolModel) return 'WebDAV';
  return syncText(context, '远端服务', 'Remote Service');
}
