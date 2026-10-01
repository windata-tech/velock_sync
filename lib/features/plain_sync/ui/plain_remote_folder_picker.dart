import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/ui/connection_editor_entry.dart';
import 'package:velock_sync/features/plain_sync/state/plain_remote_folders.dart';

/// Opens the remote folder picker of a file-sync location on [connection].
///
/// When the folders cannot be read the picker offers to edit the connection;
/// browsing then continues with the saved settings. The result carries the
/// connection as it was when the folder was chosen, so follow-up reads use the
/// edited address and sign-in rather than the stale ones.
Future<({List<String> segments, ConnectionModel connection})?>
pickPlainRemoteFolder(
  BuildContext context,
  WidgetRef ref,
  ConnectionModel connection, {
  List<String> initialSegments = const [],
}) async {
  final folders = ref.read(plainRemoteFoldersProvider);
  final connections = ref.read(connectionRepositoryProvider);
  var current = connection;

  BackupFolderSource sourceFor(BuildContext context, ConnectionModel value) => (
    connectionName: value.name,
    basePath: folders.basePath(context, value),
    loadFolders: (relative) => folders.list(value, relative),
    createFolder: (parent, name) => folders.create(value, parent, name),
  );

  final initial = sourceFor(context, connection);
  final picked = await Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      builder: (_) => BackupFolderPicker(
        connectionName: initial.connectionName,
        basePath: initial.basePath,
        forSync: true,
        initialSegments: initialSegments,
        loadFolders: initial.loadFolders,
        createFolder: initial.createFolder,
        editConnection: (pickerContext) async {
          if (!await openConnectionEditor(pickerContext, current)) return null;
          final saved = await connections.getConnectionById(current.id);
          if (saved == null || !pickerContext.mounted) return null;
          current = saved;
          // The connection lists behind the picker show the saved name too.
          ref.invalidate(connectionsProvider);
          return sourceFor(pickerContext, saved);
        },
      ),
    ),
  );
  return picked == null ? null : (segments: picked, connection: current);
}
