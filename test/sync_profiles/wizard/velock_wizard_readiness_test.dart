import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_velock_companion_probe.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

import '../../dataset_adapters/velock_exchange/velock_companion_capabilities_fixture.dart';

void main() {
  test(
    'trusted data-plane probe still fails closed without pairing control plane',
    () async {
      final result = await PlatformVelockWizardReadinessService(
        androidExchange: _ProbeExchange(() async => const []),
        androidExchangeConfigured: () async => true,
        isAndroid: () => true,
        isApple: () => false,
      ).inspect();

      expect(
        result.availability,
        VelockWizardAvailability.configurationMissing,
      );
      expect(result.canCreate, isFalse);
    },
  );

  test(
    'Apple App Group is ready only when its public descriptor exists',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'velock-apple-readiness-',
      );
      addTearDown(() => root.delete(recursive: true));
      await writeVelockCompanionCapabilities(root);
      final result = await PlatformVelockWizardReadinessService(
        appleRoot: AppleExchangeRootLocator(
          channel: _AppleRootChannel(root.path),
          isApplePlatform: () => true,
        ),
        applePairingControl: _ProbePairingControl(),
        appleCompanionProbe: _ProbeCompanionInstalled(() async => true),
        isAndroid: () => false,
        isApple: () => true,
      ).inspect();

      expect(result.availability, VelockWizardAvailability.ready);
      expect(result.descriptor?.producerId, 'producer-1');
    },
  );

  test(
    'Apple App Group leftovers never report ready when Velock is uninstalled',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'velock-apple-uninstalled-',
      );
      addTearDown(() => root.delete(recursive: true));
      final result = await PlatformVelockWizardReadinessService(
        appleRoot: AppleExchangeRootLocator(
          channel: _AppleRootChannel(root.path),
          isApplePlatform: () => true,
        ),
        applePairingControl: _ProbePairingControl(),
        appleCompanionProbe: _ProbeCompanionInstalled(() async => false),
        isAndroid: () => false,
        isApple: () => true,
      ).inspect();

      expect(result.availability, VelockWizardAvailability.appNotInstalled);
      expect(result.canCreate, isFalse);
      expect(result.canRetry, isTrue);
    },
  );

  test(
    'Apple readiness fails closed when the install probe is unavailable',
    () async {
      final result = await PlatformVelockWizardReadinessService(
        appleRoot: AppleExchangeRootLocator(
          channel: _AppleRootChannel('/unused'),
          isApplePlatform: () => true,
        ),
        applePairingControl: _ProbePairingControl(),
        appleCompanionProbe: _ProbeCompanionInstalled(
          () async => throw MissingPluginException(),
        ),
        isAndroid: () => false,
        isApple: () => true,
      ).inspect();

      expect(result.availability, VelockWizardAvailability.unsupportedVersion);
      expect(result.canCreate, isFalse);
    },
  );

  test('platform failures map to typed retry states', () async {
    final authorization = await PlatformVelockWizardReadinessService(
      androidExchange: _ProbeExchange(
        () async => throw PlatformException(code: 'ACCESS_DENIED'),
      ),
      androidExchangeConfigured: () async => true,
      isAndroid: () => true,
      isApple: () => false,
    ).inspect();
    final missing = await PlatformVelockWizardReadinessService(
      androidExchange: _ProbeExchange(
        () async => throw PlatformException(code: 'NOT_FOUND'),
      ),
      androidExchangeConfigured: () async => true,
      isAndroid: () => true,
      isApple: () => false,
    ).inspect();

    expect(
      authorization.availability,
      VelockWizardAvailability.authorizationRequired,
    );
    expect(authorization.canRetry, isTrue);
    expect(missing.availability, VelockWizardAvailability.appNotInstalled);
    expect(missing.canRetry, isTrue);
  });

  test(
    'trusted data and control planes expose a verified descriptor',
    () async {
      final result = await PlatformVelockWizardReadinessService(
        androidExchange: _ProbeExchange(() async => const []),
        androidPairingControl: _ProbePairingControl(),
        androidExchangeConfigured: () async => true,
        isAndroid: () => true,
        isApple: () => false,
      ).inspect();

      expect(result.availability, VelockWizardAvailability.ready);
      expect(result.canCreate, isTrue);
      expect(result.descriptor?.producerId, 'producer-1');
    },
  );

  test('reports access revoked for an already-paired device', () async {
    final result = await PlatformVelockWizardReadinessService(
      androidExchange: _ProbeExchange(() async => const []),
      androidPairingControl: _ProbePairingControl.revoked(),
      androidExchangeConfigured: () async => true,
      isAndroid: () => true,
      isApple: () => false,
    ).inspect(syncAppInstanceId: 'sync-instance-1');

    expect(result.availability, VelockWizardAvailability.accessRevoked);
    expect(result.canCreate, isFalse);
    expect(result.canRetry, isTrue);
  });

  group('Velock companion version gate', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('velock-capabilities-');
    });
    tearDown(() => root.delete(recursive: true));

    Future<VelockWizardReadiness> inspect({_ProbePairingControl? control}) =>
        PlatformVelockWizardReadinessService(
          appleRoot: AppleExchangeRootLocator(
            channel: _AppleRootChannel(root.path),
            isApplePlatform: () => true,
          ),
          applePairingControl: control ?? _ProbePairingControl(),
          appleCompanionProbe: _ProbeCompanionInstalled(() async => true),
          isAndroid: () => false,
          isApple: () => true,
        ).inspect(syncAppInstanceId: 'sync-instance-1');

    test(
      'Velock 2.0.6 (pairing descriptor but no capabilities) needs an update',
      () async {
        final control = _ProbePairingControl();
        final result = await inspect(control: control);
        expect(
          result.availability,
          VelockWizardAvailability.velockUpdateRequired,
        );
        expect(result.canCreate, isFalse);
        expect(result.canRetry, isTrue);
        expect(result.descriptor, isNull);
        // Nothing about pairing is read or started in this state.
        expect(control.calls, isEmpty);
      },
    );

    test('a malformed descriptor counts as too old', () async {
      final file = File('${root.path}/Control/Capabilities.json');
      await file.parent.create(recursive: true);
      for (final body in [
        'not json',
        '[]',
        '{"schema":0,"app":"velock","capabilities":[]}',
        '{"schema":"1","app":"velock","capabilities":[]}',
        '{"schema":1,"app":"other","capabilities":[]}',
        '{"schema":1,"app":"velock","capabilities":"join-request-v2"}',
      ]) {
        await file.writeAsString(body);
        expect(
          (await inspect()).availability,
          VelockWizardAvailability.velockUpdateRequired,
          reason: body,
        );
      }
    });

    test('a missing required capability counts as too old', () async {
      await writeVelockCompanionCapabilities(
        root,
        capabilities: const [
          'join-request-v2',
          'cloud-recovery-file-v1',
          'current-snapshot-v2',
          'outbox-status-v1',
        ],
      );
      expect(
        (await inspect()).availability,
        VelockWizardAvailability.velockUpdateRequired,
      );
    });

    test(
      'newer descriptors with unknown keys and capabilities stay ready',
      () async {
        await writeVelockCompanionCapabilities(
          root,
          capabilities: const [
            'join-request-v2',
            'cloud-recovery-file-v1',
            'route-sync-settings',
            'current-snapshot-v2',
            'outbox-status-v1',
            'some-future-feature-v9',
          ],
          extra: const {
            'schema': 4,
            'minimumSync': '1.3.0',
            'nested': {'anything': true},
          },
        );
        final result = await inspect();
        expect(result.availability, VelockWizardAvailability.ready);
        expect(result.canCreate, isTrue);
      },
    );
  });

  test(
    'an ordinary Android build without a configured exchange is unsupported, not "authorize in Velock"',
    () async {
      var probed = false;
      final result = await PlatformVelockWizardReadinessService(
        androidExchange: _ProbeExchange(() async {
          probed = true;
          throw PlatformException(code: 'ACCESS_DENIED');
        }),
        androidPairingControl: _ProbePairingControl(),
        androidExchangeConfigured: () async => false,
        isAndroid: () => true,
        isApple: () => false,
      ).inspect(syncAppInstanceId: 'sync-instance-1');

      expect(result.availability, VelockWizardAvailability.unsupportedPlatform);
      expect(result.canCreate, isFalse);
      expect(result.canRetry, isFalse);
      expect(probed, isFalse);
    },
  );

  test(
    'the Android configuration probe fails closed on an older native side',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('android-configured-test');
      expect(await androidVelockExchangeConfigured(channel: channel), isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'isExchangeConfigured');
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(await androidVelockExchangeConfigured(channel: channel), isTrue);
    },
  );

  test('unconfigured desktop platform is explicitly unsupported', () async {
    final result = await PlatformVelockWizardReadinessService(
      androidExchange: _ProbeExchange(() async => const []),
      isAndroid: () => false,
      isApple: () => false,
    ).inspect();

    expect(result.availability, VelockWizardAvailability.unsupportedPlatform);
    expect(result.canRetry, isFalse);
  });
}

