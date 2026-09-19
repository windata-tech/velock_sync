import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'selected_folder_empty_state.dart';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_profile_provisioner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile_executor.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_core/engine/initial_sync_assessment.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/crypto/vault_recovery_package.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

enum _FolderEntryAction { create, join }

enum _ProfileRowAction {
  syncNow,
  wifi,
  cellular10MiB,
  cellular50MiB,
  cellular100MiB,
  allowBattery,
  chargingOnly,
  exportRecovery,
  cleanupStaging,
  pause,
  resume,
  remove,
}

enum _BackgroundNetworkChoice {
  wifi,
  cellular10MiB,
  cellular50MiB,
  cellular100MiB,
}

enum _ProfileLifecycleAction { exportRecovery, pause, resume, remove }

/// Product entry point for Generic Vault selected-folder profiles. A profile
/// keeps only secure key references and a user-authorised folder reference.
class SelectedFolderProfiles extends HookConsumerWidget {
  const SelectedFolderProfiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revision = useState(0);
    final profiles = useMemoized(
      () => ref.read(selectedFolderProfilesProvider).list(),
      [revision.value],
    );
    final connections = ref.watch(connectionsProvider);
    final busy = useState(false);

    Future<void> createProfile() async {
      final available =
          connections.asData?.value.toList() ?? const <ConnectionModel>[];
      if (available.isEmpty) {
        _showMessage(context, '请先在“连接服务”中添加远端连接。');
        return;
      }
      final connectionId = await _chooseConnection(
        context,
        available,
        message: '用于新建同步文件夹',
      );
      if (connectionId == null || !context.mounted) return;
      busy.value = true;
      try {
        final profile =
            await SelectedFolderProfileProvisioner(
              authorizer: NativeFolderAccessAuthorizer(),
              profiles: ref.read(selectedFolderProfilesProvider),
              database: ref.read(syncStateDatabaseProvider),
              vaultKeys: ref.read(vaultKeyStoreProvider),
              signingKeys: ref.read(deviceSigningKeyStoreProvider),
            ).create(
              displayName: '同步文件夹',
              connectionId: connectionId,
              deviceId: await _deviceId(ref.read(localDataManagerProvider)),
              backgroundPolicy: _backgroundPolicyFrom(
                await LocalSyncGlobalSettingsStore(
                  ref.read(localDataManagerProvider),
                ).read(),
              ),
            );
        if (!context.mounted) return;
        if (profile == null) {
          _showMessage(context, '未选择文件夹。');
        } else {
          revision.value++;
          _showMessage(context, '已创建“${profile.displayName}”。');
        }
      } on Object {
        if (context.mounted) _showMessage(context, '创建同步文件夹失败。');
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> joinProfile() async {
      final available =
          connections.asData?.value.toList() ?? const <ConnectionModel>[];
      if (available.isEmpty) {
        _showMessage(context, '请先在“连接服务”中添加已有同步空间的远端连接。');
        return;
      }
      final connectionId = await _chooseConnection(
        context,
        available,
        message: '用于加入已有同步空间',
      );
      if (connectionId == null || !context.mounted) return;
      final recovery = await _requestRecoveryInput(context);
      if (recovery == null || !context.mounted) return;
      busy.value = true;
      String? rootKeyRef;
      try {
        final keyStore = ref.read(vaultKeyStoreProvider);
        final recovered = await GenericVaultRecoveryService(keyStore)
            .importBundle(
              recoveryPackage: recovery.recoveryPackage,
              passphrase: recovery.passphrase,
              expectedVaultId: recovery.vaultId,
            );
        rootKeyRef = recovered.rootKeyRef;
        final profile =
            await SelectedFolderProfileProvisioner(
              authorizer: NativeFolderAccessAuthorizer(),
              profiles: ref.read(selectedFolderProfilesProvider),
              database: ref.read(syncStateDatabaseProvider),
              vaultKeys: keyStore,
              signingKeys: ref.read(deviceSigningKeyStoreProvider),
            ).createRecovered(
              displayName: '已恢复的同步文件夹',
              connectionId: connectionId,
              deviceId: await _deviceId(ref.read(localDataManagerProvider)),
              vaultId: recovery.vaultId,
              rootKeyRef: rootKeyRef,
              recoveredTrustedDevices: recovered.trustedDevices,
              backgroundPolicy: _backgroundPolicyFrom(
                await LocalSyncGlobalSettingsStore(
                  ref.read(localDataManagerProvider),
                ).read(),
              ),
            );
        if (profile == null) {
          await keyStore.delete(rootKeyRef);
          rootKeyRef = null;
          if (context.mounted) _showMessage(context, '未选择文件夹。');
          return;
        }
        rootKeyRef = null;
        if (context.mounted) {
          revision.value++;
          _showMessage(context, '已加入“${profile.displayName}”；首次同步会验证远端 Vault。');
        }
      } on Object {
        if (rootKeyRef != null) {
          await ref.read(vaultKeyStoreProvider).delete(rootKeyRef);
        }
        if (context.mounted) {
          _showMessage(context, '恢复失败；请检查 Vault ID、恢复包、口令和远端连接。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> exportRecoveryPackage(
      SelectedFolderSyncProfile profile,
    ) async {
      final passphrase = await _requestNewRecoveryPassphrase(context);
      if (passphrase == null || !context.mounted) return;
      busy.value = true;
      try {
        final recoveryPackage =
            await GenericVaultRecoveryService(
              ref.read(vaultKeyStoreProvider),
            ).exportBundle(
              rootKeyRef: profile.rootKeyRef,
              vaultId: profile.vaultId,
              trustedDevices: await ref
                  .read(syncStateDatabaseProvider)
                  .readTrustedDevicePublicKeys(vaultId: profile.vaultId),
              passphrase: passphrase,
            );
        if (context.mounted) {
          await _showRecoveryPackage(context, recoveryPackage);
        }
      } on Object {
        if (context.mounted) {
          _showMessage(context, '无法生成恢复包；请检查本机密钥状态。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> runProfile(SelectedFolderSyncProfile profile) async {
      busy.value = true;
      try {
        final support = await getApplicationSupportDirectory();
        final service = SelectedFolderSyncService(
          database: ref.read(syncStateDatabaseProvider),
          profiles: ref.read(selectedFolderProfilesProvider),
          connections: ref.read(connectionRepositoryProvider),
          vaultKeys: ref.read(vaultKeyStoreProvider),
          signingKeys: ref.read(deviceSigningKeyStoreProvider),
          stagingRoot: Directory('${support.path}/staging'),
        );
        if (await ref
                .read(syncStateDatabaseProvider)
                .latestSyncRun(profile.profileId) ==
            null) {
          final assessment = await service.inspectInitialSync(
            profile.profileId,
          );
          if (!context.mounted ||
              !await _confirmInitialSync(context, assessment)) {
            return;
          }
        }
        final dispatcher = SyncProfileDispatcher(
          profiles: SyncProfileRepository(ref.read(syncStateDatabaseProvider)),
          executors: [SelectedFolderSyncProfileExecutor(service)],
        );
        final dispatch = await dispatcher.dispatch(profile.profileId);
        if (!context.mounted) return;
        if (dispatch.didFail) {
          throw dispatch.error!;
        }
        if (!dispatch.didRun || dispatch.run == null) {
          _showMessage(context, '同步暂不可运行；请检查配置、授权或同步状态。');
          return;
        }
        revision.value++;
        _showMessage(
          context,
          '同步完成：上传 ${dispatch.run!.upload.publishedBatchCount} 批，下载 ${dispatch.run!.download.importedBatchCount} 批。',
        );
      } on Object catch (error, stackTrace) {
        final code = error is SyncFailureException
            ? error.syncFailure.errorCode
            : error.runtimeType.toString();
        loge('Selected Folder sync failed: $code', stackTrace: stackTrace);
        if (context.mounted) {
          _showMessage(context, '同步失败；请检查连接、授权与网络。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> updateBackgroundSchedule(
      SelectedFolderSyncProfileRepository repository,
    ) async {
      final backgroundProfiles = (await repository.list())
          .where(
            (other) =>
                other.state == SelectedFolderProfileState.active &&
                other.backgroundEnabled,
          )
          .toList(growable: false);
      final scheduler = BackgroundSyncScheduler();
      if (backgroundProfiles.isEmpty) {
        await scheduler.disable();
        return;
      }
      await scheduler.enable(
        allowCellular: backgroundProfiles.any(
          (other) => other.backgroundAllowCellular,
        ),
        // A shared platform task can request this constraint only when every
        // enabled profile wants it. Each profile is checked again at runtime.
        requiresCharging: backgroundProfiles.every(
          (other) => other.backgroundRequiresCharging,
        ),
      );
    }

    Future<void> setBackground(
      SelectedFolderSyncProfile profile,
      bool enabled,
    ) async {
      busy.value = true;
      try {
        final repository = ref.read(selectedFolderProfilesProvider);
        await repository.save(profile.copyWith(backgroundEnabled: enabled));
        await updateBackgroundSchedule(repository);
        revision.value++;
      } on Object {
        if (context.mounted) {
          _showMessage(context, '无法更新后台同步设置。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> cleanupStaging(SelectedFolderSyncProfile profile) async {
      busy.value = true;
      try {
        final support = await getApplicationSupportDirectory();
        final result =
            await StagingSpaceManager(
              ref.read(syncStateDatabaseProvider),
            ).safelyCleanup(
              profileId: profile.profileId,
              profileStagingRoot: Directory(
                '${support.path}/staging/${profile.profileId}',
              ),
            );
        if (context.mounted) {
          revision.value++;
          _showMessage(
            context,
            '已安全清理 ${AppFormat.bytes(result.freedBytes)}；保留 ${result.preservedRecoverableBatchCount} 个可恢复批次。',
          );
        }
      } on StagingMaintenanceBusyException {
        if (context.mounted) {
          _showMessage(context, '当前同步正在运行，暂不能清理暂存空间。');
        }
      } on Object {
        if (context.mounted) _showMessage(context, '无法清理暂存空间。');
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> setBackgroundNetwork(
      SelectedFolderSyncProfile profile,
      _BackgroundNetworkChoice choice,
    ) async {
      busy.value = true;
      try {
        final repository = ref.read(selectedFolderProfilesProvider);
        final allowCellular = choice != _BackgroundNetworkChoice.wifi;
        final cellularMaxTransferBytes = switch (choice) {
          _BackgroundNetworkChoice.wifi =>
            profile.backgroundCellularMaxTransferBytes,
          _BackgroundNetworkChoice.cellular10MiB => 10 * 1024 * 1024,
          _BackgroundNetworkChoice.cellular50MiB => 50 * 1024 * 1024,
          _BackgroundNetworkChoice.cellular100MiB => 100 * 1024 * 1024,
        };
        await repository.save(
          profile.copyWith(
            backgroundAllowCellular: allowCellular,
            backgroundCellularMaxTransferBytes: cellularMaxTransferBytes,
          ),
        );
        await updateBackgroundSchedule(repository);
        revision.value++;
      } on Object {
        if (context.mounted) {
          _showMessage(context, '无法更新后台网络设置。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> setBackgroundCharging(
      SelectedFolderSyncProfile profile,
      bool requiresCharging,
    ) async {
      busy.value = true;
      try {
        final repository = ref.read(selectedFolderProfilesProvider);
        await repository.save(
          profile.copyWith(backgroundRequiresCharging: requiresCharging),
        );
        await updateBackgroundSchedule(repository);
        revision.value++;
      } on Object {
        if (context.mounted) {
          _showMessage(context, '无法更新后台电源设置。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> changeProfileLifecycle(
      SelectedFolderSyncProfile profile,
      _ProfileLifecycleAction action,
    ) async {
      if (action == _ProfileLifecycleAction.remove &&
          !await _confirmProfileRemoval(context, profile.displayName)) {
        return;
      }
      busy.value = true;
      try {
        final repository = ref.read(selectedFolderProfilesProvider);
        switch (action) {
          case _ProfileLifecycleAction.exportRecovery:
            // Recovery export is handled directly by the popup callback so it
            // can present its passphrase dialog before lifecycle work begins.
            return;
          case _ProfileLifecycleAction.pause:
            await repository.pause(profile.profileId);
          case _ProfileLifecycleAction.resume:
            await repository.resume(profile.profileId);
          case _ProfileLifecycleAction.remove:
            final database = ref.read(syncStateDatabaseProvider);
            if (await database.hasRunningSyncRun(profile.profileId)) {
              throw const _ProfileSyncRunningException();
            }
            await repository.remove(profile.profileId);
            await ref.read(vaultKeyStoreProvider).delete(profile.rootKeyRef);
            await ref
                .read(deviceSigningKeyStoreProvider)
                .delete(profile.signingKeyRef);
        }
        await updateBackgroundSchedule(repository);
        revision.value++;
      } on _ProfileSyncRunningException {
        if (context.mounted) {
          _showMessage(context, '同步正在进行；完成后才能移除此配置。');
        }
      } on Object {
        if (context.mounted) {
          _showMessage(context, '无法更新同步配置状态。');
        }
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    return PlatformScaffold(
      iosContentPadding:
          Theme.of(context).platform == TargetPlatform.iOS ||
          Theme.of(context).platform == TargetPlatform.macOS,
      appBar: WDAppBar(
        title: const Text('同步文件夹'),
        trailingActions: [
          AdaptiveActionMenu<_FolderEntryAction>(
            tooltip: '更多操作',
            enabled: !busy.value,
            icon: Icon(
              adaptiveIcon(
                context,
                material: Icons.more_vert,
                cupertino: CupertinoIcons.ellipsis,
              ),
            ),
            items: const [
              AdaptiveActionItem<_FolderEntryAction>(
                value: _FolderEntryAction.create,
                label: '新建同步文件夹',
                icon: Icons.create_new_folder_outlined,
              ),
              AdaptiveActionItem<_FolderEntryAction>(
                value: _FolderEntryAction.join,
                label: '通过恢复包加入已有空间',
                icon: Icons.login,
              ),
            ],
            onSelected: (action) {
              switch (action) {
                case _FolderEntryAction.create:
                  createProfile();
                case _FolderEntryAction.join:
                  joinProfile();
              }
            },
          ),
        ],
      ),
      body: FutureBuilder<List<SelectedFolderSyncProfile>>(
        future: profiles,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: PlatformCircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('无法读取同步配置。'));
          }
          final values = snapshot.data!;
          if (values.isEmpty) {
            return SelectedFolderEmptyState(
              onCreate: busy.value ? null : createProfile,
              onRecover: busy.value ? null : joinProfile,
            );
          }
          return ListView.builder(
            itemCount: values.length + 1,
            itemBuilder: (context, index) {
              if (index == values.length) {
                return _FolderProfileActions(
                  onCreate: busy.value ? null : createProfile,
                  onRecover: busy.value ? null : joinProfile,
                );
              }
              final profile = values[index];
              return Material(
                type: MaterialType.transparency,
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(profile.displayName),
                  onTap: () =>
                      context.push('/sync-profiles/${profile.profileId}'),
                  subtitle: _ProfileActivitySummary(
                    profile: profile,
                    database: ref.read(syncStateDatabaseProvider),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch.adaptive(
                        value: profile.backgroundEnabled,
                        onChanged:
                            busy.value ||
                                profile.state ==
                                    SelectedFolderProfileState.paused ||
                                !BackgroundSyncScheduler.isSupported
                            ? null
                            : (enabled) => setBackground(profile, enabled),
                      ),
                      AdaptiveActionMenu<_ProfileRowAction>(
                        tooltip: '同步配置操作',
                        enabled: !busy.value,
                        icon: const Icon(Icons.more_horiz_rounded),
                        items: [
                          AdaptiveActionItem(
                            value: _ProfileRowAction.syncNow,
                            label: '立即同步',
                            icon: Icons.sync,
                            enabled:
                                profile.state ==
                                SelectedFolderProfileState.active,
                          ),
                          AdaptiveActionItem(
                            value: _ProfileRowAction.wifi,
                            label: '仅 Wi-Fi',
                            icon: Icons.wifi,
                            enabled: _canConfigureBackground(profile),
                          ),
                          AdaptiveActionItem(
                            value: _ProfileRowAction.cellular10MiB,
                            label: '蜂窝网络，单文件最多 10 MB',
                            icon: Icons.network_cell,
                            enabled: _canConfigureBackground(profile),
                          ),
                          AdaptiveActionItem(
                            value: _ProfileRowAction.cellular50MiB,
                            label: '蜂窝网络，单文件最多 50 MB',
                            icon: Icons.network_cell,
                            enabled: _canConfigureBackground(profile),
                          ),
                          AdaptiveActionItem(
                            value: _ProfileRowAction.cellular100MiB,
                            label: '蜂窝网络，单文件最多 100 MB',
                            icon: Icons.network_cell,
                            enabled: _canConfigureBackground(profile),
                          ),
                          AdaptiveActionItem(
                            value: _ProfileRowAction.allowBattery,
                            label: '允许使用电池',
                            icon: Icons.battery_std,
                            enabled: _canConfigureBackground(profile),
                          ),
                          AdaptiveActionItem(
                            value: _ProfileRowAction.chargingOnly,
                            label: '仅充电时同步',
                            icon: Icons.battery_charging_full,
                            enabled: _canConfigureBackground(profile),
                          ),
                          const AdaptiveActionItem(
                            value: _ProfileRowAction.exportRecovery,
                            label: '生成恢复包',
                            icon: Icons.key_outlined,
                          ),
                          const AdaptiveActionItem(
                            value: _ProfileRowAction.cleanupStaging,
                            label: '清理暂存空间',
                            icon: Icons.cleaning_services_outlined,
                          ),
                          if (profile.state ==
                              SelectedFolderProfileState.active)
                            const AdaptiveActionItem(
                              value: _ProfileRowAction.pause,
                              label: '暂停同步',
                              icon: Icons.pause,
                            )
                          else
                            const AdaptiveActionItem(
                              value: _ProfileRowAction.resume,
                              label: '继续同步',
                              icon: Icons.play_arrow,
                            ),
                          const AdaptiveActionItem(
                            value: _ProfileRowAction.remove,
                            label: '移除此同步配置',
                            icon: Icons.delete_outline_rounded,
                            isDestructive: true,
                          ),
                        ],
                        onSelected: (action) => _handleProfileRowAction(
                          profile,
                          action,
                          setBackgroundNetwork: setBackgroundNetwork,
                          setBackgroundCharging: setBackgroundCharging,
                          exportRecoveryPackage: exportRecoveryPackage,
                          cleanupStaging: cleanupStaging,
                          changeProfileLifecycle: changeProfileLifecycle,
                          runProfile: runProfile,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _RecoveryInput {
  const _RecoveryInput({
    required this.vaultId,
    required this.recoveryPackage,
    required this.passphrase,
  });

  final String vaultId;
  final String recoveryPackage;
  final String passphrase;
}

class _ProfileSyncRunningException implements Exception {
  const _ProfileSyncRunningException();
}

class _ProfileActivitySummary extends StatelessWidget {
  const _ProfileActivitySummary({
    required this.profile,
    required this.database,
  });

  final SelectedFolderSyncProfile profile;
  final SyncStateDatabase database;

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<SyncProfileActivitySummary>(
    future: database.readSyncProfileActivity(profile.profileId),
    builder: (context, snapshot) {
      final location = switch (profile.accessKind) {
        FolderAccessKind.androidDocumentTree => 'Android 系统授权目录',
        FolderAccessKind.appleSecurityScopedBookmark => 'iOS 系统授权目录',
        FolderAccessKind.localPath => profile.rootPath,
      };
      if (!snapshot.hasData) return Text(location, maxLines: 2);
      final activity = snapshot.requireData;
      final run = activity.latestRun;
      final runText = profile.state == SelectedFolderProfileState.paused
          ? '已暂停'
          : switch (run?.state) {
              null => '尚未同步',
              'running' => '正在同步',
              'completed' => '最近成功：${_formatRunTime(run!.completedAt)}',
              'failed' => '最近失败：${run!.errorCode ?? '未知错误'}',
              _ => '同步状态：${run!.state}',
            };
      final background = profile.backgroundEnabled
          ? '后台：${profile.backgroundAllowCellular ? '蜂窝网络单文件最多 ${AppFormat.bytes(profile.backgroundCellularMaxTransferBytes)}' : '仅 Wi-Fi'}${profile.backgroundRequiresCharging ? '，仅充电时' : ''}'
          : '后台未启用';
      final nextCondition = profile.state == SelectedFolderProfileState.paused
          ? '下次：恢复后手动或等待触发'
          : profile.backgroundEnabled
          ? '下次：系统允许且${profile.backgroundAllowCellular ? '联网' : '连入 Wi-Fi'}${profile.backgroundRequiresCharging ? '并正在充电' : ''}'
          : '下次：手动同步';
      final transferred = activity.transferredBytes == 0
          ? ''
          : '，已传 ${AppFormat.bytes(activity.transferredBytes)}';
      return FutureBuilder<StagingSpaceSummary>(
        future: _readStagingSpace(profile, database),
        builder: (context, stagingSnapshot) {
          final staging = stagingSnapshot.hasData
              ? ' · 暂存 ${AppFormat.bytes(stagingSnapshot.requireData.totalBytes)}'
              : '';
          return Text(
            '$runText$transferred\n待上传 ${activity.pendingUploadCount}，待下载 ${activity.pendingDownloadCount}，冲突 ${activity.unresolvedConflictCount}\n$background · $nextCondition · $location$staging',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          );
        },
      );
    },
  );
}

String _formatRunTime(DateTime? value) {
  if (value == null) return '刚刚';
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

Future<StagingSpaceSummary> _readStagingSpace(
  SelectedFolderSyncProfile profile,
  SyncStateDatabase database,
) async {
  final support = await getApplicationSupportDirectory();
  return StagingSpaceManager(
    database,
  ).inspect(Directory('${support.path}/staging/${profile.profileId}'));
}

Future<String?> _chooseConnection(
  BuildContext context,
  List<ConnectionModel> connections, {
  required String message,
}) => showAdaptiveActionSheet<String>(
  context: context,
  title: '选择远端连接',
  message: message,
  actions: [
    for (final connection in connections)
      AdaptiveAction<String>(
        label: connection.name,
        caption: connection.protocol.targetLabel,
        value: connection.id,
      ),
  ],
);

Future<bool> _confirmInitialSync(
  BuildContext context,
  InitialSyncAssessment assessment,
) {
  final (title, details) = switch (assessment.remoteState) {
    InitialSyncRemoteState.empty => (
      '确认首次同步',
      '远端同步位置为空。应用会分批上传当前文件夹的基线，不会在本地复制完整数据集。',
    ),
    InitialSyncRemoteState.expectedVault => (
      '确认加入已有同步空间',
      '远端已存在此 Vault。应用会先验证协议并下载可用 checkpoint 与后续增量，然后执行本地合并。',
    ),
    InitialSyncRemoteState.unrelatedContent => (
      '远端位置包含其他内容',
      '所选位置并非空且未发现此 Vault。继续会在其中创建新的独立同步空间；请确认不会与已有数据混淆。',
    ),
  };
  return showAdaptiveConfirmation(
    context,
    title: title,
    message: details,
    confirmLabel: '确认并同步',
  );
}

Future<bool> _confirmProfileRemoval(BuildContext context, String displayName) =>
    showAdaptiveConfirmation(
      context,
      title: '移除同步配置？',
      message: '“$displayName”将停止同步，并从本机删除此配置使用的密钥引用。远端同步空间和文件不会被删除。',
      confirmLabel: '移除',
      isDestructive: true,
    );

Future<_RecoveryInput?> _requestRecoveryInput(BuildContext context) async {
  final values = await showAdaptiveTextInputs(
    context: context,
    title: '加入已有同步空间',
    message: '输入恢复包与口令，继续后选择本机文件夹。',
    inputs: const [
      AdaptiveTextInput(label: 'Vault ID', placeholder: 'Vault ID'),
      AdaptiveTextInput(
        label: '恢复包（VLSR1.）',
        placeholder: '粘贴 VLSR1. 开头的恢复包',
        minLines: 2,
        maxLines: 4,
        autocorrect: false,
      ),
      AdaptiveTextInput(
        label: '恢复口令',
        placeholder: '恢复口令',
        obscureText: true,
        autocorrect: false,
      ),
    ],
    confirmLabel: '继续',
    isValid: (values) => values.every((value) => value.trim().isNotEmpty),
  );
  if (values == null) return null;
  return _RecoveryInput(
    vaultId: values[0].trim(),
    recoveryPackage: values[1].trim(),
    passphrase: values[2],
  );
}

Future<String?> _requestNewRecoveryPassphrase(BuildContext context) async {
  final values = await showAdaptiveTextInputs(
    context: context,
    title: '生成恢复包',
    message: '恢复包和口令需通过不同的受保护渠道保存。',
    inputs: const [
      AdaptiveTextInput(
        label: '恢复口令',
        placeholder: '恢复口令',
        obscureText: true,
        autocorrect: false,
      ),
      AdaptiveTextInput(
        label: '再次输入恢复口令',
        placeholder: '再次输入恢复口令',
        obscureText: true,
        autocorrect: false,
      ),
    ],
    confirmLabel: '生成',
    isValid: (values) => values[0].isNotEmpty && values[0] == values[1],
  );
  if (values == null) return null;
  return values[0];
}

Future<void> _showRecoveryPackage(
  BuildContext context,
  String recoveryPackage,
) => showAdaptiveNotice(
  context: context,
  title: '一次性恢复包',
  message: '请安全保存。此窗口关闭后应用不会保留或自动复制该恢复包。',
  details: SelectableText(recoveryPackage),
  confirmLabel: '我已安全保存',
);

Future<String> _deviceId(LocalDataManager localData) async {
  final existing = await localData.getStringAsync(AppKeys.deviceId);
  if (existing != null && existing.isNotEmpty) return existing;
  final created = const Uuid().v4();
  await localData.setStringAsync(AppKeys.deviceId, created);
  return created;
}

SyncProfileBackgroundPolicy _backgroundPolicyFrom(
  SyncGlobalSettings settings,
) => SyncProfileBackgroundPolicy(
  enabled: false,
  allowCellular: settings.defaultAllowCellular,
  requiresCharging: settings.defaultRequiresCharging,
  cellularMaxTransferBytes: settings.defaultCellularMaxTransferBytes,
);

void _showMessage(BuildContext context, String message) {
  showPlatformMessage(context, message);
}

/// Inline entry points shown under the profile list so both actions stay
/// discoverable without opening the overflow menu.
class _FolderProfileActions extends StatelessWidget {
  const _FolderProfileActions({
    required this.onCreate,
    required this.onRecover,
  });

  final VoidCallback? onCreate;
  final VoidCallback? onRecover;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.sm,
      AppSpacing.md,
      AppSpacing.sm,
      AppSpacing.xl,
    ),
    child: Column(
      children: [
        AdaptiveListTile(
          key: const Key('selected-folder-create'),
          leading: AdaptiveIconBadge(
            icon: adaptiveIcon(
              context,
              material: Icons.create_new_folder_outlined,
              cupertino: CupertinoIcons.folder_badge_plus,
            ),
          ),
          title: const Text('新建同步文件夹'),
          subtitle: const Text('选择远端连接与本机文件夹'),
          showChevron: true,
          onTap: onCreate,
        ),
        const SizedBox(height: AppSpacing.sm),
        AdaptiveListTile(
          key: const Key('selected-folder-recover'),
          leading: AdaptiveIconBadge(
            icon: adaptiveIcon(
              context,
              material: Icons.login,
              cupertino: CupertinoIcons.arrow_right_square,
            ),
          ),
          title: const Text('通过恢复包加入已有空间'),
          subtitle: const Text('输入恢复包与口令'),
          showChevron: true,
          onTap: onRecover,
        ),
      ],
    ),
  );
}

bool _canConfigureBackground(SelectedFolderSyncProfile profile) =>
    profile.state == SelectedFolderProfileState.active &&
    profile.backgroundEnabled &&
    BackgroundSyncScheduler.isSupported;

void _handleProfileRowAction(
  SelectedFolderSyncProfile profile,
  _ProfileRowAction action, {
  required void Function(
    SelectedFolderSyncProfile profile,
    _BackgroundNetworkChoice choice,
  )
  setBackgroundNetwork,
  required void Function(
    SelectedFolderSyncProfile profile,
    bool requiresCharging,
  )
  setBackgroundCharging,
  required void Function(SelectedFolderSyncProfile profile)
  exportRecoveryPackage,
  required void Function(SelectedFolderSyncProfile profile) cleanupStaging,
  required void Function(
    SelectedFolderSyncProfile profile,
    _ProfileLifecycleAction action,
  )
  changeProfileLifecycle,
  required void Function(SelectedFolderSyncProfile profile) runProfile,
}) {
  switch (action) {
    case _ProfileRowAction.syncNow:
      runProfile(profile);
    case _ProfileRowAction.wifi:
      setBackgroundNetwork(profile, _BackgroundNetworkChoice.wifi);
    case _ProfileRowAction.cellular10MiB:
      setBackgroundNetwork(profile, _BackgroundNetworkChoice.cellular10MiB);
    case _ProfileRowAction.cellular50MiB:
      setBackgroundNetwork(profile, _BackgroundNetworkChoice.cellular50MiB);
    case _ProfileRowAction.cellular100MiB:
      setBackgroundNetwork(profile, _BackgroundNetworkChoice.cellular100MiB);
    case _ProfileRowAction.allowBattery:
      setBackgroundCharging(profile, false);
    case _ProfileRowAction.chargingOnly:
      setBackgroundCharging(profile, true);
    case _ProfileRowAction.exportRecovery:
      exportRecoveryPackage(profile);
    case _ProfileRowAction.cleanupStaging:
      cleanupStaging(profile);
    case _ProfileRowAction.pause:
      changeProfileLifecycle(profile, _ProfileLifecycleAction.pause);
    case _ProfileRowAction.resume:
      changeProfileLifecycle(profile, _ProfileLifecycleAction.resume);
    case _ProfileRowAction.remove:
      changeProfileLifecycle(profile, _ProfileLifecycleAction.remove);
  }
}
