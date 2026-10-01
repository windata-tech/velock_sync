import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_run.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart'
    show showPlatformMessage;

/// The 文件同步 tab: plain folder locations first, legacy encrypted profiles
/// kept visible but no longer offered for new locations.
class PlainSyncHome extends ConsumerStatefulWidget {
  const PlainSyncHome({super.key});

  @override
  ConsumerState<PlainSyncHome> createState() => _PlainSyncHomeState();
}

class _PlainSyncHomeState extends ConsumerState<PlainSyncHome> {
  bool _busy = false;

  /// The location whose run is in flight: only that card shows the spinner and
  /// the 「正在同步…」 label, while [_busy] keeps every other entry disabled.
  String? _runningProfileId;

  Future<void> _addLocation() async {
    // Which locations exist before the wizard, so the new one is identifiable
    // afterwards without changing the route's result type.
    final before = (ref.read(plainLocationViewsProvider).asData?.value ?? [])
        .map((view) => view.profile.profileId)
        .toSet();
    final created = await context.push<bool>(AppRoutes.addPlainLocation.path);
    if (created != true || !mounted) return;
    ref.invalidate(plainLocationViewsProvider);
    ref.read(profilesRevisionProvider.notifier).bump();

    // The wizard's promise is that the two folders start matching. Run the new
    // location's first sync straight away (its own card shows the progress)
    // instead of leaving the user to find it and tap again.
    final views = await ref.read(plainLocationViewsProvider.future);
    if (!mounted) return;
    final fresh = views
        .where((view) => !before.contains(view.profile.profileId))
        .toList(growable: false);
    if (fresh.length != 1) return;
    final view = fresh.single;
    if (view.profile.state != PlainFolderProfileState.active) return;
    await _run(view);
  }

  Future<void> _openDetail(String profileId) async {
    await context.push('/plain-locations/$profileId');
    if (mounted) ref.invalidate(plainLocationViewsProvider);
  }

