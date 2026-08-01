import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_profile_provisioner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile_executor.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_core/engine/initial_sync_assessment.dart';
import 'package:velock_sync/sync_core/crypto/vault_recovery_package.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

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
      final connectionId = await _chooseConnection(context, available);
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
      final connectionId = await _chooseConnection(context, available);
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
      } on Object {
        if (context.mounted) _showMessage(context, '同步失败；请检查连接、授权与网络。');
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
            '已安全清理 ${_formatBytes(result.freedBytes)}；保留 ${result.preservedRecoverableBatchCount} 个可恢复批次。',
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
          PlatformIconButton(
            icon: const Icon(Icons.login),
            onPressed: busy.value ? null : joinProfile,
          ),
          PlatformIconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: busy.value ? null : createProfile,
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
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sync, size: 48),
                    const SizedBox(height: 12),
                    const Text('还没有同步文件夹'),
                    const SizedBox(height: 8),
                    const Text('添加远端连接后，选择需要同步的文件夹。'),
                    const SizedBox(height: 16),
                    PlatformElevatedButton(
                      onPressed: busy.value ? null : createProfile,
                      child: const Text('添加同步文件夹'),
                    ),
                    const SizedBox(height: 8),
                    PlatformTextButton(
                      onPressed: busy.value ? null : joinProfile,
                      child: const Text('通过恢复包加入已有空间'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: values.length,
            itemBuilder: (context, index) {
              final profile = values[index];
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(profile.displayName),
                subtitle: _ProfileActivitySummary(
                  profile: profile,
                  database: ref.read(syncStateDatabaseProvider),
                ),
                trailing: SizedBox(
                  width: 352,
                  child: Row(
                    children: [
                      Switch(
                        value: profile.backgroundEnabled,
                        onChanged:
                            busy.value ||
                                profile.state ==
                                    SelectedFolderProfileState.paused ||
                                !BackgroundSyncScheduler.isSupported
                            ? null
                            : (enabled) => setBackground(profile, enabled),
                      ),
                      PopupMenuButton<_BackgroundNetworkChoice>(
                        tooltip: '后台网络',
                        enabled:
                            !busy.value &&
                            profile.state ==
                                SelectedFolderProfileState.active &&
                            profile.backgroundEnabled &&
                            BackgroundSyncScheduler.isSupported,
                        icon: Icon(
                          profile.backgroundAllowCellular
                              ? Icons.network_cell
                              : Icons.wifi,
                        ),
                        onSelected: (choice) =>
                            setBackgroundNetwork(profile, choice),
                        itemBuilder: (context) => [
                          CheckedPopupMenuItem(
                            value: _BackgroundNetworkChoice.wifi,
                            checked: !profile.backgroundAllowCellular,
                            child: const Text('仅 Wi-Fi'),
                          ),
                          CheckedPopupMenuItem(
                            value: _BackgroundNetworkChoice.cellular10MiB,
                            checked:
                                profile.backgroundAllowCellular &&
                                profile.backgroundCellularMaxTransferBytes ==
                                    10 * 1024 * 1024,
                            child: const Text('蜂窝网络，单文件最多 10 MiB'),
                          ),
                          CheckedPopupMenuItem(
                            value: _BackgroundNetworkChoice.cellular50MiB,
                            checked:
                                profile.backgroundAllowCellular &&
                                profile.backgroundCellularMaxTransferBytes ==
                                    50 * 1024 * 1024,
                            child: const Text('蜂窝网络，单文件最多 50 MiB'),
                          ),
                          CheckedPopupMenuItem(
                            value: _BackgroundNetworkChoice.cellular100MiB,
                            checked:
                                profile.backgroundAllowCellular &&
                                profile.backgroundCellularMaxTransferBytes ==
                                    100 * 1024 * 1024,
                            child: const Text('蜂窝网络，单文件最多 100 MiB'),
                          ),
                        ],
                      ),
                      PopupMenuButton<bool>(
                        tooltip: '后台电源',
                        enabled:
                            !busy.value &&
                            profile.state ==
                                SelectedFolderProfileState.active &&
                            profile.backgroundEnabled &&
                            BackgroundSyncScheduler.isSupported,
                        icon: Icon(
                          profile.backgroundRequiresCharging
                              ? Icons.battery_charging_full
                              : Icons.battery_std,
                        ),
                        onSelected: (requiresCharging) =>
                            setBackgroundCharging(profile, requiresCharging),
                        itemBuilder: (context) => [
                          CheckedPopupMenuItem(
                            value: false,
                            checked: !profile.backgroundRequiresCharging,
                            child: const Text('允许使用电池'),
                          ),
                          CheckedPopupMenuItem(
                            value: true,
                            checked: profile.backgroundRequiresCharging,
                            child: const Text('仅充电时同步'),
                          ),
                        ],
                      ),
                      PlatformIconButton(
                        icon: const Icon(Icons.key_outlined),
                        onPressed: busy.value
                            ? null
                            : () => exportRecoveryPackage(profile),
                      ),
                      PlatformIconButton(
                        icon: const Icon(Icons.cleaning_services_outlined),
                        onPressed: busy.value
                            ? null
                            : () => cleanupStaging(profile),
                      ),
                      PopupMenuButton<_ProfileLifecycleAction>(
                        tooltip: '同步配置操作',
                        enabled: !busy.value,
                        icon: Icon(
                          profile.state == SelectedFolderProfileState.paused
                              ? Icons.play_arrow
                              : Icons.more_vert,
                        ),
                        onSelected: (action) {
                          if (action ==
                              _ProfileLifecycleAction.exportRecovery) {
                            exportRecoveryPackage(profile);
                            return;
                          }
                          changeProfileLifecycle(profile, action);
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: _ProfileLifecycleAction.exportRecovery,
                            child: Text('生成恢复包'),
                          ),
                          if (profile.state ==
                              SelectedFolderProfileState.active)
                            const PopupMenuItem(
                              value: _ProfileLifecycleAction.pause,
                              child: Text('暂停同步'),
                            )
                          else
                            const PopupMenuItem(
                              value: _ProfileLifecycleAction.resume,
                              child: Text('继续同步'),
                            ),
                          const PopupMenuItem(
                            value: _ProfileLifecycleAction.remove,
                            child: Text('移除此同步配置'),
                          ),
                        ],
                      ),
                      PlatformIconButton(
                        icon: const Icon(Icons.sync),
                        onPressed:
                            busy.value ||
                                profile.state ==
                                    SelectedFolderProfileState.paused
                            ? null
                            : () => runProfile(profile),
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
          ? '后台：${profile.backgroundAllowCellular ? '蜂窝网络单文件最多 ${_formatBytes(profile.backgroundCellularMaxTransferBytes)}' : '仅 Wi-Fi'}${profile.backgroundRequiresCharging ? '，仅充电时' : ''}'
          : '后台未启用';
      final nextCondition = profile.state == SelectedFolderProfileState.paused
          ? '下次：恢复后手动或等待触发'
          : profile.backgroundEnabled
          ? '下次：系统允许且${profile.backgroundAllowCellular ? '联网' : '连入 Wi-Fi'}${profile.backgroundRequiresCharging ? '并正在充电' : ''}'
          : '下次：手动同步';
      final transferred = activity.transferredBytes == 0
          ? ''
          : '，已传 ${_formatBytes(activity.transferredBytes)}';
      return FutureBuilder<StagingSpaceSummary>(
        future: _readStagingSpace(profile, database),
        builder: (context, stagingSnapshot) {
          final staging = stagingSnapshot.hasData
              ? ' · 暂存 ${_formatBytes(stagingSnapshot.requireData.totalBytes)}'
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

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}

Future<String?> _chooseConnection(
  BuildContext context,
  List<ConnectionModel> connections,
) => showDialog<String>(
  context: context,
  builder: (context) => SimpleDialog(
    title: const Text('选择远端连接'),
    children: [
      for (final connection in connections)
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(connection.id),
          child: Text(connection.name),
        ),
    ],
  ),
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
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(details),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('确认并同步'),
        ),
      ],
    ),
  ).then((confirmed) => confirmed ?? false);
}

Future<bool> _confirmProfileRemoval(BuildContext context, String displayName) =>
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除同步配置？'),
        content: Text('“$displayName”将停止同步，并从本机删除此配置使用的密钥引用。远端同步空间和文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    ).then((confirmed) => confirmed ?? false);

Future<_RecoveryInput?> _requestRecoveryInput(BuildContext context) async {
  final vaultId = TextEditingController();
  final recoveryPackage = TextEditingController();
  final passphrase = TextEditingController();
  try {
    return await showDialog<_RecoveryInput>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('加入已有同步空间'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: vaultId,
                decoration: const InputDecoration(labelText: 'Vault ID'),
                autocorrect: false,
              ),
              TextField(
                controller: recoveryPackage,
                decoration: const InputDecoration(labelText: '恢复包（VLSR1.）'),
                minLines: 2,
                maxLines: 4,
                autocorrect: false,
              ),
              TextField(
                controller: passphrase,
                decoration: const InputDecoration(labelText: '恢复口令'),
                obscureText: true,
                autocorrect: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (vaultId.text.trim().isEmpty ||
                  recoveryPackage.text.trim().isEmpty ||
                  passphrase.text.isEmpty) {
                return;
              }
              Navigator.of(dialogContext).pop(
                _RecoveryInput(
                  vaultId: vaultId.text.trim(),
                  recoveryPackage: recoveryPackage.text.trim(),
                  passphrase: passphrase.text,
                ),
              );
            },
            child: const Text('继续选择文件夹'),
          ),
        ],
      ),
    );
  } finally {
    vaultId.dispose();
    recoveryPackage.dispose();
    passphrase.dispose();
  }
}

Future<String?> _requestNewRecoveryPassphrase(BuildContext context) async {
  final first = TextEditingController();
  final second = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('生成恢复包'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('恢复包和口令需通过不同的受保护渠道保存。'),
            TextField(
              controller: first,
              decoration: const InputDecoration(labelText: '恢复口令'),
              obscureText: true,
              autocorrect: false,
            ),
            TextField(
              controller: second,
              decoration: const InputDecoration(labelText: '再次输入恢复口令'),
              obscureText: true,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (first.text.isEmpty || first.text != second.text) return;
              Navigator.of(dialogContext).pop(first.text);
            },
            child: const Text('生成'),
          ),
        ],
      ),
    );
  } finally {
    first.dispose();
    second.dispose();
  }
}

Future<void> _showRecoveryPackage(
  BuildContext context,
  String recoveryPackage,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('一次性恢复包'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('请安全保存。此窗口关闭后应用不会保留或自动复制该恢复包。'),
          const SizedBox(height: 12),
          SelectableText(recoveryPackage),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('我已安全保存'),
      ),
    ],
  ),
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
