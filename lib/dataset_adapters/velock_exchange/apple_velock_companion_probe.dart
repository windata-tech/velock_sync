import 'package:flutter/services.dart';

const _companionInstalledChannelName =
    'tech.windata.velock.sync/companion_installed';
const _companionInstalledMethod = 'isInstalled';

/// Tells whether the independently installed Velock app is present on Apple
/// platforms.
///
/// The shared App Group alone is not proof: Velock Sync owns the same
/// container, so stale descriptors survive a Velock uninstall. This probe asks
/// the OS directly instead of trusting leftovers in the group.
abstract interface class AppleVelockCompanionProbe {
  Future<bool> isInstalled();
}

class MethodChannelAppleVelockCompanionProbe
    implements AppleVelockCompanionProbe {
  const MethodChannelAppleVelockCompanionProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_companionInstalledChannelName);

  final MethodChannel _channel;

  @override
  Future<bool> isInstalled() async =>
      await _channel.invokeMethod<bool>(_companionInstalledMethod) ?? false;
}
