import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

void main() {
  test('claims a READY package atomically and writes the lease', () async {
    final root = await Directory.systemTemp.createTemp('velock-exchange-');
    addTearDown(() => root.delete(recursive: true));
    final store = VelockExchangeStore(
      root,
      now: () => DateTime.utc(2026, 7, 15),
    );
    await _readyPackage(root, 'batch-1', sequence: 1);

    final claim = await store.claimNextOutbox(
      leaseId: 'lease-1',
      vaultId: 'vault-1',
      sourceDeviceId: 'device-1',
    );

    expect(claim!.batchId, 'batch-1');
    expect(
      await Directory('${root.path}/Outbox/Ready/batch-1').exists(),
      isFalse,
    );
    final lease = jsonDecode(
      await File('${claim.directory.path}/lease.json').readAsString(),
    );
    expect(lease['leaseId'], 'lease-1');
  });

  test(
    'claims only a READY package that matches the requested vault and source',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-exchange-');
      addTearDown(() => root.delete(recursive: true));
      final store = VelockExchangeStore(root);
      await _readyPackage(
        root,
        'batch-other',
        sequence: 1,
        vaultId: 'other-vault',
        sourceDeviceId: 'other-device',
      );
      await _readyPackage(root, 'batch-mine', sequence: 1);

      final claim = await store.claimNextOutbox(
        leaseId: 'lease-1',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
      );

      expect(claim!.batchId, 'batch-mine');
      expect(
        await Directory('${root.path}/Outbox/Ready/batch-other').exists(),
        isTrue,
      );
    },
  );

  test('never claims a package whose READY marker is missing', () async {
    // Velock writes READY last; a package without it is still being written.
    final root = await Directory.systemTemp.createTemp('velock-exchange-');
    addTearDown(() => root.delete(recursive: true));
    final store = VelockExchangeStore(root);
    await _readyPackage(root, 'batch-1', sequence: 1, ready: false);

    expect(
      await store.claimNextOutbox(
        leaseId: 'lease-1',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
      ),
      isNull,
    );
    expect(
      await Directory('${root.path}/Outbox/Ready/batch-1').exists(),
      isTrue,
    );
  });

  test('claims by envelope sequence, not by the random batch id', () async {
    // Batch IDs are UUIDs. Claiming in name order uploaded later sequences
    // first, and the history guard then reported an incomplete backup.
    final root = await Directory.systemTemp.createTemp('velock-exchange-');
    addTearDown(() => root.delete(recursive: true));
    final store = VelockExchangeStore(root);
    await _readyPackage(root, 'aaa-third', sequence: 3);
    await _readyPackage(root, 'zzz-first', sequence: 1);
    await _readyPackage(root, 'mmm-second', sequence: 2);

    final order = <String>[];
    for (var i = 0; i < 3; i++) {
      final claim = await store.claimNextOutbox(
        leaseId: 'lease-$i',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
      );
      order.add(claim!.batchId);
      await store.removeClaimedOutbox(claim.batchId);
    }

    expect(order, ['zzz-first', 'mmm-second', 'aaa-third']);
  });

  test('waits while a lower sequence is still claimed', () async {
    final root = await Directory.systemTemp.createTemp('velock-exchange-');
    addTearDown(() => root.delete(recursive: true));
    final store = VelockExchangeStore(root);
    await _readyPackage(root, 'batch-1', sequence: 1);
    await _readyPackage(root, 'batch-2', sequence: 2);
    final first = await store.claimNextOutbox(
      leaseId: 'lease-1',
      vaultId: 'vault-1',
      sourceDeviceId: 'device-1',
    );
    expect(first!.batchId, 'batch-1');

    // The run that held batch-1 died; its lease has not expired yet.
    expect(
      await store.claimNextOutbox(
        leaseId: 'lease-2',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
      ),
      isNull,
    );
    expect(
      await Directory('${root.path}/Outbox/Ready/batch-2').exists(),
      isTrue,
    );
  });

  test(
    'publishes an inbox package only after every artifact is staged',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-exchange-');
      addTearDown(() => root.delete(recursive: true));
      final store = VelockExchangeStore(root);

      final ready = await store.publishInboxPackage(
        batchId: 'batch-1',
        artifacts: {
          'envelope.json': ImmutableArtifact.fromBytes(
            Uint8List.fromList(utf8.encode('opaque')),
          ),
        },
      );

      expect(
        await File('${ready.path}/envelope.json').readAsString(),
        'opaque',
      );
      expect(
        jsonDecode(await File('${ready.path}/READY').readAsString()),
        containsPair('batchId', 'batch-1'),
      );
      expect(
        await Directory('${root.path}/Inbox/Staging/batch-1.tmp').exists(),
        isFalse,
      );
    },
  );

  test(
    'publishing the same inbox package again is an idempotent no-op',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-exchange-');
      addTearDown(() => root.delete(recursive: true));
      final store = VelockExchangeStore(root);
      final artifacts = {
        'envelope.json': ImmutableArtifact.fromBytes(
          Uint8List.fromList(utf8.encode('opaque')),
        ),
      };

      final first = await store.publishInboxPackage(
        batchId: 'batch-1',
        artifacts: artifacts,
      );
      final second = await store.publishInboxPackage(
        batchId: 'batch-1',
        artifacts: artifacts,
      );

      expect(second.path, first.path);
      expect(
        await File('${second.path}/envelope.json').readAsString(),
        'opaque',
      );
      expect(
        await Directory('${root.path}/Inbox/Staging/batch-1.tmp').exists(),
        isFalse,
      );
    },
  );
}

Future<void> _readyPackage(
  Directory root,
  String batchId, {
  required int sequence,
  String vaultId = 'vault-1',
  String sourceDeviceId = 'device-1',
  bool ready = true,
}) async {
  final package = Directory('${root.path}/Outbox/Ready/$batchId');
  await package.create(recursive: true);
  await File('${package.path}/envelope.json').writeAsString(
    jsonEncode({
      'vaultId': vaultId,
      'sourceDeviceId': sourceDeviceId,
      'sequence': sequence,
    }),
  );
  if (ready) {
    await File('${package.path}/READY').writeAsString(
      jsonEncode({'batchId': batchId}),
    );
  }
}
