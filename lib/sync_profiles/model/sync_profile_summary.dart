import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';

/// Lifecycle states shared by every V1 sync profile.
///
/// The database persists the state separately from the profile payload so a
/// scheduler can reliably suppress a profile even if a previous app version
/// wrote an older payload shape.
enum SyncProfileState {
  active,
  paused,
  accessRequired,
  reauthorizationRequired,
  blockedByConfiguration,
  error;

  static SyncProfileState? tryParse(Object? value) {
    if (value is! String) return null;
    for (final state in values) {
      if (state.name == value) return state;
    }
    return null;
  }
}

class SyncProfileBackgroundPolicy {
  const SyncProfileBackgroundPolicy({
    this.enabled = false,
    this.allowCellular = false,
    this.requiresCharging = false,
    this.cellularMaxTransferBytes = 50 * 1024 * 1024,
  }) : assert(cellularMaxTransferBytes > 0);

  final bool enabled;
  final bool allowCellular;
  final bool requiresCharging;
  final int cellularMaxTransferBytes;

  SyncProfileBackgroundPolicy copyWith({
    bool? enabled,
    bool? allowCellular,
    bool? requiresCharging,
    int? cellularMaxTransferBytes,
  }) => SyncProfileBackgroundPolicy(
    enabled: enabled ?? this.enabled,
    allowCellular: allowCellular ?? this.allowCellular,
    requiresCharging: requiresCharging ?? this.requiresCharging,
    cellularMaxTransferBytes:
        cellularMaxTransferBytes ?? this.cellularMaxTransferBytes,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'allowCellular': allowCellular,
    'requiresCharging': requiresCharging,
    'cellularMaxTransferBytes': cellularMaxTransferBytes,
  };

  factory SyncProfileBackgroundPolicy.fromJson(Map<String, dynamic>? value) {
    if (value == null) return const SyncProfileBackgroundPolicy();
    final enabled = value['enabled'];
    final allowCellular = value['allowCellular'];
    final requiresCharging = value['requiresCharging'];
    final cellularMaxTransferBytes = value['cellularMaxTransferBytes'];
    if ((enabled != null && enabled is! bool) ||
        (allowCellular != null && allowCellular is! bool) ||
        (requiresCharging != null && requiresCharging is! bool) ||
        (cellularMaxTransferBytes != null &&
            (cellularMaxTransferBytes is! int ||
                cellularMaxTransferBytes < 1))) {
      throw const FormatException('Sync profile background policy is invalid.');
    }
    return SyncProfileBackgroundPolicy(
      enabled: enabled as bool? ?? false,
      allowCellular: allowCellular as bool? ?? false,
      requiresCharging: requiresCharging as bool? ?? false,
      cellularMaxTransferBytes:
          cellularMaxTransferBytes as int? ?? 50 * 1024 * 1024,
    );
  }
}

/// A privacy-safe projection for profile lists and background scheduling.
/// Unknown/malformed payloads remain represented as isolated summaries instead
/// of being deleted or crashing startup.
class SyncProfileSummary {
  const SyncProfileSummary({
    required this.profileId,
    required this.state,
    required this.backgroundPolicy,
    this.kind,
    this.datasetId,
    this.vaultId,
    this.deviceId,
    this.displayName,
    this.connectionId,
    this.activity,
    this.isolationReason,
  });

  final String profileId;
  final SyncProfileState state;
  final SyncProfileBackgroundPolicy backgroundPolicy;
  final SyncDatasetKind? kind;
  final String? datasetId;
  final String? vaultId;
  final String? deviceId;
  final String? displayName;
  final String? connectionId;
  final SyncProfileActivitySummary? activity;
  final String? isolationReason;

  bool get isIsolated => isolationReason != null;
  bool get isRunnable =>
      !isIsolated && state == SyncProfileState.active && kind != null;
  bool get isBackgroundEligible => isRunnable && backgroundPolicy.enabled;
}
