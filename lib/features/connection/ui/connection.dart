import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/providers/provider_capability_summary.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
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
          showPlatformMessage(context, '已更新连接状态。');
        }
      } on Object {
        if (context.mounted) {
          showPlatformMessage(context, '无法测试连接，请检查网络和授权。');
        }
      }
    }

    return connection.when(
      data: (connectionModel) {
        if (connectionModel == null) {
          return PlatformScaffold(
            iosContentPadding: false,
            appBar: WDAppBar(
              leading: PlatformIconButton(
                padding: EdgeInsets.zero,
                cupertino: (context, platform) => CupertinoIconButtonData(
                  icon: const Icon(CupertinoIcons.back),
                ),
                material: (context, platform) =>
                    MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
                onPressed: () => context.pop(),
              ),
              title: const Text('连接详情'),
            ),
            body: AdaptiveEmptyState(
              icon: adaptiveIcon(
                context,
                material: Icons.link_off,
                cupertino: CupertinoIcons.link,
              ),
              title: '连接不存在',
              message: '这个连接可能已被删除。返回连接列表查看当前可用的连接。',
              action: AppPrimaryButton(
                label: '返回连接列表',
                onPressed: () => context.pop(),
              ),
            ),
          );
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

        Future<void> refreshBrowser() async {
          ref.invalidate(
            remoteFileBrowserProvider(connectionModel: connectionModel),
          );
          await testConnection();
        }

        return PlatformScaffold(
          iosContentPadding: false,
          appBar: WDAppBar(
            leading: PlatformIconButton(
              padding: EdgeInsets.zero,
              cupertino: (context, platform) => CupertinoIconButtonData(
                icon: const Icon(CupertinoIcons.back),
              ),
              material: (context, platform) =>
                  MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
              onPressed: () => context.pop(),
            ),
            title: Row(
              children: [
                ConnectStatusIndicator(
                  status: connectionModel.status,
                  pendingProgressSize: 12,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    connectionModel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
                onPressed: refreshBrowser,
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
                  if (fileBrowserState.files.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: AdaptiveEmptyState(
                        icon: CupertinoIcons.folder,
                        title: '这个目录还是空的',
                        message: '远端文件和文件夹会显示在这里。',
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        AppSpacing.sm,
                        AppSpacing.page,
                        AppSpacing.xl,
                      ),
                      sliver: SliverGrid(
                        delegate: SliverChildBuilderDelegate((
                          BuildContext context,
                          int index,
                        ) {
                          final file = fileBrowserState.files[index];
                          double? progress;
                          return StatefulBuilder(
                            builder:
                                (BuildContext context, StateSetter setState) {
                                  return SizedBox.expand(
                                    child: CupertinoButton(
                                      minimumSize: Size.zero,
                                      padding: EdgeInsets.zero,
                                      child: SizedBox.expand(
                                        child: RemoteFileItem(
                                          file: file,
                                          progress: progress,
                                        ),
                                      ),
                                      onPressed: () async {
                                        notifier.onRemoteFileItemTapped(file, (
                                          a,
                                          b,
                                        ) {
                                          setState(() {
                                            progress =
                                                a.toDouble() / b.toDouble();
                                          });
                                        });
                                      },
                                    ),
                                  );
                                },
                          );
                        }, childCount: fileBrowserState.files.length),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              childAspectRatio: 1,
                              mainAxisSpacing: AppSpacing.sm,
                              crossAxisSpacing: AppSpacing.sm,
                            ),
                      ),
                    ),
                ],
              );
            },
            error: (error, stackTrace) {
              final presentation = _RemoteBrowserErrorPresentation.from(error);
              return AdaptiveErrorState(
                title: presentation.title,
                message: presentation.message,
                details: kDebugMode
                    ? '$error\n\n${stackTrace.toString().trim()}'
                    : null,
                onRetry: () => ref.invalidate(
                  remoteFileBrowserProvider(connectionModel: connectionModel),
                ),
                secondaryAction: AppSecondaryButton(
                  label: '编辑连接',
                  onPressed: () => context.pushNamed(
                    AppRoutes.newWebDav.name,
                    queryParameters: {'replace': connectionModel.id},
                  ),
                ),
              );
            },
            loading: () => Center(child: PlatformCircularProgressIndicator()),
          ),
        );
      },
      error: (error, stackTrace) => PlatformScaffold(
        iosContentPadding: false,
        appBar: WDAppBar(
          leading: PlatformIconButton(
            padding: EdgeInsets.zero,
            cupertino: (context, platform) =>
                CupertinoIconButtonData(icon: const Icon(CupertinoIcons.back)),
            material: (context, platform) =>
                MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
            onPressed: () => context.pop(),
          ),
          title: const Text('连接详情'),
        ),
        body: AdaptiveErrorState(
          title: '无法加载连接',
          message: '连接信息读取失败，请重试；如果问题持续，请返回连接列表检查配置。',
          details: kDebugMode ? '$error' : null,
          onRetry: () => ref.invalidate(connectionDetailProvider(id)),
        ),
      ),
      loading: () => PlatformScaffold(
        appBar: WDAppBar(
          showTitle: false,
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
      iosContentPadding: false,
      appBar: WDAppBar(
        leading: PlatformIconButton(
          padding: EdgeInsets.zero,
          cupertino: (context, platform) =>
              CupertinoIconButtonData(icon: const Icon(CupertinoIcons.back)),
          material: (context, platform) =>
              MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
          onPressed: () => context.pop(),
        ),
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
        padding: const EdgeInsets.only(
          top: AppSpacing.md,
          bottom: AppSpacing.xl,
        ),
        children: [
          AdaptiveListSection(
            header: '账号与目录',
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.account_circle_outlined,
                    cupertino: CupertinoIcons.person_crop_circle,
                  ),
                ),
                title: Text(protocol.accountLabel ?? connection.target),
                subtitle: const Text('授权账号或远端目录摘要'),
              ),
            ],
          ),
          _ProviderCapabilityDetails(protocol: protocol),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.xs,
              AppSpacing.page,
              0,
            ),
            child: Text(
              '同步内容使用所选远端目录保存为协议对象；这里不会显示或读取 OAuth Token。',
              style: TextStyle(color: context.appSecondaryLabel, height: 1.35),
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
    return AdaptiveListSection(
      header: '${summary.providerName} 能力与限制',
      children: [
        if (summary.features.isNotEmpty)
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.check_circle_outline,
                cupertino: CupertinoIcons.check_mark_circled,
              ),
              color: AppColors.success,
            ),
            title: const Text('支持能力'),
            subtitle: Text(summary.features.join(' · ')),
          ),
        for (final limitation in summary.limitations)
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.info_outline,
                cupertino: CupertinoIcons.info,
              ),
              color: AppColors.warning,
            ),
            title: const Text('使用限制'),
            subtitle: Text(limitation),
          ),
      ],
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

    final radius = BorderRadius.circular(AppRadii.medium);
    final textColor = Theme.of(context).textTheme.bodyMedium?.color;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.appGroupedSurface.withValues(alpha: 0.82),
        borderRadius: radius,
        border: Border.all(
          color: context.appSeparator.withValues(
            alpha: AppOpacity.groupedBorder,
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    file.isDir
                        ? (isApple ? CupertinoIcons.folder_solid : Icons.folder)
                        : (isApple
                              ? CupertinoIcons.doc_text_fill
                              : Icons.description),
                    size: 26,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                    ).copyWith(color: textColor),
                  ),
                ],
              ),
              if (progress != null && progress! < 1.0)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.grey.withAlpha(187),
                    borderRadius: radius,
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
                          '${(progress! * 100).toInt()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Maps transport failures from the WebDAV file browser to short,
