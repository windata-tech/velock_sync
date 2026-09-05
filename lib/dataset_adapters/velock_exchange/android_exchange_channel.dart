import 'dart:io';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

/// The sole Android-facing contract for Velock's signature-protected
/// ContentProvider. It deliberately exchanges only opaque IDs and protected
/// artifact bytes; neither filesystem paths nor business records cross it.
abstract interface class AndroidExchangeChannel {
  Future<List<String>> readyOutboxIds();
  Future<bool> claimOutbox({required String batchId, required String leaseId});

  /// Copies a protected outbox artifact from Velock's signature-protected
  /// provider into this application's private cache using a native stream.
  ///
  /// The returned path is private to Velock Sync and is replayable for upload
  /// retries. It is deliberately not a path into Velock's storage.
  Future<AndroidExchangeArtifact> stageOutboxArtifact({
    required String batchId,
    required String relativePath,
  });
  Future<void> releaseStagedOutbox(String batchId);
  Future<void> writeOutboxReceipt({
    required String batchId,
    required Uint8List receipt,
  });
  Future<void> createInbox(String batchId);
  Future<void> writeInboxArtifact({
    required String batchId,
    required String relativePath,
    required ImmutableArtifact artifact,
  });
  Future<void> commitInbox(String batchId);
  Future<Uint8List?> readInboxReceipt(String batchId);
  Future<Uint8List> readInboxArtifact({
    required String batchId,
    required String relativePath,
  });
}

abstract interface class AndroidPairingControlChannel
    implements VelockPairingControlChannel {}

class AndroidExchangeArtifact {
  const AndroidExchangeArtifact({required this.path, required this.length});

  final String path;
  final int length;
}

