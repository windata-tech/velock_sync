import 'dart:convert';
import 'dart:io';

import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';

/// What the Velock app currently has queued for the sync exchange.
///
/// This is a local, read-only probe of the shared App Group directory: it
/// reports how many batches wait to be uploaded and how many downloaded
/// packages wait for Velock to import them. No payload is read.
class VelockExchangeQueueSnapshot {
  const VelockExchangeQueueSnapshot({
    required this.outboxReadyCount,
    required this.outboxClaimedCount,
    required this.inboxReadyCount,
    required this.receiptCount,
    this.lastOutboxReceiptAt,
    this.velockStatus,
  });

  final int outboxReadyCount;
  final int outboxClaimedCount;
  final int inboxReadyCount;
  final int receiptCount;
  final DateTime? lastOutboxReceiptAt;

  /// What Velock reported about changes it has not handed over yet.
  final VelockOutboxStatus? velockStatus;

  bool get hasPendingUpload => outboxReadyCount > 0 || outboxClaimedCount > 0;

  bool get isEmpty => !hasPendingUpload && inboxReadyCount == 0;
}

class VelockExchangeQueueProbe {
  const VelockExchangeQueueProbe({AppleExchangeRootLocator? rootLocator})
    : _rootLocator = rootLocator;

  final AppleExchangeRootLocator? _rootLocator;

  /// Returns `null` when the exchange directory is not available (for example
  /// on Android, or before the first pairing).
  Future<VelockExchangeQueueSnapshot?> read() async {
    Directory root;
    try {
      root = await (_rootLocator ?? AppleExchangeRootLocator()).locate();
    } on Object {
      return null;
    }
    final exchange = root;
    if (!exchange.existsSync()) return null;
    final receipts = Directory('${exchange.path}/Outbox/Receipts');
    return VelockExchangeQueueSnapshot(
      outboxReadyCount: _countDirectories(
        Directory('${exchange.path}/Outbox/Ready'),
      ),
      outboxClaimedCount: _countDirectories(
        Directory('${exchange.path}/Outbox/Claimed'),
      ),
      inboxReadyCount: _countDirectories(
        Directory('${exchange.path}/Inbox/Ready'),
      ),
      receiptCount: _countFiles(receipts),
      lastOutboxReceiptAt: _latestModified(receipts),
      velockStatus: VelockOutboxStatus.read(
        File('${exchange.path}/Control/OutboxStatus.json'),
      ),
    );
  }

  static int _countDirectories(Directory directory) {
    if (!directory.existsSync()) return 0;
    return directory
        .listSync()
        .whereType<Directory>()
        .where((entry) => !entry.path.endsWith('.tmp'))
        .length;
  }

  static int _countFiles(Directory directory) {
    if (!directory.existsSync()) return 0;
    return directory.listSync().whereType<File>().length;
  }

  static DateTime? _latestModified(Directory directory) {
    if (!directory.existsSync()) return null;
    DateTime? latest;
    for (final entry in directory.listSync().whereType<File>()) {
      final modified = entry.statSync().modified;
      if (latest == null || modified.isAfter(latest)) latest = modified;
    }
    return latest;
  }
}

/// Velock's own count of changes not yet packaged for Sync.
///
/// Sync only sees packages in Outbox. Without this hint a run reported "no
/// transfer needed" while Velock still held unpackaged changes (not opened
/// since the edit, suspended during packaging, or packaging failing).
class VelockOutboxStatus {
  const VelockOutboxStatus({
    required this.vaultId,
    required this.unpackagedChanges,
    required this.updatedAt,
    this.lastFailureAt,
    this.pendingConflicts = 0,
  });

  final String vaultId;
  final int unpackagedChanges;

  /// Conflicts waiting in Velock for the user to pick a version.
  final int pendingConflicts;
  final DateTime updatedAt;
  final DateTime? lastFailureAt;

  /// Whether this hint asks the user to open Velock.
  bool get needsVelock =>
      unpackagedChanges > 0 || lastFailureAt != null || pendingConflicts > 0;

  static VelockOutboxStatus? read(File file) {
    try {
      if (!file.existsSync() || file.lengthSync() > 4096) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        return null;
      }
      final vaultId = decoded['vaultId'];
      final count = decoded['unpackagedChanges'];
      final updatedAt = DateTime.tryParse('${decoded['updatedAt']}');
      final failure = decoded['lastFailureAt'];
      final conflicts = decoded['pendingConflicts'];
      if (vaultId is! String ||
          count is! int ||
          count < 0 ||
          updatedAt == null) {
        return null;
      }
      return VelockOutboxStatus(
        vaultId: vaultId,
        unpackagedChanges: count,
        updatedAt: updatedAt.toUtc(),
        lastFailureAt: failure is String
            ? DateTime.tryParse(failure)?.toUtc()
            : null,
        pendingConflicts: conflicts is int && conflicts > 0 ? conflicts : 0,
      );
    } on Object {
      return null;
    }
  }
}
