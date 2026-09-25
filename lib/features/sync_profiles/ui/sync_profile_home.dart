/// Sync-profiles home page: profile list, Velock connection banner, and
/// per-profile quick actions.
library;

import 'package:velock_sync/l10n/sync_locale.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'sync_profile_workspace_shared.dart';
import 'sync_profile_providers.dart';

class SyncProfilesHome extends ConsumerStatefulWidget {
  const SyncProfilesHome({super.key});

  @override
  ConsumerState<SyncProfilesHome> createState() => _SyncProfilesHomeState();
}

class _SyncProfilesHomeState extends ConsumerState<SyncProfilesHome> {
  late Future<_SyncProfilesLoadResult> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = _load();
  }

  Future<_SyncProfilesLoadResult> _load() async {
    final profiles = await ref
        .read(syncProfileRepositoryProvider)
        .listSummaries();
    final hasVelockProfile = profiles.any(
      (profile) => profile.kind == SyncDatasetKind.velockManaged,
    );
    if (!hasVelockProfile) {
      return _SyncProfilesLoadResult(profiles: profiles);
    }
    final velockProfile = profiles.firstWhere(
      (profile) => profile.kind == SyncDatasetKind.velockManaged,
    );
    final readiness = await ref
        .read(velockWizardReadinessServiceProvider)
        .inspect(syncAppInstanceId: velockProfile.deviceId)
        .timeout(
          const Duration(seconds: 1),
          onTimeout: () => const VelockWizardReadiness(
            VelockWizardAvailability.temporarilyUnavailable,
          ),
        );
    if (readiness.availability == VelockWizardAvailability.accessRevoked) {
      await ref
          .read(syncProfileRepositoryProvider)
          .setState(velockProfile.profileId, SyncProfileState.accessRequired);
    }
    return _SyncProfilesLoadResult(
      profiles: profiles,
      velockAvailability: readiness.availability,
    );
  }

  void _refresh() => setState(() {
    _profiles = _load();
  });

  Future<void> _refreshAndWait() async {
    final profiles = _load();
    setState(() {
      _profiles = profiles;
    });
    await profiles;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(profilesRevisionProvider, (previous, next) {
      if (previous != next) _refresh();
    });
    void createProfile() => context.push(AppRoutes.syncProfilesNew.path);
    return FutureBuilder<_SyncProfilesLoadResult>(
      future: _profiles,
      builder: (context, snapshot) => AdaptiveSliverScaffold(
        title: syncText(context, '备份与同步', "Backup & Sync"),
        actions: [
          if (isApplePlatform(context))
            Semantics(
              button: true,
              label: syncText(context, '新建同步', "New sync"),
              child: AdaptiveIconButton(
                key: const Key('sync-profile-create'),
                tooltip: syncText(context, '新建同步', "New sync"),
                onPressed: createProfile,
                icon: const Icon(CupertinoIcons.add),
              ),
            ),
          AdaptiveIconButton(
            tooltip: syncText(context, '刷新同步配置', "Refresh sync profiles"),
            onPressed: _refreshAndWait,
            icon: Icon(
              adaptiveIcon(
                context,
                material: Icons.refresh_rounded,
                cupertino: CupertinoIcons.refresh,
              ),
            ),
          ),
        ],
        floatingActionButton: isApplePlatform(context)
            ? null
            : FloatingActionButton.extended(
                key: const Key('sync-profile-create'),
                tooltip: syncText(context, '新建同步', "New sync"),
                onPressed: createProfile,
                icon: const Icon(Icons.add_rounded),
                label: Text(syncText(context, '新建同步', "New sync")),
              ),
        slivers: _profileSlivers(context, snapshot, onCreate: createProfile),
      ),
    );
  }

  List<Widget> _profileSlivers(
    BuildContext context,
    AsyncSnapshot<_SyncProfilesLoadResult> snapshot, {
    required VoidCallback onCreate,
  }) {
    if (snapshot.connectionState != ConnectionState.done) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(
            label: syncText(
              context,
              '正在加载备份与同步配置',
              "Loading backup and sync profiles",
            ),
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
              '无法读取备份与同步配置。',
              "Could not load backup and sync profiles.",
            ),
            onRetry: _refresh,
          ),
        ),
      ];
    }

    final loaded = snapshot.requireData;
    final profiles = loaded.profiles;
    final velockProfiles = profiles
        .where((profile) => profile.kind == SyncDatasetKind.velockManaged)
        .toList(growable: false);
    final folderProfiles = profiles
        .where((profile) => profile.kind == SyncDatasetKind.selectedFolder)
        .toList(growable: false);
    final unavailableProfiles = profiles
        .where((profile) => profile.kind == null)
        .toList(growable: false);
    final velockIssue =
        loaded.velockAvailability != null &&
        loaded.velockAvailability != VelockWizardAvailability.ready &&
        velockProfiles.isNotEmpty;
    final velockStatus = _velockDomainStatus(
      profiles: velockProfiles,
      velockAvailability: loaded.velockAvailability,
      context: context,
    );

    return [
      if (velockIssue)
        SliverToBoxAdapter(
          child: VelockConnectionBanner(
            availability: loaded.velockAvailability!,
            onRetry: _refresh,
          ),
        ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '格间', "Velock"),
          // The disconnection banner right above already carries the next step,
          // so the header only states the condition it summarises.
          headerDetail: velockIssue || velockStatus.detail == null
              ? null
              : _SectionStatusDetail(
                  message: velockStatus.detail!,
                  tone: velockStatus.tone,
                ),
          // The intro belongs to the moment before anything exists; once a
          // profile is listed it only repeats itself.
          footer: velockProfiles.isEmpty
              ? Text(
                  syncText(
                    context,
                    '零知识备份：只搬运格间已加密的数据，恢复由格间本体处理。',
                    "Zero-knowledge backup: only encrypted Velock data is transferred. Recovery is handled by Velock.",
                  ),
                )
              : null,
          emptyContent: Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const Key('velock-backup-enable'),
              icon: adaptiveIcon(
                context,
                material: Icons.add_rounded,
                cupertino: CupertinoIcons.add,
              ),
              label: syncText(context, '开启格间备份', "Enable Velock backup"),
              onPressed: () =>
                  context.pushNamed(AppRoutes.velockDatasetWizard.name),
            ),
          ),
          children: [
            for (final profile in velockProfiles)
              _ProfileTile(
                summary: profile,
                onChanged: _refresh,
                velockAvailability: loaded.velockAvailability,
              ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '其他文件', "Other files"),
          emptyContent: Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const Key('selected-folder-create'),
              icon: adaptiveIcon(
                context,
                material: Icons.add_rounded,
                cupertino: CupertinoIcons.add,
              ),
              label: syncText(context, '新建文件夹同步', "New folder sync"),
              onPressed: () =>
                  context.pushNamed(AppRoutes.selectedFolderProfiles.name),
            ),
          ),
          children: [
            for (final profile in folderProfiles)
              _ProfileTile(summary: profile, onChanged: _refresh),
          ],
        ),
      ),
      if (unavailableProfiles.isNotEmpty)
        SliverToBoxAdapter(
          child: AdaptiveListSection(
            header: syncText(context, '无法读取的配置', "Unreadable profiles"),
            children: [
              for (final profile in unavailableProfiles)
                _ProfileTile(summary: profile, onChanged: _refresh),
            ],
          ),
        ),
    ];
  }
}

