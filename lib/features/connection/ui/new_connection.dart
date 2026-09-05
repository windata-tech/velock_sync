import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

class NewConnection extends HookConsumerWidget {
  const NewConnection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionData = ref.watch(connectionCreationProvider);

    useEffect(() {
      final connectionCreationNotifier = ref.read(
        connectionCreationProvider.notifier,
      );

      if (connectionData == null) {
        Future.microtask(() {
          connectionCreationNotifier.prepareNewConnection(
            name: '新建连接',
            source: '格间',
            target: null,
          );
        });
      }
      return () {
        Future.microtask(() {
          logi('dispose NewConnection, cancel creation');
          connectionCreationNotifier.cancelCreation();
        });
      };
    }, const []);

    if (connectionData == null) {
      return const AdaptiveScaffold(
        title: '新建连接',
        body: AdaptiveLoadingState(label: '正在准备连接配置'),
      );
    }

    return AdaptiveScaffold(
      title: '新建连接',
      leading: PlatformIconButton(
        padding: EdgeInsets.zero,
        cupertino: (context, platform) =>
            CupertinoIconButtonData(icon: const Icon(CupertinoIcons.back)),
        material: (context, platform) =>
            MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
        onPressed: () => context.goNamed(AppRoutes.connections.name),
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
              '先选择本地目标，再连接一个远端空间。凭据会保存在系统安全存储中。',
              style: TextStyle(color: context.appSecondaryLabel, height: 1.4),
            ),
          ),
          AdaptiveListSection(
            header: '本地目标',
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.folder_rounded,
                    cupertino: CupertinoIcons.folder_fill,
                  ),
                  color: context.appPrimary,
                ),
                title: Text(connectionData.source ?? '选择源'),
                subtitle: const Text('当前设备上的格间数据'),
                additionalInfo: const Icon(Icons.check_rounded),
              ),
            ],
          ),
          AdaptiveListSection(
            header: '远端目标',
            children: [
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.add_link_rounded,
                    cupertino: CupertinoIcons.link,
                  ),
                ),
                title: Text(connectionData.target ?? '选择协议'),
                subtitle: const Text('WebDAV、Google Drive 或 OneDrive'),
                showChevron: true,
                onTap: () => context.goNamed(AppRoutes.protocols.name),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
