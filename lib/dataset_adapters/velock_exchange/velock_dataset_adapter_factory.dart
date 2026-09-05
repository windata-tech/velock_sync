import 'dart:io';

import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

enum VelockExchangePlatform { android, apple, unsupported }

class VelockDatasetAdapterUnavailableException implements Exception {
  const VelockDatasetAdapterUnavailableException(this.availability);

  final VelockExchangeAvailability availability;

  @override
  String toString() => 'Velock exchange adapter is unavailable.';
}

abstract interface class VelockDatasetAdapterFactory {
  Future<SyncDatasetAdapter> create(VelockSyncProfile profile);
}

/// Revalidates the dedicated platform exchange and paired identity every time
/// an adapter is reconstructed. A profile is never enough by itself to regain
/// access after package, entitlement, authorization, or producer trust changes.
class PlatformVelockDatasetAdapterFactory
    implements VelockDatasetAdapterFactory {
  PlatformVelockDatasetAdapterFactory({
    VelockExchangeDiscovery? discovery,
    VelockExchangeDiscovery Function(VelockExchangeCandidate candidate)?
    discoveryForCandidate,
    required AndroidExchangeChannel androidExchange,
    required AppleExchangeRootLocator appleRootLocator,
    VelockPairingControlChannel? pairingControl,
    VelockExchangePlatform Function()? platform,
  }) : _discovery = discovery,
       _discoveryForCandidate = discoveryForCandidate,
       _androidExchange = androidExchange,
       _appleRootLocator = appleRootLocator,
       _pairingControl = pairingControl,
       _platform = platform ?? _currentPlatform;

  /// A fixed discovery is retained for pairing/test callers that already own a
  /// verified candidate. Production profile runs use [discoveryForCandidate]
  /// (or the platform fallback) so the candidate always comes from the local
  /// paired profile being revalidated.
  final VelockExchangeDiscovery? _discovery;
  final VelockExchangeDiscovery Function(VelockExchangeCandidate candidate)?
  _discoveryForCandidate;
  final AndroidExchangeChannel _androidExchange;
  final AppleExchangeRootLocator _appleRootLocator;
  final VelockPairingControlChannel? _pairingControl;
  final VelockExchangePlatform Function() _platform;

  @override
  Future<SyncDatasetAdapter> create(VelockSyncProfile profile) async {
    if (profile.state != SyncProfileState.active) {
      throw const VelockDatasetAdapterUnavailableException(
        VelockExchangeAvailability.authorizationRequired,
      );
    }

    final expectedCandidate = VelockExchangeCandidate(
      producerId: profile.pairedProducerId,
      producerPublicKeyId: profile.pairedProducerPublicKeyId,
      exchangeBindingId: profile.exchangeBindingId,
    );
    final discoverySource =
        _discoveryForCandidate?.call(expectedCandidate) ?? _discovery;
    final discovery =
        await (discoverySource ?? _platformDiscovery(expectedCandidate))
            .discover();
    final candidate = discovery.candidate;
    if (!discovery.isAvailable ||
        candidate == null ||
        candidate.producerId != profile.pairedProducerId ||
        candidate.producerPublicKeyId != profile.pairedProducerPublicKeyId ||
        candidate.exchangeBindingId != profile.exchangeBindingId) {
      throw VelockDatasetAdapterUnavailableException(discovery.availability);
    }

    final authorization = await _authorizationStatus(profile.deviceId);
    if (authorization == VelockDeviceAuthorizationStatus.revoked) {
      throw const VelockDatasetAdapterUnavailableException(
        VelockExchangeAvailability.accessRevoked,
      );
    }

    switch (_platform()) {
      case VelockExchangePlatform.android:
        return AndroidVelockExchangeDatasetAdapter(
          datasetId: profile.datasetId,
          vaultId: profile.vaultId,
          producerDeviceId: profile.pairedProducerId,
          displayName: profile.displayName,
          exchange: _androidExchange,
        );
      case VelockExchangePlatform.apple:
        final root = await _appleRootLocator.locate();
        if (!await root.exists()) {
          throw const VelockDatasetAdapterUnavailableException(
            VelockExchangeAvailability.configurationMissing,
          );
        }
        return VelockExchangeDatasetAdapter(
          datasetId: profile.datasetId,
          vaultId: profile.vaultId,
          producerDeviceId: profile.pairedProducerId,
          displayName: profile.displayName,
          exchange: VelockExchangeStore(root),
        );
      case VelockExchangePlatform.unsupported:
        throw const VelockDatasetAdapterUnavailableException(
          VelockExchangeAvailability.appNotInstalled,
        );
    }
  }

  VelockExchangeDiscovery _platformDiscovery(
    VelockExchangeCandidate candidate,
  ) => switch (_platform()) {
    VelockExchangePlatform.android => AndroidVelockExchangeDiscovery(
      exchange: _androidExchange,
      candidate: candidate,
    ),
    VelockExchangePlatform.apple => AppleVelockExchangeDiscovery(
      rootLocator: _appleRootLocator,
      candidate: candidate,
    ),
    VelockExchangePlatform.unsupported => const _UnavailableDiscovery(),
  };

  Future<VelockDeviceAuthorizationStatus> _authorizationStatus(
    String syncAppInstanceId,
  ) async {
    final control = _pairingControl;
    if (control != null) {
      return control.queryAuthorizationStatus(syncAppInstanceId);
    }
    switch (_platform()) {
      case VelockExchangePlatform.android:
        return (_androidExchange as AndroidPairingControlChannel)
            .queryAuthorizationStatus(syncAppInstanceId);
      case VelockExchangePlatform.apple:
        final root = await _appleRootLocator.locate();
        if (!await root.exists()) {
          throw const VelockDatasetAdapterUnavailableException(
            VelockExchangeAvailability.configurationMissing,
          );
        }
        return ApplePairingControlChannel(
          rootLocator: _appleRootLocator,
        ).queryAuthorizationStatus(syncAppInstanceId);
      case VelockExchangePlatform.unsupported:
        throw const VelockDatasetAdapterUnavailableException(
          VelockExchangeAvailability.appNotInstalled,
        );
    }
  }

  static VelockExchangePlatform _currentPlatform() {
    if (Platform.isAndroid) return VelockExchangePlatform.android;
    if (Platform.isIOS || Platform.isMacOS) return VelockExchangePlatform.apple;
    return VelockExchangePlatform.unsupported;
  }
}

class _UnavailableDiscovery implements VelockExchangeDiscovery {
  const _UnavailableDiscovery();

  @override
  Future<VelockExchangeDiscoveryResult> discover() async =>
      const VelockExchangeDiscoveryResult(
        availability: VelockExchangeAvailability.appNotInstalled,
      );
}
