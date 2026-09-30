import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/ui/remote_provider_icon.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/oauth/oauth_user_registration_provider.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Protocols extends HookConsumerWidget {
  const Protocols({super.key, this.returnTo});
  final String? returnTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Types that work out of the box come first. OAuth types this build has
    // no registration for need the user's own app key; they join the main
    // list once one is saved and otherwise wait in a folded section, so
    // nobody lands on a setup page by accident. Saved connections of every
    // type stay visible in the connection list.
    final availability = ref.watch(remoteProviderAvailabilityProvider);
    final ownKeyTypes = [
      for (final type in availability.needsOwnRegistration)
        if (ref.watch(oauthUserRegistrationProvider(type)).value != null) type,
    ];
    final waitingTypes = [
      for (final type in availability.needsOwnRegistration)
        if (!ownKeyTypes.contains(type)) type,
    ];
    final showMore = useState(false);

    void openOAuth(RemoteProviderType type) => context.pushNamed(
      AppRoutes.newOAuth.name,
      queryParameters: {'returnTo': ?returnTo},
      pathParameters: {'provider': type.name},
    );

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
                '格间备份的内容在上传前由格间加密。文件同步写入的是普通文件，能访问该账号的人都能查看和修改。',
                'Velock backups are encrypted by Velock before upload. File sync writes ordinary files that anyone with access to the account can view and change.',
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
                widgetKey: const Key('protocol-webDav'),
                leading: RemoteProviderBadge(RemoteProviderType.webDav),
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
              for (final type in RemoteProviderAvailability.oauthProviderTypes)
                if (availability.canCreate(type) || ownKeyTypes.contains(type))
                  _OAuthProviderTile(
                    type: type,
                    subtitle: availability.canCreate(type)
                        ? _signInSubtitle(context, type)
                        : syncText(
                            context,
                            '使用你自己的应用密钥登录，然后选择同步所用的云端目录。',
                            'Sign in with your own app key, then choose a cloud folder for sync.',
                          ),
                    onTap: () => openOAuth(type),
                  ),
            ],
          ),
          if (waitingTypes.isNotEmpty)
            AdaptiveListSection(
              header: syncText(context, '更多云盘', 'More cloud drives'),
              footer: Text(
                syncText(
                  context,
                  '这个版本没有内置这些云盘的应用密钥。你可以在对应的开放平台免费注册一个自己的应用，把密钥填进来后即可使用；密钥只保存在本机的系统安全存储里。',
                  'This build has no app key for these services. You can register your own app for free on each provider’s developer platform and enter its key here; it is kept only in this device’s secure storage.',
                ),
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              children: [
                if (!showMore.value)
                  AdaptiveListTile(
                    widgetKey: const Key('protocols-more-toggle'),
                    leading: const Icon(CupertinoIcons.ellipsis_circle),
                    title: Text(
                      syncText(
                        context,
                        '使用自己的应用密钥连接',
                        'Connect with your own app key',
                      ),
                    ),
                    subtitle: Text(
                      waitingTypes
                          .map((type) => _providerName(context, type))
                          .join(syncText(context, '、', ', ')),
                      maxLines: 2,
                    ),
                    trailing: const Icon(CupertinoIcons.chevron_down, size: 16),
                    onTap: () => showMore.value = true,
                  )
                else
                  for (final type in waitingTypes)
                    _OAuthProviderTile(
                      type: type,
                      subtitle: syncText(
                        context,
                        '需要先在${_providerName(context, type)}开放平台注册自己的应用。',
                        'Needs an app you register on the ${_providerName(context, type)} developer platform.',
                      ),
                      onTap: () => openOAuth(type),
                    ),
              ],
            ),
        ],
      ),
    );
  }
}

class _OAuthProviderTile extends StatelessWidget {
  const _OAuthProviderTile({
    required this.type,
    required this.subtitle,
    required this.onTap,
  });

  final RemoteProviderType type;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AdaptiveListTile(
    widgetKey: Key('protocol-${type.name}'),
    leading: RemoteProviderBadge(type),
    title: Text(_providerName(context, type)),
    subtitle: Text(subtitle, maxLines: 2),
    showChevron: true,
    onTap: onTap,
  );
}

String _providerName(
  BuildContext context,
  RemoteProviderType type,
) => switch (type) {
  RemoteProviderType.baiduNetdisk => syncText(context, '百度网盘', 'Baidu Netdisk'),
  RemoteProviderType.aliyunDrive => syncText(context, '阿里云盘', 'Aliyun Drive'),
  _ => remoteProviderDisplayName(type),
};

String _signInSubtitle(BuildContext context, RemoteProviderType type) =>
    switch (type) {
      RemoteProviderType.googleDrive => syncText(
        context,
        '使用 Google 账号授权，然后选择同步所用的云端目录。',
        'Sign in with Google, then choose a cloud folder for sync.',
      ),
      RemoteProviderType.oneDrive => syncText(
        context,
        '使用 Microsoft 账号授权，然后选择同步所用的云端目录。',
        'Sign in with Microsoft, then choose a cloud folder for sync.',
      ),
      RemoteProviderType.baiduNetdisk => syncText(
        context,
        '使用百度账号授权，然后选择同步所用的云端目录。',
        'Sign in with Baidu, then choose a cloud folder for sync.',
      ),
      _ => syncText(
        context,
        '使用阿里云盘账号授权，然后选择同步所用的云端目录。',
        'Sign in with Aliyun Drive, then choose a cloud folder for sync.',
      ),
    };

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
