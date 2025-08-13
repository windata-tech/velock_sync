import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class NewConnection extends HookConsumerWidget {
  const NewConnection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PlatformScaffold(
      appBar: WDAppBar(title: Text('新建连接')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            sliver: SliverToBoxAdapter(child: Text('本地目标')),
            padding: EdgeInsets.all(16),
          ),
          SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Row(children: [FlutterLogo(), Text('格间')]), //
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
                  return CupertinoTextButtonData(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  );
                },
                child: Row(children: [Icon(PlatformIcons(context).add), Text('选择协议')]),
                onPressed: () {
                  context.pushNamed(AppRoutes.protocols.name);
                }, //
              ), //
            ),
          ),
        ],
      ),
    );
  }
}
