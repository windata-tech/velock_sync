import 'dart:io';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
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

/// Apple discovery accesses only the dedicated exchange App Group root exposed
/// by [AppleExchangeRootLocator]. It never follows arbitrary file paths.
class AppleVelockExchangeDiscovery implements VelockExchangeDiscovery {
  AppleVelockExchangeDiscovery({
    required AppleExchangeRootLocator rootLocator,
    required VelockExchangeCandidate candidate,
  }) : _rootLocator = rootLocator,
       _candidate = candidate;

  final AppleExchangeRootLocator _rootLocator;
  final VelockExchangeCandidate _candidate;

  @override
  Future<VelockExchangeDiscoveryResult> discover() async {
    if (!_candidate.isWellFormed) return _configurationMissing();
    try {
      final root = await _rootLocator.locate();
      if (!await root.exists()) return _configurationMissing();
      return VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.available,
        candidate: _candidate,
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
