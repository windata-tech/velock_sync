import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

void main() {
  test(
    'trusted data-plane probe still fails closed without pairing control plane',
    () async {
      final result = await PlatformVelockWizardReadinessService(
        androidExchange: _ProbeExchange(() async => const []),
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
      final result = await PlatformVelockWizardReadinessService(
        appleRoot: AppleExchangeRootLocator(
          channel: _AppleRootChannel(root.path),
          isApplePlatform: () => true,
        ),
        applePairingControl: _ProbePairingControl(),
        isAndroid: () => false,
        isApple: () => true,
      ).inspect();

      expect(result.availability, VelockWizardAvailability.ready);
      expect(result.descriptor?.producerId, 'producer-1');
    },
  );

  test('platform failures map to typed retry states', () async {
    final authorization = await PlatformVelockWizardReadinessService(
      androidExchange: _ProbeExchange(
        () async => throw PlatformException(code: 'ACCESS_DENIED'),
      ),
      isAndroid: () => true,
      isApple: () => false,
    ).inspect();
    final missing = await PlatformVelockWizardReadinessService(
      androidExchange: _ProbeExchange(
        () async => throw PlatformException(code: 'NOT_FOUND'),
      ),
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
        isAndroid: () => true,
        isApple: () => false,
      ).inspect();

      expect(result.availability, VelockWizardAvailability.ready);
      expect(result.canCreate, isTrue);
      expect(result.descriptor?.producerId, 'producer-1');
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

class _ProbePairingControl implements AndroidPairingControlChannel {
  @override
  Future<VelockPairingDescriptor> pairingDescriptor() async =>
      VelockPairingDescriptor.parse(
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
