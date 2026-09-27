/// Profile creation wizards: generic WebDAV flow and the Velock dataset
/// pairing wizard.
library;

import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_actions.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
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
  const VelockDatasetWizard({super.key, this.restoring = false});
  final bool restoring;

  @override
  ConsumerState<VelockDatasetWizard> createState() =>
      _VelockDatasetWizardState();
}

enum _PairingRecoveryAction { cancel, reopen }

enum _VelockReadinessAction { open, done }

class _VelockDatasetWizardState extends ConsumerState<VelockDatasetWizard>
    with WidgetsBindingObserver {
  bool _checkingVelock = false;
  bool _continuingSetup = false;
  bool _inspectingPairing = false;
  bool _pairingProblemDialogVisible = false;
  String? _destinationError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Returning from Velock automatically inspects a pending approval. The
    // post-frame entry check also resumes retained pairing/connection state.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareWizardEntry());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The router can reveal this existing page after saving a cloud account;
    // initState is not run again. Observe the route's visible state rather than
    // relying on a push Future (go() need not complete that Future).
    if (ModalRoute.of(context)?.isCurrent == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_autoResumeVelockWizard());
      });
    }
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
    ref.read(velockWizardSessionProvider.notifier).expireIfNeeded();
    final wizard = ref.read(velockWizardSessionProvider);
    if (wizard.session == null || wizard.finalization != null) return;
    if (wizard.approval != null) {
      await _verifyCurrentApproval(wizard.session!, wizard.approval!);
      return;
    }
    await _inspectPendingVelockPairing(wizard.session!);
  }

  Future<void> _prepareWizardEntry() async {
    if (!mounted) return;
    // Do not re-surface a previously completed profile in a new wizard entry.
    // Deferred to the post-frame phase: modifying provider state during
    // initState/build throws "tried to modify a provider while building".
    ref.read(velockWizardSessionProvider.notifier).clearCompletedFlow();
    ref.read(velockWizardSessionProvider.notifier).expireIfNeeded();
    final wizard = ref.read(velockWizardSessionProvider);
    if (wizard.session != null && wizard.approval == null) {
      await _inspectPendingVelockPairing(wizard.session!);
      return;
    }
    await _autoResumeVelockWizard();
  }

  Future<void> _autoResumeVelockWizard() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    ref.read(velockWizardSessionProvider.notifier).expireIfNeeded();
    final wizard = ref.read(velockWizardSessionProvider);
    final session = wizard.session;
    final approval = wizard.approval;
    if (session == null || approval == null || wizard.finalization != null) {
      return;
    }
    if (!await _verifyCurrentApproval(session, approval) ||
        !wizard.connectionNeeded) {
      return;
    }
    final connections = (await ref.read(velockWizardConnectionsProvider)())
        .where((connection) => connection.status == ConnectionStatus.active)
        .toList(growable: false);
    if (!mounted ||
        connections.isEmpty ||
        !_authorizationIsCurrent(session, approval) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    ref.read(velockWizardSessionProvider.notifier).connectionResolved();
    await _continueVelockProfile(session, approval, reuseSelection: true);
  }

  bool _authorizationIsCurrent(
    VelockPairingSession session,
    VelockPairingControlResponse approval,
  ) {
    if (!mounted) return false;
    final wizard = ref.read(velockWizardSessionProvider);
    return identical(wizard.session, session) &&
        identical(wizard.approval, approval) &&
        wizard.finalization == null;
  }

  Future<bool> _verifyCurrentApproval(
    VelockPairingSession session,
    VelockPairingControlResponse approval,
  ) async {
    if (!mounted) return false;
    final controller = ref.read(velockWizardSessionProvider.notifier);
    controller.expireIfNeeded();
    if (!_authorizationIsCurrent(session, approval)) return false;
    var verified = false;
    try {
      verified = await approval.verify(
        descriptor: session.descriptor,
        request: session.request,
        now: ref.read(velockWizardClockProvider),
      );
    } on Object {
      // A malformed response is not authorization. Do not leave it displayed
      // as approved or proceed to cloud I/O after a cryptographic failure.
    }
    if (!mounted) return false;
    controller.expireIfNeeded();
    if (!_authorizationIsCurrent(session, approval)) return false;
    if (!verified) {
      controller.authorizationInvalidated(
        session,
        VelockWizardAuthorizationProblem.invalid,
      );
    }
    return verified;
  }

  Future<void> _inspectVelock() async {
    if (_checkingVelock) return;
    setState(() => _checkingVelock = true);
    try {
      final readiness = await ref
          .read(velockWizardReadinessServiceProvider)
          .inspect()
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => const VelockWizardReadiness(
              VelockWizardAvailability.temporarilyUnavailable,
            ),
          );
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      if (readiness.canCreate) {
        await _beginVelockPairing(readiness.descriptor!);
        return;
      }
      final choice = await showAdaptiveAlert<_VelockReadinessAction>(
        context: context,
        title: syncText(context, '先在格间允许备份', 'Allow backup in Velock first'),
        message: velockReadinessMessage(
          readiness.availability,
          context: context,
        ),
        actions: [
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: syncText(context, '返回', 'Back'),
            value: _VelockReadinessAction.done,
          ),
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: syncText(context, '打开格间', 'Open Velock'),
            value: _VelockReadinessAction.open,
            isDefault: true,
            emphasized: true,
          ),
        ],
      );
      if (choice == _VelockReadinessAction.open && mounted) {
        await openVelockForBackup(context, ref);
      }
    } on Object {
      if (mounted) {
        setState(() => _checkingVelock = false);
        showMessage(
          context,
          syncText(
            context,
            '暂时无法连接格间，请解锁格间后重试。',
            'Could not connect to Velock. Unlock it, then try again.',
          ),
        );
      }
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
      await _reopenVelockPairing(session);
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
      ref.read(velockWizardSessionProvider.notifier).expireIfNeeded();
      if (!identical(ref.read(velockWizardSessionProvider).session, session)) {
        return;
      }
      if (state.isApproved) {
        final approval = state.response!;
        ref.read(velockWizardSessionProvider.notifier).approved(approval);
        await _continueVelockProfile(session, approval, reuseSelection: true);
        return;
      }
      if (state.status == VelockPairingControlStatus.pending) {
        await _showPendingPairingProblem(session);
        return;
      }
      if (state.status == VelockPairingControlStatus.expired) {
        ref
            .read(velockWizardSessionProvider.notifier)
            .authorizationInvalidated(
              session,
              VelockWizardAuthorizationProblem.expired,
            );
        return;
      }
      ref.read(velockWizardSessionProvider.notifier).reset();
      await _showEndedPairingProblem(state.status);
    } on Object {
      if (!mounted) return;
      _inspectingPairing = false;
      setState(() => _checkingVelock = false);
      final controller = ref.read(velockWizardSessionProvider.notifier);
      controller.expireIfNeeded();
      controller.authorizationInvalidated(
        session,
        VelockWizardAuthorizationProblem.invalid,
      );
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
    ref.read(velockWizardSessionProvider.notifier).expireIfNeeded();
    if (!identical(ref.read(velockWizardSessionProvider).session, session)) {
      return;
    }
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
          '你已在格间拒绝本次连接。已有数据不会改变，可随时重新授权。',
          "You declined this connection in Velock. Existing data is unchanged. You can allow access again whenever you are ready.",
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
          '格间已撤销本次授权。请重新允许 Sync 访问后再试。',
          "Velock revoked this authorization. Allow Sync access again, then retry.",
        ),
      ),
      _ => (
        syncText(context, '无法验证配对结果', "Could not verify pairing"),
        syncText(
          context,
          '无法确认这次授权，连接尚未建立。请返回格间重新允许访问。',
          "This authorization could not be confirmed. Return to Velock and allow access again.",
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
    VelockPairingControlResponse approval, {
    bool reuseSelection = false,
  }) async {
    if (_continuingSetup) return;
    _continuingSetup = true;
    try {
      if (!await _verifyCurrentApproval(session, approval)) return;
      final connections = (await ref.read(velockWizardConnectionsProvider)())
          .where((connection) => connection.status == ConnectionStatus.active)
          .toList(growable: false);
      if (!mounted || !_authorizationIsCurrent(session, approval)) return;
      if (connections.isEmpty) {
        ref.read(velockWizardSessionProvider.notifier).connectionMissing();
        showMessage(
          context,
          syncText(
            context,
            '接下来选择你的云端位置。如果授权过期，可直接重新授权，无需重新添加位置。',
            'Choose cloud storage next. If access expires, authorize again without adding your storage again.',
          ),
        );
        return;
      }
      // A connection is available: the approved pairing can proceed, so the
      // "还需要一个远端连接" banner must not keep the flow stuck.
      ref.read(velockWizardSessionProvider.notifier).connectionResolved();

      final selectedId = ref
          .read(velockWizardSessionProvider)
          .selectedConnectionId;
      final retained = reuseSelection
          ? connections.where((item) => item.id == selectedId).firstOrNull
          : null;
      final connection =
          retained ??
          (connections.length == 1
              ? connections.single
              : await _chooseVelockConnection(connections));
      if (connection == null ||
          !mounted ||
          !_authorizationIsCurrent(session, approval)) {
        return;
      }
      ref
          .read(velockWizardSessionProvider.notifier)
          .connectionSelected(connection.id);

      var remoteRootSegments = <String>[];
      final protocol = connection.protocol;
      if (protocol is WebDavProtocolModel) {
        final loader = ref.read(backupFolderLoaderProvider);
        final initialSegments = ref
            .read(velockWizardSessionProvider)
            .selectedRemoteRootSegments;
        final picked = await Navigator.of(context).push<List<String>>(
          CupertinoPageRoute(
            builder: (_) => BackupFolderPicker(
              connectionName: connection.name,
              basePath: _destinationFolderPath(protocol, const []),
              initialSegments: initialSegments,
              restoring: widget.restoring,
              loadFolders: (segments) =>
                  loader(protocol: protocol, relativeSegments: segments),
              createFolder: widget.restoring
                  ? null
                  : (segments, name) => ref.read(backupFolderCreatorProvider)(
                      protocol: protocol,
                      relativeSegments: segments,
                      name: name,
                    ),
            ),
          ),
        );
        if (!mounted || picked == null) return;
        // Retain the selected directory even if browsing outlasted the short
        // approval window. A new approval still verifies before any write.
        if (ref.read(velockWizardSessionProvider).selectedConnectionId !=
            connection.id) {
          return;
        }
        ref.read(velockWizardSessionProvider.notifier).folderSelected(picked);
        remoteRootSegments = picked;
        if (!await _verifyCurrentApproval(session, approval)) return;
      }
      final review = await _reviewVelockProfile(
        approval: approval,
        connection: connection,
        remoteRootSegments: remoteRootSegments,
      );
      if (review == null || !mounted) return;

      setState(() {
        _checkingVelock = true;
        _destinationError = null;
      });
      // A user may spend longer than the authorization lifetime in review.
      if (!await _verifyCurrentApproval(session, approval)) return;
      await ref
          .read(backupDestinationServiceProvider)
          .check(
            connectionId: connection.id,
            vaultId: approval.vaultId,
            trustedProducerIds:
                approval.trustedProducerIds ?? [approval.producerId],
            restoring: widget.restoring,
            remoteRootSegments: remoteRootSegments,
          );
      if (!mounted || !await _verifyCurrentApproval(session, approval)) return;
      final result = await ref
          .read(velockProfileFinalizerProvider)
          .finalize(
            session: session,
            approval: approval,
            connectionId: connection.id,
            remoteRootSegments: remoteRootSegments,
            displayName: review.displayName,
            backgroundPolicy: review.backgroundPolicy,
            userConfirmed: true,
          );
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      final accepted = ref
          .read(velockWizardSessionProvider.notifier)
          .profileFinalized(result, session: session, approval: approval);
      ref.read(profilesRevisionProvider.notifier).bump();
      if (!accepted) return;
      if (!result.pairingAcknowledged) {
        showMessage(
          context,
          syncText(
            context,
            '连接已保存，还有一步确认尚未完成。请在本页重试，暂未开始传输。',
            "The connection was saved, but one confirmation is still pending. Retry here; transfer has not started yet.",
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
      // Setup is finished: return to the tabbed home, not a detached detail
      // route with no navigation history.
      context.go('/');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      logw('Velock profile finalization failed: ${error.runtimeType}: $error');
      if (error is VelockProfileFinalizationException &&
          error.code == 'invalid_pairing_response') {
        final controller = ref.read(velockWizardSessionProvider.notifier);
        controller.expireIfNeeded();
        controller.authorizationInvalidated(
          session,
          VelockWizardAuthorizationProblem.invalid,
        );
        return;
      }
      final message = switch (error) {
        BackupDestinationException(code: 'backup_not_found') => syncText(
          context,
          '这里没有找到原账号的备份，未创建连接，也没有向云端写入数据。请确认已恢复原账号，并选择原来的保存位置。',
          'No backup for the original account was found here. No connection was created and nothing was written. Recover the original account and select its original cloud location.',
        ),
        BackupDestinationException() => syncText(
          context,
          '这个位置未通过读写检查，尚未开始备份。请检查权限、空间或网络后再试。',
          'This location did not pass the storage check. Backup has not started. Check permissions, available space and the network.',
        ),
        SyncFailureException() => backupFailureMessage(
          context,
          error.syncFailure.errorCode,
        ),
        VelockProfileFinalizationException(:final code) => switch (code) {
          'duplicate_pairing' => syncText(
            context,
            '这个格间账号已经连接，无需重复设置。请从首页查看已有备份。',
            "This Velock account is already connected. Continue from the existing backup on the home screen.",
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
            '无法读取格间的账号名称，请打开格间确认账号后再试。',
            "Could not read the Velock account name. Open Velock to check your account, then retry.",
          ),
          'confirmation_required' => syncText(
            context,
            '你尚未确认本次设置，连接没有建立。',
            "Setup was not confirmed. No connection was created.",
          ),
          _ => syncText(
            context,
            '连接尚未完成，请返回重试。已有云端数据不会因此删除。',
            "The connection did not finish. Go back and retry. This does not delete existing cloud data.",
          ),
        },
        _ => syncText(
          context,
          '设置尚未完成，请重试。若连接已经保存，可在首页继续。',
          'Setup did not finish. Please retry. If a connection was saved, continue from the home screen.',
        ),
      };
      setState(() => _destinationError = message);
    } finally {
      _continuingSetup = false;
      if (mounted && _checkingVelock) setState(() => _checkingVelock = false);
    }
  }

  Future<ConnectionModel?> _chooseVelockConnection(
    List<ConnectionModel> connections,
  ) => showAdaptiveActionSheet<ConnectionModel>(
    context: context,
    title: syncText(
      context,
      widget.restoring ? '从哪里恢复？' : '保存到哪里？',
      widget.restoring ? 'Where is your backup?' : 'Where should we save?',
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
    required List<String> remoteRootSegments,
  }) async {
    final defaults =
        (await ref.read(syncSettingsServiceProvider).load()).settings;
    var background = defaults.backgroundEnabled;
    if (!mounted) return null;
    return showAdaptiveForm<_VelockProfileReview>(
      context: context,
      title: syncText(
        context,
        widget.restoring ? '确认恢复位置' : '准备开始备份',
        widget.restoring ? 'Confirm backup location' : 'Ready to back up',
      ),
      barrierDismissible: false,
      builder: (context, setDialogState) => AdaptiveFormSpec<_VelockProfileReview>(
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                approval.vaultDisplayName,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                syncText(
                  context,
                  '${widget.restoring ? '从此处恢复' : '保存到'}：${connection.name}',
                  '${widget.restoring ? 'Restore from' : 'Save to'}: ${connection.name}',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                connection.protocol.targetLabel,
                style: TextStyle(
                  fontSize: 13,
                  color: context.appSecondaryLabel,
                ),
              ),
              if (connection.protocol
                  case final WebDavProtocolModel protocol) ...[
                const SizedBox(height: 8),
                Text(
                  syncText(
                    context,
                    '文件夹：${_destinationFolderPath(protocol, remoteRootSegments)}',
                    'Folder: ${_destinationFolderPath(protocol, remoteRootSegments)}',
                  ),
                  key: const Key('velock-review-folder'),
                ),
              ],
              const SizedBox(height: 18),
              if (!widget.restoring)
                AdaptiveSwitchRow(
                  key: const Key('velock-background-enabled'),
                  title: syncText(context, '允许自动备份', 'Allow automatic backup'),
                  value: background,
                  onChanged: (value) =>
                      setDialogState(() => background = value),
                ),
              const SizedBox(height: 8),
              Text(
                syncText(
                  context,
                  widget.restoring
                      ? '先检查这里是否有原账号的备份。数据下载后，还需在格间解锁完成恢复。'
                      : '先检查云端能否安全读写，再开始备份。自动备份仅在 Wi-Fi 和系统允许时运行，之后可在管理中调整。',
                  widget.restoring
                      ? 'We will first look for the original account’s backup. Unlock Velock after downloading to finish restoring.'
                      : 'We check safe cloud access before starting. Automatic backup uses Wi-Fi when allowed by the system. Change this later in settings.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          AdaptiveAlertAction<_VelockProfileReview>(
            label: syncText(context, '返回', 'Back'),
          ),
          AdaptiveAlertAction<_VelockProfileReview>(
            key: const Key('finalize-velock-profile'),
            label: syncText(
              context,
              widget.restoring ? '查找并恢复' : '开始备份',
              widget.restoring ? 'Find my backup' : 'Start backup',
            ),
            isDefault: true,
            emphasized: true,
            value: _VelockProfileReview(
              displayName: approval.vaultDisplayName,
              backgroundPolicy: SyncProfileBackgroundPolicy(
                enabled: !widget.restoring && background,
                allowCellular: false,
                requiresCharging: defaults.defaultRequiresCharging,
                cellularMaxTransferBytes:
                    defaults.defaultCellularMaxTransferBytes,
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
    final existing = ref.watch(velockExistingProfilesProvider);
    return AdaptiveScaffold(
      title: syncText(
        context,
        widget.restoring ? '恢复格间数据' : '开始格间备份',
        widget.restoring ? 'Restore Velock data' : 'Set up Velock backup',
      ),
      body: existing.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (_, _) => AdaptiveErrorState(
          message: syncText(
            context,
            '暂时无法检查已有连接。',
            'Could not check existing connections.',
          ),
          onRetry: () => ref.invalidate(velockExistingProfilesProvider),
        ),
        data: (profiles) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            if (profiles.isNotEmpty && wizard.finalization == null)
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(context, '已连接格间', 'Velock is connected'),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      syncText(
                        context,
                        '不需要重复设置。查看现有备份即可继续。更换云端前，请保留原来的完整备份。',
                        'No need to set up again. Continue from your existing backup. Keep the original complete backup before changing storage.',
                      ),
                    ),
                    const SizedBox(height: 20),
                    BackupActionButton(
                      label: syncText(context, '查看备份', 'View backup'),
                      onPressed: () => context.push(
                        '/sync-profiles/${profiles.first.profileId}',
                      ),
                    ),
                  ],
                ),
              )
            else if (wizard.finalization case final result?)
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(
                        context,
                        '连接已保存，尚未完成传输',
                        'Connection saved. Transfer not complete.',
                      ),
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      syncText(
                        context,
                        '授权确认还需要完成一次检查，已有数据不会被删除。',
                        'One authorization check remains. Existing data will not be deleted.',
                      ),
                    ),
                    const SizedBox(height: 20),
                    BackupActionButton(
                      key: const Key('retry-velock-acknowledgement'),
                      label: syncText(context, '继续完成设置', 'Finish setup'),
                      onPressed: _checkingVelock
                          ? null
                          : _retryVelockAcknowledgement,
                    ),
                    TextButton(
                      onPressed: () => context.push(
                        '/sync-profiles/${result.profile.profileId}',
                      ),
                      child: Text(syncText(context, '查看连接', 'View connection')),
                    ),
                  ],
                ),
              )
            else ...[
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(
                        context,
                        wizard.authorizationProblem ==
                                VelockWizardAuthorizationProblem.expired
                            ? '连接授权已过期'
                            : wizard.authorizationProblem != null
                            ? '需要重新授权'
                            : wizard.approval == null
                            ? '1 · 连接格间'
                            : '1 · 格间已允许连接',
                        wizard.authorizationProblem ==
                                VelockWizardAuthorizationProblem.expired
                            ? 'Connection approval expired'
                            : wizard.authorizationProblem != null
                            ? 'Authorize access again'
                            : wizard.approval == null
                            ? '1 · Connect Velock'
                            : '1 · Velock access allowed',
                      ),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      syncText(
                        context,
                        wizard.authorizationProblem != null
                            ? '为了保护你的数据，需要在格间重新确认一次。已添加的云端位置会保留，不用重新填写。'
                            : wizard.approval != null
                            ? '你的数据仍由格间加密和解密。下一步选择云端位置。'
                            : widget.restoring
                            ? '在格间恢复原账号后，允许 Sync 下载它的云端备份。'
                            : '打开并解锁格间，在「云备份」中允许备份。首次使用请保存好恢复卡。',
                        wizard.authorizationProblem != null
                            ? 'Confirm access in Velock again to protect your data. Your saved cloud locations are kept; no need to enter them again.'
                            : wizard.approval != null
                            ? 'Velock keeps control of encryption. Choose cloud storage next.'
                            : widget.restoring
                            ? 'Recover the original account in Velock, then allow Sync to download its backup.'
                            : 'Open and unlock Velock, then allow Cloud backup. Save a recovery card the first time.',
                      ),
                    ),
                    if (wizard.approval == null) ...[
                      const SizedBox(height: 22),
                      BackupActionButton(
                        key: Key(
                          wizard.authorizationProblem != null
                              ? 'renew-velock-authorization'
                              : 'inspect-velock-readiness',
                        ),
                        label: syncText(
                          context,
                          _checkingVelock
                              ? '正在检查…'
                              : wizard.authorizationProblem != null
                              ? '重新授权'
                              : wizard.session == null
                              ? '连接格间'
                              : '已在格间允许，继续',
                          _checkingVelock
                              ? 'Checking…'
                              : wizard.authorizationProblem != null
                              ? 'Authorize again'
                              : wizard.session == null
                              ? 'Connect Velock'
                              : 'I allowed access. Continue',
                        ),
                        onPressed: _checkingVelock
                            ? null
                            : wizard.session == null
                            ? _inspectVelock
                            : () =>
                                  _inspectPendingVelockPairing(wizard.session!),
                      ),
                      if (wizard.session != null)
                        TextButton(
                          onPressed: _checkingVelock
                              ? null
                              : () => _reopenVelockPairing(wizard.session!),
                          child: Text(
                            syncText(context, '重新打开格间', 'Open Velock again'),
                          ),
                        ),
                      if (wizard.authorizationProblem != null)
                        TextButton(
                          key: const Key('cancel-velock-reauthorization'),
                          onPressed: _checkingVelock
                              ? null
                              : () => ref
                                    .read(velockWizardSessionProvider.notifier)
                                    .reset(),
                          child: Text(
                            syncText(context, '取消本次设置', 'Cancel setup'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (wizard.approval != null)
                BackupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        syncText(
                          context,
                          widget.restoring ? '2 · 找到原来的备份' : '2 · 选择云端位置',
                          widget.restoring
                              ? '2 · Find your existing backup'
                              : '2 · Choose cloud storage',
                        ),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        syncText(
                          context,
                          widget.restoring
                              ? '请选择原来保存格间备份的网盘、NAS 或其他 WebDAV 服务，不要使用空目录。'
                              : '使用自己的网盘、NAS 或其他 WebDAV 服务，Sync 会先检查它是否可以安全保存数据。',
                          widget.restoring
                              ? 'Choose the cloud folder, NAS or other WebDAV service that holds your original Velock backup, not an empty folder.'
                              : 'Use your own cloud drive, NAS or other WebDAV service. Sync checks safe storage access first.',
                        ),
                      ),
                      const SizedBox(height: 22),
                      if (_destinationError != null) ...[
                        Text(
                          _destinationError!,
                          key: const Key('backup-destination-error'),
                        ),
                        const SizedBox(height: 14),
                      ],
                      BackupActionButton(
                        key: const Key('continue-velock-setup'),
                        label: syncText(
                          context,
                          _checkingVelock
                              ? '正在检查云端…'
                              : _destinationError != null
                              ? '重新选择文件夹'
                              : '选择已添加的位置',
                          _checkingVelock
                              ? 'Checking storage…'
                              : _destinationError != null
                              ? 'Choose another folder'
                              : 'Choose an existing location',
                        ),
                        busy: _checkingVelock,
                        onPressed: _checkingVelock
                            ? null
                            : () => _continueVelockProfile(
                                wizard.session!,
                                wizard.approval!,
                              ),
                      ),
                      const SizedBox(height: 10),
                      BackupActionButton(
                        key: const Key('go-create-connection'),
                        secondary: true,
                        label: syncText(context, '添加云端位置', 'Add cloud storage'),
                        onPressed: _checkingVelock
                            ? null
                            : () {
                                ref
                                    .read(connectionCreationProvider.notifier)
                                    .prepareNewConnection(
                                      name: syncText(
                                        context,
                                        '我的云端',
                                        'My cloud',
                                      ),
                                      source: syncText(context, '格间', 'Velock'),
                                      target: null,
                                    );
                                ref
                                    .read(velockWizardSessionProvider.notifier)
                                    .connectionMissing();
                                final returnTo =
                                    '${AppRoutes.velockDatasetWizard.path}${widget.restoring ? '?intent=restore' : ''}';
                                context.push(
                                  '${AppRoutes.protocols.path}?returnTo=${Uri.encodeQueryComponent(returnTo)}',
                                );
                              },
                      ),
                      TextButton(
                        key: const Key('abandon-velock-pairing'),
                        onPressed: _checkingVelock
                            ? null
                            : () => ref
                                  .read(velockWizardSessionProvider.notifier)
                                  .reset(),
                        child: Text(
                          syncText(context, '取消本次设置', 'Cancel this setup'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VelockProfileReview {
  const _VelockProfileReview({
    required this.displayName,
    required this.backgroundPolicy,
  });

  final String displayName;
  final SyncProfileBackgroundPolicy backgroundPolicy;
}

String _destinationFolderPath(
  WebDavProtocolModel protocol,
  List<String> relativeSegments,
) =>
    '/${[...RemoteObjectStoreFactory.webDavUri(protocol).pathSegments.where((s) => s.isNotEmpty), ...relativeSegments].join('/')}';
