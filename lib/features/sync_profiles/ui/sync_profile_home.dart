/// The two product domains have separate destinations; they never share a list.
library;

import 'dart:async';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_actions.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'sync_profile_workspace_shared.dart';
import 'sync_profile_providers.dart';

class SyncProfilesHome extends ConsumerStatefulWidget {
  const SyncProfilesHome({
    super.key,
    this.kind = SyncDatasetKind.velockManaged,
  });
  final SyncDatasetKind kind;
  @override
  ConsumerState<SyncProfilesHome> createState() => _SyncProfilesHomeState();
}

class _SyncProfilesHomeState extends ConsumerState<SyncProfilesHome>
    with WidgetsBindingObserver {
  late Future<_HomeData> _profiles;
  final Set<String> _running = {};
  bool get _isVelock => widget.kind == SyncDatasetKind.velockManaged;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profiles = _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _refresh();
  }

  Future<_HomeData> _load() async {
    final all = await ref.read(syncProfileRepositoryProvider).listSummaries();
    final profiles = all
        .where((p) => p.kind == widget.kind && !p.isIsolated)
        .toList();
    VelockWizardAvailability? availability;
    final snapshots = <String, SyncedDataSnapshot>{};
    if (_isVelock && profiles.isNotEmpty) {
      final ready = await ref
          .read(velockWizardReadinessServiceProvider)
          .inspect(syncAppInstanceId: profiles.first.deviceId)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => const VelockWizardReadiness(
              VelockWizardAvailability.temporarilyUnavailable,
            ),
          );
      availability = ready.availability;
      for (final p in profiles) {
        snapshots[p.profileId] = await ref
            .read(syncStateDatabaseProvider)
            .readSyncedDataSnapshot(p.profileId);
      }
    }
    return _HomeData(
      profiles,
      snapshots,
      availability,
      all.where((p) => p.isIsolated).toList(),
    );
  }

  void _refresh() {
    if (mounted) {
      setState(() {
        _profiles = _load();
      });
    }
  }

  Future<void> _refreshAndWait() async {
    final pending = _load();
    setState(() {
      _profiles = pending;
    });
    await pending;
  }

  Future<void> _open(String route) async {
    await context.push(route);
    if (mounted) _refresh();
  }

  Future<void> _action(
    SyncProfileSummary profile,
    BackupPresentation state,
  ) async {
    if (_running.contains(profile.profileId)) return;
    switch (state.action) {
      case BackupAction.openVelock:
        await openVelockForBackup(context, ref);
        return;
      case BackupAction.manage:
      case BackupAction.resolve:
        await _open('/sync-profiles/${profile.profileId}');
        return;
      case BackupAction.resume:
        setState(() => _running.add(profile.profileId));
        try {
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(profile.profileId, SyncProfileState.active);
          if (mounted) _refresh();
        } on Object {
          if (mounted) {
            showMessage(
              context,
              syncText(
                context,
                '暂时无法继续传输，请稍后重试。',
                'Could not resume transfer. Please try again.',
              ),
            );
          }
        } finally {
          if (mounted) setState(() => _running.remove(profile.profileId));
        }
        return;
      case BackupAction.transfer:
        setState(() => _running.add(profile.profileId));
        try {
          final result = await runSyncWithProgress(
            context,
            ref,
            profile.profileId,
          );
          if (mounted) await presentFirstSyncResult(context, result);
        } on Object catch (error) {
          if (mounted) {
            showMessage(
              context,
              backupFailureMessage(
                context,
                SyncFailureClassifier.classify(error).errorCode,
              ),
            );
          }
        } finally {
          if (mounted) {
            setState(() => _running.remove(profile.profileId));
            _refresh();
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(profilesRevisionProvider, (before, after) {
      if (before != after) _refresh();
    });
    return FutureBuilder<_HomeData>(
      future: _profiles,
      builder: (context, snapshot) => AdaptiveSliverScaffold(
        title: syncText(
          context,
          _isVelock ? '格间备份' : '文件同步',
          _isVelock ? 'Velock backup' : 'File sync',
        ),
        onRefresh: _refreshAndWait,
        actions: [
          AdaptiveIconButton(
            tooltip: syncText(context, '刷新状态', 'Refresh status'),
            onPressed: _refreshAndWait,
            icon: const Icon(CupertinoIcons.refresh),
          ),
        ],
        slivers: _slivers(snapshot),
      ),
    );
  }

  List<Widget> _slivers(AsyncSnapshot<_HomeData> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(
            label: syncText(context, '正在读取状态', 'Loading status'),
          ),
        ),
      ];
    }
    if (snapshot.hasError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveErrorState(
            message: syncText(
              context,
              '暂时无法读取状态，未改动你的数据。',
              'Could not load the status. Your data has not been changed.',
            ),
            onRetry: _refresh,
          ),
        ),
      ];
    }
    final data = snapshot.requireData;
    return [
      SliverToBoxAdapter(
        child: Column(
          children: [
            const SizedBox(height: 8),
            if (_isVelock) ...[
              if (data.profiles.isEmpty)
                BackupWelcomeCard(
                  onStart: () => _open(AppRoutes.velockDatasetWizard.path),
                ),
              for (final profile in data.profiles) ...[
                BackupStatusCard(
                  name: profile.displayName ?? 'Velock',
                  presentation: _presentation(profile, data),
                  onAction: () =>
                      _action(profile, _presentation(profile, data)),
                ),
                AdaptiveListSection(
                  children: [
                    AdaptiveListTile(
                      leading: const Icon(CupertinoIcons.slider_horizontal_3),
                      title: Text(
                        syncText(
                          context,
                          '备份详情与管理',
                          'Backup details and settings',
                        ),
                      ),
                      subtitle: Text(
                        syncText(
                          context,
                          '保存位置、需要处理的事项和详细记录',
                          'Cloud location, items needing attention and history',
                        ),
                      ),
                      showChevron: true,
                      onTap: () => _open('/sync-profiles/${profile.profileId}'),
                    ),
                  ],
                ),
              ],
              AdaptiveListSection(
                children: [
                  AdaptiveListTile(
                    widgetKey: const Key('velock-cloud-restore'),
                    leading: Icon(
                      CupertinoIcons.cloud_download,
                      color: context.appPrimary,
                    ),
                    title: Text(
                      syncText(context, '从云端恢复', 'Restore from cloud'),
                    ),
                    subtitle: Text(
                      syncText(
                        context,
                        '换手机、重装，或找回原来的数据',
                        'A new phone, a reinstall, or your existing data',
                      ),
                    ),
                    showChevron: true,
                    onTap: () => _open(AppRoutes.velockRecovery.path),
                  ),
                ],
              ),
            ] else ...[
              if (data.profiles.isEmpty)
                BackupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        CupertinoIcons.folder,
                        color: context.appPrimary,
                        size: 38,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        syncText(
                          context,
                          '同步你的文件夹',
                          'Keep your folders in sync',
                        ),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        syncText(
                          context,
                          '选择一个文件夹，在设备之间保持一致。它与格间备份相互独立。',
                          'Choose a folder to keep up to date across devices. This is separate from Velock backup.',
                        ),
                      ),
                      const SizedBox(height: 22),
                      BackupActionButton(
                        key: const Key('selected-folder-create'),
                        label: syncText(context, '添加文件夹', 'Add a folder'),
                        onPressed: () =>
                            _open(AppRoutes.selectedFolderProfiles.path),
                      ),
                    ],
                  ),
                ),
              if (data.profiles.isNotEmpty)
                AdaptiveListSection(
                  header: syncText(context, '我的文件夹', 'My folders'),
                  children: [
                    for (final profile in data.profiles)
                      _ProfileTile(summary: profile, onChanged: _refresh),
                    AdaptiveListTile(
                      widgetKey: const Key('selected-folder-create'),
                      leading: const Icon(CupertinoIcons.add),
                      title: Text(syncText(context, '添加文件夹', 'Add a folder')),
                      showChevron: true,
                      onTap: () => _open(AppRoutes.selectedFolderProfiles.path),
                    ),
                  ],
                ),
            ],
            if (data.isolated.isNotEmpty)
              AdaptiveListSection(
                header: syncText(
                  context,
                  '需要检查的旧连接',
                  'Existing connections needing attention',
                ),
                children: [
                  for (final profile in data.isolated)
                    _ProfileTile(summary: profile, onChanged: _refresh),
                ],
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ];
  }

  BackupPresentation _presentation(SyncProfileSummary p, _HomeData data) =>
      BackupPresentation.from(
        state: p.state,
        activity: p.activity,
        availability: data.availability,
        pendingIncoming: data.snapshots[p.profileId]?.pendingIncomingCount ?? 0,
        pendingOutgoing: data.snapshots[p.profileId]?.pendingOutgoingCount ?? 0,
        isolated: p.isIsolated,
        running: _running.contains(p.profileId),
      );
}

