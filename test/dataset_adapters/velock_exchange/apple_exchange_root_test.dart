import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';

void main() {
  test('resolves only the native App Group exchange root', () async {
    final locator = AppleExchangeRootLocator(
      channel: _FakeExchangeRootChannel('/private/group/SyncExchange'),
      isApplePlatform: () => true,
    );

    expect((await locator.locate()).path, '/private/group/SyncExchange');
  });

  test('rejects unavailable App Group paths', () {
    final locator = AppleExchangeRootLocator(
      channel: _FakeExchangeRootChannel(null),
      isApplePlatform: () => true,
    );

    expect(locator.locate, throwsStateError);
  });

  test('does not expose an App Group on non-Apple platforms', () {
    final locator = AppleExchangeRootLocator(
      channel: _FakeExchangeRootChannel('/private/group/SyncExchange'),
      isApplePlatform: () => false,
    );

    expect(locator.locate, throwsUnsupportedError);
  });

  test('creates a store only from the dedicated exchange root', () async {
    final store = await VelockExchangeStore.fromAppleAppGroup(
      rootLocator: AppleExchangeRootLocator(
        channel: _FakeExchangeRootChannel('/private/group/SyncExchange'),
        isApplePlatform: () => true,
      ),
    );

    expect(store.root.path, '/private/group/SyncExchange');
  });
}

class _FakeExchangeRootChannel implements AppleExchangeRootChannel {
  const _FakeExchangeRootChannel(this.path);

  final String? path;

  @override
  Future<String?> readExchangeRoot() async => path;
}
