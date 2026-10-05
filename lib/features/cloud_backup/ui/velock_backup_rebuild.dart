import 'package:crypto/crypto.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_backup_rebuild_service.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_snapshot_providers.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_transfer_progress.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_backup_location.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_format.dart';

/// Opens the new-backup flow for [profile]. With [destination] the folder is
/// already chosen and the flow goes straight to confirming it.
Future<void> showVelockBackupRebuild(
  BuildContext context,
  WidgetRef ref,
  SyncProfileEnvelope profile, {
  List<String>? destination,
}) async {
  final connection = await ref
      .read(connectionRepositoryProvider)
      .getConnectionById(profile.connectionId);
  if (connection == null || !context.mounted) return;
  Widget page(BuildContext _) => VelockBackupRebuildPage(
    profile: profile,
    connection: connection,
    initialDestination: destination,
  );
  await Navigator.of(context).push<void>(
    isApplePlatform(context)
        ? CupertinoPageRoute(builder: page)
        : MaterialPageRoute(builder: page),
  );
}

class VelockBackupRebuildPage extends ConsumerStatefulWidget {
  const VelockBackupRebuildPage({
    super.key,
    required this.profile,
    required this.connection,
    this.initialDestination,
  });
  final SyncProfileEnvelope profile;
  final ConnectionModel connection;

  /// A folder the user already picked (for example while changing the
  /// backup location); skips the folder picker.
  final List<String>? initialDestination;
  @override
  ConsumerState<VelockBackupRebuildPage> createState() =>
      _VelockBackupRebuildPageState();
}

