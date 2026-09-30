// On-device live probe for the OAuth cloud drives. It runs inside the app's own
// bundle, so it reuses the connections and tokens the user already signed in
// with, and exercises each one's real object store: put / stat / read + byte
// compare / ifAbsent refusal / list / delete. It only touches keys named
// `velock-probe-*` (and removes leftovers of earlier runs). It prints no
// account, token or client ID. Usage and reading the output:
// docs/OAUTH_SETUP.md, "Live check on a simulator".
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'package:flutter/widgets.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/network/sync_http.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

void log(String m) => debugPrint('PROBE $m');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('probe')),
    ),
  );
  try {
    await SystemProxy.instance.refresh();
    log('proxy https=${SystemProxy.instance.settings.https != null}');
    await LocalDataManager.instance.init();
    await SyncStateDatabase.initialize();
    final repo = ConnectionRepository(
      LocalDataManager.instance,
      SecureCredentialStore(),
      SyncStateDatabase.instance,
    );
    final all = await repo.loadConnections();
    final oauth = all.where((c) => c.protocol is OAuthProtocolModel).toList();
    log('connections=${all.length} oauth=${oauth.length}');
    for (final c in oauth) {
      await probe(repo, c);
    }
    log('DONE');
  } catch (e, s) {
    log('FATAL ${e.runtimeType}: $e\n$s');
  }
}

Future<void> probe(ConnectionRepository repo, ConnectionModel c) async {
  final p = c.protocol as OAuthProtocolModel;
  log('--- ${p.providerType.name} root=${p.rootId}');
  final store = await RemoteObjectStoreFactory.create(
    connections: repo,
    protocol: p,
  );
  final tag =
      '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';
  final bytes = utf8.encode('velock sync live probe $tag\n' * 2000); // ~70 KB
  final keys = ['velock-probe-$tag.bin', 'velock-probe-dir-$tag/sub/obj.bin'];
  Future<void> step(String name, Future<void> Function() f) async {
    final sw = Stopwatch()..start();
    try {
      await f();
      log('OK   $name (${sw.elapsedMilliseconds} ms)');
    } catch (e) {
      final inner = e is DioException
          ? ' inner=${e.error.runtimeType}: ${e.error}'
          : '';
      log(
        'FAIL $name (${sw.elapsedMilliseconds} ms): ${e.runtimeType}: $e$inner',
      );
    }
  }

  final leftovers = (await store.list(
    prefix: 'velock-probe',
  )).items.map((i) => i.logicalKey).toList();
  log('leftovers=${leftovers.length}');
  for (final key in leftovers) {
    await step('cleanup $key', () async {
      await store.delete(key);
      if (await store.stat(key) != null) throw StateError('still there');
    });
  }
  for (final key in keys) {
    await step('put $key', () async {
      final m = await store.put(
        key,
        Stream.value(bytes),
        contentLength: bytes.length,
        ifAbsent: true,
      );
      if (m.size != bytes.length) throw StateError('size ${m.size}');
    });
    await step('stat $key', () async {
      final m = await store.stat(key);
      if (m == null || m.size != bytes.length) throw StateError('stat $m');
    });
    await step('read $key', () async {
      final got = <int>[];
      await for (final chunk in store.read(key)) {
        got.addAll(chunk);
      }
      if (!_eq(got, bytes)) throw StateError('bytes differ ${got.length}');
    });
    await step('ifAbsent refuses overwrite $key', () async {
      try {
        await store.put(
          key,
          Stream.value([1, 2, 3]),
          contentLength: 3,
          ifAbsent: true,
        );
        throw StateError('overwrote');
      } on RemoteObjectAlreadyExistsException {
        // expected
      }
    });
  }
  await step('list root', () async {
    final page = await store.list(prefix: '');
    final names = page.items.map((i) => i.logicalKey).toList();
    log(
      '     root has ${names.length} items; probe listed=${names.contains(keys[0])}',
    );
    if (!names.contains(keys[0])) throw StateError('probe not listed');
  });
  await step('list nested', () async {
    final page = await store.list(prefix: 'velock-probe-dir-$tag/sub');
    final names = page.items.map((i) => i.logicalKey).toList();
    if (!names.contains(keys[1])) throw StateError('nested not listed: $names');
  });
  for (final key in keys.reversed) {
    await step('delete $key', () async {
      await store.delete(key);
      if (await store.stat(key) != null) throw StateError('still there');
    });
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
