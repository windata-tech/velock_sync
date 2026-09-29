import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';

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

/// Browsing and selecting are read-only. An explicit new-folder confirmation
/// creates only that empty directory, never a profile or a backup.
class BackupFolderPicker extends StatefulWidget {
  const BackupFolderPicker({
    super.key,
    required this.connectionName,
    required this.basePath,
    required this.loadFolders,
    this.initialSegments = const [],
    this.restoring = false,
    this.createFolder,
  });

  final String connectionName;
  final String basePath;
  final List<String> initialSegments;
  final bool restoring;
  final Future<List<WebDavBackupFolder>> Function(List<String>) loadFolders;
  final Future<void> Function(List<String> parent, String name)? createFolder;

  @override
  State<BackupFolderPicker> createState() => _BackupFolderPickerState();
}

class _BackupFolderPickerState extends State<BackupFolderPicker> {
  late List<String> _segments;
  List<WebDavBackupFolder> _folders = const [];
  bool _loading = true;
  Object? _error;
  int _generation = 0;
  bool _showingCreate = false;
  bool _creating = false;
  String? _creationError;
  bool _justCreated = false;
  bool get _busy => _loading || _creating;

  @override
  void initState() {
    super.initState();
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

  Future<void> _newFolder() async {
    final create = widget.createFolder;
    if (_busy ||
        _error != null ||
        _showingCreate ||
        create == null ||
        widget.restoring) {
      return;
    }
    _showingCreate = true;
    final parent = List<String>.unmodifiable(_segments);
    var enteredName = '';
    String? name;
    try {
      name = await showAdaptiveForm<String>(
        context: context,
        title: syncText(context, '新建文件夹', 'New folder'),
        barrierDismissible: false,
        builder: (dialogContext, setDialogState) {
          final trimmedName = enteredName.trim();
          final issue = WebDavBackupFolderBrowser.folderNameError(trimmedName);
          final duplicate = _folders.any(
            (folder) => folder.name == trimmedName,
          );
          final errorText = duplicate
              ? syncText(
                  dialogContext,
                  '这里已有同名文件夹，请换个名称。',
                  'A folder with this name already exists. Choose another name.',
                )
              : switch (issue) {
                  'empty_name' => syncText(
                    dialogContext,
                    '请输入文件夹名称。',
                    'Enter a folder name.',
                  ),
                  'name_too_long' => syncText(
                    dialogContext,
                    '名称太长，请使用短一些的名称。',
                    'This name is too long. Use a shorter name.',
                  ),
                  null => null,
                  _ => syncText(
                    dialogContext,
                    '名称不能是 . 或 ..，也不能包含斜杠或控制字符。',
                    'Use one folder name without slashes, control characters, . or ..',
                  ),
                };
          return AdaptiveFormSpec<String>(
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    syncText(
                      dialogContext,
                      '创建位置：$_displayPath',
                      'Create in: $_displayPath',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isApplePlatform(dialogContext))
                    CupertinoTextField(
                      key: const Key('new-backup-folder-name'),
                      autofocus: true,
                      placeholder: syncText(
                        dialogContext,
                        '例如：格间备份',
                        'e.g. Velock backup',
                      ),
                      onChanged: (value) =>
                          setDialogState(() => enteredName = value),
                    )
                  else
                    TextField(
                      key: const Key('new-backup-folder-name'),
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: syncText(
                          dialogContext,
                          '例如：格间备份',
                          'e.g. Velock backup',
                        ),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => enteredName = value),
                    ),
                  if (enteredName.isNotEmpty && errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText,
                      key: const Key('new-backup-folder-name-error'),
                      style: TextStyle(color: dialogContext.appDanger),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    syncText(
                      dialogContext,
                      '只新建一个空文件夹，不会改动已有数据。',
                      'Creates an empty folder without changing existing data.',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              AdaptiveAlertAction<String>(
                key: const Key('cancel-new-backup-folder'),
                label: syncText(dialogContext, '取消', 'Cancel'),
              ),
              AdaptiveAlertAction<String>(
                key: const Key('confirm-new-backup-folder'),
                label: syncText(dialogContext, '创建并进入', 'Create and open'),
                value: trimmedName,
                enabled: errorText == null,
                isDefault: true,
                emphasized: true,
              ),
            ],
          );
        },
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
        () => _creationError = switch (error) {
          ProviderRequestException(statusCode: 401) => syncText(
            context,
            '无法新建文件夹，请返回检查此位置的登录信息。',
            'Could not create a folder. Go back and check this location’s sign-in details.',
          ),
          ProviderRequestException(statusCode: 403) => syncText(
            context,
            '这个位置没有新建文件夹的权限，请选择其他位置。',
            'You do not have permission to create folders here. Choose another location.',
          ),
          ProviderRequestException(statusCode: 405) => syncText(
            context,
            '未能新建：可能已有同名文件夹，或此位置不允许新建。请刷新列表确认，或换个名称和位置。',
            'Could not create this folder. The name may already exist or this location may not allow new folders. Refresh to check, or choose another name or location.',
          ),
          ProviderRequestException(statusCode: 409) => syncText(
            context,
            '当前文件夹可能已被移动，请刷新列表或返回上一级。',
            'The current folder may have moved. Refresh or go to the parent folder.',
          ),
          _ => syncText(
            context,
            '未能确认是否创建成功。请先刷新列表查看，不要重复创建。',
            'Could not confirm whether the folder was created. Refresh the list to check before trying again.',
          ),
        },
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
        widget.restoring ? '找到原备份文件夹' : '选择备份文件夹',
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
                      style: const TextStyle(height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      syncText(
                        context,
                        widget.restoring
                            ? '选择当初备份时使用的保存文件夹，Sync 会查找其中的格间备份。'
                            : '选择已有文件夹，或新建一个空文件夹保存备份。不会改动其他文件夹。',
                        widget.restoring
                            ? 'Choose the folder you originally saved to. Sync will look for your Velock backup inside it.'
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
                            icon: CupertinoIcons.arrow_up,
                            label: syncText(context, '上一级', 'Parent folder'),
                            onPressed: _busy
                                ? null
                                : () => _load(
                                    _segments.sublist(0, _segments.length - 1),
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
                        if (!widget.restoring && widget.createFolder != null)
                          _folderAction(
                            key: const Key('new-backup-folder'),
                            icon: CupertinoIcons.folder_badge_plus,
                            label: syncText(context, '新建文件夹', 'New folder'),
                            onPressed:
                                _busy ||
                                    _error != null ||
                                    _creationError != null
                                ? null
                                : _newFolder,
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Divider(height: 1, color: context.appSeparator),
                    ),
                    if (_creating)
                      Text(syncText(context, '正在新建文件夹…', 'Creating folder…')),
                    if (_justCreated && !_loading && _error == null)
                      Text(
                        syncText(
                          context,
                          '已进入新文件夹。点下方按钮即可选择它，尚未开始备份。',
                          'Your new folder is open. Use the button below to select it. Backup has not started.',
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
                          minTileHeight: 56,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          leading: Icon(
                            CupertinoIcons.folder,
                            color: context.appPrimary,
                          ),
                          title: Text(folder.name),
                          trailing: const Icon(
                            CupertinoIcons.chevron_right,
                            size: 18,
                          ),
                          onTap: _busy
                              ? null
                              : () => _load([..._segments, folder.name]),
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

  Widget _folderAction({
    required Key key,
    required IconData icon,
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
          Icon(icon, size: 20, color: context.appPrimary),
          const SizedBox(width: 8),
          Flexible(child: Text(label)),
        ],
      ),
    ),
  );
}
