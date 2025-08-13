import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/extensions.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Connection extends HookConsumerWidget {
  const Connection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrollController = useScrollController();

    final connections = ref.watch(connectionsProvider);

    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text('连接服务'),
        trailingActions: [
          PlatformIconButton(
            icon: const Icon(Icons.add,),
            cupertino: (context, platform) {
              return CupertinoIconButtonData(
                padding: EdgeInsets.zero,
              );
            },
            onPressed: () {
              context.pushNamed(AppRoutes.newConnection.name);
              // final connection = ConnectionModel(
              //   id: (DateTime.now().millisecondsSinceEpoch).toString(),
              //   name: '格间同步到我的NAS',
              //   description: '这是一个新的连接',
              //   source: 'app',
              //   sourceDescription: '格间',
              //   target: 'http://192.168.31.168:5005',
              //   targetDescription: '我的NAS',
              //   createdAt: DateTime.now(),
              //   updatedAt: DateTime.now(),
              //   status: ConnectionStatus.pending,
              // );
              // ref.read(connectionsProvider.notifier).addSyncTask(connection);
              // logd('connections.length=${connections.value?.length}');
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
                      return Material(
                        child: ListTile(
                          title: Text(connection.name),
                          subtitle: Text('状态: ${connection.status}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () {
                              ref.read(connectionsProvider.notifier).removeSyncTask(connection);
                            },
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
