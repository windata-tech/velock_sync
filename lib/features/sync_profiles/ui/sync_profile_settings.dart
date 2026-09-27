/// Global sync settings page (background policy, limits, cellular,
/// and synced-data sections).
library;

import 'dart:async';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/l10n/sync_language_setting.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'sync_profile_workspace_shared.dart';
import 'sync_profile_providers.dart';

class SyncSettings extends ConsumerStatefulWidget {
  const SyncSettings({super.key});

  @override
  ConsumerState<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends ConsumerState<SyncSettings> {
  late Future<SyncSettingsSnapshot> _snapshot;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _snapshot = ref.read(syncSettingsServiceProvider).load();
  }

  void _reload() {
    setState(() {
      _snapshot = ref.read(syncSettingsServiceProvider).load();
    });
  }

  Future<void> _save(SyncGlobalSettings settings) async {
    setState(() {
      _busy = true;
      _snapshot = ref.read(syncSettingsServiceProvider).save(settings);
    });
    try {
      await _snapshot;
    } on Object {
      if (mounted) {
        showMessage(
          context,
          syncText(
            context,
            '无法保存全局同步设置。',
            'Could not save the global sync settings.',
          ),
        );
        _reload();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cleanupStaging() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(syncSettingsServiceProvider)
          .cleanupStaging();
      if (!mounted) return;
      final runningNote = result.busyProfileCount == 0
          ? syncText(context, '。', '.')
          : syncText(
              context,
              '，${result.busyProfileCount} 个运行中配置未清理。',
              '; ${result.busyProfileCount} profiles that were syncing were left alone.',
            );
      showMessage(
        context,
        '${syncText(context, '已释放', 'Freed')} '
        '${AppFormat.bytes(result.freedBytes)}'
        '${syncText(context, '；保留', '; kept')} '
        '${result.preservedRecoverableBatchCount} '
        '${syncText(context, '个可恢复批次', 'recoverable batches')}$runningNote',
      );
      _reload();
    } on Object {
      if (mounted) {
        showMessage(
          context,
          syncText(
            context,
            '暂存空间清理未完成，请稍后重试。',
            'Staging cleanup did not finish. Try again later.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showDiagnostics() async {
    setState(() => _busy = true);
    try {
      final diagnostics = await ref
          .read(syncSettingsServiceProvider)
          .exportSanitizedDiagnostics();
      if (!mounted) return;
      final choice = await showAdaptiveAlert<String>(
        context: context,
        title: syncText(context, '脱敏诊断', 'Sanitized diagnostics'),
        details: SizedBox(
          height: 320,
          child: SingleChildScrollView(
            child: SelectionArea(
              child: Text(
                diagnostics,
                key: const Key('sanitized-diagnostics-content'),
              ),
            ),
          ),
        ),
        actions: [
          AdaptiveAlertAction<String>(
            label: syncText(context, '复制', 'Copy'),
            value: 'copy',
            key: const Key('copy-sanitized-diagnostics'),
          ),
          AdaptiveAlertAction<String>(
            label: syncText(context, '完成', 'Done'),
            value: 'done',
            isDefault: true,
            emphasized: true,
          ),
        ],
      );
      if (choice == 'copy') {
        await Clipboard.setData(ClipboardData(text: diagnostics));
      }
    } on Object {
      if (mounted) {
        showMessage(
          context,
          syncText(
            context,
            '无法生成脱敏诊断。',
            'Could not create the sanitized diagnostics.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseCellularLimit(SyncGlobalSettings settings) async {
    final selected = await showAdaptiveActionSheet<int>(
      context: context,
      title: syncText(context, '默认蜂窝网络传输上限', 'Default cellular transfer limit'),
      message: syncText(
        context,
        '加密内容按单个传输对象限制。',
        'Encrypted data is limited per transferred item.',
      ),
      actions: [
        for (final bytes in const [
          10 * 1024 * 1024,
          50 * 1024 * 1024,
          100 * 1024 * 1024,
        ])
          AdaptiveAction<int>(label: AppFormat.bytes(bytes), value: bytes),
      ],
    );
    if (selected != null && mounted) {
      await _save(settings.copyWith(defaultCellularMaxTransferBytes: selected));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SyncSettingsSnapshot>(
    future: _snapshot,
    builder: (context, snapshot) => AdaptiveSliverScaffold(
      title: syncText(context, '设置', 'Settings'),
      slivers: [
        SliverToBoxAdapter(
          child: AdaptiveListSection(
            children: [
              AdaptiveListTile(
                widgetKey: const Key('manage-cloud-locations'),
                leading: const Icon(CupertinoIcons.cloud),
                title: Text(
                  syncText(
                    context,
                    '云端账号与保存位置',
                    'Cloud accounts and locations',
                  ),
                ),
                showChevron: true,
                onTap: () => context.push(AppRoutes.connections.path),
              ),
              AdaptiveListTile(
                leading: const Icon(CupertinoIcons.clock),
                title: Text(
                  syncText(context, '所有传输记录', 'All transfer history'),
                ),
                showChevron: true,
                onTap: () => context.push(AppRoutes.activity.path),
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SyncLanguageSetting()),
        ..._settingsSlivers(context, snapshot),
      ],
    ),
  );

  List<Widget> _settingsSlivers(
    BuildContext context,
    AsyncSnapshot<SyncSettingsSnapshot> snapshot,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(
            label: syncText(context, '正在加载同步设置', 'Loading sync settings'),
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
              '无法读取同步设置。',
              'Could not read the sync settings.',
            ),
            onRetry: _reload,
          ),
        ),
      ];
    }
    final value = snapshot.requireData;
    final settings = value.settings;
    final statusColor = value.backgroundSupported
        ? AppColors.success
        : context.appSecondaryLabel;
    final currentLimit = supportedCellularLimit(
      settings.defaultCellularMaxTransferBytes,
    );
    final gc = value.garbageCollection;
    return [
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '后台同步', 'Background sync'),
          footer: Text(
            syncText(
              context,
              '系统会根据网络、电量和各配置策略安排后台任务。',
              'The system schedules background work using the network, the battery, and each profile’s own policy.',
            ),
          ),
          children: [
            AdaptiveSwitchListTile(
              widgetKey: const Key('global-background-enabled'),
              title: Text(
                syncText(context, '全局后台同步', 'Global background sync'),
              ),
              subtitle: Text(
                value.backgroundSupported
                    ? syncText(
                        context,
                        '${value.backgroundEligibleProfileCount} 个配置已启用后台同步',
                        '${value.backgroundEligibleProfileCount} profiles have background sync on',
                      )
                    : syncText(
                        context,
                        '当前系统或构建不支持后台任务',
                        'Background work is not supported on this system or build',
                      ),
              ),
              value: settings.backgroundEnabled,
              onChanged: _busy || !value.backgroundSupported
                  ? null
                  : (enabled) =>
                        _save(settings.copyWith(backgroundEnabled: enabled)),
            ),
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: value.backgroundSupported
                      ? Icons.check_rounded
                      : Icons.info_outline_rounded,
                  cupertino: value.backgroundSupported
                      ? CupertinoIcons.check_mark
                      : CupertinoIcons.info,
                ),
                color: statusColor,
              ),
              title: Text(
                syncText(context, '系统后台状态', 'System background status'),
              ),
              additionalInfo: Text(
                value.backgroundSupported
                    ? syncText(context, '可用', 'Available')
                    : syncText(context, '受限', 'Limited'),
                style: TextStyle(
                  color: value.backgroundSupported
                      ? AppTone.ok.color(context)
                      : context.appSecondaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '新配置默认策略', 'Defaults for new profiles'),
          // Honest scope: these are the values a new profile starts from, but a
          // new sync location is stored with background sync off, so the footer
          // has to name the switch the user still has to turn on.
          footer: Text(
            syncText(
              context,
              '这些选项只用于此后新建的配置；已有配置保持自己的策略。新建的同步位置默认不开后台同步：还需要在它的详情页打开「后台同步」。',
              'These options apply only to profiles you create from now on; existing profiles keep their own policy. New sync locations start with background sync off: turn on “Background sync” on the location’s own page.',
            ),
          ),
          children: [
            AdaptiveSwitchListTile(
              widgetKey: const Key('default-allow-cellular'),
              title: Text(
                syncText(context, '默认允许蜂窝网络', 'Allow cellular data by default'),
              ),
              subtitle: Text(
                syncText(
                  context,
                  '离开 Wi-Fi 后仍可继续同步。',
                  'Keeps syncing after you leave Wi-Fi.',
                ),
              ),
              value: settings.defaultAllowCellular,
              onChanged: _busy
                  ? null
                  : (enabled) =>
                        _save(settings.copyWith(defaultAllowCellular: enabled)),
            ),
            AdaptiveSwitchListTile(
              widgetKey: const Key('default-requires-charging'),
              title: Text(
                syncText(
                  context,
                  '默认仅充电时运行',
                  'Run only while charging by default',
                ),
              ),
              value: settings.defaultRequiresCharging,
              onChanged: _busy
                  ? null
                  : (enabled) => _save(
                      settings.copyWith(defaultRequiresCharging: enabled),
                    ),
            ),
            AdaptiveListTile(
              widgetKey: isApplePlatform(context)
                  ? const Key('default-cellular-limit')
                  : null,
              title: Text(
                syncText(
                  context,
                  '默认蜂窝网络传输上限',
                  'Default cellular transfer limit',
                ),
              ),
              subtitle: Text(
                syncText(
                  context,
                  '加密内容按单个传输对象限制。',
                  'Encrypted data is limited per transferred item.',
                ),
              ),
              additionalInfo: isApplePlatform(context)
                  ? Text(AppFormat.bytes(currentLimit))
                  : null,
              showChevron: isApplePlatform(context),
              onTap: _busy || !isApplePlatform(context)
                  ? null
                  : () => _chooseCellularLimit(settings),
              trailing: isApplePlatform(context)
                  ? null
                  : DropdownButton<int>(
                      key: const Key('default-cellular-limit'),
                      value: currentLimit,
                      onChanged: _busy
                          ? null
                          : (bytes) {
                              if (bytes != null) {
                                _save(
                                  settings.copyWith(
                                    defaultCellularMaxTransferBytes: bytes,
                                  ),
                                );
                              }
                            },
                      items: const [
                        DropdownMenuItem(
                          value: 10 * 1024 * 1024,
                          child: Text('10 MB'),
                        ),
                        DropdownMenuItem(
                          value: 50 * 1024 * 1024,
                          child: Text('50 MB'),
                        ),
                        DropdownMenuItem(
                          value: 100 * 1024 * 1024,
                          child: Text('100 MB'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '删除保护', 'Deletion protection'),
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                gc == null
                    ? syncText(
                        context,
                        '完成一次包含有效检查点的同步后才会开始安全清理。',
                        'Safe cleanup starts after one sync completes with a valid checkpoint.',
                      )
                    : gc.state == 'completed'
                    ? syncText(
                        context,
                        '本次检查 ${gc.candidateCount} 个候选，'
                            '${gc.eligibleCandidateCount} 个满足清理条件，'
                            '已删除 ${gc.deletedObjectCount} 个对象。',
                        'This check found ${gc.candidateCount} candidates, '
                            '${gc.eligibleCandidateCount} met the cleanup rules, '
                            'and ${gc.deletedObjectCount} objects were deleted.',
                      )
                    : gc.skipReason == 'checkpoint-missing'
                    ? syncText(
                        context,
                        '尚未获得可信检查点，本次安全清理已跳过。',
                        'No trusted checkpoint yet, so this safe cleanup was skipped.',
                      )
                    : syncText(
                        context,
                        '本次安全清理已跳过。',
                        'This safe cleanup was skipped.',
                      ),
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                syncText(
                  context,
                  '实际清理额外保留 7 天缓冲。任一活跃设备未确认前，远端不会清理；'
                      '长期离线不会自动失效，请在格间设置 → 数据同步 → 已授权设备中移除。',
                  'Cleanup keeps an extra 7-day buffer. Nothing is removed remotely '
                      'while any active device has not confirmed it, and a device that '
                      'stays offline does not expire on its own: remove it in Velock '
                      'settings → Data sync → Authorized devices.',
                ),
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                syncText(
                  context,
                  'Sync 只负责安全清理，不展示最近删除列表、文件名、路径或恢复按钮。',
                  'Sync only runs safe cleanup: it shows no recently deleted list, file names, paths, or restore button.',
                ),
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ],
          ),
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: CupertinoIcons.delete,
                color: AppTone.ok.color(context),
              ),
              title: Text(syncText(context, '删除保护', 'Deletion protection')),
              subtitle: Text(
                syncText(
                  context,
                  '最近 30 天内的删除可恢复。',
                  'Deletions from the last 30 days can be restored.',
                ),
                maxLines: 2,
              ),
              trailing: AdaptiveStatusBadge(
                label: syncText(context, '已开启', 'On'),
                tone: AppTone.ok,
                icon: CupertinoIcons.check_mark_circled,
              ),
            ),
            AppFormRow(
              label: syncText(context, '最近清理', 'Last cleanup'),
              value: gc?.completedAt == null
                  ? syncText(context, '尚未执行', 'Not run yet')
                  : AppFormat.relativeTime(gc!.completedAt, context: context),
            ),
            AppFormRow(
              label: syncText(context, '等待确认', 'Waiting for confirmation'),
              value: syncText(
                context,
                '${gc?.unackedDeviceCount ?? 0} 台设备',
                '${gc?.unackedDeviceCount ?? 0} devices',
              ),
            ),
            AppFormRow(
              label: syncText(context, '活跃设备', 'Active devices'),
              value: syncText(
                context,
                '${gc?.activeDeviceCount ?? 0} 台',
                '${gc?.activeDeviceCount ?? 0} devices',
              ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '暂存空间', 'Staging space'),
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: CupertinoIcons.archivebox,
                color: AppTone.brand.color(context),
              ),
              title: Text(
                AppFormat.bytes(value.staging.totalBytes),
                style: AppType.rowTitleStrong,
              ),
              subtitle: Text(
                syncText(
                  context,
                  '${value.staging.batchCount} 个批次 · ${value.staging.fileCount} 个文件。'
                      '清理会保留可恢复批次，并跳过正在同步的配置。',
                  '${value.staging.batchCount} batches · ${value.staging.fileCount} files. '
                      'Cleanup keeps recoverable batches and skips profiles that are syncing right now.',
                ),
              ),
              trailing: AppSecondaryButton(
                key: const Key('cleanup-staging'),
                label: syncText(context, '清理', 'Clean'),
                onPressed: _busy ? null : _cleanupStaging,
              ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '隐私与诊断', 'Privacy & Diagnostics'),
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.privacy_tip_outlined,
                  cupertino: CupertinoIcons.lock_shield,
                ),
                color: AppColors.success,
              ),
              title: Text(syncText(context, '隐私保护', 'Privacy protection')),
              subtitle: Text(
                syncText(
                  context,
                  '日志和诊断不包含凭据、密钥、原始路径、配置标识、'
                      '格间业务内容或受保护冲突详情。',
                  'Logs and diagnostics contain no credentials, keys, original '
                      'paths, profile identifiers, Velock data, or protected conflict details.',
                ),
              ),
            ),
            AdaptiveListTile(
              widgetKey: const Key('export-sanitized-diagnostics'),
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.description_outlined,
                  cupertino: CupertinoIcons.doc_text,
                ),
              ),
              title: Text(
                syncText(context, '导出脱敏诊断', 'Export sanitized diagnostics'),
              ),
              subtitle: Text(
                syncText(
                  context,
                  '仅导出版本、系统能力、聚合计数、稳定错误码和暂存用量。',
                  'Exports only the version, system capabilities, aggregate counts, stable error codes, and staging usage.',
                ),
              ),
              showChevron: true,
              onTap: _busy ? null : _showDiagnostics,
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '版本与许可', 'Version & Licenses'),
          children: [
            AdaptiveListTile(
              title: Text(syncText(context, '协议版本', 'Protocol version')),
              subtitle: const Text(syncProtocolDisplayVersion),
            ),
            AdaptiveListTile(
              title: Text(syncText(context, '应用版本', 'App version')),
              subtitle: const Text(syncAppDisplayVersion),
            ),
            AdaptiveListTile(
              title: Text(
                syncText(context, '关于与开源许可', 'About & open-source licenses'),
              ),
              showChevron: true,
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Velock Sync',
                applicationVersion: syncAppDisplayVersion,
              ),
            ),
          ],
        ),
      ),
    ];
  }
}
