import 'dart:async';
import 'dart:math' as math;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/app_format.dart';

/// Live progress of a running backup, read from local state only.
///
/// Moved bytes come from the engine's durable transfer records. For uploads
/// the total is those plus what Velock still has queued in the exchange
/// outbox. Downloads have no known total, and neither do uploads where the
/// outbox is not readable (no App Group): the bar then keeps moving without a
/// percentage instead of inventing one. The fraction never moves backwards
/// and stops at 99 % until the run itself returns: finishing the upload is
/// not the end of the run.
class BackupTransferProgress extends ConsumerStatefulWidget {
  const BackupTransferProgress({
    super.key,
    required this.profileId,
    required this.since,
    this.pollInterval = const Duration(seconds: 1),
  });

  /// Progress for [profileId]'s current run. A run this page started may not
  /// have its record yet; then it started just now.
  factory BackupTransferProgress.forRun(
    String profileId,
    SyncRunRecord? latestRun,
  ) => BackupTransferProgress(
    key: ValueKey('backup-transfer-progress-$profileId'),
    profileId: profileId,
    since: latestRun?.state == 'running'
        ? latestRun!.startedAt
        : DateTime.now().toUtc(),
  );

  final String profileId;

  /// When the run started; transfers before it belong to earlier runs.
  final DateTime since;
  final Duration pollInterval;

  @override
  ConsumerState<BackupTransferProgress> createState() =>
      _BackupTransferProgressState();
}

class _BackupTransferProgressState
    extends ConsumerState<BackupTransferProgress> {
  // Fixed at first build: a parent rebuilding with a fresh fallback time
  // must not drop what this run already uploaded.
  late final DateTime _since = widget.since;
  Timer? _timer;
  bool _reading = false;
  int _uploaded = 0;
  int _downloaded = 0;
  double? _fraction;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_read()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final database = ref.read(syncStateDatabaseProvider);
      final uploaded = await database.transferredBytesSince(
        profileId: widget.profileId,
        since: _since,
        direction: TransferJobDirection.upload,
      );
      final downloaded = await database.transferredBytesSince(
        profileId: widget.profileId,
        since: _since,
        direction: TransferJobDirection.download,
      );
      final pending = await ref
          .read(velockExchangeQueueProbeProvider)
          .pendingUploadBytes();
      if (!mounted) return;
      final total = pending == null ? 0 : uploaded + pending;
      setState(() {
        _uploaded = math.max(_uploaded, uploaded);
        _downloaded = math.max(_downloaded, downloaded);
        if (uploaded > 0 && total > 0) {
          final next = math.min(uploaded / total, 0.99);
          _fraction = math.max(_fraction ?? 0, next);
        }
      });
    } on Object {
      // Progress is decoration; the run's own result is what counts.
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fraction = _fraction;
    final parts = <String>[
      if (_uploaded > 0)
        syncText(
          context,
          '已上传 ${AppFormat.bytes(_uploaded)}',
          '${AppFormat.bytes(_uploaded)} uploaded',
        ),
      if (_downloaded > 0)
        syncText(
          context,
          '已下载 ${AppFormat.bytes(_downloaded)}',
          '${AppFormat.bytes(_downloaded)} downloaded',
        ),
      if (fraction != null) '${(fraction * 100).floor()}%',
    ];
    final detail = parts.isEmpty
        ? syncText(context, '正在准备…', 'Preparing…')
        : parts.join(' · ');
    return BackupProgressBar(
      key: const Key('backup-transfer-progress'),
      fraction: fraction,
      detail: detail,
    );
  }
}

/// The one progress look for transfers: a rounded bar and a short line.
/// A null [fraction] keeps the bar moving without claiming a percentage.
class BackupProgressBar extends StatelessWidget {
  const BackupProgressBar({
    super.key,
    required this.fraction,
    required this.detail,
  });

  final double? fraction;
  final String detail;

  @override
  Widget build(BuildContext context) => Semantics(
    label: syncText(context, '传输进度', 'Transfer progress'),
    value: detail,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 6,
            color: context.appPrimary,
            backgroundColor: context.appPrimary.withValues(alpha: .14),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          detail,
          style: TextStyle(
            fontSize: 14,
            color: context.appSecondaryLabel,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
