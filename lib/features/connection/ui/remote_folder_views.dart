import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/state/folder_view_mode.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/automation_id.dart';

/// Switches every folder screen between tiles and rows. The icon shows the
/// layout a tap switches to, as Files and Finder do.
class FolderViewToggle extends ConsumerWidget {
  const FolderViewToggle({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(folderViewModeProvider);
    final toList = mode == FolderViewMode.grid;
    final label = toList
        ? syncText(context, '以列表显示', 'Show as list')
        : syncText(context, '以图标显示', 'Show as icons');
    return AdaptiveIconButton(
      key: const Key('folder-view-toggle'),
      tooltip: label,
      semanticLabel: label,
      icon: Icon(
        toList ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2,
        color: context.appPrimary,
      ),
      materialIcon: Icon(
        toList ? Icons.view_list_outlined : Icons.grid_view,
        size: 24,
        color: context.appPrimary,
      ),
      onPressed: enabled
          ? () => ref.read(folderViewModeProvider.notifier).toggle()
          : null,
    );
  }
}

/// "New folder" on every folder screen: the same glyph in the same place,
/// next to [FolderViewToggle].
class NewRemoteFolderButton extends StatelessWidget {
  const NewRemoteFolderButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = syncText(context, '新建文件夹', 'New folder');
    return withAutomationId(
      key,
      AdaptiveIconButton(
        tooltip: label,
        semanticLabel: label,
        icon: Icon(CupertinoIcons.folder_badge_plus, color: context.appPrimary),
        materialIcon: Icon(
          Icons.create_new_folder_outlined,
          size: 24,
          color: context.appPrimary,
        ),
        onPressed: onPressed,
      ),
    );
  }
}

/// Columns for the tile layout: as many as fit, between one and six.
SliverGridDelegate remoteEntryGridDelegate(
  BuildContext context,
  double crossAxisExtent,
) => SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount:
      ((crossAxisExtent + AppSpacing.sm) /
              (40 +
                  MediaQuery.textScalerOf(context).scale(12) * 3 +
                  AppSpacing.sm))
          .floor()
          .clamp(1, 6),
  childAspectRatio: 1,
  mainAxisSpacing: AppSpacing.sm,
  crossAxisSpacing: AppSpacing.sm,
);

IconData _glyph(BuildContext context, bool isDir) {
  final apple = isApplePlatform(context);
  return isDir
      ? (apple ? CupertinoIcons.folder_solid : Icons.folder)
      : (apple ? CupertinoIcons.doc_text_fill : Icons.description);
}

/// A folder or file as a square tile.
class RemoteEntryTile extends StatelessWidget {
  const RemoteEntryTile({
    super.key,
    required this.name,
    required this.isDir,
    this.progress,
    this.inactive = false,
  });

  final String name;
  final bool isDir;
  final double? progress;

  /// The screen is busy, so the tile cannot be opened right now. The glyph
  /// keeps its own colour and the tile is faded instead of turning grey.
  final bool inactive;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.medium);
    final textColor = Theme.of(context).textTheme.bodyMedium?.color;
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: context.appGroupedSurface.withValues(alpha: 0.82),
        borderRadius: radius,
        border: Border.all(
          color: context.appSeparator.withValues(
            alpha: AppOpacity.groupedBorder,
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _glyph(context, isDir),
                    size: 26,
                    // Explicit colour so a disabled parent button cannot
                    // repaint the glyph with its own grey.
                    color: isDir
                        ? context.appPrimary
                        : context.appSecondaryLabel,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                    ).copyWith(color: textColor),
                  ),
                ],
              ),
              if (progress != null && progress! < 1.0)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.grey.withAlpha(187),
                    borderRadius: radius,
                  ),
                  child: Center(
                    child: Stack(
                      fit: StackFit.loose,
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: progress,
                          color: Colors.white,
                        ),
                        Text(
                          '${(progress! * 100).toInt()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // Always the same widget shape: swapping the root widget type would unmount
    // and rebuild the whole tile (and its text elements) on every refresh, which
    // is exactly the flicker the loading state must avoid.
    return Opacity(opacity: inactive ? AppOpacity.disabled : 1, child: content);
  }
}

