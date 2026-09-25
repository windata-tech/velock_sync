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
        showMessage(context, '无法保存全局同步设置。');
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
      showMessage(
        context,
        '已释放 ${AppFormat.bytes(result.freedBytes)}；'
        '保留 ${result.preservedRecoverableBatchCount} 个可恢复批次'
        '${result.busyProfileCount == 0 ? '。' : '，${result.busyProfileCount} 个运行中配置未清理。'}',
      );
      _reload();
    } on Object {
      if (mounted) showMessage(context, '暂存空间清理未完成，请稍后重试。');
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
        title: '脱敏诊断',
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
            label: '复制',
            value: 'copy',
            key: const Key('copy-sanitized-diagnostics'),
          ),
          AdaptiveAlertAction<String>(
            label: '完成',
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
      if (mounted) showMessage(context, '无法生成脱敏诊断。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseCellularLimit(SyncGlobalSettings settings) async {
    final selected = await showAdaptiveActionSheet<int>(
      context: context,
      title: '默认蜂窝网络传输上限',
      message: '加密内容按单个传输对象限制。',
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
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(label: '正在加载同步设置'),
        ),
      ];
    }
    if (snapshot.hasError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveErrorState(message: '无法读取同步设置。', onRetry: _reload),
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
          header: '后台同步',
          footer: const Text('系统会根据网络、电量和各配置策略安排后台任务。'),
          children: [
            AdaptiveSwitchListTile(
              widgetKey: const Key('global-background-enabled'),
              title: const Text('全局后台同步'),
              subtitle: Text(
                value.backgroundSupported
                    ? '${value.backgroundEligibleProfileCount} 个配置已启用后台同步'
                    : '当前系统或构建不支持后台任务',
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
              title: const Text('系统后台状态'),
              additionalInfo: Text(
                value.backgroundSupported ? '可用' : '受限',
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
          header: '新配置默认策略',
          footer: const Text('这些选项只影响此后创建的配置；已有配置保持自己的策略。'),
          children: [
            AdaptiveSwitchListTile(
              widgetKey: const Key('default-allow-cellular'),
              title: const Text('默认允许蜂窝网络'),
              subtitle: const Text('离开 Wi-Fi 后仍可继续同步。'),
              value: settings.defaultAllowCellular,
              onChanged: _busy
                  ? null
                  : (enabled) =>
                        _save(settings.copyWith(defaultAllowCellular: enabled)),
            ),
            AdaptiveSwitchListTile(
              widgetKey: const Key('default-requires-charging'),
              title: const Text('默认仅充电时运行'),
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
              title: const Text('默认蜂窝网络传输上限'),
              subtitle: const Text('加密内容按单个传输对象限制。'),
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
          header: '删除保护',
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                gc == null
                    ? '完成一次包含有效检查点的同步后才会开始安全清理。'
                    : gc.state == 'completed'
                    ? '本次检查 ${gc.candidateCount} 个候选，'
                          '${gc.eligibleCandidateCount} 个满足清理条件，'
                          '已删除 ${gc.deletedObjectCount} 个对象。'
                    : gc.skipReason == 'checkpoint-missing'
                    ? '尚未获得可信检查点，本次安全清理已跳过。'
                    : '本次安全清理已跳过。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '实际清理额外保留 7 天缓冲。任一活跃设备未确认前，远端不会清理；'
                '长期离线不会自动失效，请在格间设置 → 数据同步 → 已授权设备中移除。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Sync 只负责安全清理，不展示最近删除列表、文件名、路径或恢复按钮。',
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
              title: const Text('删除保护'),
              subtitle: const Text('最近 30 天内的删除可恢复。', maxLines: 2),
              trailing: AdaptiveStatusBadge(
                label: '已开启',
                tone: AppTone.ok,
                icon: CupertinoIcons.check_mark_circled,
              ),
            ),
            AppFormRow(
              label: '最近清理',
              value: gc?.completedAt == null
                  ? '尚未执行'
                  : AppFormat.relativeTime(gc!.completedAt),
            ),
            AppFormRow(
              label: '等待确认',
              value: '${gc?.unackedDeviceCount ?? 0} 台设备',
            ),
            AppFormRow(label: '活跃设备', value: '${gc?.activeDeviceCount ?? 0} 台'),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '暂存空间',
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
                '${value.staging.batchCount} 个批次 · ${value.staging.fileCount} 个文件。'
                '清理会保留可恢复批次，并跳过正在同步的配置。',
                maxLines: 2,
              ),
              trailing: AppSecondaryButton(
                key: const Key('cleanup-staging'),
                label: '清理',
                onPressed: _busy ? null : _cleanupStaging,
              ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '隐私与诊断',
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
              title: const Text('隐私保护'),
              subtitle: const Text(
                '日志和诊断不包含凭据、密钥、原始路径、配置标识、'
                '格间业务内容或受保护冲突详情。',
                maxLines: 3,
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
              title: const Text('导出脱敏诊断'),
              subtitle: const Text('仅导出版本、系统能力、聚合计数、稳定错误码和暂存用量。', maxLines: 2),
              showChevron: true,
              onTap: _busy ? null : _showDiagnostics,
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '版本与许可',
          children: [
            const AdaptiveListTile(
              title: Text('协议版本'),
              subtitle: Text(syncProtocolDisplayVersion),
            ),
            const AdaptiveListTile(
              title: Text('应用版本'),
              subtitle: Text(syncAppDisplayVersion),
            ),
            AdaptiveListTile(
              title: const Text('关于与开源许可'),
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
