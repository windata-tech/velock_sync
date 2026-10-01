import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace_shared.dart';

/// Opens the editor of the connection a backup uses, after the server
/// rejected its saved sign-in (401).
///
/// Returns true only when the user saved the connection and then explicitly
/// chose to retry the backup. Saving never starts a backup on its own.
Future<bool> editBackupConnection(
  BuildContext context,
  WidgetRef ref,
  String? connectionId,
) async {
  final connection = connectionId == null
      ? null
      : await ref
            .read(connectionRepositoryProvider)
            .getConnectionById(connectionId);
  if (!context.mounted) return false;
  if (connection == null) {
    showMessage(
      context,
      syncText(
        context,
        '找不到这个备份使用的连接，请在「连接」页检查。',
        'The connection this backup uses was not found. Check it on the Connections page.',
      ),
    );
    return false;
  }
  final protocol = connection.protocol;
  final query = {'replace': connection.id, 'returnTo': connectionEditorPopBack};
  final saved = protocol is OAuthProtocolModel
      ? await context.pushNamed<bool>(
          AppRoutes.newOAuth.name,
          pathParameters: {'provider': protocol.providerType.name},
          // Signing in again keeps the access the connection was made with.
          queryParameters: {
            ...query,
            if (protocol.fullDriveAccess) 'access': oauthFullDriveAccess,
          },
        )
      : await context.pushNamed<bool>(
          AppRoutes.newWebDav.name,
          queryParameters: query,
        );
  if (saved != true || !context.mounted) return false;
  return showAdaptiveConfirmation(
    context,
    title: syncText(context, '连接已更新', 'Connection updated'),
    message: syncText(
      context,
      '现在用新的登录信息重试备份吗？',
      'Retry the backup with the new sign-in now?',
    ),
    confirmLabel: syncText(context, '重试备份', 'Retry backup'),
    cancelLabel: syncText(context, '稍后', 'Later'),
  );
}