  /// Runs one location, including the confirmed deletion pass.
  ///
  /// The deletion pass happens INSIDE this busy window on purpose: the previous
  /// version re-entered [_run] while `_busy` was still true, so confirming
  /// 「确认删除并继续」 silently did nothing and the next tap applied the
  /// deletions with no review at all.
  ///
  /// `allowDeletions` is never passed in by callers any more: deletions are
  /// only ever applied right after the review sheet, so a plan the user has not
  /// seen can never be executed.
  Future<void> _run(PlainLocationView view) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _runningProfileId = view.profile.profileId;
    });
    try {
      await runPlainLocation(context, ref, view);
      if (!mounted) return;
      ref.invalidate(plainLocationViewsProvider);
      ref.read(profilesRevisionProvider.notifier).bump();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _runningProfileId = null;
        });
      }
    }
  }

  Future<void> _setPaused(PlainLocationView view, bool paused) async {
    try {
      final repository = ref.read(plainFolderProfilesProvider);
      if (paused) {
        await repository.pause(view.profile.profileId);
      } else {
        await repository.resume(view.profile.profileId);
      }
      if (!mounted) return;
      ref.invalidate(plainLocationViewsProvider);
      ref.read(profilesRevisionProvider.notifier).bump();
    } on Object catch (error, stackTrace) {
      loge('Plain folder state update failed: $error', stackTrace: stackTrace);
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(plainLocationViewsProvider);
    return AdaptiveSliverScaffold(
      title: syncText(context, '文件同步', 'File sync'),
      onRefresh: () async {
        ref.invalidate(plainLocationViewsProvider);
        await ref.read(plainLocationViewsProvider.future);
      },
      actions: [
        // One "+" in the header replaces the full-width "add location" row that
        // used to sit under the list.
        AdaptiveIconButton(
          key: const Key('plain-location-add'),
          tooltip: syncText(context, '添加同步位置', 'Add a sync location'),
          onPressed: _busy ? null : _addLocation,
          icon: const Icon(CupertinoIcons.add),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xs),
              _intro(context),
              ..._locationSlivers(context, locations),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ],
    );
  }

  Widget _intro(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.page,
      AppSpacing.xs,
      AppSpacing.page,
      AppSpacing.sm,
    ),
    child: Text(
      syncText(
        context,
        '每个同步位置把本机的一个文件夹和远端的一个文件夹绑定在一起，可以添加多个。远端保存的是普通文件，没有加密，NAS 或其他程序都能直接打开。',
        'Each sync location binds one folder on this device to one folder on your remote storage, and you can add as many as you need. The remote folder holds ordinary, unencrypted files that any NAS or other program can open.',
      ),
      style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
    ),
  );

  List<Widget> _locationSlivers(
    BuildContext context,
    AsyncValue<List<PlainLocationView>> locations,
  ) {
    if (locations.isLoading && !locations.hasValue) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: AdaptiveLoadingState(
            label: syncText(context, '正在读取同步位置', 'Loading sync locations'),
          ),
        ),
      ];
    }
    if (locations.hasError) {
      return [
        AdaptiveErrorState(
          message: syncText(
            context,
            '暂时无法读取同步位置，未改动你的文件。',
            'Could not load your sync locations. Your files were not changed.',
          ),
          onRetry: () => ref.invalidate(plainLocationViewsProvider),
        ),
      ];
    }
    final views = locations.requireValue;
    if (views.isEmpty) {
      return [
        BackupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                CupertinoIcons.folder_badge_plus,
                color: context.appPrimary,
                size: 34,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                syncText(context, '添加第一个同步位置', 'Add your first location'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                syncText(
                  context,
                  '选择本机文件夹，再选择远端文件夹，两边就会保持一致。',
                  'Pick a folder on this device, then a folder on your remote storage, and the two stay in step.',
                ),
                style: TextStyle(color: context.appSecondaryLabel),
              ),
              const SizedBox(height: AppSpacing.md),
              BackupActionButton(
                key: const Key('plain-location-create'),
                label: syncText(context, '添加同步位置', 'Add a location'),
                onPressed: _addLocation,
              ),
            ],
          ),
        ),
      ];
    }
    return [
      for (final view in views) ...[
        _LocationCard(
          view: view,
          busy: _runningProfileId == view.profile.profileId,
          // Re-entry is blocked for every card while any run is in flight.
          blocked: _busy,
          onOpen: () => _openDetail(view.profile.profileId),
          // Always through the review flow: a location with held deletions
          // re-plans and asks again, listing the paths, instead of deleting
          // whatever the new plan happens to contain.
          onPrimaryAction: () => _run(view),
          onTogglePause: () => _setPaused(
            view,
            view.profile.state != PlainFolderProfileState.paused,
          ),
        ),
      ],
    ];
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.view,
    required this.busy,
    this.blocked = false,
    required this.onOpen,
    required this.onPrimaryAction,
    required this.onTogglePause,
  });

  final PlainLocationView view;

  /// This location is the one transferring right now.
  final bool busy;

  /// Another location is transferring, so this card stays disabled but must not
  /// claim to be the one running.
  final bool blocked;
  final VoidCallback onOpen;
  final VoidCallback onPrimaryAction;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final status = plainLocationStatus(context, view);
    final paused = view.profile.state == PlainFolderProfileState.paused;
    // BackupCard already carries the page's 16pt horizontal margin; adding
    // another inset here made the card surface narrower than the text above it.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: BackupCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    view.profile.displayName,
                    style: AppType.rowTitleStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                AdaptiveStatusBadge(
                  label: directionLabel(context, view.profile.direction),
                  tone: AppTone.brand,
                  icon: CupertinoIcons.arrow_left_right,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _PathRow(
              icon: CupertinoIcons.device_phone_portrait,
              label: syncText(context, '本机', 'This device'),
              value: view.profile.localDisplayName,
            ),
            const SizedBox(height: 2),
            _PathRow(
              icon: CupertinoIcons.cloud,
              label: syncText(context, '远端', 'Remote'),
              value: view.connection == null
                  ? syncText(context, '远端连接已删除', 'Remote connection deleted')
                  : '${view.connectionName}${view.remotePath}',
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xxs,
              children: [
                AdaptiveStatusBadge(label: status.label, tone: status.tone),
                if (view.hasConflicts)
                  AdaptiveStatusBadge(
                    label: syncText(
                      context,
                      '冲突 ${view.conflictCount}',
                      '${view.conflictCount} conflicts',
                    ),
                    tone: AppTone.attention,
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
            if (view.hasSyncedBefore && !view.didFail) ...[
              const SizedBox(height: 2),
              Text(
                plainRunSummary(context, view.stats),
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: BackupActionButton(
                    key: Key('plain-location-run-${view.profile.profileId}'),
                    label: busy
                        ? syncText(context, '正在同步…', 'Syncing…')
                        : paused
                        ? syncText(context, '继续', 'Resume')
                        : (status.actionLabel ??
                              syncText(context, '立即同步', 'Sync now')),
                    busy: busy,
                    onPressed: busy || blocked
                        ? null
                        : (paused ? onTogglePause : onPrimaryAction),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: BackupActionButton(
                    key: Key('plain-location-open-${view.profile.profileId}'),
                    label: syncText(context, '详情', 'Details'),
                    secondary: true,
                    onPressed: onOpen,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 15, color: context.appSecondaryLabel),
      const SizedBox(width: AppSpacing.xs),
      SizedBox(
        width: 34,
        child: Text(
          label,
          style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: AppType.rowSubtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}