class _SyncProfilesLoadResult {
  const _SyncProfilesLoadResult({
    required this.profiles,
    this.velockAvailability,
  });

  final List<SyncProfileSummary> profiles;
  final VelockWizardAvailability? velockAvailability;
}

/// line of context, and only speaks up when something needs attention.
class _DomainStatus {
  const _DomainStatus({required this.tone, this.detail});

  final AppTone tone;

  /// One sentence of context, or null when the section holds nothing but an
  /// entry to start the domain.
  final String? detail;
}

_DomainStatus _velockDomainStatus({
  required BuildContext context,
  required List<SyncProfileSummary> profiles,
  required VelockWizardAvailability? velockAvailability,
}) {
  if (profiles.isEmpty) {
    // The empty slot below already reads as "not set up yet", so the header
    // adds nothing here.
    return const _DomainStatus(tone: AppTone.neutral);
  }

  final velockUnavailable =
      velockAvailability != null &&
      velockAvailability != VelockWizardAvailability.ready;
  if (velockUnavailable) {
    return _DomainStatus(
      tone: AppTone.danger,
      detail: syncText(
        context,
        '请打开格间完成授权；恢复连接后备份会自动继续。',
        "Open Velock to authorize access. Backup resumes automatically when the connection is restored.",
      ),
    );
  }

  final attention = profiles.where(_velockProfileNeedsAttention).length;
  if (attention > 0) {
    return _DomainStatus(
      tone: AppTone.attention,
      detail: syncText(
        context,
        '格间已重置或授权已失效。请移除下方配置，再用「＋ → 备份格间数据」重新配对。',
        "Velock was reset or access expired. Remove the profile below, then use + → Back up Velock data to pair again.",
      ),
    );
  }

  // Nothing to report when the domain is healthy: the run itself carries its
  // timestamp, so the header stays text-free.
  return const _DomainStatus(tone: AppTone.ok);
}

bool _velockProfileNeedsAttention(SyncProfileSummary profile) =>
    profile.isIsolated ||
    profile.activity?.latestRun?.state == 'failed' ||
    profile.state == SyncProfileState.accessRequired ||
    profile.state == SyncProfileState.reauthorizationRequired ||
    profile.state == SyncProfileState.blockedByConfiguration ||
    profile.state == SyncProfileState.error;

/// One line of section-level context under a section header.
class _SectionStatusDetail extends StatelessWidget {
  const _SectionStatusDetail({required this.message, required this.tone});

  final String message;
  final AppTone tone;

  @override
  Widget build(BuildContext context) {
    final needsAction = tone == AppTone.attention || tone == AppTone.danger;
    return Text(
      message,
      style: AppType.rowSubtitle.copyWith(
        color: needsAction ? tone.color(context) : context.appSecondaryLabel,
      ),
    );
  }
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({
    required this.summary,
    required this.onChanged,
    this.velockAvailability,
  });

  final SyncProfileSummary summary;
  final VoidCallback onChanged;
  final VelockWizardAvailability? velockAvailability;

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
      velockAvailability: velockAvailability,
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
          final forceRunning =
              summary.kind == SyncDatasetKind.velockManaged &&
              velockAvailability != null &&
              velockAvailability != VelockWizardAvailability.ready;
          await ref
              .read(syncProfileRepositoryProvider)
              .remove(summary.profileId, forceRunning: forceRunning);
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
