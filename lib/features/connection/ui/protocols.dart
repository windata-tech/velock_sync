import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/icon_widgets.dart';

class Protocols extends HookConsumerWidget {
  const Protocols({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdaptiveScaffold(
      title: '选择远端协议',
      leading: PlatformIconButton(
        padding: EdgeInsets.zero,
        cupertino: (context, platform) =>
            CupertinoIconButtonData(icon: const Icon(CupertinoIcons.back)),
        material: (context, platform) =>
            MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
        onPressed: () => context.pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(
          top: AppSpacing.md,
          bottom: AppSpacing.xl,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.sm,
            ),
            child: Text(
              '选择一个远端空间保存加密同步数据。',
              style: TextStyle(color: context.appSecondaryLabel, height: 1.4),
            ),
          ),
          AdaptiveListSection(
            header: '可用协议',
            headerTrailing: _InlineHelpAction(
              onPressed: () => context.pushNamed(AppRoutes.connectionHelp.name),
            ),
            children: [
              AdaptiveListTile(
                leading: const ProtocolIcon(protocolName: 'DAV'),
                title: const Text('WebDAV'),
                subtitle: const Text('填写地址、端口和凭据，保存时自动测试连接'),
                showChevron: true,
                onTap: () => context.pushNamed(AppRoutes.newWebDav.name),
              ),
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.cloud_outlined,
                    cupertino: CupertinoIcons.cloud,
                  ),
                ),
                title: const Text('Google Drive'),
                subtitle: const Text('准备 OAuth Client ID，浏览器授权后选择同步目录'),
                showChevron: true,
                onTap: () => context.pushNamed(
                  AppRoutes.newOAuth.name,
                  pathParameters: {
                    'provider': RemoteProviderType.googleDrive.name,
                  },
                ),
              ),
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.cloud_outlined,
                    cupertino: CupertinoIcons.cloud,
                  ),
                ),
                title: const Text('OneDrive'),
                subtitle: const Text('准备 OAuth Client ID，浏览器授权后选择同步目录'),
                showChevron: true,
                onTap: () => context.pushNamed(
                  AppRoutes.newOAuth.name,
                  pathParameters: {
                    'provider': RemoteProviderType.oneDrive.name,
                  },
                ),
              ),
            ],
          ),
          AdaptiveListSection(
            header: '其他服务',
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.key_outlined,
                    cupertino: CupertinoIcons.lock,
                  ),
                  color: context.appSecondaryLabel,
                ),
                title: const Text('百度网盘'),
                subtitle: const Text('可配置 AppKey 和 Token；同步适配器尚未开放'),
                showChevron: true,
                onTap: () => context.pushNamed(AppRoutes.newBaiduToken.name),
              ),
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.lock_outline,
                    cupertino: CupertinoIcons.lock,
                  ),
                  color: context.appSecondaryLabel,
                ),
                title: const Text('阿里云盘'),
                subtitle: const Text('需要官方 Token Broker，当前未开放'),
                enabled: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineHelpAction extends StatelessWidget {
  const _InlineHelpAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '查看详细配置说明',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Text(
          '查看说明',
          style: TextStyle(
            color: context.appPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}
