import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_provisioner.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';
import 'package:velock_sync/features/plain_sync/local_folder_open.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_run.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'package:velock_sync/widgets/common_widgets.dart'
    show showPlatformMessage;
import 'plain_option_row.dart';

/// One plain sync location: both halves, the sync policy and its history.
class PlainLocationDetail extends ConsumerStatefulWidget {
  const PlainLocationDetail({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<PlainLocationDetail> createState() =>
      _PlainLocationDetailState();
}

class _PlainLocationDetailState extends ConsumerState<PlainLocationDetail> {
  bool _busy = false;

  /// Direction and conflict handling are edited as a draft: the header's save
  /// action commits them together, and leaving with a draft asks first.
  MirrorDirection? _draftDirection;
  MirrorConflictPolicy? _draftConflictPolicy;

  MirrorDirection _directionOf(PlainFolderSyncProfile profile) =>
      _draftDirection ?? profile.direction;

  MirrorConflictPolicy _conflictOf(PlainFolderSyncProfile profile) =>
      _draftConflictPolicy ?? profile.conflictPolicy;

  bool _hasDraft(PlainFolderSyncProfile profile) =>
      _directionOf(profile) != profile.direction ||
      _conflictOf(profile) != profile.conflictPolicy;

  void _discardDraft() {
    _draftDirection = null;
    _draftConflictPolicy = null;
  }

  /// Commits the draft; returns whether it was actually stored.
  ///
  /// Success is read back from the refreshed provider rather than assumed:
  /// [_update] reports failures with a message instead of throwing, and a
  /// refused save must not look like a saved one.
  Future<bool> _saveDraft(PlainLocationView view) async {
    final profile = view.profile;
    if (!_hasDraft(profile)) return false;
    final wantedDirection = _directionOf(profile);
    final wantedConflict = _conflictOf(profile);
    await _update(
      view,
      (current) => current.copyWith(
        direction: wantedDirection,
        conflictPolicy: wantedConflict,
      ),
    );
    if (!mounted) return false;
    final fresh = ref.read(plainLocationViewsProvider).asData?.value;
    final stored = fresh == null ? null : _view(fresh);
    final saved =
        stored != null &&
        stored.profile.direction == wantedDirection &&
        stored.profile.conflictPolicy == wantedConflict;
    if (!saved) return false;
    setState(_discardDraft);
    return true;
  }

  void _popDetail() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go(AppRoutes.files.path);
    }
  }

