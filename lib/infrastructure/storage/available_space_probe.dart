import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Reads free bytes on the volume that contains an app-private staging path.
/// Implementations must not report total volume capacity as available space.
abstract interface class AvailableSpaceProbe {
  Future<int> availableBytes(Directory directory);
}

/// Production probe for mobile platforms and POSIX desktop hosts.
class PlatformAvailableSpaceProbe implements AvailableSpaceProbe {
  const PlatformAvailableSpaceProbe();

  static const _channel = MethodChannel('tech.windata.velock.sync/disk_space');

  @override
  Future<int> availableBytes(Directory directory) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final bytes = await _channel.invokeMethod<int>('availableBytes', {
        'path': directory.absolute.path,
      });
      if (bytes == null || bytes < 0) {
        throw StateError('Platform did not provide available storage.');
      }
      return bytes;
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final result = await Process.run('df', ['-Pk', directory.absolute.path]);
      if (result.exitCode != 0) {
        throw StateError('Unable to inspect available storage.');
      }
      final lines = result.stdout
          .toString()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList(growable: false);
      if (lines.length < 2) {
        throw StateError('Available storage output is invalid.');
      }
      final columns = lines.last.trim().split(RegExp(r'\s+'));
      if (columns.length < 4) {
        throw StateError('Available storage output is invalid.');
      }
      final availableBlocks = int.tryParse(columns[3]);
      if (availableBlocks == null || availableBlocks < 0) {
        throw StateError('Available storage output is invalid.');
      }
      return availableBlocks * 1024;
    }
    throw UnsupportedError('Available storage preflight is unsupported here.');
  }
}
