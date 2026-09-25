import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

class NewConnection extends ConsumerWidget {
  const NewConnection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The draft is normally prepared by the tap handler that opens this
    // route. Keep a local fallback as well so a deep link or restored route
    // remains usable without mutating a provider during build.
    final connectionData =
        ref.watch(connectionCreationProvider) ??
        CreateConnectionDto.empty(
          name: syncText(context, '新建连接', 'New Connection'),
        ).copyWith(source: syncText(context, '格间', 'Velock'), target: null);

    return AdaptiveScaffold(
      title: syncText(context, '新建连接', 'New Connection'),
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
              syncText(
                context,
                '本地数据始终留在设备上，只有加密后的同步对象会写入远端空间。',
                'Local data stays on your device. Only encrypted sync objects are written to remote storage.',
              ),
              style: AppType.footnote.copyWith(
                color: context.appSecondaryLabel,
              ),
            ),
          ),
          AdaptiveListSection(
            header: syncText(context, '本地数据', 'Local Data'),
            footer: Text(
              syncText(
                context,
                'Velock Sync 不读取格间明文，也不保存格间密钥。',
                'Velock Sync does not read unencrypted Velock data or store Velock keys.',
              ),
            ),
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.folder_fill,
                  color: AppTone.brand.color(context),
                ),
                title: Text(
                  connectionData.source == null || connectionData.source == '格间'
                      ? syncText(context, '格间', 'Velock')
                      : connectionData.source!,
                  style: AppType.rowTitleStrong,
                ),
                subtitle: Text(
                  syncText(context, '当前设备上的格间数据', 'Velock data on this device'),
                  maxLines: 2,
                ),
              ),
            ],
          ),
          AdaptiveListSection(
            header: syncText(context, '远端目标', 'Remote Destination'),
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.link,
                  color: AppTone.brand.color(context),
                ),
                title: Text(
                  connectionData.target ??
                      syncText(context, '选择远端协议', 'Choose Remote Protocol'),
                  style: AppType.rowTitleStrong,
                ),
                subtitle: Text(
                  syncText(
                    context,
                    'WebDAV、Google Drive 或 OneDrive',
                    'WebDAV, Google Drive, or OneDrive',
                  ),
                  maxLines: 2,
                ),
                showChevron: true,
                onTap: () => context.pushNamed(AppRoutes.protocols.name),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