class _VelockBackupRebuildPageState
    extends ConsumerState<VelockBackupRebuildPage>
    with WidgetsBindingObserver {
  VelockBackupRebuildJob? job;
  bool busy = false, ready = false, complete = false;
  int done = 0, total = 0, generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreDraft();
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Velock after confirming: continue by itself instead of
    // making the user press "check" and then "upload".
    if (state == AppLifecycleState.resumed && !busy && !complete) {
      _refresh(continueWhenReady: true);
    }
  }

  Future<VelockBackupRebuildService> get service =>
      ref.read(velockBackupRebuildServiceProvider.future);
  Future<void> _restoreDraft() async {
    final epoch = ++generation;
    setState(() => busy = true);
    try {
      final stored = await (await service).jobs.read(widget.profile.profileId);
      if (mounted &&
          generation == epoch &&
          stored != null &&
          sha256.convert(snapshotJson(stored.original.toJson())) ==
              sha256.convert(snapshotJson(widget.profile.toJson()))) {
        setState(() => job = stored);
      }
    } catch (_) {
      /* A draft is optional; no request or profile can be inferred from a bad file. */
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
    if (mounted && generation == epoch && job != null) {
      await _refresh();
    } else {
      final destination = widget.initialDestination;
      if (mounted && generation == epoch && destination != null) {
        await _startAt(destination);
      }
    }
  }

  Future<void> _failure() async {
    if (!mounted) return;
    await showAdaptiveNotice(
      context: context,
      title: syncText(context, '新备份尚未完成', 'New backup has not finished'),
      message: syncText(
        context,
        '原备份位置未改变。请确认新文件夹为空、连接可用，并在格间解锁确认后重试。已上传的内容会在重试时校验后继续，不会删除原备份。',
        'The original backup location has not changed. Check that the new folder is empty, the connection is available, and Velock is unlocked and approved. A retry verifies and resumes uploaded content without deleting the original backup.',
      ),
      confirmLabel: syncText(context, '知道了', 'OK'),
    );
  }

  /// Without this the page had no way out: every failure brought the same
  /// pending job back, even when its folder was gone or not writable.
  Future<void> _discard() async {
    final pending = job;
    if (busy || pending == null || complete) return;
    final epoch = ++generation;
    setState(() => busy = true);
    try {
      await (await service).jobs.discard(pending.original.profileId);
      if (mounted && epoch == generation) {
        setState(() {
          job = null;
          ready = false;
          done = 0;
          total = 0;
        });
      }
    } catch (_) {
      await _failure();
    } finally {
      if (mounted && epoch == generation) setState(() => busy = false);
    }
  }

  Future<void> _refresh({bool continueWhenReady = false}) async {
    final pending = job;
    if (busy || pending == null || complete) return;
    final epoch = ++generation;
    setState(() => busy = true);
    var available = false;
    try {
      available = await (await service).isReady(pending);
      if (mounted && epoch == generation) setState(() => ready = available);
    } catch (_) {
      await _failure();
    } finally {
      if (mounted && epoch == generation) setState(() => busy = false);
    }
    if (continueWhenReady && available && mounted && epoch == generation) {
      await _upload();
    }
  }

  Future<void> _choose() async {
    if (busy) return;
    final protocol = widget.connection.protocol;
    if (protocol is! WebDavProtocolModel) {
      await showAdaptiveNotice(
        context: context,
        title: syncText(
          context,
          '此保存位置暂不支持建立新备份',
          'New backups are not supported here yet',
        ),
        message: syncText(
          context,
          '目前建立新备份支持 WebDAV 文件夹。你仍可以查找原来的完整备份；此操作不会更改现有保存位置。',
          'Creating a new backup currently supports WebDAV folders. You can still locate the original complete backup. Your saved location has not changed.',
        ),
        confirmLabel: syncText(context, '知道了', 'OK'),
      );
      return;
    }
    setState(() => busy = true);
    try {
      final loader = ref.read(backupFolderLoaderProvider);
      final selected = await Navigator.of(context).push<List<String>>(
        isApplePlatform(context)
            ? CupertinoPageRoute(builder: (_) => _picker(protocol, loader))
            : MaterialPageRoute(builder: (_) => _picker(protocol, loader)),
      );
      if (selected == null || !mounted) return;
      setState(() => busy = false);
      await _startAt(selected);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Confirms [selected] as the new backup folder and asks Velock to build
  /// the complete backup for it.
  Future<void> _startAt(List<String> selected) async {
    if (busy) return;
    var notEmpty = false;
    setState(() => busy = true);
    try {
      final label =
          '${widget.connection.name}\n${backupPathFor(widget.connection, selected) ?? selected.join('/')}';
      final confirmed = await showAdaptiveConfirmation(
        context,
        title: syncText(context, '在这里建立新备份？', 'Create a new backup here?'),
        message:
            '$label\n\n${syncText(context, '仅备份格间当前本机可读取的内容。已丢失、只存在于原云端的数据无法找回。完成校验前不会切换保存位置，也不会删除原备份。', 'Only content currently readable in Velock on this device will be backed up. Lost cloud-only data cannot be recovered. The saved location changes only after verification; the original backup is not deleted.')}',
        confirmLabel: syncText(context, '前往格间确认', 'Confirm in Velock'),
        confirmKey: const Key('backup-rebuild-confirm'),
      );
      if (!confirmed || !mounted) return;
      final api = await service;
      // The display label uses one line because the signed request rejects control characters.
      final created = await api.start(
        expected: widget.profile,
        destination: selected,
        destinationLabel: label.replaceAll('\n', ' · '),
      );
      if (!mounted) return;
      setState(() {
        job = created;
        ready = false;
      });
      await api.open(created);
    } on StateError catch (error) {
      if (error.message.contains('not empty') ||
          error.message.contains('new empty')) {
        // A folder with other content (or the current one) cannot take a
        // fresh backup; offer the fix, not an "OK".
        notEmpty = true;
      } else {
        await _failure();
      }
    } catch (_) {
      await _failure();
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (notEmpty && mounted) {
      final choose = await showAdaptiveConfirmation(
        context,
        title: syncText(
          context,
          '这个文件夹不能放新备份',
          'This folder cannot hold the new backup',
        ),
        message: syncText(
          context,
          '新备份要放在一个空文件夹里，而且不能是现在的保存位置。请选一个空文件夹，或在里面新建一个。',
          'A new backup needs an empty folder other than the current location. Choose an empty folder or create one.',
        ),
        confirmLabel: syncText(context, '换一个文件夹', 'Choose another folder'),
        confirmKey: const Key('backup-rebuild-choose-again'),
        cancelLabel: syncText(context, '稍后', 'Later'),
      );
      if (choose && mounted) await _choose();
    }
  }

  Widget _picker(WebDavProtocolModel protocol, BackupFolderLoader loader) =>
      BackupFolderPicker(
        connectionName: widget.connection.name,
        basePath:
            backupPathFor(widget.connection, const []) ??
            widget.connection.target,
        initialSegments: VelockSyncProfile.fromEnvelope(
          widget.profile,
        ).remoteRootSegments,
        restoring: false,
        loadFolders: (segments) =>
            loader(protocol: protocol, relativeSegments: segments),
        createFolder: (segments, name) => ref.read(backupFolderCreatorProvider)(
          protocol: protocol,
          relativeSegments: segments,
          name: name,
        ),
      );
  Future<void> _open() async {
    final pending = job;
    if (busy || pending == null) return;
    setState(() => busy = true);
    try {
      final api = await service;
      var current = pending;
      if (!DateTime.now().toUtc().isBefore(pending.request.expiresAt)) {
        current = await api.start(
          expected: widget.profile,
          destination: pending.destination,
          destinationLabel: pending.request.destinationLabel,
        );
        if (!mounted) return;
        setState(() => job = current);
      }
      await api.open(current);
    } catch (_) {
      await _failure();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _upload() async {
    final pending = job;
    if (busy || pending == null || !ready) return;
    setState(() => busy = true);
    var switched = false;
    var failed = false;
    try {
      final api = await service;
      await api.finish(
        pending,
        onProgress: (completed, count) {
          if (mounted) {
            setState(() {
              done = completed;
              total = count;
            });
          }
        },
      );
      switched = true;
      ref.read(profilesRevisionProvider.notifier).bump();
      if (!mounted) return;
      setState(() => complete = true);
      // The verified snapshot and location switch have their own durable
      // completion record. Later edits are handled by the next normal backup;
      // do not immediately reread the snapshot in a second, incremental run.
    } catch (_) {
      failed = !switched;
    } finally {
      if (mounted) setState(() => busy = false);
    }
    // Uploaded objects are verified and kept, so a retry continues where
    // this one stopped: offer exactly that.
    if (failed && mounted) {
      final retry = await showAdaptiveConfirmation(
        context,
        title: syncText(context, '新备份尚未完成', 'New backup has not finished'),
        message: syncText(
          context,
          '原备份位置未改变，已上传的部分会保留。网络或连接恢复后点重试，会从中断的地方继续。',
          'The original backup location has not changed and what was uploaded is kept. Once the network or connection is back, retry to continue where it stopped.',
        ),
        confirmLabel: syncText(context, '重试', 'Try again'),
        confirmKey: const Key('backup-rebuild-retry'),
        cancelLabel: syncText(context, '稍后', 'Later'),
      );
      if (retry && mounted) await _upload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = job;
    return PopScope(
      canPop: !busy,
      child: AdaptiveScaffold(
        title: syncText(context, '建立新备份', 'Create a new backup'),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            BackupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    syncText(
                      context,
                      complete
                          ? '已切换到新备份位置'
                          : pending == null
                          ? '原备份丢失后，仍可重新备份'
                          : ready
                          ? '格间已准备好备份内容'
                          : '请在格间确认备份内容',
                      complete
                          ? 'New backup location is active'
                          : pending == null
                          ? 'Create a backup when the original is lost'
                          : ready
                          ? 'Velock has prepared your backup'
                          : 'Confirm the backup in Velock',
                    ),
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    syncText(
                      context,
                      complete
                          ? '本次完整备份已上传并通过校验。准备备份之后新增或修改的内容，会在下一次备份时处理。'
                          : pending == null
                          ? '选择一个新的空文件夹，再前往格间确认。新备份包含本机当前可读取的内容，不会删除原备份；无法找回只存在于已丢失云端的数据。'
                          : ready
                          ? '返回后继续上传。所有内容上传并回读校验通过后，才切换到新位置。'
                          : '格间会生成当前本机内容的完整备份。准备好后，请返回这里继续上传。',
                      complete
                          ? 'This full backup has been uploaded and verified. Content added or changed after preparation will be handled by the next backup.'
                          : pending == null
                          ? 'Choose a new empty folder, then confirm in Velock. The new backup includes content currently readable on this device and does not delete the original. Lost cloud-only data cannot be recovered.'
                          : ready
                          ? 'Continue uploading here. The location changes only after all content has been uploaded and read back for verification.'
                          : 'Velock will prepare a full backup of the content on this device. Return here when it is ready to upload.',
                    ),
                  ),
                  if (pending != null) ...[
                    const SizedBox(height: 16),
                    Text(pending.request.destinationLabel),
                  ],
                  if (total > 0 && !complete) ...[
                    const SizedBox(height: 16),
                    BackupProgressBar(
                      fraction: (done / total).clamp(0, 1).toDouble(),
                      detail: syncText(
                        context,
                        '已上传 ${AppFormat.bytes(done)} / ${AppFormat.bytes(total)} · ${(done / total * 100).clamp(0, 100).floor()}%',
                        '${AppFormat.bytes(done)} of ${AppFormat.bytes(total)} uploaded · ${(done / total * 100).clamp(0, 100).floor()}%',
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  BackupActionButton(
                    key: const Key('backup-rebuild-primary'),
                    busy: busy,
                    label: syncText(
                      context,
                      complete
                          ? '返回备份'
                          : pending == null
                          ? '选择新文件夹'
                          : ready
                          ? '上传新备份'
                          : '前往格间确认',
                      complete
                          ? 'Back to backup'
                          : pending == null
                          ? 'Choose a new folder'
                          : ready
                          ? 'Upload new backup'
                          : 'Confirm in Velock',
                    ),
                    onPressed: busy
                        ? null
                        : complete
                        ? _returnToBackup
                        : pending == null
                        ? _choose
                        : ready
                        ? _upload
                        : _open,
                  ),
                  if (pending != null && !complete) ...[
                    const SizedBox(height: 12),
                    BackupActionButton(
                      key: const Key('backup-rebuild-refresh'),
                      secondary: true,
                      label: syncText(
                        context,
                        '我已确认，检查准备结果',
                        'Check preparation result',
                      ),
                      onPressed: busy ? null : _refresh,
                    ),
                    const SizedBox(height: 12),
                    BackupActionButton(
                      key: const Key('backup-rebuild-discard'),
                      secondary: true,
                      label: syncText(
                        context,
                        '放弃这次，换个文件夹',
                        'Cancel and choose another folder',
                      ),
                      onPressed: busy ? null : _discard,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _returnToBackup() {
    final router = GoRouter.of(context);
    // Help and rebuild are imperative routes above a preserved shell branch.
    // Going to '/' alone leaves them visible when that branch is already home.
    Navigator.of(context).popUntil((route) => route.isFirst);
    router.go('/');
  }
}
