import 'dart:convert';
import 'dart:io';

import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// What the installed Velock app says it can do, read from the advisory
/// `Control/Capabilities.json` it writes into the shared exchange folder at
/// every start (Velock 2.0.7 and later).
///
/// This is not a trust signal. It only decides whether Sync offers Velock
/// backup at all: Velock 2.0.6 pairs fine but can never finish a backup (no
/// cloud recovery file, no `velock://sync-settings` route), which trapped
/// users in an "open Velock" loop. Every signature, pairing, history and
/// recovery check still runs as before.
class VelockCompanionCapabilities {
  const VelockCompanionCapabilities({
    required this.schema,
    required this.version,
    required this.build,
    required this.capabilities,
  });

  static const relativePath = 'Control/Capabilities.json';
  static const minimumVersionLabel = '2.0.7';

  static const joinRequestV2 = 'join-request-v2';
  static const cloudRecoveryFile = 'cloud-recovery-file-v1';
  static const syncSettingsRoute = 'route-sync-settings';
  static const currentSnapshotV2 = 'current-snapshot-v2';
  static const outboxStatus = 'outbox-status-v1';

  /// Everything Sync 1.0 relies on. Velock may list more; unknown entries are
  /// ignored so newer Velock builds keep working.
  static const required = <String>{
    joinRequestV2,
    cloudRecoveryFile,
    syncSettingsRoute,
    currentSnapshotV2,
    outboxStatus,
  };

  static const _maxBytes = 16 * 1024;

  final int schema;
  final String? version;
  final int? build;
  final Set<String> capabilities;

  bool get supportsSync => required.every(capabilities.contains);

  /// Forward compatible: unknown keys and capability strings are ignored;
  /// only a malformed file or a schema below 1 is rejected (`null`).
  static VelockCompanionCapabilities? parse(List<int> bytes) {
    try {
      if (bytes.length > _maxBytes) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      final schema = decoded['schema'];
      if (schema is! int || schema < 1) return null;
      if (decoded['app'] != 'velock') return null;
      final list = decoded['capabilities'];
      if (list is! List) return null;
      final version = decoded['version'];
      final build = decoded['build'];
      return VelockCompanionCapabilities(
        schema: schema,
        version: version is String ? version : null,
        build: build is int ? build : null,
        capabilities: list.whereType<String>().toSet(),
      );
    } on Object {
      return null;
    }
  }

  /// Reads the descriptor from an exchange root. Missing, unreadable or
  /// malformed files all yield `null` (treated as "Velock too old").
  static Future<VelockCompanionCapabilities?> read(Directory exchangeRoot) async {
    try {
      final file = File('${exchangeRoot.path}/$relativePath');
      if (!await file.exists()) return null;
      if (await file.length() > _maxBytes) return null;
      return parse(await file.readAsBytes());
    } on Object {
      return null;
    }
  }

  /// Whether the Velock app behind [exchangeRoot] implements everything Sync
  /// needs. `false` means Velock is too old or has not been opened since it
  /// was updated.
  static Future<bool> isSupported(Directory exchangeRoot) async =>
      (await read(exchangeRoot))?.supportsSync ?? false;

  /// Throws [VelockUpdateRequired] unless [exchangeRoot] advertises every
  /// capability Sync needs.
  static Future<void> requireSupported(Directory exchangeRoot) async {
    if (!await isSupported(exchangeRoot)) throw VelockUpdateRequired();
  }
}

/// The installed Velock is older than 2.0.7 (or was not opened since it was
/// updated). Retrying cannot help until Velock is updated.
class VelockUpdateRequired extends StateError implements SyncFailureException {
  VelockUpdateRequired() : super('Velock must be updated for backup.');

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'local.velock_update_required',
    category: SyncErrorCategory.userActionRequired,
    retryable: true,
    suggestedAction: '请在 App Store 把格间更新到 2.0.7 或更高版本，并打开一次后再回来。',
  );
}
