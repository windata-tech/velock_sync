import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pending_pairing_store.dart';

void main() {
  final base = DateTime.utc(2026, 9, 30, 8);

  VelockPairingControlRequest request({
    Duration ttl = const Duration(minutes: 5),
  }) => VelockPairingControlRequest(
    requestId: 'request-1',
    challenge: 'challenge-1',
    producerId: 'producer-1',
    producerPublicKeyId: 'key-1',
    exchangeBindingId: 'binding-1',
    syncAppInstanceId: 'sync-1',
    createdAt: base,
    expiresAt: base.add(ttl),
  );

  group('VelockPendingPairing', () {
    test('round-trips the request and its purpose', () {
      final raw = VelockPendingPairing(
        request: request(),
        restoring: true,
        replacingProfileId: 'profile-1',
      ).encode();
      final decoded = VelockPendingPairing.decode(raw, now: base)!;
      expect(decoded.request.toJson(), request().toJson());
      expect(decoded.restoring, isTrue);
      expect(decoded.replacingProfileId, 'profile-1');
    });

    test('holds no key or approval material', () {
      final json =
          jsonDecode(VelockPendingPairing(request: request()).encode())
              as Map<String, Object?>;
      expect(json.keys, unorderedEquals(['version', 'request', 'restoring']));
      expect(
        (json['request']! as Map).keys,
        isNot(contains(anyOf('signature', 'vaultId', 'approvedAt'))),
      );
    });

    test('is unusable from the moment it expires', () {
      final raw = VelockPendingPairing(request: request()).encode();
      final expiresAt = base.add(const Duration(minutes: 5));
      expect(
        VelockPendingPairing.decode(
          raw,
          now: expiresAt.subtract(const Duration(seconds: 1)),
        ),
        isNotNull,
      );
      expect(VelockPendingPairing.decode(raw, now: expiresAt), isNull);
    });

    test('rejects malformed, extended or foreign records', () {
      final good =
          jsonDecode(VelockPendingPairing(request: request()).encode())
              as Map<String, Object?>;
      Map<String, Object?> edit(void Function(Map<String, Object?>) change) {
        final copy = jsonDecode(jsonEncode(good)) as Map<String, Object?>;
        change(copy);
        return copy;
      }

      final rejected = <Object?>[
        'not json',
        '[]',
        edit((json) => json['version'] = 2),
        edit((json) => json.remove('request')),
        edit((json) => json['restoring'] = 'yes'),
        edit((json) => json['replacingProfileId'] = ''),
        edit((json) => json['replacingProfileId'] = 'x' * 129),
        edit((json) => (json['request']! as Map).remove('challenge')),
        // A lifetime longer than the protocol allows is never accepted.
        edit(
          (json) => (json['request']! as Map)['expiresAt'] = base
              .add(const Duration(hours: 1))
              .toIso8601String(),
        ),
      ];
      for (final raw in rejected) {
        final text = raw is String ? raw : jsonEncode(raw);
        expect(
          VelockPendingPairing.decode(text, now: base),
          isNull,
          reason: text,
        );
      }
    });
  });

  group('LocalVelockPendingPairingStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await LocalDataManager.instance.init();
    });

    test('a quick start-then-cancel does not resurrect the request', () async {
      final store = LocalVelockPendingPairingStore(LocalDataManager.instance);
      // Not awaited, as in the controller.
      store.save(VelockPendingPairing(request: request()));
      store.clear();
      expect(await store.load(now: base), isNull);

      final fresh = LocalVelockPendingPairingStore(LocalDataManager.instance);
      expect(await fresh.load(now: base), isNull);
    });

    test('survives a new store instance and drops expired records', () async {
      await LocalVelockPendingPairingStore(
        LocalDataManager.instance,
      ).save(VelockPendingPairing(request: request()));

      final restarted = LocalVelockPendingPairingStore(
        LocalDataManager.instance,
      );
      expect((await restarted.load(now: base))?.request.requestId, 'request-1');

      final later = base.add(const Duration(minutes: 5));
      expect(await restarted.load(now: later), isNull);
      expect(
        await LocalDataManager.instance.getStringAsync(
          LocalVelockPendingPairingStore.key,
        ),
        isNull,
      );
    });
  });
}