class _ProbeExchange implements AndroidExchangeChannel {
  _ProbeExchange(this._probe);

  final Future<List<String>> Function() _probe;

  @override
  Future<List<String>> readyOutboxIds() => _probe();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppleRootChannel implements AppleExchangeRootChannel {
  const _AppleRootChannel(this.path);

  final String path;

  @override
  Future<String?> readExchangeRoot() async => path;
}

class _ProbeCompanionInstalled implements AppleVelockCompanionProbe {
  const _ProbeCompanionInstalled(this._installed);

  final Future<bool> Function() _installed;

  @override
  Future<bool> isInstalled() => _installed();
}

class _ProbePairingControl implements AndroidPairingControlChannel {
  _ProbePairingControl({this.revoked = false});

  factory _ProbePairingControl.revoked() => _ProbePairingControl(revoked: true);

  final bool revoked;
  final List<String> calls = [];

  @override
  Future<VelockPairingDescriptor> pairingDescriptor() async {
    calls.add('pairingDescriptor');
    return _descriptor();
  }

  VelockPairingDescriptor _descriptor() => VelockPairingDescriptor.parse(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'controlVersion': 1,
          'exchangeBindingId': 'binding-1',
          'exchangeVersion': 1,
          'producerId': 'producer-1',
          'producerPublicKeyId': 'key-1',
          'producerSigningPublicKey': base64UrlEncode(
            Uint8List.fromList(List.filled(32, 1)),
          ),
          'protocol': 'velock-sync',
          'protocolVersion': 1,
          'publishedAt': '2026-07-18T08:00:00.000Z',
          'signatureAlgorithm': 'Ed25519',
        }),
      ),
    ),
  );

  @override
  Future<VelockDeviceAuthorizationStatus> queryAuthorizationStatus(
    String syncAppInstanceId,
  ) async {
    calls.add('queryAuthorizationStatus');
    return revoked
        ? VelockDeviceAuthorizationStatus.revoked
        : VelockDeviceAuthorizationStatus.granted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
