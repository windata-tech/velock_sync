import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/extensions.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/icon_widgets.dart';

class Protocols extends HookConsumerWidget {
  const Protocols({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PlatformScaffold(
      iosContentPadding:
          Theme.of(context).platform == TargetPlatform.iOS ||
          Theme.of(context).platform == TargetPlatform.macOS,
      appBar: WDAppBar(title: Text('协议列表')),
      body: ListView.separated(
        padding: EdgeInsets.all(16),
        itemBuilder: (context, index) {
          return switch (index) {
            0 => PlatformTextButton(
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
            1 || 2 => PlatformTextButton(
              child: Row(
                children: [
                  const Icon(Icons.cloud_outlined),
                  const SizedBox(width: 8),
                  Text(index == 1 ? 'Google Drive' : 'OneDrive'),
                ],
              ),
              onPressed: () => context.pushNamed(
                AppRoutes.newOAuth.name,
                pathParameters: {
                  'provider':
                      (index == 1
                              ? RemoteProviderType.googleDrive
                              : RemoteProviderType.oneDrive)
                          .name,
                },
              ),
            ),
            _ => PlatformTextButton(
              onPressed: null,
              child: const Row(
                children: [
                  Icon(Icons.lock_outline),
                  SizedBox(width: 8),
                  Text('百度网盘、阿里云盘（需要官方 Token Broker）'),
                ],
              ),
            ),
          };
        },
        separatorBuilder: (context, index) {
          return Divider(height: 1, color: context.dividerColor);
        },
        itemCount: 4,
      ),
    );
  }
}
