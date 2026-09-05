import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_velock_companion_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tech.windata.velock.sync/companion_installed');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reports installed when the native probe answers true', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'isInstalled');
          return true;
        });

    expect(
      await const MethodChannelAppleVelockCompanionProbe().isInstalled(),
      isTrue,
    );
  });

  test('fails closed when the native probe does not return a value', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    expect(
      await const MethodChannelAppleVelockCompanionProbe().isInstalled(),
      isFalse,
    );
  });
}
