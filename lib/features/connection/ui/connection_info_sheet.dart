import 'package:flutter/widgets.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/provider_capability_summary.dart';
import 'package:velock_sync/widgets/app_components.dart';

/// Technical notes about one connection type.
///
/// Read-only and offline: it never probes the server, never writes remotely and
/// never changes the current folder — it only describes the adapter behind the
/// connection. Shared by the connection page's info button and the connections
/// list action menu so both entries stay identical.
Future<void> showConnectionInfoSheet(
  BuildContext context,
  ProtocolModel protocol,
) {
  final summary = providerCapabilitySummary(protocol, context: context);
  return showAppDetailSheet(
    context,
    title: syncText(context, '连接说明', 'Connection info'),
    rows: [
      AppDetailSheetRow(
        label: syncText(context, '说明', 'About'),
        value: syncText(
          context,
          '这些是连接方式的技术说明，不是当前服务器的检测结果。',
          'These describe the connection implementation, not test results for this server.',
        ),
      ),
      AppDetailSheetRow(
        label: syncText(context, '连接方式', 'Connection type'),
        value: summary.providerName,
      ),
      if (summary.features.isNotEmpty)
        AppDetailSheetRow(
          label: syncText(context, '功能说明', 'Features'),
          value: summary.features.join('\n'),
        ),
      if (summary.limitations.isNotEmpty)
        AppDetailSheetRow(
          label: syncText(context, '注意事项', 'Limitations'),
          value: summary.limitations.join('\n'),
        ),
      // Where the secret lives is a property of this app, not a feature of the
      // connection type, so it gets its own row instead of a feature bullet.
      AppDetailSheetRow(
        label: syncText(context, '登录信息', 'Credentials'),
        value: summary.credentials,
      ),
    ],
    footnote: syncText(
      context,
      '浏览文件夹不需要设置这些项目。能否备份，以实际连接和备份检查为准。',
      'There is nothing to configure here. Backup availability is determined by actual connection and backup checks.',
    ),
  );
}
