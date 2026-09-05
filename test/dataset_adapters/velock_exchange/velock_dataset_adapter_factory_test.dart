import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

void main() {
  test(
    'creates the Android adapter only after current paired identity validates',
    () async {
      final factory = PlatformVelockDatasetAdapterFactory(
        discovery: _FakeDiscovery(() async => _available()),
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator('/unused', isApplePlatform: false),
        platform: () => VelockExchangePlatform.android,
      );

      final adapter = await factory.create(_profile());

      expect(adapter, isA<AndroidVelockExchangeDatasetAdapter>());
    },
  );

  test('creates the Apple adapter from the dedicated exchange root', () async {
    final root = await Directory.systemTemp.createTemp('velock-factory-');
    addTearDown(() => root.delete(recursive: true));
    final factory = PlatformVelockDatasetAdapterFactory(
      discovery: _FakeDiscovery(() async => _available()),
      androidExchange: _FakeAndroidExchangeChannel(),
      appleRootLocator: _locator(root.path),
      platform: () => VelockExchangePlatform.apple,
    );

    final adapter = await factory.create(_profile());

    expect(adapter, isA<VelockExchangeDatasetAdapter>());
  });

  test(
    'derives discovery revalidation from the persisted pairing fields',
    () async {
      VelockExchangeCandidate? requested;
      final factory = PlatformVelockDatasetAdapterFactory(
        discoveryForCandidate: (candidate) {
          requested = candidate;
          return _FakeDiscovery(
            () async => VelockExchangeDiscoveryResult(
              availability: VelockExchangeAvailability.available,
              candidate: candidate,
            ),
          );
        },
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator('/unused', isApplePlatform: false),
        platform: () => VelockExchangePlatform.android,
      );

      await factory.create(_profile());

      expect(requested?.producerId, _candidate.producerId);
      expect(requested?.producerPublicKeyId, _candidate.producerPublicKeyId);
      expect(requested?.exchangeBindingId, _candidate.exchangeBindingId);
    },
  );

  test(
    'rejects inactive profiles, unavailable exchange, and changed identity',
    () async {
      final inactiveFactory = PlatformVelockDatasetAdapterFactory(
        discovery: _FakeDiscovery(() async => _available()),
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator('/unused', isApplePlatform: false),
        platform: () => VelockExchangePlatform.android,
      );
      await _expectUnavailable(
        inactiveFactory.create(
          _profile(state: SyncProfileState.accessRequired),
        ),
        VelockExchangeAvailability.authorizationRequired,
      );

      final unavailableFactory = PlatformVelockDatasetAdapterFactory(
        discovery: _FakeDiscovery(
          () async => const VelockExchangeDiscoveryResult(
            availability: VelockExchangeAvailability.signatureMismatch,
          ),
        ),
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator('/unused', isApplePlatform: false),
        platform: () => VelockExchangePlatform.android,
      );
      await _expectUnavailable(
        unavailableFactory.create(_profile()),
        VelockExchangeAvailability.signatureMismatch,
      );

      final changedIdentityFactory = PlatformVelockDatasetAdapterFactory(
        discovery: _FakeDiscovery(
          () async => const VelockExchangeDiscoveryResult(
            availability: VelockExchangeAvailability.available,
            candidate: VelockExchangeCandidate(
              producerId: 'different-producer',
              producerPublicKeyId: 'producer-key-1',
              exchangeBindingId: 'exchange-1',
            ),
          ),
        ),
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator('/unused', isApplePlatform: false),
        platform: () => VelockExchangePlatform.android,
      );
      await _expectUnavailable(
        changedIdentityFactory.create(_profile()),
        VelockExchangeAvailability.available,
      );
    },
  );

  test(
    'fails closed for unsupported platforms and roots that disappear after discovery',
    () async {
      final unsupportedFactory = PlatformVelockDatasetAdapterFactory(
        discovery: _FakeDiscovery(() async => _available()),
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator('/unused', isApplePlatform: false),
        platform: () => VelockExchangePlatform.unsupported,
      );
      await _expectUnavailable(
        unsupportedFactory.create(_profile()),
        VelockExchangeAvailability.appNotInstalled,
      );

      final missingRoot = Directory(
        '${Directory.systemTemp.path}/velock-root-gone-${DateTime.now().microsecondsSinceEpoch}',
      );
      final appleFactory = PlatformVelockDatasetAdapterFactory(
        discovery: _FakeDiscovery(() async => _available()),
        androidExchange: _FakeAndroidExchangeChannel(),
        appleRootLocator: _locator(missingRoot.path),
        platform: () => VelockExchangePlatform.apple,
      );
      await _expectUnavailable(
        appleFactory.create(_profile()),
        VelockExchangeAvailability.configurationMissing,
      );
    },
  );

  test('rejects a profile whose Velock authorization was revoked', () async {
    final factory = PlatformVelockDatasetAdapterFactory(
      discovery: _FakeDiscovery(() async => _available()),
      androidExchange: _FakeAndroidExchangeChannel(),
      appleRootLocator: _locator('/unused', isApplePlatform: false),
      pairingControl: _FakePairingControl(
        () async => VelockDeviceAuthorizationStatus.revoked,
      ),
      platform: () => VelockExchangePlatform.android,
    );

    await _expectUnavailable(
      factory.create(_profile()),
      VelockExchangeAvailability.accessRevoked,
    );
  });
}