class _HomeData {
  const _HomeData(
    this.profiles,
    this.snapshots,
    this.availability,
    this.isolated,
  );
  final List<SyncProfileSummary> profiles;
  final Map<String, SyncedDataSnapshot> snapshots;
  final VelockWizardAvailability? availability;
  final List<SyncProfileSummary> isolated;
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.summary, required this.onChanged});

  final SyncProfileSummary summary;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title =
        summary.displayName ??
        syncText(context, '不可用的同步配置', "Unavailable sync profile");
    final presentation = profileStatusPresentation(
      context,
      kind: summary.kind,
      state: summary.state,
      isIsolated: summary.isIsolated,
      lastRunFailed: summary.activity?.latestRun?.state == 'failed',
      velockAvailability: null,
    );
    // When the pairing binding is gone the row already states the cause and
    // the next step, so the generic "sync unfinished" line is redundant.
    final failureSubtitle = summary.state == SyncProfileState.accessRequired
        ? null
        : summary.activity?.latestRun?.state == 'failed'
        ? latestRunFailureSubtitle(
            summary.activity?.latestRun,
            context: context,
          )
        : null;
    final baseSubtitle = summary.state == SyncProfileState.accessRequired
        ? syncText(
            context,
            '格间已重置或授权已失效，请移除本配置后重新配对。',
            "Velock was reset or access expired. Remove this profile and pair again.",
          )
        : presentation.detail ??
              profileSecondaryText(summary, context: context);
    final subtitleText = failureSubtitle == null
        ? baseSubtitle
        : '$baseSubtitle，$failureSubtitle';

    return Semantics(
      label: '$title，$subtitleText，${presentation.label}',
      child: AdaptiveListTile(
        leading: AdaptiveIconBadge(
          icon: adaptiveKindIcon(context, summary.kind),
          color: presentation.tone.color(context),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.rowTitleStrong,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    baseSubtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.rowSubtitle.copyWith(
                      color: context.appSecondaryLabel,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                AdaptiveStatusBadge(
                  label: presentation.label,
                  tone: presentation.tone,
                  icon: presentation.icon,
                ),
              ],
            ),
            if (failureSubtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                failureSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.rowSubtitle.copyWith(
                  color: presentation.tone.color(context),
                ),
              ),
            ],
          ],
        ),
        isThreeLine:
            failureSubtitle != null ||
            summary.state == SyncProfileState.accessRequired,
        enabled: !summary.isIsolated,
        onTap: () => context.push('/sync-profiles/${summary.profileId}'),
        trailing: AdaptiveActionMenu<_ProfileAction>(
          tooltip: syncText(context, '同步配置操作', "Sync profile actions"),
          onSelected: (action) => _runAction(context, ref, action),
          items: [
            if (summary.isRunnable && !summary.isIsolated)
              AdaptiveActionItem(
                value: _ProfileAction.syncNow,
                label: syncText(context, '立即同步', "Sync now"),
                icon: CupertinoIcons.arrow_2_circlepath,
              ),
            if (summary.state == SyncProfileState.active)
              AdaptiveActionItem(
                value: _ProfileAction.pause,
                label: syncText(context, '暂停', "Pause"),
                icon: CupertinoIcons.pause,
              ),
            if (summary.state == SyncProfileState.paused)
              AdaptiveActionItem(
                value: _ProfileAction.resume,
                label: syncText(context, '恢复', "Resume"),
                icon: CupertinoIcons.play,
              ),
            AdaptiveActionItem(
              value: _ProfileAction.remove,
              label: syncText(context, '删除同步配置', "Delete sync profile"),
              icon: CupertinoIcons.delete,
              isDestructive: true,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    _ProfileAction action,
  ) async {
    try {
      switch (action) {
        case _ProfileAction.syncNow:
          final result = await runSyncWithProgress(
            context,
            ref,
            summary.profileId,
          );
          if (!context.mounted || result == null) return;
          await presentSyncResult(context, result);
        case _ProfileAction.pause:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.paused);
        case _ProfileAction.resume:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.active);
        case _ProfileAction.remove:
          if (!await confirmSyncProfileRemoval(
            context,
            summary.displayName ??
                syncText(context, '不可用的同步配置', "Unavailable sync profile"),
          )) {
            return;
          }
          await ref
              .read(syncProfileRepositoryProvider)
              .remove(summary.profileId);
      }
      onChanged();
    } on SyncProfileRemovalWhileRunningException {
      if (context.mounted) {
        showMessage(
          context,
          syncText(
            context,
            '同步正在运行，暂时无法删除。',
            "Sync is running. The profile cannot be deleted yet.",
          ),
        );
      }
    } on Object {
      if (context.mounted) {
        showMessage(
          context,
          syncText(
            context,
            '操作未完成，请稍后重试。',
            "Could not complete the action. Please try again later.",
          ),
        );
      }
    }
  }
}

/// Label, tone and optional detail for a profile's status pill.
///
/// Label and colour always come from the same source, so a healthy profile can

enum _ProfileAction { syncNow, pause, resume, remove }
