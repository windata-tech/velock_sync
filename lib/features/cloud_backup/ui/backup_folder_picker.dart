import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/folder_view_mode.dart';
import 'package:velock_sync/features/connection/ui/remote_folder_views.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/connection_settings_glyph.dart';

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

typedef BackupFolderCreator =
    Future<void> Function({
      required WebDavProtocolModel protocol,
      required List<String> relativeSegments,
      required String name,
    });

final backupFolderCreatorProvider = Provider<BackupFolderCreator>((ref) {
  final browser = WebDavBackupFolderBrowser(
    connections: ref.watch(connectionRepositoryProvider),
  );
  return ({required protocol, required relativeSegments, required name}) =>
      browser.createFolder(
        protocol: protocol,
        relativeSegments: relativeSegments,
        name: name,
      );
});

/// What a [BackupFolderPicker] browses. Editing the connection replaces it,
/// since the address and the sign-in are part of how folders are read.
typedef BackupFolderSource = ({
  String connectionName,
  String basePath,
  Future<List<WebDavBackupFolder>> Function(List<String>) loadFolders,
  Future<void> Function(List<String> parent, String name)? createFolder,
});

/// Browsing and selecting are read-only. An explicit new-folder confirmation
/// creates only that empty directory, never a profile or a backup.
class BackupFolderPicker extends ConsumerStatefulWidget {
  const BackupFolderPicker({
    super.key,
    required this.connectionName,
    required this.basePath,
    required this.loadFolders,
    this.initialSegments = const [],
    this.restoring = false,
    this.forSync = false,
    this.createFolder,
    this.editConnection,
  });

  final String connectionName;
  final String basePath;
  final List<String> initialSegments;
  final bool restoring;

  /// The folder is for a plain file-sync location, which says 「同步」.
  final bool forSync;
  final Future<List<WebDavBackupFolder>> Function(List<String>) loadFolders;
  final Future<void> Function(List<String> parent, String name)? createFolder;

  /// Opens the connection's editor on top of the picker when its folders
  /// cannot be read, so a wrong address or password is fixed in place instead
  /// of abandoning the flow. Returns the source to browse with the saved
  /// connection, or null when nothing was saved.
  final Future<BackupFolderSource?> Function(BuildContext context)?
  editConnection;

  @override
  ConsumerState<BackupFolderPicker> createState() => _BackupFolderPickerState();
}

class _BackupFolderPickerState extends ConsumerState<BackupFolderPicker> {
  late List<String> _segments;
  List<WebDavBackupFolder> _folders = const [];
  bool _loading = true;
  Object? _error;
  int _generation = 0;
  bool _showingCreate = false;
  bool _creating = false;
  String? _creationError;
  bool _justCreated = false;
  bool _editing = false;
  late BackupFolderSource _source;
  bool get _busy => _loading || _creating || _editing;

  @override
  void initState() {
    super.initState();
    _source = (
      connectionName: widget.connectionName,
      basePath: widget.basePath,
      loadFolders: widget.loadFolders,
      createFolder: widget.createFolder,
    );
    _segments = List.unmodifiable(widget.initialSegments);
    _load(_segments);
  }