class MethodChannelAndroidExchangeChannel
    implements AndroidExchangeChannel, AndroidPairingControlChannel {
  MethodChannelAndroidExchangeChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = VelockExchangeV1Contract.androidFlutterChannel;
  final MethodChannel _channel;

  @override
  Future<List<String>> readyOutboxIds() async => List<String>.from(
    await _channel.invokeListMethod<String>('readyOutboxIds') ?? const [],
  );

  @override
  Future<bool> claimOutbox({
    required String batchId,
    required String leaseId,
  }) async =>
      await _channel.invokeMethod<bool>('claimOutbox', {
        'batchId': batchId,
        'leaseId': leaseId,
      }) ??
      false;

  @override
  Future<AndroidExchangeArtifact> stageOutboxArtifact({
    required String batchId,
    required String relativePath,
  }) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'stageOutboxArtifact',
      {'batchId': batchId, 'relativePath': relativePath},
    );
    final path = value?['path'];
    final length = value?['length'];
    if (path is! String || path.isEmpty || length is! int || length < 0) {
      throw StateError('stageOutboxArtifact returned an invalid artifact.');
    }
    return AndroidExchangeArtifact(path: path, length: length);
  }

  @override
  Future<void> releaseStagedOutbox(String batchId) =>
      _channel.invokeMethod<void>('releaseStagedOutbox', {'batchId': batchId});

  @override
  Future<void> writeOutboxReceipt({
    required String batchId,
    required Uint8List receipt,
  }) => _channel.invokeMethod<void>('writeOutboxReceipt', {
    'batchId': batchId,
    'receipt': receipt,
  });

  @override
  Future<void> createInbox(String batchId) =>
      _channel.invokeMethod<void>('createInbox', {'batchId': batchId});

  @override
  Future<void> writeInboxArtifact({
    required String batchId,
    required String relativePath,
    required ImmutableArtifact artifact,
  }) async {
    final sourcePath = await _channel.invokeMethod<String>(
      'createInboxArtifactSource',
      {
        'batchId': batchId,
        'relativePath': relativePath,
        'length': artifact.length,
      },
    );
    if (sourcePath == null || sourcePath.isEmpty) {
      throw StateError('Native inbox staging path is unavailable.');
    }
    final source = File(sourcePath);
    final sink = source.openWrite();
    var written = 0;
    var sinkClosed = false;
    try {
      await for (final chunk in await artifact.openRead()) {
        written += chunk.length;
        if (written > artifact.length) {
          throw StateError('Inbox artifact exceeds its declared length.');
        }
        sink.add(chunk);
      }
      await sink.close();
      sinkClosed = true;
      if (written != artifact.length) {
        throw StateError('Inbox artifact length is invalid.');
      }
      await _channel.invokeMethod<void>('writeInboxArtifactFromPath', {
        'batchId': batchId,
        'relativePath': relativePath,
        'sourcePath': sourcePath,
        'length': artifact.length,
      });
    } on Object {
      if (!sinkClosed) await sink.close();
      rethrow;
    } finally {
      if (await source.exists()) await source.delete();
    }
  }

  @override
  Future<void> commitInbox(String batchId) =>
      _channel.invokeMethod<void>('commitInbox', {'batchId': batchId});

  @override
  Future<Uint8List?> readInboxReceipt(String batchId) async {
    final value = await _channel.invokeMethod<Uint8List>('readInboxReceipt', {
      'batchId': batchId,
    });
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<Uint8List> readInboxArtifact({
    required String batchId,
    required String relativePath,
  }) => _requiredBytes('readInboxArtifact', {
    'batchId': batchId,
    'relativePath': relativePath,
  });

  @override
  Future<VelockPairingDescriptor> pairingDescriptor() async =>
      VelockPairingDescriptor.parse(
        await _requiredBytes(
          VelockExchangeV1Contract.androidPairingDescriptorMethod,
          const {},
        ),
      );

  @override
  Future<VelockDeviceAuthorizationStatus> queryAuthorizationStatus(
    String syncAppInstanceId,
  ) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      VelockExchangeV1Contract.androidQueryAuthorizationStatusMethod,
      {'deviceId': syncAppInstanceId},
    );
    final status = value?['status'];
    final artifact = value?['artifact'];
    if (status == 'granted') {
      if (artifact != null) {
        throw StateError('Unexpected revocation artifact for granted access.');
      }
      return VelockDeviceAuthorizationStatus.granted;
    }
    if (status == 'revoked') {
      if (artifact is! Uint8List) {
        throw StateError('Revocation artifact is missing.');
      }
      final descriptor = await pairingDescriptor();
      final revocation = VelockPairingRevocation.parse(artifact);
      if (revocation.deviceId != syncAppInstanceId ||
          !await revocation.verify(descriptor: descriptor)) {
        throw StateError('Invalid Velock authorization revocation.');
      }
      return VelockDeviceAuthorizationStatus.revoked;
    }
    throw StateError('Invalid Velock authorization status.');
  }

  @override
  Future<VelockPairingControlStatus> submitPairingRequest(
    VelockPairingControlRequest request,
  ) async {
    final status = await _channel.invokeMethod<String>(
      VelockExchangeV1Contract.androidSubmitPairingRequestMethod,
      {'requestId': request.requestId, 'request': request.encode()},
    );
    return _status(status);
  }

  @override
  Future<VelockPairingControlResult> queryPairingResponse(
    String requestId,
  ) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      VelockExchangeV1Contract.androidQueryPairingResponseMethod,
      {'requestId': requestId},
    );
    final status = _status(value?['status']);
    final encoded = value?['response'];
    if (status == VelockPairingControlStatus.approved) {
      if (encoded is! Uint8List) {
        throw StateError('Approved pairing response is missing.');
      }
      return VelockPairingControlResult(
        status: status,
        response: VelockPairingControlResponse.parse(encoded),
      );
    }
    if (encoded != null) {
      throw StateError('Unexpected pairing response payload.');
    }
    return VelockPairingControlResult(status: status);
  }

  @override
  Future<void> acknowledgePairing(String requestId) =>
      _channel.invokeMethod<void>(
        VelockExchangeV1Contract.androidAcknowledgePairingMethod,
        {'requestId': requestId},
      );

  Future<Uint8List> _requiredBytes(
    String method,
    Map<String, Object> arguments,
  ) async {
    final value = await _channel.invokeMethod<Uint8List>(method, arguments);
    if (value == null) throw StateError('$method returned no artifact.');
    return Uint8List.fromList(value);
  }

  VelockPairingControlStatus _status(Object? value) => switch (value) {
    'pending' => VelockPairingControlStatus.pending,
    'approved' => VelockPairingControlStatus.approved,
    'denied' => VelockPairingControlStatus.denied,
    'expired' => VelockPairingControlStatus.expired,
    'revoked' => VelockPairingControlStatus.revoked,
    _ => throw StateError('Invalid Velock pairing control status.'),
  };
}

Future<AndroidExchangeChannel> androidExchangeChannel() async {
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      'Velock Android exchange is only available on Android.',
    );
  }
  return MethodChannelAndroidExchangeChannel();
}