/// actionable copy. Raw exceptions stay in the collapsed details panel.
class _RemoteBrowserErrorPresentation {
  const _RemoteBrowserErrorPresentation({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  factory _RemoteBrowserErrorPresentation.from(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return const _RemoteBrowserErrorPresentation(
            title: '连接超时',
            message: '远端服务器响应超时。请检查网络状况，或稍后重试。',
          );
        case DioExceptionType.badCertificate:
          return const _RemoteBrowserErrorPresentation(
            title: '证书不受信任',
            message: '无法验证远端服务器的安全证书，请检查服务器证书配置后重试。',
          );
        case DioExceptionType.badResponse:
          return _fromStatusCode(error.response?.statusCode);
        case DioExceptionType.cancel:
          return const _RemoteBrowserErrorPresentation(
            title: '请求已取消',
            message: '本次文件夹读取已取消，点击重试可以重新加载。',
          );
        case DioExceptionType.connectionError:
          if (_isConnectionRefused(error.error)) {
            return const _RemoteBrowserErrorPresentation(
              title: '无法连接到远端服务器',
              message: '服务器拒绝了连接。请确认设备与服务器处于同一网络，并检查地址、端口以及 WebDAV 服务是否已启动。',
            );
          }
          return const _RemoteBrowserErrorPresentation(
            title: '网络连接失败',
            message: '暂时无法连接到远端服务器，请检查网络和服务器状态后重试。',
          );
        case DioExceptionType.unknown:
          break;
      }
    }
    if (error is SocketException && _isConnectionRefused(error)) {
      return const _RemoteBrowserErrorPresentation(
        title: '无法连接到远端服务器',
        message: '服务器拒绝了连接。请确认设备与服务器处于同一网络，并检查地址、端口以及 WebDAV 服务是否已启动。',
      );
    }
    if (error is UnsupportedError) {
      return const _RemoteBrowserErrorPresentation(
        title: '暂不支持浏览此连接',
        message: '当前协议还不支持在线浏览文件，请返回连接列表使用其他功能。',
      );
    }
    return const _RemoteBrowserErrorPresentation(
      title: '无法加载文件夹',
      message: '读取远端目录时发生问题，请稍后重试。如果仍然失败，可以查看错误详情。',
    );
  }

