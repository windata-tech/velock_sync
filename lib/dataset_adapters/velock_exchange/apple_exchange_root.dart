import 'dart:io';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';

const velockExchangeAppGroupId = VelockExchangeV1Contract.appleAppGroup;
const _exchangeChannelName = VelockExchangeV1Contract.appleSyncFlutterChannel;

abstract interface class AppleExchangeRootChannel {
  Future<String?> readExchangeRoot();
}

class MethodChannelAppleExchangeRoot implements AppleExchangeRootChannel {
  const MethodChannelAppleExchangeRoot({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_exchangeChannelName);

  final MethodChannel _channel;

  @override
  Future<String?> readExchangeRoot() => _channel.invokeMethod<String>(
    VelockExchangeV1Contract.appleSyncRootMethod,
  );
}

/// Resolves only the dedicated App Group exchange directory. This boundary
/// intentionally exposes no API for Velock databases, keys, or app-private
/// business files.
class AppleExchangeRootLocator {
  AppleExchangeRootLocator({
    AppleExchangeRootChannel? channel,
    bool Function()? isApplePlatform,
  }) : _channel = channel ?? const MethodChannelAppleExchangeRoot(),
       _isApplePlatform =
           isApplePlatform ?? (() => Platform.isIOS || Platform.isMacOS);

  final AppleExchangeRootChannel _channel;
  final bool Function() _isApplePlatform;

  Future<Directory> locate() async {
    if (!_isApplePlatform()) {
      throw UnsupportedError('Velock exchange App Group is Apple-only.');
    }
    final path = await _channel.readExchangeRoot();
    if (path == null || path.isEmpty || !path.startsWith('/')) {
      throw StateError('Velock exchange App Group is unavailable.');
    }
    return Directory(path);
  }
}
