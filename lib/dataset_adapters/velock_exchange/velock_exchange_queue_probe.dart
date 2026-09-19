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
  });

  final int outboxReadyCount;
  final int outboxClaimedCount;
  final int inboxReadyCount;
  final int receiptCount;
  final DateTime? lastOutboxReceiptAt;

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
