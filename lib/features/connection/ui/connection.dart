import 'package:flutter/widgets.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class Connection extends HookConsumerWidget {
  const Connection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text(''),
      ),
      body: Container(),
    );
  }
}
