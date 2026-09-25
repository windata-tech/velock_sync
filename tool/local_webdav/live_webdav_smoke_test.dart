// Opt-in live test of the production adapter. Creates and removes only a fresh
// random child collection; never reuses or deletes an existing remote vault.
// Run after exporting nas_webdav.local.env with VELOCK_RUN_LIVE_WEBDAV=1:
// flutter test --no-pub tool/local_webdav/live_webdav_smoke_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

void main() {
  test(
    'live WebDAV: isolated upload, immutable create, list, range, hash, delete',
    () async {
      final env = Platform.environment;
      final rawUrl = env['WEBDAV_URL'];
      final username = env['WEBDAV_USER'];
      final password = env['WEBDAV_PASSWORD'];
      if (rawUrl == null || username == null || password == null) {
        fail('Export WEBDAV_URL, WEBDAV_USER and WEBDAV_PASSWORD first.');
      }
      final base = Uri.parse(rawUrl.endsWith('/') ? rawUrl : '$rawUrl/');
      if (!['http', 'https'].contains(base.scheme) ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty ||
          base.hasQuery ||
          base.hasFragment) {
        fail('Expected an HTTP(S) collection URL without inline credentials.');
      }
      final token = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final namespace = 'velock-auto-test-$token';
      final testUri = base.resolve('$namespace/');
      final requests = <String, int>{};
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 20),
          followRedirects: false,
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.update(
              options.method,
              (value) => value + 1,
              ifAbsent: () => 1,
            );
            handler.next(options);
          },
        ),
      );
      final authorization =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
      Future<int?> collectionRequest(Uri uri, String method) async {
        try {
          final response = await dio.requestUri<void>(
            uri,
            options: Options(
              method: method,
              headers: {'Authorization': authorization, 'Depth': '0'},
              validateStatus: (_) => true,
            ),
          );
          return response.statusCode;
        } on DioException catch (error) {
          // No request URL, headers, credentials or server body in test output.
          fail('WebDAV $method transport failed (${error.type.name}).');
        }
      }

      var ownsCollection = false;
      try {
        expect(
          await collectionRequest(base, 'PROPFIND'),
          207,
          reason:
              'Authentication/root check failed; no remote writes attempted.',
        );
        expect(
          await collectionRequest(testUri, 'MKCOL'),
          201,
          reason: 'Refusing to reuse an existing test collection.',
        );
        ownsCollection = true;
        final store = WebDavObjectStore(
          dio: dio,
          baseUri: testUri,
          username: username,
          password: password,
          rateLimitRetry: ProviderRateLimitRetry(maxRetries: 0),
        );
        const key = '中文 空格/payload.bin';
        final data = Uint8List.fromList(
          List.generate(1024 * 1024, (index) => (index * 31 + 7) & 255),
        );
        final upload = Stopwatch()..start();
        await store.put(
          key,
          Stream.value(data),
          contentLength: data.length,
          ifAbsent: true,
        );
        upload.stop();
        expect((await store.stat(key))?.size, data.length);
        Object? conflict;
        try {
          await store.put(
            key,
            Stream.value(const [0]),
            contentLength: 1,
            ifAbsent: true,
          );
        } on Object catch (error) {
          conflict = error;
        }
        // Read the original before asserting the exception: a status-only check
        // previously hid the NAS's actual destructive overwrite.
        final afterConflict = await store
            .read(key)
            .expand((bytes) => bytes)
            .toList();
        stdout.writeln(
          'IMMUTABLE_BYTE_PROOF ${jsonEncode({'original_bytes': data.length, 'original_sha256': sha256.convert(data).toString(), 'after_bytes': afterConflict.length, 'after_sha256': sha256.convert(afterConflict).toString(), 'conflict_type': conflict?.runtimeType.toString()})}',
        );
        expect(sha256.convert(afterConflict), sha256.convert(data));
        expect(
          conflict is RemoteObjectAlreadyExistsException,
          isTrue,
          reason:
              'Conditional create must reject without changing original bytes.',
        );
        // Competing production-adapter publishers must have exactly one winner.
        final winners = await Future.wait(
          List.generate(4, (index) async {
            try {
              await store.put(
                'race.bin',
                Stream.value([index]),
                contentLength: 1,
                ifAbsent: true,
              );
              return index;
            } on RemoteObjectAlreadyExistsException {
              return -1;
            }
          }),
        );
        final successful = winners.where((index) => index >= 0).toList();
        expect(successful, hasLength(1));
        expect(
          await store.read('race.bin').expand((bytes) => bytes).toList(),
          successful,
        );
        await store.delete('race.bin');
        stdout.writeln(
          'ATOMIC_MOVE_RACE ${jsonEncode({'winners': successful.length, 'conflicts': winners.where((index) => index < 0).length})}',
        );
        final listing = await store.list(prefix: '中文 空格/');
        expect(listing.items.map((item) => item.logicalKey), contains(key));
        final download = Stopwatch()..start();
        final restored = await store
            .read(key)
            .fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (builder, chunk) => builder..add(chunk),
            );
        download.stop();
        expect(sha256.convert(restored.takeBytes()), sha256.convert(data));
        final range = await store
            .read(key, start: 100, endInclusive: 199)
            .fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (builder, chunk) => builder..add(chunk),
            );
        expect(range.takeBytes(), data.sublist(100, 200));
        await store.delete(key);
        expect(await store.stat(key), isNull);
        stdout.writeln(
          'LIVE_WEBDAV_SMOKE ${jsonEncode({'bytes': data.length, 'upload_ms': upload.elapsedMilliseconds, 'download_ms': download.elapsedMilliseconds, 'requests': requests, 'immutable_create': 'passed', 'range_hash_unicode': 'passed', 'scope': 'production adapter; not full cross-app sync'})}',
        );
      } finally {
        try {
          if (ownsCollection) {
            expect(
              await collectionRequest(testUri, 'DELETE'),
              anyOf(200, 204),
              reason:
                  'Cleanup failed for newly created test namespace $namespace',
            );
          }
        } finally {
          dio.close(force: true);
        }
      }
    },
    skip: Platform.environment['VELOCK_RUN_LIVE_WEBDAV'] != '1'
        ? 'Explicit VELOCK_RUN_LIVE_WEBDAV=1 is required for remote writes.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
