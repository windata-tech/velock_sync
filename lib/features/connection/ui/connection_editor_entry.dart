import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';

/// Reopens the form a connection was created with, prefilled, and returns to
/// the page that opened it once the connection was saved.
///
/// QA 2026-09-29: the editor used to `go('/connections')` after saving, which
/// replaced the pushed stack and left the connection list without a back
/// button or tab bar. Returns true when the connection was saved.
Future<bool> openConnectionEditor(
  BuildContext context,
  ConnectionModel connection,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
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
  if (saved != true) return false;
  // The detail page reads the connection once; show the saved values.
  container.invalidate(connectionDetailProvider(connection.id));
  return true;
}