  static _RemoteBrowserErrorPresentation _fromStatusCode(int? statusCode) {
    return switch (statusCode) {
      401 => const _RemoteBrowserErrorPresentation(
        title: '认证失败',
        message: '远端服务器拒绝了当前账号。请重新输入用户名和密码后再试。',
      ),
      403 => const _RemoteBrowserErrorPresentation(
        title: '没有访问权限',
        message: '当前账号无法访问这个远端目录，请检查 WebDAV 权限设置。',
      ),
      404 => const _RemoteBrowserErrorPresentation(
        title: '目录不存在',
        message: '配置的远端目录不存在或已被移动，请检查 WebDAV 路径。',
      ),
      409 => const _RemoteBrowserErrorPresentation(
        title: '远端目录发生冲突',
        message: '远端目录当前存在冲突，请确认没有其他设备正在同时操作。',
      ),
      final int code when code >= 500 => const _RemoteBrowserErrorPresentation(
        title: '服务器暂时不可用',
        message: '远端服务器暂时无法处理请求，请稍后重试。',
      ),
      final int code => _RemoteBrowserErrorPresentation(
        title: '远端返回异常',
        message: '远端服务器返回 HTTP $code，请检查服务器配置后重试。',
      ),
      _ => const _RemoteBrowserErrorPresentation(
        title: '远端返回异常',
        message: '远端服务器返回了无法识别的响应，请稍后重试。',
      ),
    };
  }
}

bool _isConnectionRefused(Object? cause) {
  if (cause is! SocketException) return false;
  final code = cause.osError?.errorCode;
  return code == 61 ||
      code == 111 ||
      code == 10061 ||
      cause.message.toLowerCase().contains('connection refused');
}