  Future<void> _load(List<String> segments, {bool justCreated = false}) async {
    final generation = ++_generation;
    setState(() {
      _segments = List.unmodifiable(segments);
      _folders = const [];
      _error = null;
      _creationError = null;
      _justCreated = justCreated;
      _loading = true;
    });
    try {
      final folders = await _source.loadFolders(_segments);
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

  Future<void> _newFolder() async {
    final create = _source.createFolder;
    if (_busy ||
        _error != null ||
        _showingCreate ||
        create == null ||
        widget.restoring) {
      return;
    }
    _showingCreate = true;
    final parent = List<String>.unmodifiable(_segments);
    String? name;
    try {
      name = await showNewRemoteFolderDialog(
        context,
        location: _displayPath,
        existingNames: {for (final folder in _folders) folder.name},
        placeholder: syncText(
          context,
          widget.forSync ? '例如：照片' : '例如：格间备份',
          widget.forSync ? 'e.g. Photos' : 'e.g. Velock backup',
        ),
        confirmLabel: syncText(context, '创建并进入', 'Create and open'),
      );
    } finally {
      _showingCreate = false;
    }
    if (!mounted || name == null) return;
    setState(() {
      _creating = true;
      _creationError = null;
      _justCreated = false;
    });
    try {
      await create(parent, name);
      if (!mounted) return;
      await _load([...parent, name], justCreated: true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(
        () => _creationError = remoteFolderCreationError(context, error),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  bool get _authenticationError =>
      _error is ProviderRequestException &&
      const {
        401,
        403,
      }.contains((_error as ProviderRequestException).statusCode);

  String _errorMessage(BuildContext context) {
    final editable = widget.editConnection != null;
    if (_authenticationError) {
      return editable
          ? syncText(
              context,
              '服务器拒绝了这个连接的账号或密码。请修改连接后再试。',
              'The server refused this connection’s account or password. Edit the connection, then try again.',
            )
          : syncText(
              context,
              '无法读取文件夹。请返回并检查这个位置的账号或访问权限。',
              'Cannot read folders. Go back and check this location’s account or access permissions.',
            );
    }
    return editable
        ? syncText(
            context,
            '连不上这个位置，暂时读不到文件夹。可以检查连接的地址、端口和账号，或稍后重试。',
            'Could not reach this location to read its folders. Check the connection’s address, port and account, or retry later.',
          )
        : syncText(
            context,
            '暂时无法读取文件夹。你可以重试，或返回选择其他位置。',
            'Could not read folders. Retry or go back to choose another location.',
          );
  }

  String get _displayPath =>
      [
        _source.basePath.replaceFirst(RegExp(r'/+$'), ''),
        ..._segments,
      ].join('/').isEmpty
      ? '/'
      : [
          _source.basePath.replaceFirst(RegExp(r'/+$'), ''),
          ..._segments,
        ].join('/');

  Future<void> _editConnection() async {
    final edit = widget.editConnection;
    if (edit == null || _busy) return;
    setState(() => _editing = true);
    BackupFolderSource? updated;
    try {
      updated = await edit(context);
    } finally {
      if (mounted) setState(() => _editing = false);
    }
    if (updated == null || !mounted) return;
    _source = updated;
    await _load(_segments);
  }

  void _goBack() {
    if (_creating) return;
    if (_segments.isNotEmpty) {
      _load(_segments.sublist(0, _segments.length - 1));
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_creating && _segments.isEmpty,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && !_creating && _segments.isNotEmpty) _goBack();
    },
    child: AdaptiveScaffold(
      leading: AppBackButton(
        key: const Key('backup-folder-back'),
        onPressed: _creating ? null : _goBack,
        semanticLabel: _segments.isNotEmpty
            ? syncText(context, '返回上一级文件夹', 'Parent folder')
            : syncText(context, '返回', 'Back'),
      ),
      title: syncText(
        context,
        widget.restoring
            ? '找到原备份文件夹'
            : widget.forSync
            ? '选择同步文件夹'
            : '选择备份文件夹',
        // The English title must stay short: the navigation bar gives the title
        // the space the leading and trailing slots leave over, and the length
        // of the title is what pushes a long one into an ellipsis.
        widget.restoring ? 'Find the backup folder' : 'Choose a folder',
      ),
      body: SafeArea(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  key: const Key('backup-folder-list'),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      sliver: SliverList.list(
                        children: [
                          // The connection and, next to it, the way to fix it: the
                          // address or account shown here is what an edit changes.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _source.connectionName,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _displayPath,
                                      key: const Key(
                                        'backup-folder-current-path',
                                      ),
                                      style: const TextStyle(height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                              if (widget.editConnection != null) ...[
                                const SizedBox(width: 12),
                                _folderAction(
                                  key: const Key(
                                    'backup-folder-edit-connection',
                                  ),
                                  icon: const ConnectionSettingsGlyph(size: 20),
                                  label: syncText(context, '修改连接', 'Edit'),
                                  onPressed: _busy ? null : _editConnection,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            syncText(
                              context,
                              widget.restoring
                                  ? '选择当初备份时使用的保存文件夹，Sync 会查找其中的格间备份。'
                                  : widget.forSync
                                  ? '选择要和本机文件夹同步的远端文件夹，也可以新建一个空文件夹。不会改动其他文件夹。'
                                  : '选择已有文件夹，或新建一个空文件夹保存备份。不会改动其他文件夹。',
                              widget.restoring
                                  ? 'Choose the folder you originally saved to. Sync will look for your Velock backup inside it.'
                                  : widget.forSync
                                  ? 'Choose the remote folder to sync with the folder on this device, or create an empty one. Other folders stay unchanged.'
                                  : 'Choose a folder or create an empty one for your backup. Other folders stay unchanged.',
                            ),
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.45,
                              color: context.appSecondaryLabel,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OverflowBar(
                            alignment: MainAxisAlignment.spaceBetween,
                            overflowAlignment: OverflowBarAlignment.end,
                            spacing: 16,
                            overflowSpacing: 4,
                            children: [
                              if (_segments.isNotEmpty)
                                _folderAction(
                                  key: const Key('backup-folder-up'),
                                  icon: Icon(
                                    CupertinoIcons.arrow_up,
                                    size: 20,
                                    color: context.appPrimary,
                                  ),
                                  label: syncText(
                                    context,
                                    '上一级',
                                    'Parent folder',
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () => _load(
                                          _segments.sublist(
                                            0,
                                            _segments.length - 1,
                                          ),
                                        ),
                                )
                              else
                                Text(
                                  syncText(context, '文件夹', 'Folders'),
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: context.appSecondaryLabel,
                                  ),
                                ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!widget.restoring &&
                                      _source.createFolder != null)
                                    NewRemoteFolderButton(
                                      key: const Key('new-backup-folder'),
                                      onPressed:
                                          _busy ||
                                              _error != null ||
                                              _creationError != null
                                          ? null
                                          : _newFolder,
                                    ),
                                  const FolderViewToggle(),
                                ],
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 8),
                            child: Divider(
                              height: 1,
                              color: context.appSeparator,
                            ),
                          ),
                          if (_creating)
                            Text(
                              syncText(context, '正在新建文件夹…', 'Creating folder…'),
                            ),
                          if (_justCreated && !_loading && _error == null)
                            Text(
                              syncText(
                                context,
                                widget.forSync
                                    ? '已进入新文件夹。点下方按钮即可选择它，尚未开始同步。'
                                    : '已进入新文件夹。点下方按钮即可选择它，尚未开始备份。',
                                widget.forSync
                                    ? 'Your new folder is open. Use the button below to select it. Sync has not started.'
                                    : 'Your new folder is open. Use the button below to select it. Backup has not started.',
                              ),
                              key: const Key('backup-folder-created'),
                            ),
                          if (_creationError != null) ...[
                            Text(
                              _creationError!,
                              key: const Key('backup-folder-create-error'),
                            ),
                            TextButton(
                              key: const Key('refresh-after-folder-create'),
                              onPressed: _busy ? null : () => _load(_segments),
                              child: Text(
                                syncText(context, '刷新列表', 'Refresh folders'),
                              ),
                            ),
                          ],
                          if (_loading)
                            const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(
                                child: CircularProgressIndicator.adaptive(),
                              ),
                            )
                          else if (_error != null)
                            _errorState(context)
                          else if (_folders.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 28),
                              child: Text(
                                syncText(
                                  context,
                                  '这里没有子文件夹，可以选择当前文件夹。',
                                  'No subfolders here. You can use this folder.',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!_loading && _error == null && _folders.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        sliver: _folderSliver(context),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: BackupActionButton(
                  key: const Key('use-backup-folder'),
                  label: syncText(context, '使用这个文件夹', 'Use this folder'),
                  onPressed: _busy || _error != null || _creationError != null
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
    ),
  );

  /// The subfolders, as tiles or rows. Opening one is the only thing a tap
  /// does; choosing still needs "Use this folder".
  Widget _folderSliver(BuildContext context) {
    void open(WebDavBackupFolder folder) => _load([..._segments, folder.name]);
    if (ref.watch(folderViewModeProvider) == FolderViewMode.list) {
      return SliverList.builder(
        itemCount: _folders.length,
        itemBuilder: (context, index) {
          final folder = _folders[index];
          return RemoteEntryRow(
            key: ValueKey('backup-folder-${folder.name}'),
            name: folder.name,
            isDir: true,
            inactive: _busy,
            onTap: _busy ? null : () => open(folder),
          );
        },
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) => SliverGrid.builder(
          gridDelegate: remoteEntryGridDelegate(
            context,
            constraints.crossAxisExtent,
          ),
          itemCount: _folders.length,
          itemBuilder: (context, index) {
            final folder = _folders[index];
            return CupertinoButton(
              key: ValueKey('backup-folder-${folder.name}'),
              minimumSize: Size.zero,
              padding: EdgeInsets.zero,
              onPressed: _busy ? null : () => open(folder),
              child: SizedBox.expand(
                child: RemoteEntryTile(
                  name: folder.name,
                  isDir: true,
                  inactive: _busy,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Why the folders cannot be shown, and the one thing to do about it:
  /// retry a connection that did not answer, or fix one that was refused.
  Widget _errorState(BuildContext context) {
    final fixFirst = _authenticationError;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(
            fixFirst
                ? CupertinoIcons.lock_shield
                : CupertinoIcons.wifi_exclamationmark,
            size: 40,
            color: context.appSecondaryLabel,
          ),
          const SizedBox(height: 12),
          Text(
            _errorMessage(context),
            key: const Key('backup-folder-error'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.45,
              color: context.appSecondaryLabel,
            ),
          ),
          if (!fixFirst || widget.editConnection != null) ...[
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: fixFirst
                  ? BackupActionButton(
                      key: const Key('backup-folder-error-edit'),
                      label: syncText(context, '修改连接', 'Edit connection'),
                      secondary: true,
                      onPressed: _busy ? null : _editConnection,
                    )
                  : BackupActionButton(
                      key: const Key('backup-folder-retry'),
                      label: syncText(context, '重试', 'Retry'),
                      secondary: true,
                      onPressed: _busy ? null : () => _load(_segments),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _folderAction({
    required Key key,
    required Widget icon,
    required String label,
    required VoidCallback? onPressed,
  }) => AdaptiveTextButton(
    key: key,
    onPressed: onPressed,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTheme.merge(
            data: IconThemeData(color: context.appPrimary),
            child: icon,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(label)),
        ],
      ),
    ),
  );
}
