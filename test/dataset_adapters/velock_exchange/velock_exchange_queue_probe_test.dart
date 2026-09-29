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

  test('reads the unpackaged-change hint Velock publishes', () async {
    final root = await Directory.systemTemp.createTemp('velock-queue-test');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/Control/OutboxStatus.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"version":1,"vaultId":"vault-1","unpackagedChanges":3,'
        '"updatedAt":"2026-09-28T10:00:00.000Z","lastFailureAt":null}',
      );

    final status = VelockOutboxStatus.read(file)!;
    expect(status.vaultId, 'vault-1');
    expect(status.unpackagedChanges, 3);
    expect(status.needsVelock, isTrue);

    file.writeAsStringSync(
      '{"version":1,"vaultId":"vault-1","unpackagedChanges":0,'
      '"updatedAt":"2026-09-28T10:00:00.000Z","lastFailureAt":null}',
    );
    expect(VelockOutboxStatus.read(file)!.needsVelock, isFalse);

    file.writeAsStringSync('not json');
    expect(VelockOutboxStatus.read(file), isNull);
  });
}
