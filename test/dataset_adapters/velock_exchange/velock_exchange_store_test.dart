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
    await Directory(
      '${root.path}/Outbox/Ready/batch-1',
    ).create(recursive: true);

    final claim = await store.claimNextOutbox(leaseId: 'lease-1');

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
}
