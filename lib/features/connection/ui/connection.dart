import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

class Connection extends HookConsumerWidget {
  final String id;

  const Connection(this.id, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionDetailProvider(id));
    return connection.when(
      data: (connectionModel) {
        if (connectionModel == null) {
          return Center(child: Text('Connection is null!'));
        }
        // 监听整个状态
        final asyncFileBrowserState = ref.watch(remoteFileBrowserProvider(connectionModel: connectionModel));
        final notifier = ref.read(remoteFileBrowserProvider(connectionModel: connectionModel).notifier);
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
                  ConnectStatusIndicator(status: connectionModel.status, pendingProgressSize: 12),
                  SizedBox(width: 8),
                  Text(connectionModel.name),
                ],
              ),
              trailingActions: [
                PlatformIconButton(
                   padding: EdgeInsets.zero,
                  cupertino: (context, platform) {
                    return CupertinoIconButtonData(minSize: 0, icon: Icon(CupertinoIcons.ellipsis_circle));
                  },
                  material: (context, platform) {
                    return MaterialIconButtonData(icon: Icon(Icons.more_vert, size: 24));
                  },
                  onPressed: () {},
                ),
              ],
            ),
            body: asyncFileBrowserState.when(
              data: (fileBrowserState) {
                return CustomScrollView(
                  slivers: [
                    SliverGrid(
                      delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
                        final file = fileBrowserState.files[index];
                        return CupertinoButton(
                          minSize: 0,
                          padding: EdgeInsets.zero,
                          child: RemoteFileItem(file: file),
                          onPressed: () async {
                            notifier.onRemoteFileItemTapped(file);
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
                return CupertinoIconButtonData(minSize: 0, icon: Icon(CupertinoIcons.ellipsis_circle));
              },
              material: (context, platform) {
                return MaterialIconButtonData(icon: Icon(Icons.more_vert, size: 24));
              },
              onPressed: null,
            ),
          ],
        ),
      ),
    );
  }
}

class RemoteFileItem extends StatelessWidget {
  final WebdavFile file;

  const RemoteFileItem({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isApple = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    return Container(
      padding: EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (file.isDir)
            Icon(isApple ? CupertinoIcons.folder_solid : Icons.folder, size: 32)
          else
            Icon(isApple ? CupertinoIcons.doc_text_fill : Icons.description, size: 32),
          Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
