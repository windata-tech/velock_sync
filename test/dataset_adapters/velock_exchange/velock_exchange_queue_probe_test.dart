import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_queue_probe.dart';

class _FakeRootChannel implements AppleExchangeRootChannel {
  _FakeRootChannel(this.path);

  final String path;

  @override
  Future<String?> readExchangeRoot() async => path;
}

void main() {
  test('counts the Velock exchange queue without reading payloads', () async {
    final root = await Directory.systemTemp.createTemp('velock-queue-test');
    addTearDown(() => root.delete(recursive: true));

    Directory('${root.path}/Outbox/Ready/batch-1').createSync(recursive: true);
    Directory(
      '${root.path}/Outbox/Claimed/batch-2',
    ).createSync(recursive: true);
    Directory('${root.path}/Inbox/Ready/batch-3').createSync(recursive: true);
    Directory('${root.path}/Outbox/Receipts').createSync(recursive: true);
    File('${root.path}/Outbox/Receipts/batch-1.json').writeAsStringSync('{}');

    final probe = VelockExchangeQueueProbe(
      rootLocator: AppleExchangeRootLocator(
        channel: _FakeRootChannel(root.path),
        isApplePlatform: () => true,
      ),
    );

    final snapshot = await probe.read();

    expect(snapshot, isNotNull);
    expect(snapshot!.outboxReadyCount, 1);
    expect(snapshot.outboxClaimedCount, 1);
    expect(snapshot.inboxReadyCount, 1);
    expect(snapshot.receiptCount, 1);
    expect(snapshot.hasPendingUpload, isTrue);
    expect(snapshot.isEmpty, isFalse);
    expect(snapshot.lastOutboxReceiptAt, isNotNull);
  });

  test('reports an empty queue once everything is drained', () async {
    final root = await Directory.systemTemp.createTemp('velock-queue-drained');
    addTearDown(() => root.delete(recursive: true));
    Directory('${root.path}/Outbox/Ready').createSync(recursive: true);

    final probe = VelockExchangeQueueProbe(
      rootLocator: AppleExchangeRootLocator(
        channel: _FakeRootChannel(root.path),
        isApplePlatform: () => true,
      ),
    );

    final snapshot = await probe.read();

    expect(snapshot!.isEmpty, isTrue);
    expect(snapshot.hasPendingUpload, isFalse);
  });
}
