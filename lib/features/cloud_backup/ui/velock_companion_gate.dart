import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

/// States in which Velock backup must not be offered at all: pairing would
/// either succeed and then fail every backup (an old Velock), or can never
/// work (a platform/build without the exchange). No pairing entry, no join
/// request, no "authorize in Velock" advice.
bool isVelockBackupGated(VelockWizardAvailability? availability) =>
    availability == VelockWizardAvailability.velockUpdateRequired ||
    availability == VelockWizardAvailability.unsupportedPlatform;

String _text(BuildContext? context, String zh, String en) =>
    context == null ? zh : syncText(context, zh, en);

String velockUpdateRequiredTitle([BuildContext? context]) =>
    _text(context, '需要更新格间', 'Update Velock');

String velockUpdateRequiredMessage([BuildContext? context]) => _text(
  context,
  '格间备份需要格间 2.0.7 或更高版本。请在 App Store 更新格间，并打开一次后再回来。文件同步不受影响。',
  'Velock backup needs Velock 2.0.7 or later. Update Velock in the App Store, open it once, then come back. File sync is not affected.',
);

String velockUnsupportedPlatformTitle([BuildContext? context]) =>
    _text(context, '暂不支持格间备份', 'Velock backup is not available');

String velockUnsupportedPlatformMessage([BuildContext? context]) =>
    defaultTargetPlatform == TargetPlatform.android
    ? _text(
        context,
        '这个版本暂不支持在 Android 上备份格间。文件同步可以正常使用。',
        'This version cannot back up Velock on Android yet. File sync works as usual.',
      )
    : _text(
        context,
        '这台设备暂不支持备份格间。文件同步可以正常使用。',
        'Velock backup is not available on this device yet. File sync works as usual.',
      );

/// Title for a gated state, or `null` when [availability] is not gated.
String? velockGateTitle(
  VelockWizardAvailability? availability, [
  BuildContext? context,
]) => switch (availability) {
  VelockWizardAvailability.velockUpdateRequired => velockUpdateRequiredTitle(
    context,
  ),
  VelockWizardAvailability.unsupportedPlatform =>
    velockUnsupportedPlatformTitle(context),
  _ => null,
};

/// Message for a gated state, or `null` when [availability] is not gated.
String? velockGateMessage(
  VelockWizardAvailability? availability, [
  BuildContext? context,
]) => switch (availability) {
  VelockWizardAvailability.velockUpdateRequired => velockUpdateRequiredMessage(
    context,
  ),
  VelockWizardAvailability.unsupportedPlatform =>
    velockUnsupportedPlatformMessage(context),
  _ => null,
};

/// Replaces the "start backup" welcome card while Velock backup is gated.
/// An old Velock gets "open Velock" and "check again"; an unsupported
/// platform gets no action at all.
class VelockCompanionGateCard extends StatelessWidget {
  const VelockCompanionGateCard({
    super.key,
    required this.availability,
    required this.onOpenVelock,
    required this.onRecheck,
    this.checking = false,
  });

  final VelockWizardAvailability availability;
  final VoidCallback onOpenVelock;
  final VoidCallback onRecheck;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final updatable =
        availability == VelockWizardAvailability.velockUpdateRequired;
    return BackupCard(
      key: Key('velock-gate-${availability.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            updatable
                ? CupertinoIcons.arrow_up_circle
                : CupertinoIcons.info_circle,
            color: AppColors.warning,
            size: 38,
          ),
          const SizedBox(height: 16),
          Text(
            velockGateTitle(availability, context) ?? '',
            key: const Key('velock-gate-title'),
            style: TextStyle(
              fontSize: 25,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            velockGateMessage(availability, context) ?? '',
            style: TextStyle(
              fontSize: 16,
              height: 1.45,
              color: context.appSecondaryLabel,
            ),
          ),
          if (updatable) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: BackupActionButton(
                    key: const Key('velock-gate-open'),
                    label: syncText(context, '打开格间', 'Open Velock'),
                    onPressed: onOpenVelock,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: BackupActionButton(
                    key: const Key('velock-gate-recheck'),
                    label: syncText(context, '重新检查', 'Check again'),
                    secondary: true,
                    busy: checking,
                    onPressed: onRecheck,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
