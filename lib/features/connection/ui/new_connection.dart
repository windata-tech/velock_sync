import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';


class NewConnection extends HookConsumerWidget {
  const NewConnection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionData = ref.watch(connectionCreationProvider);

    useEffect(() {
      if (connectionData == null) {
        Future.microtask(() {
          ref.read(connectionCreationProvider.notifier).prepareNewConnection(
            name: '新建连接',
            source: '格间',
            target: null,
          );
        });
      }
      return null;
    }, const []);

    if (connectionData == null) {
      return PlatformScaffold(
        appBar: WDAppBar(title: Text('新建连接')),
        body: const Center(
          child: PlatformCircularProgressIndicator(),
        ),
      );
    }

    // 4. 当 connectionData 不为 null 时 (第二帧)，显示真实的 UI
    return PlatformScaffold(
      appBar: WDAppBar(title: Text(connectionData.name)),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            sliver: SliverToBoxAdapter(child: Text('本地目标')),
            padding: EdgeInsets.all(16),
          ),
          SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Row(children: [FlutterLogo(), Text(connectionData.source ?? '选择源')]),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: Text('远程目标')),
          ),
          SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: PlatformTextButton(
                padding: EdgeInsets.zero,
                cupertino: (context, platform) {
                  return CupertinoTextButtonData(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4));
                },
                child: Row(children: [
                  Icon(PlatformIcons(context).add),
                  Text(connectionData.target ?? '选择协议') // 读取数据
                ]),
                onPressed: () {
                  context.pushNamed(AppRoutes.protocols.name);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}