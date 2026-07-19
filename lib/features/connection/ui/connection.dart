import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/providers/provider_capability_summary.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

class Connection extends HookConsumerWidget {
  final String id;

  const Connection(this.id, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionDetailProvider(id));
    Future<void> testConnection() async {
      try {
        await ref.read(connectionsProvider.notifier).refreshStatuses();
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已更新连接状态。')));
        }
      } on Object {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法测试连接，请检查网络和授权。')));
        }
      }
    }

    return connection.when(
      data: (connectionModel) {
        if (connectionModel == null) {
          return Center(child: Text('Connection is null!'));
        }
        if (connectionModel.protocol is OAuthProtocolModel) {
          return _OAuthConnectionDetails(
            connection: connectionModel,
            onTestConnection: testConnection,
          );
        }
        // 监听整个状态
        final asyncFileBrowserState = ref.watch(
          remoteFileBrowserProvider(connectionModel: connectionModel),
        );
        final notifier = ref.read(
          remoteFileBrowserProvider(connectionModel: connectionModel).notifier,
        );
        return PopScope(
          canPop: asyncFileBrowserState.value?.isRoot ?? true,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            await notifier.goBack();
          },
          child: PlatformScaffold(
            iosContentPadding:
                Theme.of(context).platform == TargetPlatform.iOS ||
                Theme.of(context).platform == TargetPlatform.macOS,
            appBar: WDAppBar(
              title: Row(
                children: [
                  ConnectStatusIndicator(
                    status: connectionModel.status,
                    pendingProgressSize: 12,
                  ),
                  SizedBox(width: 8),
                  Text(connectionModel.name),
                ],
              ),
              trailingActions: [
                PlatformIconButton(
                  padding: EdgeInsets.zero,
                  cupertino: (context, platform) {
                    return CupertinoIconButtonData(
                      icon: const Icon(CupertinoIcons.pencil),
                    );
                  },
                  material: (context, platform) {
                    return MaterialIconButtonData(
                      icon: const Icon(Icons.edit_outlined, size: 24),
                    );
                  },
                  onPressed: () => context.pushNamed(
                    AppRoutes.newWebDav.name,
                    queryParameters: {'replace': connectionModel.id},
                  ),
                ),
                PlatformIconButton(
                  padding: EdgeInsets.zero,
                  cupertino: (context, platform) {
                    return CupertinoIconButtonData(
                      icon: Icon(CupertinoIcons.refresh),
                    );
                  },
                  material: (context, platform) {
                    return MaterialIconButtonData(
                      icon: Icon(Icons.refresh, size: 24),
                    );
                  },
                  onPressed: testConnection,
                ),
              ],
            ),
            body: asyncFileBrowserState.when(
              data: (fileBrowserState) {
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: _ProviderCapabilityDetails(
                        protocol: connectionModel.protocol,
                      ),
                    ),
                    SliverGrid(
                      delegate: SliverChildBuilderDelegate((
                        BuildContext context,
                        int index,
                      ) {
                        final file = fileBrowserState.files[index];
                        double? progress;
                        return StatefulBuilder(
                          builder:
                              (BuildContext context, StateSetter setState) {
                                return CupertinoButton(
                                  minimumSize: const Size(0, 0),
                                  padding: EdgeInsets.zero,
                                  child: RemoteFileItem(
                                    file: file,
                                    progress: progress,
                                  ),
                                  onPressed: () async {
                                    notifier.onRemoteFileItemTapped(file, (
                                      a,
                                      b,
                                    ) {
                                      setState(() {
                                        progress = a.toDouble() / b.toDouble();
                                      });
                                    });
                                  },
                                );
                              },
                        );
                      }, childCount: fileBrowserState.files.length),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 1.5,
                        mainAxisSpacing: 1,
                        crossAxisSpacing: 1,
                      ),
                    ),
                  ],
                );
              },
              error: (e, s) => Center(child: Text('Error! e=$e')),
              loading: () => Center(child: PlatformCircularProgressIndicator()),
            ),
          ),
        );
      },
      error: (e, s) => Center(child: Text('Error! e=$e')),
      loading: () => PlatformScaffold(
        appBar: WDAppBar(
          title: PlatformCircularProgressIndicator(),
          trailingActions: [
            PlatformIconButton(
              padding: EdgeInsets.zero,
              cupertino: (context, platform) {
                return CupertinoIconButtonData(
                  icon: Icon(CupertinoIcons.ellipsis_circle),
                );
              },
              material: (context, platform) {
                return MaterialIconButtonData(
                  icon: Icon(Icons.more_vert, size: 24),
                );
              },
              onPressed: null,
            ),
          ],
        ),
      ),
    );
  }
}

class _OAuthConnectionDetails extends StatelessWidget {
  const _OAuthConnectionDetails({
    required this.connection,
    required this.onTestConnection,
  });

  final ConnectionModel connection;
  final Future<void> Function() onTestConnection;

  @override
  Widget build(BuildContext context) {
    final protocol = connection.protocol as OAuthProtocolModel;
    return PlatformScaffold(
      iosContentPadding:
          Theme.of(context).platform == TargetPlatform.iOS ||
          Theme.of(context).platform == TargetPlatform.macOS,
      appBar: WDAppBar(
        title: Text(connection.name),
        trailingActions: [
          PlatformIconButton(
            icon: const Icon(Icons.refresh),
            onPressed: onTestConnection,
          ),
          PlatformTextButton(
            onPressed: () => context.pushNamed(
              AppRoutes.newOAuth.name,
              pathParameters: {'provider': protocol.providerType.name},
              queryParameters: {'replace': connection.id},
            ),
            child: const Text('重新授权'),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(protocol.accountLabel ?? connection.target),
            subtitle: const Text('授权账号或远端目录摘要'),
          ),
          _ProviderCapabilityDetails(protocol: protocol),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '同步内容使用所选远端目录保存为协议对象；这里不会显示或读取 OAuth Token。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderCapabilityDetails extends StatelessWidget {
  const _ProviderCapabilityDetails({required this.protocol});

  final ProtocolModel protocol;

  @override
  Widget build(BuildContext context) {
    final summary = providerCapabilitySummary(protocol);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${summary.providerName} 能力与限制'),
              const SizedBox(height: 8),
              if (summary.features.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final feature in summary.features)
                      Chip(label: Text(feature)),
                  ],
                ),
              for (final limitation in summary.limitations)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('限制：$limitation'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class RemoteFileItem extends StatelessWidget {
  final WebdavFile file;
  final double? progress;

  const RemoteFileItem({super.key, required this.file, this.progress});

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    return Container(
      padding: EdgeInsets.all(4),
      child: Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (file.isDir)
                Icon(
                  isApple ? CupertinoIcons.folder_solid : Icons.folder,
                  size: 32,
                )
              else
                Icon(
                  isApple ? CupertinoIcons.doc_text_fill : Icons.description,
                  size: 32,
                ),
              Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          if (progress != null && progress! < 1.0)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(4)),
                color: Colors.grey.withAlpha(187),
              ),
              child: Center(
                child: Stack(
                  fit: StackFit.loose,
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress,
                      color: Colors.white,
                    ),
                    Text(
                      "${(progress! * 100).toInt()}%",
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
