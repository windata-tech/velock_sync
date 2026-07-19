import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tech.windata.velock.sync/velock_exchange');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'maps opaque outbox and inbox operations to the native contract',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'android-exchange-channel-',
      );
      addTearDown(() => root.delete(recursive: true));
      final inboxSource = File('${root.path}/inbox-source.artifact');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'readyOutboxIds':
                return ['batch-1'];
              case 'claimOutbox':
                return true;
              case 'stageOutboxArtifact':
                return {
                  'path': '/private/cache/batch-1/operations.enc',
                  'length': 2,
                };
              case 'createInboxArtifactSource':
                return inboxSource.path;
              case 'writeInboxArtifactFromPath':
                expect(await inboxSource.readAsBytes(), [4]);
                return null;
              case 'readInboxArtifact':
                return Uint8List.fromList([1, 2]);
              case 'readInboxReceipt':
                return Uint8List.fromList([3]);
              default:
                return null;
            }
          });
      final exchange = MethodChannelAndroidExchangeChannel(channel: channel);

      expect(await exchange.readyOutboxIds(), ['batch-1']);
      expect(
        await exchange.claimOutbox(batchId: 'batch-1', leaseId: 'lease-1'),
        isTrue,
      );
      expect(
        await exchange.stageOutboxArtifact(
          batchId: 'batch-1',
          relativePath: 'operations.enc',
        ),
        isA<AndroidExchangeArtifact>()
            .having(
              (artifact) => artifact.path,
              'path',
              '/private/cache/batch-1/operations.enc',
            )
            .having((artifact) => artifact.length, 'length', 2),
      );
      await exchange.releaseStagedOutbox('batch-1');
      await exchange.writeInboxArtifact(
        batchId: 'batch-1',
        relativePath: 'operations.enc',
        artifact: ImmutableArtifact.fromBytes(Uint8List.fromList([4])),
      );
      expect(await exchange.readInboxReceipt('batch-1'), [3]);
      expect(
        calls.map((call) => call.method),
        containsAll([
          'readyOutboxIds',
          'claimOutbox',
          'stageOutboxArtifact',
          'releaseStagedOutbox',
          'createInboxArtifactSource',
          'writeInboxArtifactFromPath',
          'readInboxReceipt',
        ]),
      );
    },
  );
}