  /// Asks what to do with unsaved changes; true when the page may close.
  Future<bool> _confirmLeaving(PlainLocationView view) async {
    if (!_hasDraft(view.profile)) return true;
    final choice = await showAdaptiveActionSheet<_LeaveChoice>(
      context: context,
      title: syncText(context, '保存这次修改？', 'Save these changes?'),
      message: syncText(
        context,
        '同步方向和冲突处理的修改还没有保存。',
        'Your changes to direction and conflict handling are not saved yet.',
      ),
      actions: [
        AdaptiveAction(
          key: const Key('plain-draft-save'),
          value: _LeaveChoice.save,
          label: syncText(context, '保存', 'Save'),
        ),
        AdaptiveAction(
          key: const Key('plain-draft-discard'),
          value: _LeaveChoice.discard,
          label: syncText(context, '不保存', 'Discard'),
          isDestructive: true,
        ),
      ],
      cancelLabel: syncText(context, '取消', 'Cancel'),
    );
    switch (choice) {
      case _LeaveChoice.save:
        // The caller pops once, whether the save succeeded or not: a refused
        // save keeps the draft so the user can retry.
        return mounted ? await _saveDraft(view) : false;
      case _LeaveChoice.discard:
        setState(_discardDraft);
        return true;
      case _LeaveChoice.cancel:
      case null:
        return false;
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(plainLocationViewsProvider);
    await ref.read(plainLocationViewsProvider.future);
  }

  PlainLocationView? _view(List<PlainLocationView> views) {
    for (final view in views) {
      if (view.profile.profileId == widget.profileId) return view;
    }
    return null;
  }

  Future<void> _update(
    PlainLocationView view,
    PlainFolderSyncProfile Function(PlainFolderSyncProfile current) change, {
    bool resetBaseline = false,
  }) async {
    setState(() => _busy = true);
    try {
      await ref.read(plainFolderProfilesProvider).update(view.profile, change);
      if (resetBaseline) {
        await ref
            .read(syncStateDatabaseProvider)
            .clearMirrorEntries(widget.profileId);
      }
      await _refresh();
    } on Object catch (error, stackTrace) {
      loge('Plain location update failed: $error', stackTrace: stackTrace);
      if (mounted) {
        showPlatformMessage(
          context,
          syncText(
            context,
            '没有保存成功：这个同步位置可能正在运行或已被修改，请返回后重试。',
            'Not saved: this location may be running or was changed. Go back and try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pause and resume use the repository's own state transitions, so the
  /// lifecycle state is changed by the same call the location card uses.
  Future<void> _setPaused(
    PlainLocationView view, {
    required bool paused,
  }) async {
    setState(() => _busy = true);
    try {
      final repository = ref.read(plainFolderProfilesProvider);
      if (paused) {
        await repository.pause(widget.profileId);
      } else {
        await repository.resume(widget.profileId);
      }
      await _refresh();
    } on Object catch (error, stackTrace) {
      loge(
        'Plain location state update failed: $error',
        stackTrace: stackTrace,
      );
      if (mounted) {
        showPlatformMessage(
          context,
          syncText(
            context,
            '暂时无法更新状态，请稍后重试。',
            'Could not update the state. Try again later.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rescheduleBackground() async {
    final eligible = await ref
        .read(syncProfileRepositoryProvider)
        .listBackgroundEligible();
    final scheduler = BackgroundSyncScheduler();
    if (eligible.isEmpty) {
      await scheduler.disable();
      return;
    }
    await scheduler.enable(
      allowCellular: eligible.any(
        (summary) => summary.backgroundPolicy.allowCellular,
      ),
      requiresCharging: eligible.every(
        (summary) => summary.backgroundPolicy.requiresCharging,
      ),
    );
  }

  /// Hands the local folder to the system file manager, at that folder.
  Future<void> _openLocalFolder(PlainLocationView view) async {
    if (_busy) return;
    final outcome = await openLocalFolderInFileManager(
      grantForLocalRoot(
        kind: view.profile.accessKind,
        rootReference: view.profile.localRootReference,
      ),
      launch: ref.read(folderLauncherProvider),
      appleFolders: ref.read(appleFolderAccessProvider),
    );
    if (!mounted || outcome == FolderOpenOutcome.opened) return;
    showPlatformMessage(
      context,
      folderOpenUnavailableMessage(context, view.profile.localDisplayName),
    );
  }

  /// Opens the app's own browser on the remote folder this location mirrors.
  void _openRemoteFolder(PlainLocationView view) {
    if (_busy || view.connection == null) return;
    final segments = view.profile.remoteRootSegments;
    context.pushNamed(
      AppRoutes.connection.name,
      pathParameters: {'id': view.profile.connectionId},
      queryParameters: {
        if (segments.isNotEmpty) 'segments': segments.join('/'),
      },
    );
  }

  Future<void> _changeLocalFolder(PlainLocationView view) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final provisioner = PlainFolderProvisioner(
        authorizer: ref.read(folderAccessAuthorizerProvider),
        profiles: ref.read(plainFolderProfilesProvider),
        // The provisioner refuses a scope that belongs to a Velock backup; the
        // repository is required so that check cannot be forgotten here.
        backups: ref.read(syncProfileRepositoryProvider),
      );
      final grant = await provisioner.pickLocalFolder();
      if (grant == null || !mounted) return;
      final label = await provisioner.resolveLocalDisplayName(grant);
      if (!mounted) return;
      final confirmed = await showAdaptiveConfirmation(
        context,
        title: syncText(context, '更换本机文件夹？', 'Change the local folder?'),
        message: syncText(
          context,
          '新的本机文件夹：$label\n\n更换后需要重新建立同步基线，下一次同步会重新比较两边内容（只在本机的新文件会上传，远端已有的文件会下载）。远端文件不会被删除，旧本机文件夹里的文件也不会被删除。',
          'New local folder: $label\n\nChanging it rebuilds the sync baseline: the next sync compares both sides again (files that exist only locally are uploaded, files that exist remotely are downloaded). Nothing is deleted on either side, including in the old folder.',
        ),
        confirmLabel: syncText(context, '更换并重建基线', 'Change and rebuild'),
        confirmKey: const Key('plain-change-local-confirm'),
      );
      if (!confirmed || !mounted) return;
      await _update(
        view,
        (current) => current.copyWith(
          localRootReference: grant.rootReference,
          localDisplayName: label,
          accessKind: grant.kind,
        ),
        resetBaseline: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeRemoteFolder(PlainLocationView view) async {
    final connection = view.connection;
    if (_busy || connection == null) return;
    final protocol = connection.protocol;
    if (protocol is! WebDavProtocolModel) return;
    setState(() => _busy = true);
    try {
      final loader = ref.read(backupFolderLoaderProvider);
      final picked = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          builder: (_) => BackupFolderPicker(
            connectionName: connection.name,
            basePath: RemoteObjectStoreFactory.webDavDisplayAddress(protocol),
            forSync: true,
            initialSegments: view.profile.remoteRootSegments,
            loadFolders: (relative) =>
                loader(protocol: protocol, relativeSegments: relative),
            createFolder: (parent, name) => ref.read(
              backupFolderCreatorProvider,
            )(protocol: protocol, relativeSegments: parent, name: name),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      if (picked.isEmpty) {
        showPlatformMessage(
          context,
          syncText(
            context,
            '请进入一个真实存在的文件夹再选择。',
            'Open a folder that really exists and select it.',
          ),
        );
        return;
      }
      // Moving onto a backup folder — or onto another location's folder — is
      // refused for the same reasons as creating there: the mirror would treat
      // encrypted objects as ordinary files, and two locations over the same
      // tree would overwrite each other.
      try {
        await assertPlainFolderIsNotBackup(
          backups: ref.read(syncProfileRepositoryProvider),
          connectionId: view.profile.connectionId,
          segments: picked,
          childFolderNames: () async => [
            for (final folder in await loader(
              protocol: protocol,
              relativeSegments: picked,
            ))
              folder.name,
          ],
        );
        await assertPlainScopeAvoidsOtherLocations(
          profiles: ref.read(plainFolderProfilesProvider),
          connectionId: view.profile.connectionId,
          segments: picked,
          localRootReference: view.profile.localRootReference,
          selfProfileId: view.profile.profileId,
        );
      } on BackupFolderOverlapException catch (failure) {
        if (!mounted) return;
        showPlatformMessage(
          context,
          failure.backupName.isEmpty
              ? syncText(
                  context,
                  '这个文件夹里有格间的加密备份，明文同步不能用它。',
                  'That folder holds a Velock encrypted backup. Plain sync cannot use it.',
                )
              : syncText(
                  context,
                  '这个文件夹属于格间备份（${failure.backupName}），明文同步不能用它。',
                  'That folder belongs to the backup “${failure.backupName}”. Plain sync cannot use it.',
                ),
        );
        return;
      } on PlainLocationOverlapException catch (failure) {
        if (!mounted) return;
        showPlatformMessage(
          context,
          syncText(
            context,
            '这个文件夹和另一个同步位置互相包含（${failure.existingDisplayName}）。',
            'That folder overlaps another sync location (${failure.existingDisplayName}).',
          ),
        );
        return;
      }
      if (!mounted) return;
      final confirmed = await showAdaptiveConfirmation(
        context,
        title: syncText(context, '更换远端文件夹？', 'Change the remote folder?'),
        message: syncText(
          context,
          '新的远端文件夹：/${picked.join('/')}\n\n只修改这个同步位置的远端路径，不改动连接本身。更换后需要重新建立同步基线；旧远端文件夹里的文件不会被删除，也不会自动迁移。',
          'New remote folder: /${picked.join('/')}\n\nOnly this location’s remote path changes; the connection itself is untouched. The baseline is rebuilt, and nothing in the old remote folder is deleted or migrated.',
        ),
        confirmLabel: syncText(context, '更换并重建基线', 'Change and rebuild'),
        confirmKey: const Key('plain-change-remote-confirm'),
      );
      if (!confirmed || !mounted) return;
      await _update(
        view,
        (current) => current.copyWith(remoteRootSegments: picked),
        resetBaseline: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(PlainLocationView view) async {
    final confirmed = await showAdaptiveConfirmation(
      context,
      title: syncText(context, '删除这个同步位置？', 'Delete this sync location?'),
      message: syncText(
        context,
        '只删除本机的同步配置和同步记录。本机文件夹和远端文件夹里的文件都不会被删除，也不会被改动。',
        'Only the configuration and its sync history on this device are removed. Files in the local folder and in the remote folder are not touched.',
      ),
      confirmLabel: syncText(context, '删除同步位置', 'Delete location'),
      isDestructive: true,
      confirmKey: const Key('plain-remove-confirm'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(syncProfileRepositoryProvider).remove(widget.profileId);
      await ref
          .read(syncStateDatabaseProvider)
          .clearMirrorEntries(widget.profileId);
      if (!mounted) return;
      ref.invalidate(plainLocationViewsProvider);
      context.pop();
    } on Object catch (error, stackTrace) {
      loge('Plain location removal failed: $error', stackTrace: stackTrace);
      if (mounted) {
        showPlatformMessage(
          context,
          syncText(
            context,
            '同步正在运行或状态不允许，暂时无法删除。',
            'Sync is running or the state does not allow deleting yet.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs this location, including the deletion pass the user confirmed.
  ///
  /// The confirmed pass runs inside the same busy window: re-entering [_run]
  /// while `_busy` was still true made 「确认删除并继续」 silently do nothing (and
  /// the next tap then deleted an unreviewed plan). Deletions are never applied
  /// without the review sheet that lists the paths.
  Future<void> _run(PlainLocationView view) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runPlainLocation(context, ref, view);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(plainLocationViewsProvider);
    final data = locations.asData?.value;
    final view = data == null ? null : _view(data);
    final dirty = view != null && _hasDraft(view.profile);
    return AdaptiveScaffold(
      title:
          view?.profile.displayName ??
          syncText(context, '同步位置', 'Sync location'),
      actions: [
        if (view != null && dirty)
          TextButton(
            key: const Key('plain-detail-save'),
            onPressed: _busy ? null : () => _saveDraft(view),
            child: Text(syncText(context, '保存', 'Save')),
          ),
        AdaptiveIconButton(
          tooltip: syncText(context, '刷新', 'Refresh'),
          onPressed: _refresh,
          icon: const Icon(CupertinoIcons.refresh),
        ),
      ],
      body: view == null
          ? (locations.hasError
                ? AdaptiveErrorState(
                    message: syncText(
                      context,
                      '找不到这个同步位置。',
                      'This sync location could not be loaded.',
                    ),
                    onRetry: _refresh,
                  )
                : AdaptiveLoadingState(
                    label: syncText(
                      context,
                      '正在读取同步位置',
                      'Loading sync location',
                    ),
                  ))
          : PopScope(
              // Leaving with an unsaved direction/conflict draft asks first;
              // the system back gesture and the header back button both land
              // here because the header pops with `maybePop`.
              canPop: !dirty,
              onPopInvokedWithResult: (didPop, result) async {
                if (didPop || !mounted) return;
                final leave = await _confirmLeaving(view);
                if (leave && mounted) _popDetail();
              },
              child: _body(context, view),
            ),
    );
  }

  Widget _body(BuildContext context, PlainLocationView view) {
    final profile = view.profile;
    final status = plainLocationStatus(context, view);
    final paused = profile.state == PlainFolderProfileState.paused;
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      children: [
        _StatusCard(
          view: view,
          status: status,
          busy: _busy,
          // Always through the review flow, never with deletions switched
          // on from a plan the user has not seen.
          onRun: () => _run(view),
          onTogglePause: () => _setPaused(view, paused: !paused),
        ),
        AdaptiveListSection(
          header: syncText(context, '这个同步位置', 'This location'),
          footer: Text(
            syncText(
              context,
              '远端是明文文件夹：能访问这个云端账号的人都能看到和修改这些文件。',
              'The remote folder is not encrypted: anyone with access to that cloud account can read and change these files.',
            ),
          ),
          children: [
            AdaptiveListTile(
              widgetKey: const Key('plain-local-folder'),
              leading: const Icon(CupertinoIcons.device_phone_portrait),
              title: Text(syncText(context, '本机文件夹', 'Local folder')),
              subtitle: Text(profile.localDisplayName),
              trailing: AdaptiveTrailingGroup(
                children: [
                  _FolderAction(
                    widgetKey: const Key('plain-local-open'),
                    label: syncText(context, '打开', 'Open'),
                    onTap: _busy ? null : () => _openLocalFolder(view),
                  ),
                  _FolderAction(
                    widgetKey: const Key('plain-local-change'),
                    label: syncText(context, '更改', 'Change'),
                    onTap: _busy ? null : () => _changeLocalFolder(view),
                  ),
                ],
              ),
              onTap: _busy ? null : () => _changeLocalFolder(view),
            ),
            AdaptiveListTile(
              widgetKey: const Key('plain-remote-folder'),
              leading: const Icon(CupertinoIcons.cloud),
              title: Text(syncText(context, '远端文件夹', 'Remote folder')),
              subtitle: Text(
                view.connection == null
                    ? syncText(context, '远端连接已删除', 'Remote connection deleted')
                    : '${view.connectionName}${view.remotePath}',
              ),
              trailing: view.connection == null
                  ? null
                  : AdaptiveTrailingGroup(
                      children: [
                        _FolderAction(
                          widgetKey: const Key('plain-remote-open'),
                          label: syncText(context, '打开', 'Open'),
                          onTap: _busy ? null : () => _openRemoteFolder(view),
                        ),
                        _FolderAction(
                          widgetKey: const Key('plain-remote-change'),
                          label: syncText(context, '更改', 'Change'),
                          onTap: _busy ? null : () => _changeRemoteFolder(view),
                        ),
                      ],
                    ),
              onTap: _busy || view.connection == null
                  ? null
                  : () => _changeRemoteFolder(view),
            ),
          ],
        ),
        AdaptiveListSection(
          header: syncText(context, '同步方向', 'Direction'),
          children: [
            for (final value in MirrorDirection.values)
              PlainOptionRow(
                widgetKey: Key('plain-detail-direction-${value.name}'),
                selected: value == _directionOf(profile),
                title: directionLabel(context, value),
                explanation: directionExplanation(context, value),
                enabled: !_busy,
                onTap: () => setState(() => _draftDirection = value),
              ),
          ],
        ),
        if (_directionOf(profile) == MirrorDirection.bidirectional)
          AdaptiveListSection(
            header: syncText(context, '冲突处理', 'Conflicts'),
            footer: Text(
              syncText(
                context,
                '两边同时改过同一个文件时按这里的设置处理；默认保留两份，不会静默覆盖。',
                'When the same file changed on both sides, this setting decides. Keeping both is the default and never silently overwrites.',
              ),
            ),
            children: [
              for (final value in MirrorConflictPolicy.values)
                PlainOptionRow(
                  widgetKey: Key('plain-detail-conflict-${value.name}'),
                  selected: value == _conflictOf(profile),
                  title: conflictPolicyLabel(context, value),
                  explanation: conflictPolicyExplanation(context, value),
                  enabled: !_busy,
                  onTap: () => setState(() => _draftConflictPolicy = value),
                ),
            ],
          ),
        AdaptiveListSection(
          header: syncText(context, '最近一次同步', 'Last sync'),
          children: [
            AdaptiveListTile(
              leading: const Icon(CupertinoIcons.time),
              title: Text(
                view.stats?.finishedAt == null
                    ? syncText(context, '还没有同步过', 'Not synced yet')
                    : AppFormat.stamp(view.stats!.finishedAt),
              ),
              subtitle: Text(plainRunSummary(context, view.stats)),
            ),
            if (view.hasConflicts)
              AdaptiveListTile(
                widgetKey: const Key('plain-conflicts'),
                leading: Icon(
                  CupertinoIcons.exclamationmark_triangle,
                  color: AppTone.attention.color(context),
                ),
                title: Text(
                  syncText(
                    context,
                    '有 ${view.conflictCount} 个冲突记录',
                    '${view.conflictCount} conflicts recorded',
                  ),
                ),
                subtitle: Text(
                  syncText(
                    context,
                    '冲突按设置处理并保留在本机文件夹里；这里只记录发生过什么。',
                    'Conflicts were handled by your setting and stay in the local folder; this list only records what happened.',
                  ),
                ),
                isThreeLine: true,
                onTap: () => _showConflicts(view),
              ),
          ],
        ),
        AdaptiveListSection(
          header: syncText(context, '后台策略', 'Background policy'),
          children: [
            AdaptiveSwitchListTile(
              title: Text(syncText(context, '后台同步', 'Background sync')),
              subtitle: Text(
                syncText(
                  context,
                  '仅在系统允许时运行；暂停的位置不会运行。',
                  'Runs only when the system allows it, and never while paused.',
                ),
              ),
              value: profile.backgroundEnabled,
              onChanged: _busy
                  ? null
                  : (value) async {
                      await _update(
                        view,
                        (current) => current.copyWith(backgroundEnabled: value),
                      );
                      await _rescheduleBackground();
                    },
            ),
            AdaptiveSwitchListTile(
              title: Text(syncText(context, '允许蜂窝网络', 'Allow cellular data')),
              value: profile.backgroundAllowCellular,
              onChanged: !_busy && profile.backgroundEnabled
                  ? (value) async {
                      await _update(
                        view,
                        (current) =>
                            current.copyWith(backgroundAllowCellular: value),
                      );
                      await _rescheduleBackground();
                    }
                  : null,
            ),
            AdaptiveSwitchListTile(
              title: Text(syncText(context, '仅充电时运行', 'Only while charging')),
              value: profile.backgroundRequiresCharging,
              onChanged: !_busy && profile.backgroundEnabled
                  ? (value) async {
                      await _update(
                        view,
                        (current) =>
                            current.copyWith(backgroundRequiresCharging: value),
                      );
                      await _rescheduleBackground();
                    }
                  : null,
            ),
          ],
        ),
        AdaptiveListSection(
          header: syncText(context, '危险操作', 'Danger zone'),
          children: [
            AdaptiveListTile(
              widgetKey: const Key('plain-remove'),
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.delete_outline,
                  cupertino: CupertinoIcons.delete,
                ),
                color: AppTone.danger.color(context),
              ),
              title: Text(
                syncText(context, '删除这个同步位置', 'Delete this sync location'),
                style: TextStyle(color: AppTone.danger.color(context)),
              ),
              subtitle: Text(
                syncText(
                  context,
                  '只删除本机配置与记录，两端文件保持原样。',
                  'Removes only this device’s configuration and history. Both folders stay as they are.',
                ),
              ),
              enabled: !_busy,
              onTap: () => _remove(view),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showConflicts(PlainLocationView view) async {
    final conflicts = await ref
        .read(syncStateDatabaseProvider)
        .readMirrorConflicts(widget.profileId, limit: 50);
    if (!mounted) return;
    final title = syncText(context, '冲突记录', 'Conflict history');
    if (conflicts.isEmpty) {
      await showAdaptiveNotice(
        context: context,
        title: title,
        message: syncText(context, '没有冲突记录。', 'No conflicts recorded.'),
        confirmLabel: syncText(context, '知道了', 'OK'),
      );
      return;
    }
    final list = conflicts
        .map(
          (conflict) =>
              '${AppFormat.stamp(conflict.detectedAt)}  ${conflict.relativePath}',
        )
        .join('\n');
    final clear = await showAdaptiveConfirmation(
      context,
      title: title,
      message:
          '$list\n\n${syncText(context, '清除只移除这些记录，不会改动或删除任何文件。', 'Clearing removes only these records. No file is changed or deleted.')}',
      confirmLabel: syncText(context, '清除记录', 'Clear records'),
      cancelLabel: syncText(context, '关闭', 'Close'),
      confirmKey: const Key('plain-conflicts-clear'),
    );
    if (!clear || !mounted) return;
    await ref
        .read(syncStateDatabaseProvider)
        .clearMirrorConflicts(
          widget.profileId,
          through: conflicts.first.detectedAt,
        );
    await _refresh();
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.view,
    required this.status,
    required this.busy,
    required this.onRun,
    required this.onTogglePause,
  });

  final PlainLocationView view;
  final PlainLocationStatus status;
  final bool busy;
  final VoidCallback onRun;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final paused = view.profile.state == PlainFolderProfileState.paused;
    return BackupCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: [
              AdaptiveStatusBadge(label: status.label, tone: status.tone),
              AdaptiveStatusBadge(
                label: directionLabel(context, view.profile.direction),
                tone: AppTone.brand,
                icon: CupertinoIcons.arrow_left_right,
              ),
            ],
          ),
          if (status.detail != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              status.detail!,
              style: AppType.rowSubtitle.copyWith(
                color: context.appSecondaryLabel,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: BackupActionButton(
                  key: const Key('plain-detail-run'),
                  label: busy
                      ? syncText(context, '正在同步…', 'Syncing…')
                      : paused
                      ? syncText(context, '继续同步', 'Resume sync')
                      : (status.actionLabel ??
                            syncText(context, '立即同步', 'Sync now')),
                  busy: busy,
                  onPressed: busy ? null : (paused ? onTogglePause : onRun),
                ),
              ),
              if (!paused) ...[
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: BackupActionButton(
                    key: const Key('plain-detail-pause'),
                    label: syncText(context, '暂停同步', 'Pause sync'),
                    secondary: true,
                    onPressed: busy ? null : onTogglePause,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Trailing text action used by the folder rows (打开 / 更改).
class _FolderAction extends StatelessWidget {
  const _FolderAction({
    required this.widgetKey,
    required this.label,
    required this.onTap,
  });

  final Key widgetKey;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: widgetKey,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxs,
        vertical: AppSpacing.xs,
      ),
      child: Text(
        label,
        style: AppType.footnote.copyWith(
          color: onTap == null
              ? context.appPrimary.withValues(alpha: AppOpacity.disabled)
              : context.appPrimary,
        ),
      ),
    ),
  );
}

/// What to do with an unsaved direction/conflict draft when leaving the page.
enum _LeaveChoice { save, discard, cancel }
