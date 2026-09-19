/// Profile creation wizards: generic WebDAV flow and the Velock dataset
/// pairing wizard.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'sync_profile_workspace_shared.dart';
import 'sync_profile_providers.dart';

class SyncProfileWizard extends ConsumerStatefulWidget {
  const SyncProfileWizard({super.key});
  @override
  ConsumerState<SyncProfileWizard> createState() => _SyncProfileWizardState();
}

class _SyncProfileWizardState extends ConsumerState<SyncProfileWizard> {
  @override
  void initState() {
    super.initState();
    // A freshly opened wizard must not keep showing an already-completed
    // flow; in-progress pairings survive in the app-scoped session provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(velockWizardSessionProvider.notifier).clearCompletedFlow();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final existingVelockProfiles =
        ref.watch(velockExistingProfilesProvider).asData?.value ??
        const <SyncProfileSummary>[];
    final pairedVelock = existingVelockProfiles.isEmpty
        ? null
        : existingVelockProfiles.first;
    return AdaptiveScaffold(
      title: '格间备份',
      body: ListView(
        children: [
          const SizedBox(height: AppSpacing.xs),
          AdaptiveListSection(
            header: '格间远程备份',
            footer: const Text(
              '格间是数据源，Velock Sync 只负责持续把已加密和认证的数据备份到你的远端。换机、重装或设备丢失后，恢复格间账号并连接同一远端即可恢复。',
            ),
            children: [
              if (pairedVelock != null)
                AdaptiveListTile(
                  widgetKey: const Key('velock-already-paired'),
                  enabled: false,
                  leading: AdaptiveIconBadge(
                    icon: adaptiveIcon(
                      context,
                      material: Icons.shield_outlined,
                      cupertino: CupertinoIcons.shield,
                    ),
                    color: AppColors.success,
                  ),
                  title: const Text('格间数据'),
                  subtitle: Text(
                    '已连接 ${pairedVelock.displayName ?? '格间'}。如需重新配对，请先删除当前同步配置。',
                  ),
                  trailing: Icon(
                    adaptiveIcon(
                      context,
                      material: Icons.lock_outline,
                      cupertino: CupertinoIcons.lock,
                    ),
                  ),
                )
              else
                AdaptiveListTile(
                  widgetKey: const Key('enter-velock-flow'),
                  leading: AdaptiveIconBadge(
                    icon: adaptiveIcon(
                      context,
                      material: Icons.shield_outlined,
                      cupertino: CupertinoIcons.shield,
                    ),
                  ),
                  title: const Text('格间数据'),
                  subtitle: const Text('持续备份格间中的密码、卡片、笔记、文档、文件和媒体。'),
                  showChevron: true,
                  onTap: () => context.push(AppRoutes.velockDatasetWizard.path),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class VelockDatasetWizard extends ConsumerStatefulWidget {
  const VelockDatasetWizard({super.key});

  @override
  ConsumerState<VelockDatasetWizard> createState() =>
      _VelockDatasetWizardState();
}

enum _PairingRecoveryAction { cancel, reopen }

enum _VelockReadinessAction { retry, pair, done }

class _VelockDatasetWizardState extends ConsumerState<VelockDatasetWizard>
    with WidgetsBindingObserver {
  bool _checkingVelock = false;
  bool _inspectingPairing = false;
  bool _pairingProblemDialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Returning from Velock automatically inspects a pending approval. The
    // post-frame entry check also resumes retained pairing/connection state.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareWizardEntry());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _handleVelockAppResume();
  }

  Future<void> _handleVelockAppResume() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    final wizard = ref.read(velockWizardSessionProvider);
    if (wizard.session == null || wizard.approval != null) return;
    await _inspectPendingVelockPairing(wizard.session!);
  }

  Future<void> _prepareWizardEntry() async {
    if (!mounted) return;
    // Do not re-surface a previously completed profile in a new wizard entry.
    // Deferred to the post-frame phase: modifying provider state during
    // initState/build throws "tried to modify a provider while building".
    ref.read(velockWizardSessionProvider.notifier).clearCompletedFlow();
    final wizard = ref.read(velockWizardSessionProvider);
    if (wizard.session != null && wizard.approval == null) {
      await _inspectPendingVelockPairing(wizard.session!);
      return;
    }
    await _autoResumeVelockWizard();
  }

  Future<void> _autoResumeVelockWizard() async {
    if (!mounted) return;
    final wizard = ref.read(velockWizardSessionProvider);
    final session = wizard.session;
    final approval = wizard.approval;
    if (session == null || approval == null || !wizard.connectionNeeded) {
      return;
    }
    final connections = (await ref.read(velockWizardConnectionsProvider)())
        .where((connection) => connection.status == ConnectionStatus.active)
        .toList(growable: false);
    if (!mounted || connections.isEmpty) return;
    ref.read(velockWizardSessionProvider.notifier).connectionResolved();
    await _continueVelockProfile(session, approval);
  }

  Future<void> _inspectVelock() async {
    setState(() => _checkingVelock = true);
    final readiness = await ref
        .read(velockWizardReadinessServiceProvider)
        .inspect();
    if (!mounted) return;
    setState(() => _checkingVelock = false);
    final choice = await showAdaptiveAlert<_VelockReadinessAction>(
      context: context,
      title: velockReadinessTitle(readiness.availability),
      message: velockReadinessMessage(readiness.availability),
      actions: [
        if (readiness.canRetry)
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: '重试',
            value: _VelockReadinessAction.retry,
            key: const Key('retry-velock-readiness'),
          ),
        if (readiness.canCreate)
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: '开始配对',
            value: _VelockReadinessAction.pair,
            key: const Key('begin-velock-pairing'),
            isDefault: true,
            emphasized: true,
          )
        else
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: '完成',
            value: _VelockReadinessAction.done,
            isDefault: true,
            emphasized: true,
          ),
      ],
    );
    switch (choice) {
      case _VelockReadinessAction.retry:
        await _inspectVelock();
      case _VelockReadinessAction.pair:
        await _beginVelockPairing(readiness.descriptor!);
      case _VelockReadinessAction.done:
      case null:
        break;
    }
  }

  Future<void> _beginVelockPairing(VelockPairingDescriptor descriptor) async {
    setState(() => _checkingVelock = true);
    try {
      final appInstanceId = await ref.read(velockSyncAppInstanceIdProvider)();
      final session = await ref
          .read(velockPairingSessionServiceProvider)
          .begin(descriptor: descriptor, syncAppInstanceId: appInstanceId);
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      ref.read(velockWizardSessionProvider.notifier).sessionStarted(session);
    } on Object {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      showMessage(context, '无法发起安全配对；未创建任何 Profile。');
    }
  }

  Future<void> _inspectPendingVelockPairing(
    VelockPairingSession session,
  ) async {
    if (!mounted || _inspectingPairing) return;
    _inspectingPairing = true;
    setState(() => _checkingVelock = true);
    try {
      final state = await ref
          .read(velockPairingSessionServiceProvider)
          .inspect(session);
      if (!mounted) return;
      _inspectingPairing = false;
      setState(() => _checkingVelock = false);
      if (state.isApproved) {
        final approval = state.response!;
        ref.read(velockWizardSessionProvider.notifier).approved(approval);
        await _continueVelockProfile(session, approval);
        return;
      }
      if (state.status == VelockPairingControlStatus.pending) {
        await _showPendingPairingProblem(session);
        return;
      }
      ref.read(velockWizardSessionProvider.notifier).reset();
      await _showEndedPairingProblem(state.status);
    } on Object {
      if (!mounted) return;
      _inspectingPairing = false;
      setState(() => _checkingVelock = false);
      ref.read(velockWizardSessionProvider.notifier).reset();
      await _showEndedPairingProblem(null);
    }
  }

  Future<void> _showPendingPairingProblem(VelockPairingSession session) async {
    if (!mounted || _pairingProblemDialogVisible) return;
    _pairingProblemDialogVisible = true;
    final action = await showAdaptiveAlert<_PairingRecoveryAction>(
      context: context,
      title: '尚未收到 Velock 批准',
      message: '如果你刚开启“允许新的配对”，请重新打开 Velock 并刷新待审批请求。仍看不到时，取消后重新发起。',
      icon: Icon(
        adaptiveIcon(
          context,
          material: Icons.sync_problem_outlined,
          cupertino: CupertinoIcons.exclamationmark_circle,
        ),
        color: context.appSecondaryLabel,
      ),
      actions: [
        AdaptiveAlertAction<_PairingRecoveryAction>(
          label: '取消配对',
          value: _PairingRecoveryAction.cancel,
          key: const Key('cancel-velock-pairing'),
        ),
        AdaptiveAlertAction<_PairingRecoveryAction>(
          label: '重新打开 Velock',
          value: _PairingRecoveryAction.reopen,
          key: const Key('reopen-velock-pairing'),
          isDefault: true,
          emphasized: true,
        ),
      ],
    );
    _pairingProblemDialogVisible = false;
    if (!mounted) return;
    switch (action) {
      case _PairingRecoveryAction.cancel:
        ref.read(velockWizardSessionProvider.notifier).reset();
      case _PairingRecoveryAction.reopen:
        await _reopenVelockPairing(session);
      case null:
        return;
    }
  }

  Future<void> _reopenVelockPairing(VelockPairingSession session) async {
    try {
      await ref.read(velockPairingSessionServiceProvider).reopen(session);
    } on Object {
      if (mounted) {
        showMessage(context, '无法重新打开 Velock，请取消后重新发起。');
      }
    }
  }

  Future<void> _showEndedPairingProblem(
    VelockPairingControlStatus? status,
  ) async {
    if (!mounted) return;
    final (title, message) = switch (status) {
      VelockPairingControlStatus.denied => (
        '配对已拒绝',
        '你已在 Velock 中拒绝本次配对，未创建任何 Profile。',
      ),
      VelockPairingControlStatus.expired => ('配对已过期', '本次请求已过期，请重新发起。'),
      VelockPairingControlStatus.revoked => (
        '授权已撤销',
        'Velock 已撤销本次授权，未创建任何 Profile。',
      ),
      _ => ('无法验证配对结果', '配对响应无效或不可用，未创建任何 Profile。'),
    };
    final retry = await showAdaptiveConfirmation(
      context,
      title: title,
      message: message,
      confirmLabel: '重新发起',
      cancelLabel: '关闭',
    );
    if (retry == true && mounted) await _inspectVelock();
  }

  Future<void> _continueVelockProfile(
    VelockPairingSession session,
    VelockPairingControlResponse approval,
  ) async {
    try {
      final connections = (await ref.read(velockWizardConnectionsProvider)())
          .where((connection) => connection.status == ConnectionStatus.active)
          .toList(growable: false);
      if (!mounted) return;
      if (connections.isEmpty) {
        ref.read(velockWizardSessionProvider.notifier).connectionMissing();
        showMessage(context, '还没有可用的云端连接。先添加并验证 WebDAV 连接，返回后会继续完成格间同步。');
        return;
      }
      // A connection is available: the approved pairing can proceed, so the
      // "还需要一个远端连接" banner must not keep the flow stuck.
      ref.read(velockWizardSessionProvider.notifier).connectionResolved();

      final connection = connections.length == 1
          ? connections.single
          : await _chooseVelockConnection(connections);
      if (connection == null || !mounted) return;

      final review = await _reviewVelockProfile(
        approval: approval,
        connection: connection,
      );
      if (review == null || !mounted) return;

      setState(() => _checkingVelock = true);
      final result = await ref
          .read(velockProfileFinalizerProvider)
          .finalize(
            session: session,
            approval: approval,
            connectionId: connection.id,
            displayName: review.displayName,
            backgroundPolicy: review.backgroundPolicy,
            userConfirmed: true,
          );
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      ref.read(velockWizardSessionProvider.notifier).profileFinalized(result);
      ref.read(profilesRevisionProvider.notifier).bump();
      if (!result.pairingAcknowledged) {
        showMessage(context, '同步配置已保存，但配对清理尚未确认；可在本页重试。');
        return;
      }

      // Creating the profile is not the user's goal. The user's goal is that
      // the first backup/recovery actually runs. Start it before leaving this
      // flow, so a successful setup always has a visible transfer result.
      final firstRun = await runSyncWithProgress(
        context,
        ref,
        result.profile.profileId,
      );
      if (!mounted) return;
      ref.read(velockWizardSessionProvider.notifier).reset();
      if (context.mounted) {
        await presentFirstSyncResult(context, firstRun);
      }
      if (!mounted) return;
      context.goNamed(AppRoutes.dashboard.name);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      logw('Velock profile finalization failed: ${error.runtimeType}: $error');
      final message = switch (error) {
        VelockProfileFinalizationException(:final code) => switch (code) {
          'duplicate_pairing' => '该 Velock 账号已绑定同步配置，无需重复创建；请直接使用列表中的配置。',
          'connection_missing' => '所选远端连接已不存在，请返回重新选择。',
          'connection_unavailable' => '所选远端连接当前不可用，请先在连接页验证。',
          'invalid_pairing_response' => '配对响应未通过验证；请重新发起配对。',
          'invalid_display_name' => 'Profile 名称无效，请重新输入。',
          'confirmation_required' => '未确认创建；未创建任何 Profile。',
          _ => '创建 Profile 失败（$code）；未创建任何 Profile。',
        },
        _ => '未能完成 Velock Profile；未创建任何 Profile。',
      };
      showMessage(context, message);
    }
  }

  Future<ConnectionModel?> _chooseVelockConnection(
    List<ConnectionModel> connections,
  ) => showAdaptiveActionSheet<ConnectionModel>(
    context: context,
    title: '步骤 2 / 3 · 选择远端连接',
    message: '选定后进入最终确认，可在那里核对远端目标。',
    barrierDismissible: false,
    actions: [
      for (final connection in connections)
        AdaptiveAction<ConnectionModel>(
          label: connection.name,
          caption: connection.protocol.targetLabel,
          value: connection,
          key: Key('velock-connection-${connection.id}'),
        ),
    ],
  );

  Future<_VelockProfileReview?> _reviewVelockProfile({
    required VelockPairingControlResponse approval,
    required ConnectionModel connection,
  }) async {
    final defaults =
        (await ref.read(syncSettingsServiceProvider).load()).settings;
    var displayName = approval.vaultDisplayName;
    var enabled = defaults.backgroundEnabled;
    var allowCellular = defaults.defaultAllowCellular;
    var requiresCharging = defaults.defaultRequiresCharging;
    var maximumBytes = defaults.defaultCellularMaxTransferBytes;
    const choices = <int>[10, 50, 100];
    if (!choices.map((value) => value * 1024 * 1024).contains(maximumBytes)) {
      maximumBytes = 50 * 1024 * 1024;
    }
    if (!mounted) return null;
    return showAdaptiveForm<_VelockProfileReview>(
      context: context,
      title: '步骤 3 / 3 · 确认并创建',
      barrierDismissible: false,
      builder: (context, setDialogState) =>
          AdaptiveFormSpec<_VelockProfileReview>(
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AdaptiveTextField(
                    key: const Key('velock-profile-name'),
                    label: 'Profile 名称',
                    initialValue: displayName,
                    maxLength: 128,
                    onChanged: (value) =>
                        setDialogState(() => displayName = value),
                  ),
                  const SizedBox(height: 10),
                  Text('Vault：${approval.vaultDisplayName}'),
                  Text('设备：${approval.deviceDisplayName}'),
                  Text('远端：${connection.name} · ${connection.target}'),
                  const Divider(height: 20),
                  AdaptiveSwitchRow(
                    key: const Key('velock-background-enabled'),
                    title: '允许后台同步',
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                  ),
                  AdaptiveSwitchRow(
                    title: '允许使用蜂窝网络',
                    value: allowCellular,
                    onChanged: enabled
                        ? (value) => setDialogState(() => allowCellular = value)
                        : null,
                  ),
                  AdaptiveSwitchRow(
                    title: '仅充电时运行',
                    value: requiresCharging,
                    onChanged: enabled
                        ? (value) =>
                              setDialogState(() => requiresCharging = value)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  AdaptiveOptionPicker<int>(
                    label: '蜂窝网络单次上限',
                    value: maximumBytes,
                    options: [
                      for (final value in choices)
                        ('$value MB', value * 1024 * 1024),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => maximumBytes = value),
                  ),
                  const Divider(height: 20),
                  Text(
                    '确认后先原子保存 Profile，成功后才消费本次一次性配对响应。',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.appSecondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              const AdaptiveAlertAction<_VelockProfileReview>(label: '返回'),
              AdaptiveAlertAction<_VelockProfileReview>(
                label: '确认并创建',
                key: const Key('finalize-velock-profile'),
                enabled: displayName.trim().isNotEmpty,
                isDefault: true,
                emphasized: true,
                value: _VelockProfileReview(
                  displayName: displayName.trim(),
                  backgroundPolicy: SyncProfileBackgroundPolicy(
                    enabled: enabled,
                    allowCellular: enabled && allowCellular,
                    requiresCharging: enabled && requiresCharging,
                    cellularMaxTransferBytes: maximumBytes,
                  ),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _retryVelockAcknowledgement() async {
    final session = ref.read(velockWizardSessionProvider).session;
    if (session == null) return;
    setState(() => _checkingVelock = true);
    final acknowledged = await ref
        .read(velockProfileFinalizerProvider)
        .retryAcknowledgement(session);
    if (!mounted) return;
    setState(() => _checkingVelock = false);
    if (acknowledged) {
      ref.read(velockWizardSessionProvider.notifier).acknowledged();
    }
    showMessage(context, acknowledged ? '配对清理已确认。' : '仍无法确认配对清理，请稍后重试。');
  }

  @override
  Widget build(BuildContext context) {
    final wizard = ref.watch(velockWizardSessionProvider);
    final existingVelockProfiles = ref.watch(velockExistingProfilesProvider);
    return AdaptiveScaffold(
      title: '格间备份',
      body: ListView(
        padding: const EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.xl,
        ),
        children: _velockFlowChildren(
          wizard,
          existingVelockProfiles.asData?.value ?? const [],
        ),
      ),
    );
  }

  List<Widget> _velockFlowChildren(
    VelockWizardSessionState wizard,
    List<SyncProfileSummary> existingVelockProfiles,
  ) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Text(
        existingVelockProfiles.isEmpty
            ? '只需配对一次：在格间中批准本次请求后，会建立持续加密备份；以后新增或修改只传输增量。'
            : '本机已经有格间备份配置；如需更换远端或重新授权，请先移除当前配置再重新连接。',
        style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
      ),
    ),
    if (existingVelockProfiles.isNotEmpty)
      AdaptiveListSection(
        header: '已连接的格间备份',
        footer: const Text('同一时间只保留一个格间备份配置。需要更换远端或重新授权时，请先在上方配置中移除它。'),
        children: [
          for (final profile in existingVelockProfiles)
            Builder(
              builder: (context) {
                final presentation = profileStatusPresentation(
                  context,
                  kind: profile.kind,
                  state: profile.state,
                  isIsolated: profile.isIsolated,
                  lastRunFailed: profile.activity?.latestRun?.state == 'failed',
                );
                return AdaptiveListTile(
                  leading: AdaptiveIconBadge(
                    icon: adaptiveKindIcon(context, profile.kind),
                    color: presentation.tone.color(context),
                  ),
                  title: Text(
                    profile.displayName ?? '格间同步配置',
                    style: AppType.rowTitleStrong,
                  ),
                  subtitle: Text(
                    '${kindLabel(profile.kind)} · ${presentation.label}',
                    maxLines: 2,
                  ),
                  showChevron: true,
                  onTap: () =>
                      context.push('/sync-profiles/${profile.profileId}'),
                );
              },
            ),
        ],
      ),
    if (wizard.session != null && wizard.approval == null)
      AdaptiveListSection(
        header: '配对状态',
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.pending_actions_outlined,
                cupertino: CupertinoIcons.hourglass,
              ),
              color: context.appPrimary,
            ),
            title: const Text('Velock 配对等待批准'),
            subtitle: const Text('从 Velock 返回后会自动检查；也可点此重新检测。'),
            trailing: _checkingVelock
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    adaptiveIcon(
                      context,
                      material: Icons.chevron_right_rounded,
                      cupertino: CupertinoIcons.chevron_right,
                    ),
                  ),
            onTap: _checkingVelock
                ? null
                : () => _inspectPendingVelockPairing(wizard.session!),
          ),
        ],
      ),
    if (wizard.approval != null)
      AdaptiveListSection(
        header: '配对已验证',
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.verified_user_outlined,
                cupertino: CupertinoIcons.checkmark_seal,
              ),
              color: AppColors.success,
            ),
            title: Text(wizard.approval!.vaultDisplayName),
            subtitle: Text(
              '已验证 ${wizard.approval!.deviceDisplayName}；尚未创建 Profile。',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('abandon-velock-pairing'),
                  onPressed: _checkingVelock
                      ? null
                      : () => ref
                            .read(velockWizardSessionProvider.notifier)
                            .reset(),
                  child: const Text('放弃'),
                ),
                Icon(
                  adaptiveIcon(
                    context,
                    material: Icons.chevron_right_rounded,
                    cupertino: CupertinoIcons.chevron_right,
                  ),
                ),
              ],
            ),
            onTap: _checkingVelock
                ? null
                : () =>
                      _continueVelockProfile(wizard.session!, wizard.approval!),
          ),
        ],
      ),
    if (wizard.approval != null && wizard.connectionNeeded)
      AdaptiveListSection(
        header: '下一步',
        footer: const Text('配对已保留。创建并验证远端连接后，回来点击上方已验证的配对继续。'),
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.add_link_rounded,
                cupertino: CupertinoIcons.link,
              ),
              color: AppColors.warning,
            ),
            title: const Text('还需要一个远端连接'),
            subtitle: const Text('先准备一个可用的 WebDAV、Google Drive 或 OneDrive 连接。'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: AppPrimaryButton(
              key: const Key('go-create-connection'),
              label: '去创建连接',
              icon: CupertinoIcons.arrow_up_right,
              expand: true,
              onPressed: () {
                ref
                    .read(connectionCreationProvider.notifier)
                    .prepareNewConnection(
                      name: '新建连接',
                      source: '格间',
                      target: null,
                    );
                context.push(AppRoutes.newWebDav.path);
              },
            ),
          ),
        ],
      ),
    if (wizard.finalization case final result?)
      AdaptiveListSection(
        header: '创建结果',
        children: [
          AdaptiveListTile(
            key: const Key('velock-finalization-result'),
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: result.pairingAcknowledged
                    ? Icons.check_circle_outline
                    : Icons.sync_problem_outlined,
                cupertino: result.pairingAcknowledged
                    ? CupertinoIcons.check_mark_circled
                    : CupertinoIcons.exclamationmark_triangle,
              ),
              color: result.pairingAcknowledged
                  ? AppColors.success
                  : AppColors.warning,
            ),
            title: Text(result.profile.displayName),
            subtitle: Text(
              result.pairingAcknowledged
                  ? 'Profile 已保存，配对响应已安全消费。'
                  : 'Profile 已保存；配对清理尚未确认。',
            ),
            trailing: result.pairingAcknowledged
                ? null
                : TextButton(
                    key: const Key('retry-velock-acknowledgement'),
                    onPressed: _checkingVelock
                        ? null
                        : _retryVelockAcknowledgement,
                    child: const Text('重试清理'),
                  ),
          ),
        ],
      ),
    if (wizard.session == null &&
        wizard.approval == null &&
        existingVelockProfiles.isEmpty)
      AdaptiveListSection(
        header: '开始',
        children: [
          AdaptiveListTile(
            key: const Key('inspect-velock-readiness'),
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.shield_outlined,
                cupertino: CupertinoIcons.shield,
              ),
              color: context.appPrimary,
            ),
            title: const Text('开始连接格间'),
            subtitle: const Text('检查格间授权并发起配对。配置保存后会立即执行第一次上传或恢复。'),
            trailing: _checkingVelock
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    adaptiveIcon(
                      context,
                      material: Icons.chevron_right_rounded,
                      cupertino: CupertinoIcons.chevron_right,
                    ),
                  ),
            enabled: !_checkingVelock,
            onTap: _checkingVelock ? null : _inspectVelock,
          ),
        ],
      ),
  ];
}

class _VelockProfileReview {
  const _VelockProfileReview({
    required this.displayName,
    required this.backgroundPolicy,
  });

  final String displayName;
  final SyncProfileBackgroundPolicy backgroundPolicy;
}
