import 'dart:async';
import 'dart:convert';

import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

/// A pairing request Sync has sent to Velock and not yet finished.
///
/// The user approves in Velock, and iOS may terminate Sync in the meantime.
/// Only the request is kept: it holds public identifiers and a random
/// challenge, never a key, a password or the approval itself. On return the
/// approval is fetched from Velock again and fully re-verified; nothing here
/// is trusted as authorization.
class VelockPendingPairing {
  const VelockPendingPairing({
    required this.request,
    this.restoring = false,
    this.replacingProfileId,
  });

  final VelockPairingControlRequest request;
  final bool restoring;
  final String? replacingProfileId;

  static const _version = 1;

  String encode() => jsonEncode({
    'version': _version,
    // toJson validates identifiers and the request lifetime.
    'request': request.toJson(),
    'restoring': restoring,
    'replacingProfileId': ?replacingProfileId,
  });

  /// Returns null for anything malformed or expired at [now]; a stored value
  /// that cannot be used is never repaired or extended.
  static VelockPendingPairing? decode(String raw, {required DateTime now}) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?> || json['version'] != _version) {
        return null;
      }
      final fields = json['request'];
      final restoring = json['restoring'];
      final replacing = json['replacingProfileId'];
      if (fields is! Map<String, Object?> ||
          restoring is! bool ||
          (replacing != null &&
              (replacing is! String ||
                  replacing.isEmpty ||
                  replacing.length > 128))) {
        return null;
      }
      String text(String key) {
        final value = fields[key];
        if (value is! String) throw const FormatException('field');
        return value;
      }

      final request = VelockPairingControlRequest(
        requestId: text('requestId'),
        challenge: text('challenge'),
        producerId: text('producerId'),
        producerPublicKeyId: text('producerPublicKeyId'),
        exchangeBindingId: text('exchangeBindingId'),
        syncAppInstanceId: text('syncAppInstanceId'),
        createdAt: DateTime.parse(text('createdAt')),
        expiresAt: DateTime.parse(text('expiresAt')),
      )..toJson();
      if (!now.toUtc().isBefore(request.expiresAt)) return null;
      return VelockPendingPairing(
        request: request,
        restoring: restoring,
        replacingProfileId: replacing as String?,
      );
    } on Object {
      return null;
    }
  }
}

abstract interface class VelockPendingPairingStore {
  Future<VelockPendingPairing?> load({required DateTime now});
  Future<void> save(VelockPendingPairing pending);
  Future<void> clear();
}

/// Writes are serialized so a quick start-then-cancel cannot land out of
/// order and resurrect a cancelled request. Every operation is best effort:
/// losing this record only means pairing starts over, as it did before.
class LocalVelockPendingPairingStore implements VelockPendingPairingStore {
  LocalVelockPendingPairingStore(this._localData);

  static const key = 'velock_sync_pending_pairing';

  final LocalDataManager _localData;
  Future<void> _writes = Future.value();

  @override
  Future<VelockPendingPairing?> load({required DateTime now}) async {
    try {
      await _writes;
      final raw = await _localData.getStringAsync(key);
      if (raw == null) return null;
      final pending = VelockPendingPairing.decode(raw, now: now);
      if (pending == null) await clear();
      return pending;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(VelockPendingPairing pending) =>
      _enqueue(() => _localData.setStringAsync(key, pending.encode()));

  @override
  Future<void> clear() => _enqueue(() => _localData.removeAsync(key));

  Future<void> _enqueue(Future<void> Function() write) {
    final next = _writes.then((_) => write()).catchError((Object _) {});
    _writes = next;
    return next;
  }
}

class InMemoryVelockPendingPairingStore implements VelockPendingPairingStore {
  String? raw;

  @override
  Future<VelockPendingPairing?> load({required DateTime now}) async {
    final value = raw;
    return value == null ? null : VelockPendingPairing.decode(value, now: now);
  }

  @override
  Future<void> save(VelockPendingPairing pending) async =>
      raw = pending.encode();

  @override
  Future<void> clear() async => raw = null;
}
