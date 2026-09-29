import 'dart:io';

import 'package:dio/dio.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/ui/connection_info_sheet.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

class Connection extends HookConsumerWidget {
  final String id;

  /// Relative folder (already split into segments) to open first.
  ///
  /// Used by the backup detail page so "cloud location" lands on the folder
  /// that actually holds the backup instead of the connection root. The
  /// connection root stays the browsing boundary, so Back walks up to it.
  final List<String> initialSegments;

  const Connection(this.id, {super.key, this.initialSegments = const []});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionDetailProvider(id));
    Future<void> testConnection() async {
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
      }
    }

    return connection.when(
      data: (connectionModel) {
        if (connectionModel == null) {
          return AdaptivePageScaffold(
            appBar: WDAppBar(
              leading: AppBackButton(
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              title: Text(syncText(context, '连接详情', 'Connection details')),
            ),
            body: AdaptiveEmptyState(
              icon: adaptiveIcon(
                context,
                material: Icons.link_off,
                cupertino: CupertinoIcons.link,
              ),
              title: syncText(context, '连接不存在', 'Connection not found'),
              message: syncText(
                context,
                '这个连接可能已被删除。返回连接列表查看当前可用的连接。',
                'This connection may have been deleted. Go back to the connections list to see which ones are available.',
              ),
              action: AppPrimaryButton(
                label: syncText(context, '返回连接列表', 'Back to connections'),
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

        // One-shot: open the backup's own folder once the browser has loaded.
        final jumpedToInitialSegments = useRef(false);
        final wanted = initialSegments.isEmpty
            ? null
            : _scopedPath(connectionModel, initialSegments);
        if (wanted != null &&
            !jumpedToInitialSegments.value &&
            asyncFileBrowserState.hasValue &&
            !asyncFileBrowserState.isLoading &&
            notifier.currentPath != wanted) {
          jumpedToInitialSegments.value = true;
          Future<void>.microtask(() async {
            try {
              await notifier.go(wanted);
            } on Object {
              /* the browser keeps showing the connection root */
            }
          });
        }

        Future<void> refreshBrowser() async {
          await notifier.refresh();
          await testConnection();
        }

        final isLoading = asyncFileBrowserState.isLoading;
        final fileBrowserState = notifier.visibleState;
        final browserError = asyncFileBrowserState.hasError && !isLoading
            ? _RemoteBrowserErrorPresentation.from(
                context,
                asyncFileBrowserState.error!,
              )
            : null;
        final canGoUp = notifier.canGoBack;
        void goBack() {
          if (notifier.canGoBack) {
            notifier.goBack();
          } else {
            Navigator.of(context).maybePop();
          }
        }

        return PopScope(
          canPop: !canGoUp,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && notifier.canGoBack) notifier.goBack();
          },
          child: AdaptivePageScaffold(
            appBar: WDAppBar(
              leading: AppBackButton(
                onPressed: goBack,
                semanticLabel: canGoUp
                    ? syncText(context, '返回上一级文件夹', 'Parent folder')
                    : syncText(context, '返回', 'Back'),
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
                _ConnectionInfoButton(protocol: connectionModel.protocol),
                AdaptiveIconButton(
                  icon: const Icon(CupertinoIcons.pencil),
                  materialIcon: const Icon(Icons.edit_outlined, size: 24),
                  onPressed: () => context.pushNamed(
                    AppRoutes.newWebDav.name,
                    queryParameters: {'replace': connectionModel.id},
                  ),
                ),
                AdaptiveIconButton(
                  icon: const Icon(CupertinoIcons.refresh),
                  materialIcon: const Icon(Icons.refresh, size: 24),
                  onPressed: isLoading ? null : refreshBrowser,
                ),
              ],
            ),
            body: CustomScrollView(
              key: const Key('remote-browser-scroll'),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            fileBrowserState?.path ?? notifier.currentPath,
                            key: const Key('remote-browser-current-path'),
                            style: TextStyle(color: context.appSecondaryLabel),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Reserve the same space, including when idle, so the
                        // path and capability section never jump on loading.
                        SizedBox.square(
                          dimension: 20,
                          child: isLoading
                              ? Semantics(
                                  key: const Key('remote-browser-loading'),
                                  liveRegion: true,
                                  label: syncText(
                                    context,
                                    '正在读取文件夹',
                                    'Loading folder',
                                  ),
                                  child:
                                      const CircularProgressIndicator.adaptive(
                                        strokeWidth: 2,
                                      ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                if (browserError != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: AdaptiveErrorState(
                      title: browserError.title,
                      message: browserError.message,
                      details: kDebugMode
                          ? '${asyncFileBrowserState.error}\n\n${asyncFileBrowserState.stackTrace}'
                          : null,
                      onRetry: notifier.refresh,
                      secondaryAction: AppSecondaryButton(
                        label: syncText(context, '编辑连接', 'Edit connection'),
                        onPressed: () => context.pushNamed(
                          AppRoutes.newWebDav.name,
                          queryParameters: {'replace': connectionModel.id},
                        ),
                      ),
                    ),
                  )
                else if (fileBrowserState != null &&
                    fileBrowserState.files.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.sm,
                      AppSpacing.page,
                      AppSpacing.xl,
                    ),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) => SliverGrid(
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
                                      onPressed: isLoading
                                          ? null
                                          : () async {
                                              notifier.onRemoteFileItemTapped(
                                                file,
                                                (a, b) {
                                                  setState(() {
                                                    progress =
                                                        a.toDouble() /
                                                        b.toDouble();
                                                  });
                                                },
                                              );
                                            },
                                      child: SizedBox.expand(
                                        child: RemoteFileItem(
                                          file: file,
                                          progress: progress,
                                          inactive: isLoading,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                          );
                        }, childCount: fileBrowserState.files.length),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount:
                              ((constraints.crossAxisExtent + AppSpacing.sm) /
                                      (40 +
                                          MediaQuery.textScalerOf(
                                                context,
                                              ).scale(12) *
                                              3 +
                                          AppSpacing.sm))
                                  .floor()
                                  .clamp(1, 6),
                          childAspectRatio: 1,
                          mainAxisSpacing: AppSpacing.sm,
                          crossAxisSpacing: AppSpacing.sm,
                        ),
                      ),
                    ),
                  )
                else if (!isLoading && fileBrowserState != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: AdaptiveEmptyState(
                      icon: CupertinoIcons.folder,
                      title: syncText(
                        context,
                        '这个目录还是空的',
                        'This folder is empty',
                      ),
                      message: syncText(
                        context,
                        '远端文件和文件夹会显示在这里。',
                        'Remote files and folders show up here.',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      error: (error, stackTrace) => AdaptivePageScaffold(
        appBar: WDAppBar(
          leading: AppBackButton(
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(syncText(context, '连接详情', 'Connection details')),
        ),
        body: AdaptiveErrorState(
          title: syncText(context, '无法加载连接', 'Could not load connection'),
          message: syncText(
            context,
            '连接信息读取失败，请重试；如果问题持续，请返回连接列表检查配置。',
            'Reading the connection failed. Try again; if it keeps failing, go back to the connections list and check the settings.',
          ),
          details: kDebugMode ? '$error' : null,
          onRetry: () => ref.invalidate(connectionDetailProvider(id)),
        ),
      ),
      loading: () => AdaptivePageScaffold(
        appBar: WDAppBar(
          showTitle: false,
          title: AdaptiveSpinner(),
          trailingActions: [
            AdaptiveIconButton(
              icon: const Icon(CupertinoIcons.ellipsis_circle),
              materialIcon: const Icon(Icons.more_vert, size: 24),
              onPressed: null,
            ),
          ],
        ),
        body: const SizedBox.shrink(),
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
    return AdaptivePageScaffold(
      appBar: WDAppBar(
        leading: AppBackButton(
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(connection.name),
        trailingActions: [
          _ConnectionInfoButton(protocol: protocol),
          AdaptiveIconButton(
            icon: Icon(
              adaptiveIcon(
                context,
                material: Icons.refresh,
                cupertino: CupertinoIcons.refresh,
              ),
            ),
            onPressed: onTestConnection,
          ),
          AdaptiveTextButton(
            onPressed: () => context.pushNamed(
              AppRoutes.newOAuth.name,
              pathParameters: {'provider': protocol.providerType.name},
              queryParameters: {'replace': connection.id},
            ),
            child: Text(syncText(context, '重新授权', 'Authorize again')),
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
            header: syncText(context, '账号与目录', 'Account and folder'),
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
                subtitle: Text(
                  syncText(
                    context,
                    '授权账号或远端目录摘要',
                    'Signed-in account or remote folder summary',
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.xs,
              AppSpacing.page,
              0,
            ),
            child: Text(
              syncText(
                context,
                '同步内容使用所选远端目录保存为协议对象；这里不会显示或读取 OAuth Token。',
                'Synced items are stored as protocol objects in the remote folder you chose; no OAuth token is shown or read here.',
              ),
              style: TextStyle(color: context.appSecondaryLabel, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Connection-level reference information, deliberately kept out of the
/// directory content. Opening this sheet performs no probe or remote request.
class _ConnectionInfoButton extends StatelessWidget {
  const _ConnectionInfoButton({required this.protocol});

  final ProtocolModel protocol;

  @override
  Widget build(BuildContext context) {
    final label = syncText(context, '连接说明', 'Connection info');
    return Tooltip(
      message: label,
      child: AdaptiveIconButton(
        key: const Key('connection-info'),
        icon: Icon(
          adaptiveIcon(
            context,
            material: Icons.info_outline,
            cupertino: CupertinoIcons.info_circle,
          ),
          semanticLabel: label,
        ),
        onPressed: () => showConnectionInfoSheet(context, protocol),
      ),
    );
  }
}

class RemoteFileItem extends StatelessWidget {
  final WebdavFile file;
  final double? progress;

  /// The browser is busy, so the tile cannot be opened right now. The glyph
  /// keeps its own colour and the card is faded instead of turning grey.
  final bool inactive;

  const RemoteFileItem({
    super.key,
    required this.file,
    this.progress,
    this.inactive = false,
  });

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    final radius = BorderRadius.circular(AppRadii.medium);
    final textColor = Theme.of(context).textTheme.bodyMedium?.color;
    final content = DecoratedBox(
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
                    // Explicit colour so a disabled parent button cannot
                    // repaint the glyph with its own grey.
                    color: file.isDir
                        ? context.appPrimary
                        : context.appSecondaryLabel,
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
    // Always the same widget shape: swapping the root widget type would unmount
    // and rebuild the whole tile (and its text elements) on every refresh, which
    // is exactly the flicker the loading state must avoid.
    return Opacity(opacity: inactive ? AppOpacity.disabled : 1, child: content);
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

  factory _RemoteBrowserErrorPresentation.from(
    BuildContext context,
    Object error,
  ) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return _RemoteBrowserErrorPresentation(
            title: syncText(context, '连接超时', 'Connection timed out'),
            message: syncText(
              context,
              '远端服务器响应超时。请检查网络状况，或稍后重试。',
              'The remote server did not respond in time. Check your network, or try again later.',
            ),
          );
        case DioExceptionType.badCertificate:
          return _RemoteBrowserErrorPresentation(
            title: syncText(context, '证书不受信任', 'Certificate not trusted'),
            message: syncText(
              context,
              '无法验证远端服务器的安全证书，请检查服务器证书配置后重试。',
              'The remote server certificate could not be verified. Check the certificate configuration and try again.',
            ),
          );
        case DioExceptionType.badResponse:
          return _fromStatusCode(context, error.response?.statusCode);
        case DioExceptionType.cancel:
          return _RemoteBrowserErrorPresentation(
            title: syncText(context, '请求已取消', 'Request cancelled'),
            message: syncText(
              context,
              '本次文件夹读取已取消，点击重试可以重新加载。',
              'This folder read was cancelled. Tap retry to load it again.',
            ),
          );
        case DioExceptionType.connectionError:
          if (_isConnectionRefused(error.error)) {
            return _RemoteBrowserErrorPresentation(
              title: syncText(
                context,
                '无法连接到远端服务器',
                'Could not reach the remote server',
              ),
              message: syncText(
                context,
                '服务器拒绝了连接。请确认设备与服务器处于同一网络，并检查地址、端口以及 WebDAV 服务是否已启动。',
                'The server refused the connection. Check that this device is on the same network as the server, and check the address, the port and whether the WebDAV service is running.',
              ),
            );
          }
          return _RemoteBrowserErrorPresentation(
            title: syncText(context, '网络连接失败', 'Network connection failed'),
            message: syncText(
              context,
              '暂时无法连接到远端服务器，请检查网络和服务器状态后重试。',
              'The remote server cannot be reached right now. Check your network and the server state, then try again.',
            ),
          );
        case DioExceptionType.unknown:
          break;
      }
    }
    if (error is SocketException && _isConnectionRefused(error)) {
      return _RemoteBrowserErrorPresentation(
        title: syncText(
          context,
          '无法连接到远端服务器',
          'Could not reach the remote server',
        ),
        message: syncText(
          context,
          '服务器拒绝了连接。请确认设备与服务器处于同一网络，并检查地址、端口以及 WebDAV 服务是否已启动。',
          'The server refused the connection. Check that this device is on the same network as the server, and check the address, the port and whether the WebDAV service is running.',
        ),
      );
    }
    if (error is UnsupportedError) {
      return _RemoteBrowserErrorPresentation(
        title: syncText(
          context,
          '暂不支持浏览此连接',
          'Browsing this connection is not supported yet',
        ),
        message: syncText(
          context,
          '当前协议还不支持在线浏览文件，请返回连接列表使用其他功能。',
          'This protocol cannot browse files online yet. Go back to the connections list and use the other features.',
        ),
      );
    }
    return _RemoteBrowserErrorPresentation(
      title: syncText(context, '无法加载文件夹', 'Could not load the folder'),
      message: syncText(
        context,
        '读取远端目录时发生问题，请稍后重试。如果仍然失败，可以查看错误详情。',
        'Something went wrong while reading the remote folder. Try again later; if it still fails, open the error details.',
      ),
    );
  }

  static _RemoteBrowserErrorPresentation _fromStatusCode(
    BuildContext context,
    int? statusCode,
  ) {
    return switch (statusCode) {
      401 => _RemoteBrowserErrorPresentation(
        title: syncText(context, '认证失败', 'Sign-in failed'),
        message: syncText(
          context,
          '远端服务器拒绝了当前账号。请重新输入用户名和密码后再试。',
          'The remote server rejected this account. Enter the username and password again and retry.',
        ),
      ),
      403 => _RemoteBrowserErrorPresentation(
        title: syncText(context, '没有访问权限', 'No access permission'),
        message: syncText(
          context,
          '当前账号无法访问这个远端目录，请检查 WebDAV 权限设置。',
          'This account cannot access the remote folder. Check the WebDAV permissions.',
        ),
      ),
      404 => _RemoteBrowserErrorPresentation(
        title: syncText(context, '目录不存在', 'Folder not found'),
        message: syncText(
          context,
          '配置的远端目录不存在或已被移动，请检查 WebDAV 路径。',
          'The configured remote folder does not exist or has moved. Check the WebDAV path.',
        ),
      ),
      409 => _RemoteBrowserErrorPresentation(
        title: syncText(context, '远端目录发生冲突', 'Remote folder conflict'),
        message: syncText(
          context,
          '远端目录当前存在冲突，请确认没有其他设备正在同时操作。',
          'The remote folder is in conflict right now. Check that no other device is working in it at the same time.',
        ),
      ),
      final int code when code >= 500 => _RemoteBrowserErrorPresentation(
        title: syncText(context, '服务器暂时不可用', 'Server temporarily unavailable'),
        message: syncText(
          context,
          '远端服务器暂时无法处理请求，请稍后重试。',
          'The remote server cannot handle the request right now. Try again later.',
        ),
      ),
      final int code => _RemoteBrowserErrorPresentation(
        title: syncText(context, '远端返回异常', 'Unexpected remote reply'),
        message: syncText(
          context,
          '远端服务器返回 HTTP $code，请检查服务器配置后重试。',
          'The remote server returned HTTP $code. Check the server configuration and retry.',
        ),
      ),
      _ => _RemoteBrowserErrorPresentation(
        title: syncText(context, '远端返回异常', 'Unexpected remote reply'),
        message: syncText(
          context,
          '远端服务器返回了无法识别的响应，请稍后重试。',
          'The remote server returned a response that could not be recognised. Try again later.',
        ),
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

/// Absolute WebDAV path of a profile folder inside [connection], or null when
/// the connection cannot be expressed as a path (OAuth) or the segments are not
/// a valid relative folder (the value arrives through a route parameter).
String? _scopedPath(ConnectionModel connection, List<String> segments) {
  if (connection.protocol is! WebDavProtocolModel) return null;
  try {
    final scoped = RemoteObjectStoreFactory.scopeProtocol(
      connection.protocol,
      segments,
    );
    if (scoped is! WebDavProtocolModel) return null;
    final parts = RemoteObjectStoreFactory.webDavUri(
      scoped,
    ).pathSegments.where((segment) => segment.isNotEmpty);
    return '/${parts.join('/')}';
  } on Object {
    return null;
  }
}
