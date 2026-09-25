import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

ImmutableArtifact _bytes(List<int> bytes) =>
    ImmutableArtifact.fromBytes(Uint8List.fromList(bytes));

void main() {
  late Directory root;
  late VelockExchangeStore store;
  late Map<String, ImmutableArtifact> artifacts;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('exchange-inbox-fault-');
    store = VelockExchangeStore(root);
    artifacts = {
      'envelope.json': _bytes([1, 2]),
      'operations.enc': _bytes([3, 4]),
      'blobs/blob-1.blob': _bytes([5, 6]),
    };
  });
  tearDown(() => root.delete(recursive: true));

  Future<Directory> publish() =>
      store.publishInboxPackage(batchId: 'batch-1', artifacts: artifacts);

  test(
    'marker failure never exposes a partial Ready package; retry works',
    () async {
      var fail = true;
      store = VelockExchangeStore(
        root,
        now: () {
          if (fail) throw StateError('injected marker failure');
          return DateTime.utc(2026, 9, 19);
        },
      );
      await expectLater(publish(), throwsStateError);
      expect(
        await Directory('${root.path}/Inbox/Ready/batch-1').exists(),
        isFalse,
      );
      expect(
        await Directory('${root.path}/Inbox/Staging/batch-1.tmp').exists(),
        isFalse,
      );
      fail = false;
      final ready = await publish();
      expect(await File('${ready.path}/READY').exists(), isTrue);
      expect(await store.readInboxReceipt('batch-1'), isNull);
    },
  );

  test('READY hashes staged envelope without reopening its source', () async {
    var opens = 0;
    artifacts['envelope.json'] = ImmutableArtifact(
      length: 2,
      openRead: () async {
        opens++;
        return Stream.value(opens == 1 ? [1, 2] : [8, 9]);
      },
    );
    final ready = await publish();
    final marker = jsonDecode(await File('${ready.path}/READY').readAsString());
    expect(
      marker['envelopeSha256'],
      sha256
          .convert(await File('${ready.path}/envelope.json').readAsBytes())
          .toString(),
    );
    expect(opens, 1);
  });

  for (final path in ['envelope.json', 'operations.enc', 'blobs/blob-1.blob']) {
    test(
      'same batch ID with different $path is rejected without mutation',
      () async {
        final ready = await publish();
        final before = await File('${ready.path}/$path').readAsBytes();
        final marker = await File('${ready.path}/READY').readAsBytes();
        artifacts[path] = _bytes([8, 9]);
        await expectLater(publish(), throwsFormatException);
        expect(await File('${ready.path}/$path').readAsBytes(), before);
        expect(await File('${ready.path}/READY').readAsBytes(), marker);
        expect(
          await Directory('${root.path}/Inbox/Staging/batch-1.tmp').exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'retry repairs matching legacy package missing READY without losing ACK',
    () async {
      final ready = await publish();
      await File('${ready.path}/READY').delete();
      final ack = File('${ready.path}/ack/peer.ack');
      await ack.parent.create();
      await ack.writeAsBytes([9]);
      await publish();
      expect(await File('${ready.path}/READY').exists(), isTrue);
      expect(await ack.readAsBytes(), [9]);
    },
  );

  for (final failure in ['stream', 'short', 'long']) {
    test('$failure artifact failure is clean and retryable', () async {
      artifacts['blobs/blob-1.blob'] = ImmutableArtifact(
        length: 2,
        openRead: () async => failure == 'stream'
            ? Stream<List<int>>.error(StateError('injected stream failure'))
            : Stream.value(failure == 'short' ? [5] : [5, 6, 7]),
      );
      await expectLater(publish(), throwsStateError);
      expect(
        await Directory('${root.path}/Inbox/Ready/batch-1').exists(),
        isFalse,
      );
      expect(
        await Directory('${root.path}/Inbox/Staging/batch-1.tmp').exists(),
        isFalse,
      );
      artifacts['blobs/blob-1.blob'] = _bytes([5, 6]);
      final ready = await publish();
      expect(await File('${ready.path}/blobs/blob-1.blob').readAsBytes(), [
        5,
        6,
      ]);
      expect(await File('${ready.path}/READY').exists(), isTrue);
    });
  }

  test('ACK read rejects a symlinked parent directory', () async {
    final ready = await publish();
    final outside = Directory('${root.path}/outside');
    await outside.create();
    await File('${outside.path}/peer.ack').writeAsBytes([99]);
    await Link('${ready.path}/ack').create(outside.path);
    await expectLater(
      store.readInboxArtifact(batchId: 'batch-1', relativePath: 'ack/peer.ack'),
      throwsStateError,
    );
  });

  test(
    'receipt read rejects symlinks instead of trusting their target',
    () async {
      await store.initialize();
      final outside = File('${root.path}/outside-receipt.json');
      await outside.writeAsBytes([99]);
      await Link(
        '${root.path}/Inbox/Receipts/batch-1.json',
      ).create(outside.path);
      await expectLater(store.readInboxReceipt('batch-1'), throwsStateError);
    },
  );

  test(
    'idempotent replay consumes streams but preserves peer ACK and receipt',
    () async {
      final ready = await publish();
      final marker = await File('${ready.path}/READY').readAsBytes();
      final ack = File('${ready.path}/ack/peer.ack');
      await ack.parent.create();
      await ack.writeAsBytes([9]);
      await store.writeInboxReceipt(
        batchId: 'batch-1',
        receipt: Uint8List.fromList([7]),
      );
      var opens = 0;
      artifacts['blobs/blob-1.blob'] = ImmutableArtifact(
        length: 2,
        openRead: () async {
          opens++;
          return Stream.value([5, 6]);
        },
      );
      await publish();
      expect(opens, 1);
      expect(await ack.readAsBytes(), [9]);
      expect(await store.readInboxReceipt('batch-1'), [7]);
      expect(await File('${ready.path}/READY').readAsBytes(), marker);
    },
  );
}
