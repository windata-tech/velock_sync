import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// Entry point for creating either a zero-knowledge Velock backup or an
/// independent user-selected folder sync.
class NewSyncProfile extends StatelessWidget {
  const NewSyncProfile({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      title: '新建同步',
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
              '选择要保护或同步的数据。两类数据使用同一套可靠传输引擎，但恢复和安全边界不同。',
              style: AppType.footnote.copyWith(
                color: context.appSecondaryLabel,
              ),
            ),
          ),
          AdaptiveListSection(
            header: '格间数据',
            children: [
              AdaptiveListTile(
                widgetKey: const Key('new-velock-backup'),
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.shield_outlined,
                    cupertino: CupertinoIcons.shield,
                  ),
                  color: AppTone.ok.color(context),
                ),
                title: const Text('备份格间数据'),
                subtitle: const Text(
                  '持续把格间已经加密和认证的数据备份到你的远端。设备丢失、损坏、重装或误操作后，可连接同一远端恢复。',
                ),
                showChevron: true,
                onTap: () =>
                    context.pushNamed(AppRoutes.velockDatasetWizard.name),
              ),
            ],
          ),
          AdaptiveListSection(
            header: '其他数据',
            footer: const Text(
              '文件夹同步不依赖格间账号。远端保存加密后的同步对象，恢复材料用于在另一台设备重新加入同步空间。',
            ),
            children: [
              AdaptiveListTile(
                widgetKey: const Key('new-selected-folder-sync'),
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.folder_outlined,
                    cupertino: CupertinoIcons.folder,
                  ),
                ),
                title: const Text('同步文件夹'),
                subtitle: const Text(
                  '选择一个文件夹并同步到 WebDAV、Google Drive 或 OneDrive，像使用同步盘一样保持多设备一致。',
                ),
                showChevron: true,
                onTap: () =>
                    context.pushNamed(AppRoutes.selectedFolderProfiles.name),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
