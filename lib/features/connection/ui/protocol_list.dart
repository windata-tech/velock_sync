import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/extensions.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/icon_widgets.dart';

class Protocols extends HookConsumerWidget {
  const Protocols({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supportProtocols = ref.watch(supportedProtocolsProvider);
    return PlatformScaffold(
      appBar: WDAppBar(title: Text('协议列表')),
      body: ListView.separated(
        padding: EdgeInsets.all(16),
        itemBuilder: (context, index) {
          final protocol = supportProtocols[index];
          return switch (protocol) {
            WebDavProtocolModel() => PlatformTextButton(
              child: Row(
                children: [
                  ProtocolIcon(protocolName: 'DAV'),
                  SizedBox(width: 8),
                  Text('WebDAV 协议'),
                ],
              ),
              onPressed: () {
                context.pushNamed(AppRoutes.newWebDav.name);
              },
            ),
          };
        },
        separatorBuilder: (context, index) {
          return Divider(height: 1, color: context.dividerColor);
        },
        itemCount: supportProtocols.length,
      ),
    );
  }
}
