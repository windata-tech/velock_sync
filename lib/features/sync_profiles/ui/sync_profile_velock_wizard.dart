/// Profile creation wizards: generic WebDAV flow and the Velock dataset
/// pairing wizard.
library;

import 'package:velock_sync/l10n/sync_locale.dart';
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
      title: syncText(context, '格间备份', "Velock backup"),
      body: ListView(
        children: [
          const SizedBox(height: AppSpacing.xs),
          AdaptiveListSection(
            header: syncText(context, '格间远程备份', "Remote Velock backup"),
            footer: Text(
              syncText(
                context,
                '格间是数据源，Velock Sync 只负责持续把已加密和认证的数据备份到你的远端。换机、重装或设备丢失后，恢复格间账号并连接同一远端即可恢复。',
                "Velock is the data source. Velock Sync continuously backs up its encrypted, authenticated data to your remote storage. After switching devices, reinstalling, or losing a device, recover your Velock account and connect to the same remote storage.",
              ),
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
                  title: Text(syncText(context, '格间数据', "Velock data")),
                  subtitle: Text(
                    syncText(
                      context,
                      '已连接 ${pairedVelock.displayName ?? '格间'}。如需重新配对，请先删除当前同步配置。',
                      "Connected to ${pairedVelock.displayName ?? 'Velock'}. Delete the current sync profile before pairing again.",
                    ),
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
                  title: Text(syncText(context, '格间数据', "Velock data")),
                  subtitle: Text(
                    syncText(
                      context,
                      '持续备份格间中的密码、卡片、笔记、文档、文件和媒体。',
                      "Continuously back up passwords, cards, notes, documents, files, and media from Velock.",
                    ),
                  ),
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
      title: velockReadinessTitle(readiness.availability, context: context),
      message: velockReadinessMessage(readiness.availability, context: context),
      actions: [
        if (readiness.canRetry)
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: syncText(context, '重试', "Retry"),
            value: _VelockReadinessAction.retry,
            key: const Key('retry-velock-readiness'),
          ),
        if (readiness.canCreate)
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: syncText(context, '开始配对', "Start pairing"),
            value: _VelockReadinessAction.pair,
            key: const Key('begin-velock-pairing'),
            isDefault: true,
            emphasized: true,
          )
        else
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: syncText(context, '完成', "Done"),
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
      showMessage(
        context,
        syncText(
          context,
          '无法发起安全配对；未创建任何 Profile。',
          "Could not start secure pairing. No profile was created.",
        ),
      );
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
      title: syncText(context, '尚未收到 Velock 批准', "Awaiting Velock approval"),
      message: syncText(
        context,
        '如果你刚开启“允许新的配对”，请重新打开 Velock 并刷新待审批请求。仍看不到时，取消后重新发起。',
        "If you just enabled “Allow new pairings”, reopen Velock and refresh pending requests. If the request is still missing, cancel and start again.",
      ),
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
          label: syncText(context, '取消配对', "Cancel pairing"),
          value: _PairingRecoveryAction.cancel,
          key: const Key('cancel-velock-pairing'),
        ),
        AdaptiveAlertAction<_PairingRecoveryAction>(
          label: syncText(context, '重新打开 Velock', "Reopen Velock"),
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
        showMessage(
          context,
          syncText(
            context,
            '无法重新打开 Velock，请取消后重新发起。',
            "Could not reopen Velock. Cancel and start again.",
          ),
        );
      }
    }
  }

  Future<void> _showEndedPairingProblem(
    VelockPairingControlStatus? status,
  ) async {
    if (!mounted) return;
    final (title, message) = switch (status) {
      VelockPairingControlStatus.denied => (
        syncText(context, '配对已拒绝', "Pairing denied"),
        syncText(
          context,
          '你已在 Velock 中拒绝本次配对，未创建任何 Profile。',
          "You denied this pairing in Velock. No profile was created.",
        ),
      ),
      VelockPairingControlStatus.expired => (
        syncText(context, '配对已过期', "Pairing expired"),
        syncText(
          context,
          '本次请求已过期，请重新发起。',
          "This request has expired. Please start again.",
        ),
      ),
      VelockPairingControlStatus.revoked => (
        syncText(context, '授权已撤销', "Access revoked"),
        syncText(
          context,
          'Velock 已撤销本次授权，未创建任何 Profile。',
          "Velock revoked this authorization. No profile was created.",
        ),
      ),
      _ => (
        syncText(context, '无法验证配对结果', "Could not verify pairing"),
        syncText(
          context,
          '配对响应无效或不可用，未创建任何 Profile。',
          "The pairing response is invalid or unavailable. No profile was created.",
        ),
      ),
    };
    final retry = await showAdaptiveConfirmation(
      context,
      title: title,
      message: message,
      confirmLabel: syncText(context, '重新发起', "Start again"),
      cancelLabel: syncText(context, '关闭', "Close"),
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
        showMessage(
          context,
          syncText(
            context,
            '还没有可用的云端连接。先添加并验证 WebDAV 连接，返回后会继续完成格间同步。',
            "No remote connection is available. Add and verify a WebDAV connection, then return to continue setting up Velock sync.",
          ),
        );
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
        showMessage(
          context,
          syncText(
            context,
            '同步配置已保存，但配对清理尚未确认；可在本页重试。',
            "The sync profile was saved, but pairing cleanup is not yet confirmed. Retry on this page.",
          ),
        );
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
          'duplicate_pairing' => syncText(
            context,
            '该 Velock 账号已绑定同步配置，无需重复创建；请直接使用列表中的配置。',
            "This Velock account already has a sync profile. Use the existing profile in the list.",
          ),
          'connection_missing' => syncText(
            context,
            '所选远端连接已不存在，请返回重新选择。',
            "The selected remote connection no longer exists. Go back and choose another.",
          ),
          'connection_unavailable' => syncText(
            context,
            '所选远端连接当前不可用，请先在连接页验证。',
            "The selected remote connection is unavailable. Verify it on the Connections page first.",
          ),
          'invalid_pairing_response' => syncText(
            context,
            '配对响应未通过验证；请重新发起配对。',
            "The pairing response could not be verified. Please pair again.",
          ),
          'invalid_display_name' => syncText(
            context,
            'Profile 名称无效，请重新输入。',
            "Invalid profile name. Please enter another name.",
          ),
          'confirmation_required' => syncText(
            context,
            '未确认创建；未创建任何 Profile。',
            "Creation was not confirmed. No profile was created.",
          ),
          _ => syncText(
            context,
            '创建 Profile 失败（$code）；未创建任何 Profile。',
            "Could not create profile ($code). No profile was created.",
          ),
        },
        _ => syncText(
          context,
          '未能完成 Velock Profile；未创建任何 Profile。',
          "Could not complete the Velock profile. No profile was created.",
        ),
      };
      showMessage(context, message);
    }
  }

  Future<ConnectionModel?> _chooseVelockConnection(
    List<ConnectionModel> connections,
  ) => showAdaptiveActionSheet<ConnectionModel>(
    context: context,
    title: syncText(
      context,
      '步骤 2 / 3 · 选择远端连接',
      "Step 2 / 3 · Choose remote connection",
    ),
    message: syncText(
      context,
      '选定后进入最终确认，可在那里核对远端目标。',
      "Continue to the final review to check the remote destination.",
    ),
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
      title: syncText(
        context,
        '步骤 3 / 3 · 确认并创建',
        "Step 3 / 3 · Review and create",
      ),
      barrierDismissible: false,
      builder: (context, setDialogState) => AdaptiveFormSpec<_VelockProfileReview>(
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveTextField(
                key: const Key('velock-profile-name'),
                label: syncText(context, 'Profile 名称', "Profile name"),
                initialValue: displayName,
                maxLength: 128,
                onChanged: (value) => setDialogState(() => displayName = value),
              ),
              const SizedBox(height: 10),
              Text('Vault：${approval.vaultDisplayName}'),
              Text(
                syncText(
                  context,
                  '设备：${approval.deviceDisplayName}',
                  "Device: ${approval.deviceDisplayName}",
                ),
              ),
              Text(
                syncText(
                  context,
                  '远端：${connection.name} · ${connection.target}',
                  "Remote: ${connection.name} · ${connection.target}",
                ),
              ),
              const Divider(height: 20),
              AdaptiveSwitchRow(
                key: const Key('velock-background-enabled'),
                title: syncText(context, '允许后台同步', "Allow background sync"),
                value: enabled,
                onChanged: (value) => setDialogState(() => enabled = value),
              ),
              AdaptiveSwitchRow(
                title: syncText(context, '允许使用蜂窝网络', "Allow cellular data"),
                value: allowCellular,
                onChanged: enabled
                    ? (value) => setDialogState(() => allowCellular = value)
                    : null,
              ),
              AdaptiveSwitchRow(
                title: syncText(context, '仅充电时运行', "Only while charging"),
                value: requiresCharging,
                onChanged: enabled
                    ? (value) => setDialogState(() => requiresCharging = value)
                    : null,
              ),
              const SizedBox(height: 8),
              AdaptiveOptionPicker<int>(
                label: syncText(context, '蜂窝网络单次上限', "Cellular transfer limit"),
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
                syncText(
                  context,
                  '确认后先原子保存 Profile，成功后才消费本次一次性配对响应。',
                  "The profile is saved atomically before this one-time pairing response is consumed.",
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: context.appSecondaryLabel,
                ),
              ),
            ],
          ),
        ),
        actions: [
          AdaptiveAlertAction<_VelockProfileReview>(
            label: syncText(context, '返回', "Back"),
          ),
          AdaptiveAlertAction<_VelockProfileReview>(
            label: syncText(context, '确认并创建', "Confirm and create"),
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
    showMessage(
      context,
      acknowledged
          ? syncText(context, '配对清理已确认。', "Pairing cleanup confirmed.")
          : syncText(
              context,
              '仍无法确认配对清理，请稍后重试。',
              "Pairing cleanup could not be confirmed. Try again later.",
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wizard = ref.watch(velockWizardSessionProvider);
    final existingVelockProfiles = ref.watch(velockExistingProfilesProvider);
    return AdaptiveScaffold(
      title: syncText(context, '格间备份', "Velock backup"),
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
            ? syncText(
                context,
                '只需配对一次：在格间中批准本次请求后，会建立持续加密备份；以后新增或修改只传输增量。',
                "Pair once: approve the request in Velock to enable continuous encrypted backup. Only changes are transferred afterward.",
              )
            : syncText(
                context,
                '本机已经有格间备份配置；如需更换远端或重新授权，请先移除当前配置再重新连接。',
                "This device already has a Velock backup profile. Remove it before changing remote storage or authorizing again.",
              ),
        style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
      ),
    ),
    if (existingVelockProfiles.isNotEmpty)
      AdaptiveListSection(
        header: syncText(context, '已连接的格间备份', "Connected Velock backup"),
        footer: Text(
          syncText(
            context,
            '同一时间只保留一个格间备份配置。需要更换远端或重新授权时，请先在上方配置中移除它。',
            "Only one Velock backup profile is kept at a time. Remove the profile above before changing remote storage or authorizing again.",
          ),
        ),
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
                    profile.displayName ??
                        syncText(context, '格间同步配置', "Velock sync profile"),
                    style: AppType.rowTitleStrong,
                  ),
                  subtitle: Text(
                    '${kindLabel(profile.kind, context: context)} · ${presentation.label}',
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
        header: syncText(context, '配对状态', "Pairing status"),
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
            title: Text(
              syncText(
                context,
                'Velock 配对等待批准',
                "Velock pairing awaiting approval",
              ),
            ),
            subtitle: Text(
              syncText(
                context,
                '从 Velock 返回后会自动检查；也可点此重新检测。',
                "Approval is checked automatically when you return from Velock. Tap to check again.",
              ),
            ),
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
        header: syncText(context, '配对已验证', "Pairing verified"),
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
              syncText(
                context,
                '已验证 ${wizard.approval!.deviceDisplayName}；尚未创建 Profile。',
                "Verified ${wizard.approval!.deviceDisplayName}. No profile has been created yet.",
              ),
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
                  child: Text(syncText(context, '放弃', "Discard")),
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
        header: syncText(context, '下一步', "Next"),
        footer: Text(
          syncText(
            context,
            '配对已保留。创建并验证远端连接后，回来点击上方已验证的配对继续。',
            "Pairing has been retained. Create and verify a remote connection, then return and tap the verified pairing above to continue.",
          ),
        ),
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
            title: Text(
              syncText(
                context,
                '还需要一个远端连接',
                "A remote connection is still needed",
              ),
            ),
            subtitle: Text(
              syncText(
                context,
                '先准备一个可用的 WebDAV、Google Drive 或 OneDrive 连接。',
                "Set up a working WebDAV, Google Drive, or OneDrive connection first.",
              ),
            ),
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
              label: syncText(context, '去创建连接', "Set up connection"),
              icon: CupertinoIcons.arrow_up_right,
              expand: true,
              onPressed: () {
                ref
                    .read(connectionCreationProvider.notifier)
                    .prepareNewConnection(
                      name: syncText(context, '新建连接', "New connection"),
                      source: syncText(context, '格间', "Velock"),
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
        header: syncText(context, '创建结果', "Setup result"),
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
                  ? syncText(
                      context,
                      'Profile 已保存，配对响应已安全消费。',
                      "Profile saved. The pairing response was safely consumed.",
                    )
                  : syncText(
                      context,
                      'Profile 已保存；配对清理尚未确认。',
                      "Profile saved. Pairing cleanup is not yet confirmed.",
                    ),
            ),
            trailing: result.pairingAcknowledged
                ? null
                : TextButton(
                    key: const Key('retry-velock-acknowledgement'),
                    onPressed: _checkingVelock
                        ? null
                        : _retryVelockAcknowledgement,
                    child: Text(syncText(context, '重试清理', "Retry cleanup")),
                  ),
          ),
        ],
      ),
    if (wizard.session == null &&
        wizard.approval == null &&
        existingVelockProfiles.isEmpty)
      AdaptiveListSection(
        header: syncText(context, '开始', "Start"),
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
            title: Text(syncText(context, '开始连接格间', "Connect to Velock")),
            subtitle: Text(
              syncText(
                context,
                '检查格间授权并发起配对。配置保存后会立即执行第一次上传或恢复。',
                "Check Velock authorization and start pairing. The first upload or recovery runs as soon as the profile is saved.",
              ),
            ),
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
