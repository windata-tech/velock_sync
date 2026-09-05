import 'dart:io';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_velock_companion_probe.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

/// Public, privacy-safe availability returned before a pairing or sync attempt.
enum VelockExchangeAvailability {
  available,
  appNotInstalled,
  unsupportedVersion,
  authorizationRequired,
  signatureMismatch,
  configurationMissing,
  accessRevoked,
  temporarilyUnavailable,
}

class VelockExchangeCandidate {
  const VelockExchangeCandidate({
    required this.producerId,
    required this.producerPublicKeyId,
    required this.exchangeBindingId,
    this.producerSigningPublicKey,
  });

  final String producerId;
  final String producerPublicKeyId;
  final String exchangeBindingId;
  final String? producerSigningPublicKey;

  bool get isWellFormed => [
    producerId,
    producerPublicKeyId,
    exchangeBindingId,
  ].every((value) => value.trim().isNotEmpty);

  bool sameIdentityAs(VelockExchangeCandidate other) =>
      producerId == other.producerId &&
      producerPublicKeyId == other.producerPublicKeyId &&
      exchangeBindingId == other.exchangeBindingId;
}

/// Initial Android discovery reads the Velock-owned public descriptor through
/// the same package/certificate-validated, signature-protected bridge as the
/// data plane. It removes the former requirement to preconfigure producer IDs.
class AndroidVelockPairingDiscovery implements VelockExchangeDiscovery {
  const AndroidVelockPairingDiscovery(this._control);

  final AndroidPairingControlChannel _control;

  @override
  Future<VelockExchangeDiscoveryResult> discover() async {
    try {
      final VelockPairingDescriptor descriptor = await _control
          .pairingDescriptor();
      return VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.available,
        candidate: VelockExchangeCandidate(
          producerId: descriptor.producerId,
          producerPublicKeyId: descriptor.producerPublicKeyId,
          producerSigningPublicKey: descriptor.producerSigningPublicKey,
          exchangeBindingId: descriptor.exchangeBindingId,
        ),
      );
    } on PlatformException catch (error) {
      return VelockExchangeDiscoveryResult(
        availability: _availabilityForPlatformError(error.code),
      );
    } on MissingPluginException {
      return const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.unsupportedVersion,
      );
    } on Object {
      return const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.configurationMissing,
      );
    }
  }
}

class VelockExchangeDiscoveryResult {
  const VelockExchangeDiscoveryResult({
    required this.availability,
    this.candidate,
  });

  final VelockExchangeAvailability availability;
  final VelockExchangeCandidate? candidate;

  bool get isAvailable =>
      availability == VelockExchangeAvailability.available &&
      candidate != null &&
      candidate!.isWellFormed;
}

abstract interface class VelockExchangeDiscovery {
  Future<VelockExchangeDiscoveryResult> discover();
}

/// Android discovery intentionally probes the signature-protected provider.
/// Native code owns package/authority/certificate validation and fails closed
/// before returning opaque IDs. Discovery does not imply that the producer is
/// paired or trusted by Sync.
class AndroidVelockExchangeDiscovery implements VelockExchangeDiscovery {
  AndroidVelockExchangeDiscovery({
    required AndroidExchangeChannel exchange,
    required VelockExchangeCandidate candidate,
  }) : _exchange = exchange,
       _candidate = candidate;

  final AndroidExchangeChannel _exchange;
  final VelockExchangeCandidate _candidate;

  @override
  Future<VelockExchangeDiscoveryResult> discover() async {
    if (!_candidate.isWellFormed) return _configurationMissing();
    try {
      await _exchange.readyOutboxIds();
      return VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.available,
        candidate: _candidate,
      );
    } on PlatformException catch (error) {
      return VelockExchangeDiscoveryResult(
        availability: _availabilityForPlatformError(error.code),
      );
    } on MissingPluginException {
      return const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.unsupportedVersion,
      );
    } on Object {
      // An unclassified provider failure must never be considered trusted.
      return _configurationMissing();
    }
  }

  VelockExchangeDiscoveryResult _configurationMissing() =>
      const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.configurationMissing,
      );
}

/// Apple discovery revalidates the paired producer against the descriptor in
/// the dedicated Exchange App Group. The App Group root can also be opened by
/// Sync, so its existence alone does not prove that Velock has initialized it.
class AppleVelockExchangeDiscovery implements VelockExchangeDiscovery {
  AppleVelockExchangeDiscovery({
    required AppleExchangeRootLocator rootLocator,
    required VelockExchangeCandidate candidate,
    VelockPairingControlChannel? control,
    AppleVelockCompanionProbe? companionProbe,
  }) : _control =
           control ?? ApplePairingControlChannel(rootLocator: rootLocator),
       _companionProbe =
           companionProbe ?? const MethodChannelAppleVelockCompanionProbe(),
       _candidate = candidate;

  final VelockPairingControlChannel _control;
  final AppleVelockCompanionProbe _companionProbe;
  final VelockExchangeCandidate _candidate;

  @override
  Future<VelockExchangeDiscoveryResult> discover() async {
    if (!_candidate.isWellFormed) return _configurationMissing();
    try {
      if (!await _companionProbe.isInstalled()) {
        return const VelockExchangeDiscoveryResult(
          availability: VelockExchangeAvailability.appNotInstalled,
        );
      }
      final descriptor = await _control.pairingDescriptor();
      final discovered = VelockExchangeCandidate(
        producerId: descriptor.producerId,
        producerPublicKeyId: descriptor.producerPublicKeyId,
        producerSigningPublicKey: descriptor.producerSigningPublicKey,
        exchangeBindingId: descriptor.exchangeBindingId,
      );
      if (!_candidate.sameIdentityAs(discovered)) {
        return const VelockExchangeDiscoveryResult(
          availability: VelockExchangeAvailability.accessRevoked,
        );
      }
      return VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.available,
        candidate: discovered,
      );
    } on PlatformException catch (error) {
      return VelockExchangeDiscoveryResult(
        availability: _availabilityForPlatformError(error.code),
      );
    } on MissingPluginException {
      return const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.unsupportedVersion,
      );
    } on UnsupportedError {
      return const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.appNotInstalled,
      );
    } on StateError {
      return _configurationMissing();
    } on FileSystemException {
      return const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.temporarilyUnavailable,
      );
    } on Object {
      return _configurationMissing();
    }
  }

  VelockExchangeDiscoveryResult _configurationMissing() =>
      const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.configurationMissing,
      );
}

VelockExchangeAvailability _availabilityForPlatformError(
  String code,
) => switch (code) {
  'NOT_FOUND' => VelockExchangeAvailability.appNotInstalled,
  'UNSUPPORTED_VERSION' => VelockExchangeAvailability.unsupportedVersion,
  'ACCESS_DENIED' => VelockExchangeAvailability.authorizationRequired,
  'TEMPORARY_UNAVAILABLE' => VelockExchangeAvailability.temporarilyUnavailable,
  'appNotInstalled' => VelockExchangeAvailability.appNotInstalled,
  'unsupportedVersion' => VelockExchangeAvailability.unsupportedVersion,
  'authorizationRequired' => VelockExchangeAvailability.authorizationRequired,
  'signatureMismatch' => VelockExchangeAvailability.signatureMismatch,
  'accessRevoked' => VelockExchangeAvailability.accessRevoked,
  'temporarilyUnavailable' => VelockExchangeAvailability.temporarilyUnavailable,
  _ => VelockExchangeAvailability.configurationMissing,
};
