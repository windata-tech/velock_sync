import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

import 'backup_widgets.dart';

typedef BackupFolderLoader =
    Future<List<WebDavBackupFolder>> Function({
      required WebDavProtocolModel protocol,
      required List<String> relativeSegments,
    });

final backupFolderLoaderProvider = Provider<BackupFolderLoader>((ref) {
  final browser = WebDavBackupFolderBrowser(
    connections: ref.watch(connectionRepositoryProvider),
  );
  return ({required protocol, required relativeSegments}) =>
      browser.list(protocol: protocol, relativeSegments: relativeSegments);
});

/// Browsing is read-only. Selecting a folder returns a draft path; it does not
/// edit the saved connection, publish a profile or start a backup.
class BackupFolderPicker extends StatefulWidget {
  const BackupFolderPicker({
    super.key,
    required this.connectionName,
    required this.basePath,
    required this.loadFolders,
    this.initialSegments = const [],
    this.restoring = false,
  });

  final String connectionName;
  final String basePath;
  final List<String> initialSegments;
  final bool restoring;
  final Future<List<WebDavBackupFolder>> Function(List<String>) loadFolders;

  @override
  State<BackupFolderPicker> createState() => _BackupFolderPickerState();
}

class _BackupFolderPickerState extends State<BackupFolderPicker> {
  late List<String> _segments;
  List<WebDavBackupFolder> _folders = const [];
  bool _loading = true;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _segments = List.unmodifiable(widget.initialSegments);
    _load(_segments);
  }

  Future<void> _load(List<String> segments) async {
    final generation = ++_generation;
    setState(() {
      _segments = List.unmodifiable(segments);
      _folders = const [];
      _error = null;
      _loading = true;
    });
    try {
      final folders = await widget.loadFolders(_segments);
      if (!mounted || generation != _generation) return;
      setState(() {
        _folders = folders;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  bool get _authenticationError =>
      _error is ProviderRequestException &&
      const {
        401,
        403,
      }.contains((_error as ProviderRequestException).statusCode);

  String get _displayPath =>
      [
        widget.basePath.replaceFirst(RegExp(r'/+$'), ''),
        ..._segments,
      ].join('/').isEmpty
      ? '/'
      : [
          widget.basePath.replaceFirst(RegExp(r'/+$'), ''),
          ..._segments,
        ].join('/');

  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
    title: syncText(
      context,
      widget.restoring ? '找到原备份文件夹' : '选择备份文件夹',
      widget.restoring ? 'Find your backup folder' : 'Choose a backup folder',
    ),
    body: SafeArea(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                key: const Key('backup-folder-list'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                children: [
                  Text(
                    widget.connectionName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _displayPath,
                    key: const Key('backup-folder-current-path'),
                    style: TextStyle(color: context.appSecondaryLabel),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    syncText(
                      context,
                      widget.restoring
                          ? '选择当初备份时使用的保存文件夹，Sync 会查找其中的格间备份。'
                          : '打开共享文件夹，选好保存位置后，点下方按钮。Sync 会在这里创建自己的备份文件夹。',
                      widget.restoring
                          ? 'Choose the folder you originally saved to. Sync will look for your Velock backup inside it.'
                          : 'Open a shared folder, choose where to save, then use the button below. Sync creates its own backup folder here.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_segments.isNotEmpty)
                    ListTile(
                      key: const Key('backup-folder-up'),
                      leading: const Icon(CupertinoIcons.arrow_up),
                      title: Text(syncText(context, '上一级', 'Parent folder')),
                      onTap: _loading
                          ? null
                          : () => _load(
                              _segments.sublist(0, _segments.length - 1),
                            ),
                    ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                    )
                  else if (_error != null) ...[
                    Text(
                      syncText(
                        context,
                        _authenticationError
                            ? '无法读取文件夹。请返回并检查这个位置的账号或访问权限。'
                            : '暂时无法读取文件夹。你可以重试，或返回选择其他位置。',
                        _authenticationError
                            ? 'Cannot read folders. Go back and check this location’s account or access permissions.'
                            : 'Could not read folders. Retry or go back to choose another location.',
                      ),
                      key: const Key('backup-folder-error'),
                    ),
                    if (!_authenticationError)
                      TextButton(
                        key: const Key('backup-folder-retry'),
                        onPressed: () => _load(_segments),
                        child: Text(syncText(context, '重试', 'Retry')),
                      ),
                  ] else if (_folders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        syncText(
                          context,
                          '这里没有子文件夹，可以选择当前文件夹。',
                          'No subfolders here. You can use this folder.',
                        ),
                      ),
                    )
                  else
                    for (final folder in _folders)
                      ListTile(
                        key: ValueKey('backup-folder-${folder.name}'),
                        leading: const Icon(CupertinoIcons.folder),
                        title: Text(folder.name),
                        trailing: const Icon(
                          CupertinoIcons.chevron_right,
                          size: 18,
                        ),
                        onTap: () => _load([..._segments, folder.name]),
                      ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: BackupActionButton(
                key: const Key('use-backup-folder'),
                label: syncText(context, '使用这个文件夹', 'Use this folder'),
                onPressed: _loading || _error != null
                    ? null
                    : () => Navigator.of(
                        context,
                      ).pop(List<String>.unmodifiable(_segments)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
