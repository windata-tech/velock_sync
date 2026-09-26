import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Protocols extends HookConsumerWidget {
  const Protocols({super.key, this.returnTo});
  final String? returnTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdaptiveScaffold(
      title: syncText(context, '选择云端位置', 'Choose cloud storage'),
      leading: AppBackButton(
        semanticLabel: syncText(context, '返回', 'Back'),
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
              syncText(
                context,
                '同步数据会以加密对象写入远端空间，远端服务无法读取内容。',
                'Sync data is stored remotely as encrypted objects. The remote service cannot read their contents.',
              ),
              style: AppType.footnote.copyWith(
                color: context.appSecondaryLabel,
              ),
            ),
          ),
          AdaptiveListSection(
            header: syncText(context, '保存到哪里', 'Where to save'),
            headerTrailing: _InlineHelpAction(
              onPressed: () => context.pushNamed(AppRoutes.connectionHelp.name),
            ),
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.rectangle_stack,
                  color: AppTone.brand.color(context),
                ),
                title: Text('WebDAV'),
                subtitle: Text(
                  syncText(
                    context,
                    '使用服务器地址、端口和账号密码连接 NAS 或网盘服务。',
                    'Connect to a NAS or cloud storage service using its server address, port, and credentials.',
                  ),
                  maxLines: 2,
                ),
                showChevron: true,
                onTap: () => context.pushNamed(
                  AppRoutes.newWebDav.name,
                  queryParameters: {'returnTo': ?returnTo},
                ),
              ),
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.folder_badge_plus,
                  color: AppTone.ok.color(context),
                ),
                title: Text('Google Drive'),
                subtitle: Text(
                  syncText(
                    context,
                    '使用 Google 账号授权，然后选择同步所用的云端目录。',
                    'Sign in with Google, then choose a cloud folder for sync.',
                  ),
                  maxLines: 2,
                ),
                showChevron: true,
                onTap: () => context.pushNamed(
                  AppRoutes.newOAuth.name,
                  queryParameters: {'returnTo': ?returnTo},
                  pathParameters: {
                    'provider': RemoteProviderType.googleDrive.name,
                  },
                ),
              ),
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.cloud,
                  color: AppTone.brand.color(context),
                ),
                title: Text('OneDrive'),
                subtitle: Text(
                  syncText(
                    context,
                    '使用 Microsoft 账号授权，然后选择同步所用的云端目录。',
                    'Sign in with Microsoft, then choose a cloud folder for sync.',
                  ),
                  maxLines: 2,
                ),
                showChevron: true,
                onTap: () => context.pushNamed(
                  AppRoutes.newOAuth.name,
                  queryParameters: {'returnTo': ?returnTo},
                  pathParameters: {
                    'provider': RemoteProviderType.oneDrive.name,
                  },
                ),
              ),
            ],
          ),
          AdaptiveListSection(
            header: syncText(context, '其他服务', 'Other Services'),
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.cloud_fill,
                  color: AppTone.neutral.color(context),
                ),
                title: Text(syncText(context, '百度网盘', 'Baidu Netdisk')),
                subtitle: Text(
                  syncText(
                    context,
                    '可填写 AppKey 与 Token，同步适配器尚未开放。',
                    'AppKey and token setup is available. Sync support is not yet available.',
                  ),
                  maxLines: 2,
                ),
                showChevron: true,
                onTap: () => context.pushNamed(AppRoutes.newBaiduToken.name),
              ),
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.lock,
                  color: AppTone.neutral.color(context),
                ),
                title: Text(syncText(context, '阿里云盘', 'Aliyun Drive')),
                subtitle: Text(
                  syncText(
                    context,
                    '需要官方 Token Broker，当前未开放。',
                    'Requires an official token broker. Not currently available.',
                  ),
                  maxLines: 2,
                ),
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
    label: syncText(context, '查看详细配置说明', 'View Detailed Setup Instructions'),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Text(
          syncText(context, '查看说明', 'View Instructions'),
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
