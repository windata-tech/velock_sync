import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

typedef VelockPairingLauncher = Future<bool> Function(Uri uri);

/// iOS-first pairing control plane over the dedicated Exchange App Group.
///
/// Only public descriptors, one-time requests, signed responses and decision
/// markers are stored here. Velock's databases and private keys never enter the
/// shared container.
class ApplePairingControlChannel implements VelockPairingControlChannel {
  ApplePairingControlChannel({
    AppleExchangeRootLocator? rootLocator,
    VelockPairingLauncher? launchVelock,
    DateTime Function()? now,
  }) : _rootLocator = rootLocator ?? AppleExchangeRootLocator(),
       _launchVelock = launchVelock ?? launchUrl,
       _now = now ?? DateTime.now;

  final AppleExchangeRootLocator _rootLocator;
  final VelockPairingLauncher _launchVelock;
  final DateTime Function() _now;

  @override
  Future<VelockPairingDescriptor> pairingDescriptor() async {
    final root = await _root();
    return VelockPairingDescriptor.parse(
      await _readBounded(File('${root.path}/Control/descriptor.json')),
    );
  }

  @override
  Future<VelockDeviceAuthorizationStatus> queryAuthorizationStatus(
    String syncAppInstanceId,
  ) async {
    final root = await _root();
    final id = _opaque(syncAppInstanceId);
    final file = File('${root.path}/Control/Revocations/$id.json');
    if (!await file.exists()) {
      return VelockDeviceAuthorizationStatus.granted;
    }
    final descriptor = await pairingDescriptor();
    final revocation = VelockPairingRevocation.parse(await _readBounded(file));
    if (revocation.deviceId != syncAppInstanceId ||
        !await revocation.verify(descriptor: descriptor)) {
      throw const FormatException('Invalid pairing revocation.');
    }
    return VelockDeviceAuthorizationStatus.revoked;
  }

  @override
  Future<VelockPairingControlStatus> submitPairingRequest(
    VelockPairingControlRequest request,
  ) async {
    final encoded = request.encode();
    final root = await _root();
    final id = _opaque(request.requestId);
    final requestFile = File('${root.path}/Control/Requests/$id.json');
    for (final path in [
      '${root.path}/Control/Responses/$id.json',
      '${root.path}/Control/Decisions/$id.json',
      '${root.path}/Control/Consumed/$id.json',
    ]) {
      if (await File(path).exists()) {
        throw StateError('Pairing request was already decided or consumed.');
      }
    }
    if (await requestFile.exists()) {
      throw StateError('Pairing request already exists.');
    }
    await _writeAtomic(requestFile, encoded);
    await _launchVelock(
      Uri(
        scheme: 'velock',
        host: 'sync-pairing',
        queryParameters: {'requestId': id},
      ),
    );
    return VelockPairingControlStatus.pending;
  }

  @override
  Future<VelockPairingControlResult> queryPairingResponse(
    String requestId,
  ) async {
    final root = await _root();
    final id = _opaque(requestId);
    if (await File('${root.path}/Control/Consumed/$id.json').exists()) {
      throw StateError('Pairing request was already consumed.');
    }
    final response = File('${root.path}/Control/Responses/$id.json');
    if (await response.exists()) {
      return VelockPairingControlResult(
        status: VelockPairingControlStatus.approved,
        response: VelockPairingControlResponse.parse(
          await _readBounded(response),
        ),
      );
    }
    final decision = File('${root.path}/Control/Decisions/$id.json');
    if (await decision.exists()) {
      return VelockPairingControlResult(
        status: _decisionStatus(await _readBounded(decision), id),
      );
    }
    if (!await File('${root.path}/Control/Requests/$id.json').exists()) {
      throw StateError('Pairing request is unavailable.');
    }
    return const VelockPairingControlResult(
      status: VelockPairingControlStatus.pending,
    );
  }

  @override
  Future<void> acknowledgePairing(String requestId) async {
    final root = await _root();
    final id = _opaque(requestId);
    final response = File('${root.path}/Control/Responses/$id.json');
    final decision = File('${root.path}/Control/Decisions/$id.json');
    if (!await response.exists() || !await decision.exists()) {
      throw StateError('Pairing response is incomplete.');
    }
    await _writeAtomic(
      File('${root.path}/Control/Consumed/$id.json'),
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'consumedAt': _now().toUtc().toIso8601String(),
            'requestId': id,
          }),
        ),
      ),
    );
    final request = File('${root.path}/Control/Requests/$id.json');
    if (await request.exists()) await request.delete();
    await response.delete();
  }

  Future<Directory> _root() async {
    final root = await _rootLocator.locate();
    if (!await root.exists()) {
      throw StateError('Velock exchange App Group is unavailable.');
    }
    return root;
  }

  Future<Uint8List> _readBounded(File file) async {
    if (!await file.exists() || await FileSystemEntity.isLink(file.path)) {
      throw StateError('Pairing control artifact is unavailable.');
    }
    final length = await file.length();
    if (length < 1 || length > 16 * 1024) {
      throw const FormatException('Pairing control artifact is too large.');
    }
    return file.readAsBytes();
  }

  Future<void> _writeAtomic(File target, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Pairing control artifact is invalid.');
    }
    await target.parent.create(recursive: true);
    if (await FileSystemEntity.isLink(target.parent.path)) {
      throw StateError('Pairing control directory is invalid.');
    }
    final temporary = File('${target.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }
}

String _opaque(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value) ||
      value.endsWith('.tmp')) {
    throw ArgumentError.value(value, 'requestId');
  }
  return value;
}

VelockPairingControlStatus _decisionStatus(Uint8List bytes, String requestId) {
  final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference({
        'decidedAt',
        'requestId',
        'status',
      }).isNotEmpty ||
      value['requestId'] != requestId ||
      value['decidedAt'] is! String) {
    throw const FormatException('Pairing decision is invalid.');
  }
  return switch (value['status']) {
    'approved' => VelockPairingControlStatus.approved,
    'denied' => VelockPairingControlStatus.denied,
    'expired' => VelockPairingControlStatus.expired,
    'revoked' => VelockPairingControlStatus.revoked,
    _ => throw const FormatException('Pairing decision is invalid.'),
  };
}