/// A folder or file as a list row: its name in full, a file's size and time
/// underneath, and a chevron on folders.
class RemoteEntryRow extends StatelessWidget {
  const RemoteEntryRow({
    super.key,
    required this.name,
    required this.isDir,
    required this.onTap,
    this.detail,
    this.progress,
    this.inactive = false,
  });

  final String name;
  final bool isDir;
  final String? detail;
  final double? progress;
  final bool inactive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final downloading = progress != null && progress! < 1.0;
    return Opacity(
      opacity: inactive ? AppOpacity.disabled : 1,
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          minTileHeight: 56,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            _glyph(context, isDir),
            color: isDir ? context.appPrimary : context.appSecondaryLabel,
          ),
          title: Text(name),
          subtitle: detail == null
              ? null
              : Text(
                  detail!,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.appSecondaryLabel,
                  ),
                ),
          trailing: downloading
              ? SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2.5,
                  ),
                )
              : isDir
              ? Icon(
                  CupertinoIcons.chevron_right,
                  size: 18,
                  color: context.appSecondaryLabel,
                )
              : null,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// Asks for the name of one new folder in [location]. Returns the trimmed
/// name, or null when cancelled. Nothing is created here.
Future<String?> showNewRemoteFolderDialog(
  BuildContext context, {
  required String location,
  required Set<String> existingNames,
  required String placeholder,
  required String confirmLabel,
}) {
  var enteredName = '';
  return showAdaptiveForm<String>(
    context: context,
    title: syncText(context, '新建文件夹', 'New folder'),
    icon: const Icon(CupertinoIcons.folder_fill_badge_plus),
    barrierDismissible: false,
    builder: (dialogContext, setDialogState) {
      final trimmedName = enteredName.trim();
      final issue = WebDavBackupFolderBrowser.folderNameError(trimmedName);
      final errorText = existingNames.contains(trimmedName)
          ? syncText(
              dialogContext,
              '这里已有同名的文件或文件夹，请换个名称。',
              'Something with this name already exists here. Choose another name.',
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
      final apple = isApplePlatform(dialogContext);
      final showError = enteredName.isNotEmpty && errorText != null;
      final secondary = TextStyle(
        fontSize: apple ? 13 : null,
        height: 1.4,
        color: dialogContext.appSecondaryLabel,
      );
      return AdaptiveFormSpec<String>(
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (apple)
                Text(
                  syncText(dialogContext, '创建在 $location', 'In $location'),
                  style: TextStyle(color: dialogContext.appSecondaryLabel),
                )
              else ...[
                const SizedBox(height: 12),
                Text(
                  syncText(
                    dialogContext,
                    '创建位置：$location',
                    'Create in: $location',
                  ),
                ),
              ],
              SizedBox(height: apple ? 16 : 12),
              if (apple)
                AppDialogTextField(
                  key: const Key('new-backup-folder-name'),
                  autofocus: true,
                  autocorrect: false,
                  placeholder: placeholder,
                  invalid: showError,
                  onChanged: (value) =>
                      setDialogState(() => enteredName = value),
                )
              else
                TextField(
                  key: const Key('new-backup-folder-name'),
                  autofocus: true,
                  decoration: InputDecoration(hintText: placeholder),
                  onChanged: (value) =>
                      setDialogState(() => enteredName = value),
                ),
              if (showError) ...[
                const SizedBox(height: 8),
                Text(
                  errorText,
                  key: const Key('new-backup-folder-name-error'),
                  style: TextStyle(
                    fontSize: apple ? 13 : null,
                    color: dialogContext.appDanger,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                syncText(
                  dialogContext,
                  '只新建一个空文件夹，不会改动已有数据。',
                  'Creates an empty folder without changing existing data.',
                ),
                style: apple ? secondary : null,
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
            label: confirmLabel,
            value: trimmedName,
            enabled: errorText == null,
            isDefault: true,
            emphasized: true,
          ),
        ],
      );
    },
  );
}

/// Why a new folder could not be created, in words the user can act on.
/// Anything without a clear answer may still have been created, so the user is
/// told to look before trying again.
String remoteFolderCreationError(
  BuildContext context,
  Object error,
) => switch (error) {
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
};
