import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';

class Connection extends HookConsumerWidget {
  final String id;

  const Connection(this.id, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionDetailProvider(id));
    return PlatformScaffold(
      iosContentPadding:
          Theme.of(context).platform == TargetPlatform.iOS ||
          Theme.of(context).platform == TargetPlatform.macOS,
      appBar: WDAppBar(title: Text('')),
      body: connection.when(
        data: (connectionModel) {
          if (connectionModel == null) {
            return Center(child: Text('连接不存在'));
          }
          if (connectionModel.status != ConnectionStatus.active) {
            return Center(child: Text('连接未激活'));
          }
          final remoteFilesAsync = ref.watch(
            remoteFilesProvider(connectionModel: connectionModel),
          );
          return remoteFilesAsync.when(
            data: (remoteFiles) {
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('名称: ${connectionModel.name}'),
                        SizedBox(height: 8),
                        Text('地址: ${connectionModel.protocol.address}'),
                        SizedBox(height: 8),
                        Text('状态: ${connectionModel.status}'),
                        SizedBox(height: 8),
                        // 其他连接详情
                        Text('文件:'),
                      ],
                    ),
                  ),
                  SliverGrid(
                    delegate: SliverChildBuilderDelegate((
                      BuildContext context,
                      int index,
                    ) {
                      final file = remoteFiles[index];
                      final platform = Theme.of(context).platform;
                      final isApple =
                          platform == TargetPlatform.iOS ||
                          platform == TargetPlatform.macOS;
                      return GestureDetector(
                        child: Container(
                          margin: EdgeInsets.all(8),
                          color: Colors.amber,
                          child: Column(
                            children: [
                              if (file.isDir)
                                Icon(
                                  isApple
                                      ? CupertinoIcons.folder
                                      : Icons.folder,
                                )
                              else
                                Icon(
                                  isApple
                                      ? CupertinoIcons.doc_text
                                      : Icons.description,
                                ),
                              Text(file.name),
                            ],
                          ),
                        ),
                        onTap: () async {
                          final s = ref.read(
                            remoteFilesProvider(
                              connectionModel: connectionModel,
                            ).notifier,
                          );
                          if (file.isDir) {
                            logger.d("file.path:${file.path}");
                            await s.go(file.path);
                          } else {
                            final ext = p.extension(file.path);
                            final file2 = await s.downloadFile(file.path, ext: ext);
                            final result = await OpenFilex.open(file2.path);
                            if (result.type != ResultType.done) {
                              logger.d("打开失败，原因: ${result.message}");
                              // 常见错误：文件不存在、没有 App 能打开这种格式
                            } else {
                              logger.d("成功调用外部 App");
                            }
                            // Fluttertoast.showToast(msg: "文件！${file.name}不能打开，因为还没下载，路径是：${file.path}");
                          }
                        },
                      );
                    }, childCount: remoteFiles.length),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                    ),
                  ),
                ],
              );
            },
            error: (e, s) => Center(child: Text('Error! e=$e')),
            loading: () => Center(child: const CircularProgressIndicator()),
          );
          // return CustomScrollView(
          //   slivers: [
          //     SliverToBoxAdapter(
          //       child: Column(
          //         children: [
          //           Text('名称: ${connectionModel.name}'),
          //           SizedBox(height: 8),
          //           Text('地址: ${connectionModel.protocol.address}'),
          //           SizedBox(height: 8),
          //           Text('状态: ${connectionModel.status}'),
          //           SizedBox(height: 8),
          //           // 其他连接详情
          //           Text('文件:'),
          //         ],
          //       ),
          //     ),
          //     SliverGrid(
          //       delegate: SliverChildBuilderDelegate(
          //         (BuildContext context, int index) {},
          //         childCount: 10,
          //       ),
          //       gridDelegate: gridDelegate,
          //     ),
          //   ],
          // );
          // return Column(
          //   children: [
          //     ListView(
          //       shrinkWrap: true,
          //       padding: EdgeInsets.all(16),
          //       children: [
          //         Text('名称: ${connectionModel.name}'),
          //         SizedBox(height: 8),
          //         Text('地址: ${connectionModel.protocol.address}'),
          //         SizedBox(height: 8),
          //         Text('状态: ${connectionModel.status}'),
          //         SizedBox(height: 8),
          //         // 其他连接详情
          //         Text('文件:'),
          //       ],
          //     ),
          //     Expanded(
          //       child: Builder(
          //         builder: (context) {
          //           if (connectionModel.status != ConnectionStatus.active) {
          //             return Center(child: Text('连接未激活'));
          //           }
          //           final remoteFilesAsync = ref.watch(
          //             remoteFilesProvider(connectionModel: connectionModel),
          //           );
          //           return remoteFilesAsync.when(
          //             data: (remoteFiles) {
          //               return GridView.builder(
          //                 gridDelegate:
          //                     SliverGridDelegateWithFixedCrossAxisCount(
          //                       crossAxisCount: 3,
          //                     ),
          //                 itemBuilder: (BuildContext context, int index) {
          //                   final file = remoteFiles[index];
          //                   return Container(
          //                     margin: EdgeInsets.all(8),
          //                     child: Text("${file.name}"),
          //                   );
          //                 },
          //                 itemCount: remoteFiles.length,
          //               );
          //             },
          //             error: (e, s) => Text('Error! e=$e'),
          //             loading: () => const CircularProgressIndicator(),
          //           );
          //         },
          //       ),
          //     ),
          //   ],
          // );
        },
        error: (e, s) => Center(child: Text('error:${e.toString()}')),
        loading: () => Center(child: PlatformCircularProgressIndicator()),
      ),
    );
  }
}
