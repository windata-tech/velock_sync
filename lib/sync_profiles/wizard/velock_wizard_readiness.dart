import 'dart:io';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_velock_companion_probe.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

enum VelockWizardAvailability {
  ready,
  appNotInstalled,
  authorizationRequired,
  accessRevoked,
  unsupportedVersion,
  signatureMismatch,
  configurationMissing,
  temporarilyUnavailable,
  unsupportedPlatform,
}

class VelockWizardReadiness {
  const VelockWizardReadiness(this.availability, {this.descriptor});

  final VelockWizardAvailability availability;
  final VelockPairingDescriptor? descriptor;

  bool get canCreate =>
      availability == VelockWizardAvailability.ready && descriptor != null;
  bool get canRetry => switch (availability) {
    VelockWizardAvailability.appNotInstalled ||
    VelockWizardAvailability.authorizationRequired ||
    VelockWizardAvailability.accessRevoked ||
    VelockWizardAvailability.temporarilyUnavailable => true,
    _ => false,
  };
}

abstract interface class VelockWizardReadinessService {
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId});
}

/// Probes only the independently installed Velock application's protected
/// Exchange boundary. Android is ready only when both the data plane and a
/// strict public pairing descriptor are available. Readiness still does not
/// authorize or save a profile; explicit signed pairing follows in the wizard.
class PlatformVelockWizardReadinessService
    implements VelockWizardReadinessService {
  PlatformVelockWizardReadinessService({
    AndroidExchangeChannel? androidExchange,
    AndroidPairingControlChannel? androidPairingControl,
    AppleExchangeRootLocator? appleRoot,
    VelockPairingControlChannel? applePairingControl,
    AppleVelockCompanionProbe? appleCompanionProbe,
    bool Function()? isAndroid,
    bool Function()? isApple,
  }) : _androidExchange =
           androidExchange ?? MethodChannelAndroidExchangeChannel(),
       _androidPairingControl = androidPairingControl,
       _appleRoot = appleRoot ?? AppleExchangeRootLocator(),
       _applePairingControl =
           applePairingControl ??
           ApplePairingControlChannel(
             rootLocator: appleRoot ?? AppleExchangeRootLocator(),
           ),
       _appleCompanionProbe =
           appleCompanionProbe ??
           const MethodChannelAppleVelockCompanionProbe(),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid),
       _isApple = isApple ?? (() => Platform.isIOS || Platform.isMacOS);

  final AndroidExchangeChannel _androidExchange;
  final AndroidPairingControlChannel? _androidPairingControl;
  final AppleExchangeRootLocator _appleRoot;
  final VelockPairingControlChannel _applePairingControl;
  final AppleVelockCompanionProbe _appleCompanionProbe;
  final bool Function() _isAndroid;
  final bool Function() _isApple;

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async {
    try {
      if (_isAndroid()) {
        await _androidExchange.readyOutboxIds();
        final control =
            _androidPairingControl ??
            (_androidExchange is AndroidPairingControlChannel
                ? _androidExchange as AndroidPairingControlChannel
                : null);
        if (control == null) {
          return const VelockWizardReadiness(
            VelockWizardAvailability.configurationMissing,
          );
        }
        final descriptor = await control.pairingDescriptor();
        final authorization = syncAppInstanceId == null
            ? VelockDeviceAuthorizationStatus.granted
            : await control.queryAuthorizationStatus(syncAppInstanceId);
        if (authorization == VelockDeviceAuthorizationStatus.revoked) {
          return VelockWizardReadiness(
            VelockWizardAvailability.accessRevoked,
            descriptor: descriptor,
          );
        }
        return VelockWizardReadiness(
          VelockWizardAvailability.ready,
          descriptor: descriptor,
        );
      }
      if (_isApple()) {
        if (!await _appleCompanionProbe.isInstalled()) {
          return const VelockWizardReadiness(
            VelockWizardAvailability.appNotInstalled,
          );
        }
        final root = await _appleRoot.locate();
        if (!await root.exists()) {
          return const VelockWizardReadiness(
            VelockWizardAvailability.configurationMissing,
          );
        }
        final descriptor = await _applePairingControl.pairingDescriptor();
        final authorization = syncAppInstanceId == null
            ? VelockDeviceAuthorizationStatus.granted
            : await _applePairingControl.queryAuthorizationStatus(
                syncAppInstanceId,
              );
        if (authorization == VelockDeviceAuthorizationStatus.revoked) {
          return VelockWizardReadiness(
            VelockWizardAvailability.accessRevoked,
            descriptor: descriptor,
          );
        }
        return VelockWizardReadiness(
          VelockWizardAvailability.ready,
          descriptor: descriptor,
        );
      }
      return const VelockWizardReadiness(
        VelockWizardAvailability.unsupportedPlatform,
      );
    } on PlatformException catch (error) {
      return VelockWizardReadiness(_platformAvailability(error.code));
    } on MissingPluginException {
      return const VelockWizardReadiness(
        VelockWizardAvailability.unsupportedVersion,
      );
    } on UnsupportedError {
      return const VelockWizardReadiness(
        VelockWizardAvailability.appNotInstalled,
      );
    } on FileSystemException {
      return const VelockWizardReadiness(
        VelockWizardAvailability.temporarilyUnavailable,
      );
    } on Object {
      return const VelockWizardReadiness(
        VelockWizardAvailability.configurationMissing,
      );
    }
  }

  VelockWizardAvailability _platformAvailability(String code) => switch (code) {
    'NOT_FOUND' ||
    'appNotInstalled' => VelockWizardAvailability.appNotInstalled,
    'ACCESS_DENIED' ||
    'authorizationRequired' => VelockWizardAvailability.authorizationRequired,
    'UNSUPPORTED_VERSION' ||
    'unsupportedVersion' => VelockWizardAvailability.unsupportedVersion,
    'accessRevoked' => VelockWizardAvailability.accessRevoked,
    'signatureMismatch' => VelockWizardAvailability.signatureMismatch,
    'TEMPORARY_UNAVAILABLE' ||
    'temporarilyUnavailable' => VelockWizardAvailability.temporarilyUnavailable,
    _ => VelockWizardAvailability.configurationMissing,
  };
}
