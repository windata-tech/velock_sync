import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
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
  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(velockExistingProfilesProvider);
    return AdaptiveScaffold(
      title: syncText(context, '从云端恢复', 'Restore from cloud'),
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
                        '接收云端的新内容，请在现有备份中继续传输，然后打开格间。不会重新创建连接或覆盖你的账号。',
                        'Continue the existing transfer to receive cloud changes, then open Velock. No new connection is created and your account is not replaced.',
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
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(CupertinoIcons.lock_shield, size: 36),
                    const SizedBox(height: 16),
                    Text(
                      syncText(
                        context,
                        '先找回你的格间账号',
                        'First, recover your Velock account',
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