Future<void> _expectUnavailable(
  Future<Object?> operation,
  VelockExchangeAvailability availability,
) => expectLater(
  operation,
  throwsA(
    isA<VelockDatasetAdapterUnavailableException>().having(
      (error) => error.availability,
      'availability',
      availability,
    ),
  ),
);

AppleExchangeRootLocator _locator(String path, {bool isApplePlatform = true}) =>
    AppleExchangeRootLocator(
      channel: _FakeAppleExchangeRootChannel(() async => path),
      isApplePlatform: () => isApplePlatform,
    );

const _candidate = VelockExchangeCandidate(
  producerId: 'producer-1',
  producerPublicKeyId: 'producer-key-1',
  exchangeBindingId: 'exchange-1',
);

VelockExchangeDiscoveryResult _available() =>
    const VelockExchangeDiscoveryResult(
      availability: VelockExchangeAvailability.available,
      candidate: _candidate,
    );

VelockSyncProfile _profile({
  SyncProfileState state = SyncProfileState.active,
}) => VelockSyncProfile(
  profileId: 'profile-1',
  datasetId: 'dataset-1',
  vaultId: 'vault-1',
  deviceId: 'device-1',
  displayName: 'Velock vault',
  connectionId: 'connection-1',
  pairedProducerId: _candidate.producerId,
  pairedProducerPublicKeyId: _candidate.producerPublicKeyId,
  exchangeBindingId: _candidate.exchangeBindingId,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  state: state,
  createdAt: DateTime.utc(2026, 7, 17),
);

class _FakeDiscovery implements VelockExchangeDiscovery {
  _FakeDiscovery(this._discover);
  final Future<VelockExchangeDiscoveryResult> Function() _discover;

  @override
  Future<VelockExchangeDiscoveryResult> discover() => _discover();
}

class _FakeAndroidExchangeChannel
    implements AndroidExchangeChannel, AndroidPairingControlChannel {
  @override
  Future<VelockDeviceAuthorizationStatus> queryAuthorizationStatus(
    String syncAppInstanceId,
  ) async => VelockDeviceAuthorizationStatus.granted;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePairingControl implements AndroidPairingControlChannel {
  _FakePairingControl(this._status);

  final Future<VelockDeviceAuthorizationStatus> Function() _status;

  @override
  Future<VelockDeviceAuthorizationStatus> queryAuthorizationStatus(
    String syncAppInstanceId,
  ) => _status();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAppleExchangeRootChannel implements AppleExchangeRootChannel {
  _FakeAppleExchangeRootChannel(this._read);
  final Future<String?> Function() _read;

  @override
  Future<String?> readExchangeRoot() => _read();
}
