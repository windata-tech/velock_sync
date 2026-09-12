import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
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
          name: '新建连接',
        ).copyWith(source: '格间', target: null);

    return AdaptiveScaffold(
      title: '新建连接',
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
              '本地数据始终留在设备上，只有加密后的同步对象会写入远端空间。',
              style: AppType.footnote.copyWith(
                color: context.appSecondaryLabel,
              ),
            ),
          ),
          AdaptiveListSection(
            header: '本地数据',
            footer: const Text('Velock Sync 不读取格间明文，也不保存格间密钥。'),
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.folder_fill,
                  color: AppTone.brand.color(context),
                ),
                title: Text(
                  connectionData.source ?? '格间',
                  style: AppType.rowTitleStrong,
                ),
                subtitle: const Text(
                  '当前设备上的格间数据',
                  maxLines: 2,
                ),
              ),
            ],
          ),
          AdaptiveListSection(
            header: '远端目标',
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: CupertinoIcons.link,
                  color: AppTone.brand.color(context),
                ),
                title: Text(
                  connectionData.target ?? '选择远端协议',
                  style: AppType.rowTitleStrong,
                ),
                subtitle: const Text(
                  'WebDAV、Google Drive 或 OneDrive',
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
