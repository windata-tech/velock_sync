import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';

void main() {
  const candidate = VelockExchangeCandidate(
    producerId: 'producer-1',
    producerPublicKeyId: 'producer-key-1',
    exchangeBindingId: 'exchange-1',
  );

  test(
    'Android discovery trusts only a successful protected capability probe',
    () async {
      final result = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(() async => const ['batch-1']),
        candidate: candidate,
      ).discover();

      expect(result.availability, VelockExchangeAvailability.available);
      expect(result.candidate, same(candidate));
      expect(result.isAvailable, isTrue);
    },
  );

  test(
    'Android discovery maps known native trust failures and fails closed otherwise',
    () async {
      final signatureMismatch = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(
          () async => throw PlatformException(code: 'signatureMismatch'),
        ),
        candidate: candidate,
      ).discover();
      final accessDenied = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(
          () async => throw PlatformException(code: 'ACCESS_DENIED'),
        ),
        candidate: candidate,
      ).discover();
      final temporary = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(
          () async => throw PlatformException(code: 'TEMPORARY_UNAVAILABLE'),
        ),
        candidate: candidate,
      ).discover();
      final unknown = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(
          () async => throw StateError('probe failed'),
        ),
        candidate: candidate,
      ).discover();
      final missingPlugin = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(
          () async => throw MissingPluginException(),
        ),
        candidate: candidate,
      ).discover();

      expect(
        signatureMismatch.availability,
        VelockExchangeAvailability.signatureMismatch,
      );
      expect(
        accessDenied.availability,
        VelockExchangeAvailability.authorizationRequired,
      );
      expect(
        temporary.availability,
        VelockExchangeAvailability.temporarilyUnavailable,
      );
      expect(
        unknown.availability,
        VelockExchangeAvailability.configurationMissing,
      );
      expect(
        missingPlugin.availability,
        VelockExchangeAvailability.unsupportedVersion,
      );
    },
  );

  test(
    'Android discovery rejects a malformed candidate without probing the platform',
    () async {
      var invoked = false;
      final result = await AndroidVelockExchangeDiscovery(
        exchange: _FakeAndroidExchangeChannel(() async {
          invoked = true;
          return const [];
        }),
        candidate: const VelockExchangeCandidate(
          producerId: '',
          producerPublicKeyId: 'producer-key-1',
          exchangeBindingId: 'exchange-1',
        ),
      ).discover();

      expect(
        result.availability,
        VelockExchangeAvailability.configurationMissing,
      );
      expect(invoked, isFalse);
    },
  );

  test(
    'Apple discovery accepts only the dedicated locator root when it exists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'velock-exchange-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final locator = AppleExchangeRootLocator(
        channel: _FakeAppleExchangeRootChannel(() async => directory.path),
        isApplePlatform: () => true,
      );

      final result = await AppleVelockExchangeDiscovery(
        rootLocator: locator,
        candidate: candidate,
      ).discover();

      expect(result.availability, VelockExchangeAvailability.available);
      expect(result.candidate, same(candidate));
    },
  );

  test(
    'Apple discovery rejects a missing root and a non-Apple platform',
    () async {
      final missingDirectory = Directory(
        '${Directory.systemTemp.path}/velock-missing-${DateTime.now().microsecondsSinceEpoch}',
      );
      final missing = await AppleVelockExchangeDiscovery(
        rootLocator: AppleExchangeRootLocator(
          channel: _FakeAppleExchangeRootChannel(
            () async => missingDirectory.path,
          ),
          isApplePlatform: () => true,
        ),
        candidate: candidate,
      ).discover();
      final unsupported = await AppleVelockExchangeDiscovery(
        rootLocator: AppleExchangeRootLocator(
          channel: _FakeAppleExchangeRootChannel(() async => '/unused'),
          isApplePlatform: () => false,
        ),
        candidate: candidate,
      ).discover();

      expect(
        missing.availability,
        VelockExchangeAvailability.configurationMissing,
      );
      expect(
        unsupported.availability,
        VelockExchangeAvailability.appNotInstalled,
      );
    },
  );
}

class _FakeAndroidExchangeChannel implements AndroidExchangeChannel {
  _FakeAndroidExchangeChannel(this._readyOutboxIds);

  final Future<List<String>> Function() _readyOutboxIds;

  @override
  Future<List<String>> readyOutboxIds() => _readyOutboxIds();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAppleExchangeRootChannel implements AppleExchangeRootChannel {
  _FakeAppleExchangeRootChannel(this._readExchangeRoot);

  final Future<String?> Function() _readExchangeRoot;

  @override
  Future<String?> readExchangeRoot() => _readExchangeRoot();
}
