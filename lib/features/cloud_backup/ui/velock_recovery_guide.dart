import 'dart:io';
import 'velock_recovery_download.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'backup_actions.dart';
import 'backup_widgets.dart';

/// Recovery secrets remain in Velock. This guide never asks for or stores them.
class VelockRecoveryGuide extends ConsumerStatefulWidget {
  const VelockRecoveryGuide({super.key});
  @override
  ConsumerState<VelockRecoveryGuide> createState() =>
      _VelockRecoveryGuideState();
}

class _VelockRecoveryGuideState extends ConsumerState<VelockRecoveryGuide> {
  bool _accountRestored = false;
  bool _downloadingRecovery = false;
  bool _recoveryReady = false;
  String? _recoveryError;

  Future<void> _prepareRecovery() async {
    if (_downloadingRecovery) return;
    setState(() {
      _downloadingRecovery = true;
      _recoveryError = null;
      _recoveryReady = false;
    });
    try {
      final ready = await downloadVelockRecovery(context, ref);
      if (mounted) setState(() => _recoveryReady = ready);
    } on Object {
      if (mounted) {
        setState(
          () => _recoveryError = syncText(
            context,
            '未能取回恢复文件。请检查网络、云端连接和原备份目录。旧备份没有此文件时，请用旧卡的完整二维码，或在原设备升级后再备份一次。',
            'Could not retrieve the recovery file. Check your network, cloud connection and original backup folder. For an older backup without this file, use the old complete QR card, or update and back up once more on the original device.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _downloadingRecovery = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(velockExistingProfilesProvider);
    return AdaptiveScaffold(
      title: syncText(context, '从云端恢复', 'Restore from cloud'),
      // Adding the original connection returns here with `go`, which leaves
      // nothing to pop; the page must still lead back home.
      leading: AppBackButton(
        onPressed: () => context.canPop() ? context.pop() : context.go('/'),
      ),
      body: profiles.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (_, _) => AdaptiveErrorState(
          message: syncText(
            context,
            '无法读取当前连接，暂时不能开始恢复。',
            'Could not check the existing connection. Recovery has not started.',
          ),
          onRetry: () => ref.invalidate(velockExistingProfilesProvider),
        ),
        data: (existing) => ListView(
          children: [
            const SizedBox(height: 10),
            if (existing.isNotEmpty) ...[
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(
                        context,
                        '这台设备已经连接格间',
                        'Velock is already connected',
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
                        '接收云端的新内容，请先继续完成现有备份，然后打开格间。不会重新创建连接或覆盖你的账号。',
                        'Continue the existing backup to receive cloud changes, then open Velock. No new connection is created and your account is not replaced.',
                      ),
                    ),
                    const SizedBox(height: 20),
                    BackupActionButton(
                      label: syncText(
                        context,
                        '查看现有备份',
                        'View existing backup',
                      ),
                      onPressed: () => context.push(
                        '/sync-profiles/${existing.first.profileId}',
                      ),
                    ),
                  ],
                ),
              ),
              BackupCard(
                child: Text(
                  syncText(
                    context,
                    '如果是在换手机，请在新手机上打开 Sync，选择「从云端恢复」。',
                    'Moving to a new phone? Open Sync on that phone and choose Restore from cloud.',
                  ),
                ),
              ),
            ] else ...[
              if (Platform.isIOS || Platform.isMacOS)
                BackupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        syncText(
                          context,
                          '先取回加密恢复文件',
                          'Retrieve the encrypted recovery file',
                        ),
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        syncText(
                          context,
                          '只有纸卡时，先选择原备份目录。Sync 只下载加密文件，不会索要密钥或密码；随后在格间输入纸卡上的四项信息。使用旧卡完整二维码时可跳过此步。',
                          'If you have a paper card, first select the original backup folder. Sync downloads only encrypted files and never asks for your secret key or password. Then enter the four card fields in Velock. You can skip this step with an old complete QR card.',
                        ),
                      ),
                      const SizedBox(height: 16),
                      BackupActionButton(
                        key: const Key('restore-download-recovery'),
                        label: syncText(
                          context,
                          _downloadingRecovery ? '正在读取…' : '选择原备份目录',
                          _downloadingRecovery
                              ? 'Reading…'
                              : 'Select original backup folder',
                        ),
                        onPressed: _downloadingRecovery
                            ? null
                            : _prepareRecovery,
                      ),
                      if (_recoveryReady)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            syncText(
                              context,
                              '恢复文件已就绪，请到格间输入纸卡信息。',
                              'Recovery file ready. Enter your paper card information in Velock.',
                            ),
                          ),
                        ),
                      if (_recoveryError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_recoveryError!),
                        ),
                    ],
                  ),
                ),
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(CupertinoIcons.lock_shield, size: 36),
                    const SizedBox(height: 16),
                    Text(
                      syncText(
                        context,
                        '在格间恢复原账号',
                        'Recover your original account in Velock',
                      ),
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      syncText(
                        context,
                        '准备好恢复卡和原来的云端账号。恢复卡只在格间中使用，Sync 不会向你索要。',
                        'Have your recovery card and original cloud account ready. Use the card only in Velock. Sync will never ask for it.',
                      ),
                    ),
                    const SizedBox(height: 20),
                    BackupActionButton(
                      key: const Key('restore-open-velock'),
                      label: syncText(
                        context,
                        '打开格间，恢复原账号',
                        'Open Velock to recover your account',
                      ),
                      onPressed: () => openVelockForBackup(context, ref),
                    ),
                    const SizedBox(height: 10),
                    AdaptiveSwitchRow(
                      key: const Key('restore-account-confirmed'),
                      title: syncText(
                        context,
                        '我已在格间恢复原来的账号',
                        'I recovered my original account in Velock',
                      ),
                      value: _accountRestored,
                      onChanged: (value) =>
                          setState(() => _accountRestored = value),
                    ),
                  ],
                ),
              ),
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(
                        context,
                        '再连接原来的云端',
                        'Then connect your original cloud storage',
                      ),
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      syncText(
                        context,
                        '接下来会验证格间授权，并寻找这个账号的备份。下载后仍需回到格间解锁，才能完成恢复。',
                        'Next we verify Velock access and look for this account’s backup. After downloading, unlock Velock to finish restoring.',
                      ),
                    ),
                    const SizedBox(height: 18),
                    BackupActionButton(
                      key: const Key('restore-continue'),
                      label: syncText(
                        context,
                        '继续，连接云端',
                        'Continue to cloud storage',
                      ),
                      onPressed: _accountRestored
                          ? () => context.push(
                              '${AppRoutes.velockDatasetWizard.path}?intent=restore',
                            )
                          : null,
                    ),
                  ],
                ),
              ),
              AdaptiveListSection(
                header: syncText(context, '没有恢复卡？', 'No recovery card?'),
                footer: Text(
                  syncText(
                    context,
                    '旧设备还能打开格间时，可先在那里保存恢复卡。如果所有设备和恢复卡都已丢失，Sync 无法绕过加密找回数据。不要先创建新账号冒充原账号。',
                    'If Velock still opens on your old device, save a recovery card there first. If both the devices and recovery card are lost, Sync cannot bypass encryption. A new account cannot replace the original one.',
                  ),
                ),
                children: const [],
              ),
            ],
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}
