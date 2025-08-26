import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/extensions.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Connections extends HookConsumerWidget {
  const Connections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrollController = useScrollController();

    final connections = ref.watch(connectionsProvider);

    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text('连接服务'),
        trailingActions: [
          PlatformIconButton(
            icon: const Icon(Icons.add),
            cupertino: (context, platform) {
              return CupertinoIconButtonData(padding: EdgeInsets.zero);
            },
            onPressed: () {
              context.pushNamed(AppRoutes.newConnection.name);
            },
          ),
        ],
      ),
      body: connections.when(
        data: (connections) => connections.isEmpty
            ? Center(child: Text('没有连接的服务'))
            : CustomScrollView(
                slivers: [
                  PinnedHeaderSliver(
                    child: Container(
                      color: context.backgroundColor,
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Text('已连接服务'), //
                    ), // 这是头
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
                      final connection = connections[index];
                      return GestureDetector(
                        onTap: () {
                          context.pushNamed(
                            AppRoutes.connection.name,
                            pathParameters: {'id': connection.id},
                          );
                        },
                        child: Material(
                          child: ListTile(
                            title: Text(connection.name),
                            subtitle: Text('状态: ${connection.status}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () {
                                ref.read(connectionsProvider.notifier).removeConnection(connection);
                              },
                            ),
                          ),
                        ),
                      );
                    }, childCount: connections.length),
                  ),
                ],
              ),
        error: (e, s) => Text('Error! e=$e'),
        loading: () => const CircularProgressIndicator(),
      ),
    );
  }
}
