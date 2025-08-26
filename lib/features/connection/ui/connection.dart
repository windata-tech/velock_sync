import 'package:flutter/widgets.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Connection extends HookConsumerWidget {
  final String id;
  const Connection(this.id, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionDetailProvider(id));
    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text(''),
      ),
      body: connection.when(data: (connectionModel) {
        if (connectionModel == null) {
          return Center(child: Text('连接不存在'));
        }
        return ListView(
          padding: EdgeInsets.all(16),
          children: [
            Text('名称: ${connectionModel.name}'),
            SizedBox(height: 8),
            Text('地址: ${connectionModel.protocol.address}'),
            SizedBox(height: 8),
            Text('状态: ${connectionModel.status}'),
            SizedBox(height: 8),
            // 其他连接详情
          ],
        );
      }, error: (e,s) => Text('data'), loading: () => Center(child: PlatformCircularProgressIndicator())),
    );
  }
}
