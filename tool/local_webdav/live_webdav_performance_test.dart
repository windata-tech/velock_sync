// Opt-in, single-sample provider benchmark (NOT P95 or end-to-end sync).
// set -a; source tool/local_webdav/nas_webdav.local.env; set +a
// VELOCK_RUN_LIVE_WEBDAV=1 flutter test --no-pub \
//   tool/local_webdav/live_webdav_performance_test.dart
import 'dart:async';
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

const _bytes = 100 * 1024 * 1024;
const _chunkBytes = 64 * 1024;

// Deterministic opaque synthetic bytes, no attachment parsing or encryption.
// Each yielded allocation is 64KiB, never a 100MiB List<int> or buffered body.
Stream<List<int>> _payload() async* {
  var state = 0x12345678;
  for (var offset = 0; offset < _bytes; offset += _chunkBytes) {
    final chunk = Uint8List(_chunkBytes);
    final words = ByteData.sublistView(chunk);
    for (var i = 0; i < chunk.length; i += 4) {
      state ^= (state << 13) & 0xffffffff;
      state ^= state >> 17;
      state ^= (state << 5) & 0xffffffff;
      words.setUint32(i, state, Endian.little);
    }
    yield chunk;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

void main() {
  test(
    'live 100MiB streaming WebDAV safe-create >= 60% ordinary PUT',
    () async {
      final env = Platform.environment;
      final rawUrl = env['WEBDAV_URL'];
      final user = env['WEBDAV_USER'];
      final password = env['WEBDAV_PASSWORD'];
      if (rawUrl == null || user == null || password == null) {
        fail('Source/export the local NAS environment first.');
      }
      final base = Uri.parse(rawUrl.endsWith('/') ? rawUrl : '$rawUrl/');
      if (!['http', 'https'].contains(base.scheme) ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty ||
          base.hasQuery ||
          base.hasFragment) {
        fail('Expected HTTP(S) collection URL without inline credentials.');
      }
      final random = Random.secure();
      final token = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final namespace = 'velock-perf-$token';
      final root = base.resolve('$namespace/');
      final authorization =
          'Basic ${base64Encode(utf8.encode('$user:$password'))}';
      Dio client() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(seconds: 25),
          followRedirects: false,
        ),
      );
      final dio = client();
      final cleanupDio = client();
      final cancellation = RemoteOperationCancellation();
      final total = Stopwatch()..start();
      final report = <String, Object?>{
        'bytes_per_object': _bytes,
        'chunk_bytes': _chunkBytes,
        'namespace': namespace,
        'samples_per_variant': 1,
        'scope':
            'provider-only; sequential; no P95, concurrency or cross-app E2E',
        'order': 'ordinary PUT/read then cold safe-create/read; same Dio/store',
        'timing':
            'includes streaming generation/hash; safe-create includes probe and cleanup',
        'minimum_safe_to_baseline_upload_throughput_ratio': 0.60,
        'cleanup_success': false,
      };
      var owns = false;
      var expired = false;
      String? failure;
      final deadline = Timer(const Duration(seconds: 100), () {
        expired = true;
        cancellation.cancel();
        dio.close(force: true);
      });
      // Closing a Dio adapter alone need not reject future requests. Fence all
      // late work as well, before finally deletes the exclusively owned root.
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (expired) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                ),
              );
            } else {
              handler.next(options);
            }
          },
        ),
      );
      Future<int?> request(Dio http, Uri uri, String method) async {
        final cancel = CancelToken();
        try {
          final response = await http.requestUri<void>(
            uri,
            cancelToken: cancel,
            options: Options(
              method: method,
              headers: {'Authorization': authorization, 'Depth': '0'},
              validateStatus: (_) => true,
            ),
          );
          return response.statusCode;
        } finally {
          cancel.cancel();
        }
      }

      // Cleanup uses a separate client and a total per-operation timeout.
      Future<int?> cleanupRequest(String method) async {
        return request(cleanupDio, root, method).timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            cleanupDio.close(force: true);
            throw TimeoutException('Cleanup timed out');
          },
        );
      }

      try {
        await (() async {
          expect(
            await request(dio, base, 'PROPFIND'),
            207,
            reason: 'Authentication/root preflight failed; no writes.',
          );
          final status = await request(dio, root, 'MKCOL');
          owns = status == 201;
          expect(owns, isTrue, reason: 'Never reuse an existing collection.');
          final store = WebDavObjectStore(
            dio: dio,
            baseUri: root,
            username: user,
            password: password,
            rateLimitRetry: ProviderRateLimitRetry(maxRetries: 0),
          );
          String? expectedHash;
          for (final safe in [false, true]) {
            final label = safe ? 'safe' : 'baseline';
            final key = '$label.bin';
            final digest = _DigestSink();
            final hasher = sha256.startChunkedConversion(digest);
            var uploaded = 0;
            final watch = Stopwatch()..start();
            try {
              await store.put(
                key,
                _payload().map((chunk) {
                  cancellation.throwIfCancelled();
                  uploaded += chunk.length;
                  hasher.add(chunk);
                  return chunk;
                }),
                contentLength: _bytes,
                ifAbsent: safe,
                cancellation: cancellation,
              );
            } finally {
              hasher.close();
            }
            watch.stop();
            final uploadSeconds = watch.elapsedMicroseconds / 1e6;
            report['${label}_upload_seconds'] = uploadSeconds;
            report['${label}_upload_mib_s'] = 100 / uploadSeconds;
            report['${label}_uploaded_bytes'] = uploaded;
            report['${label}_upload_sha256'] = digest.value.toString();
            expect(uploaded, _bytes);
            expectedHash ??= digest.value.toString();
            expect(digest.value.toString(), expectedHash);
            var downloaded = 0;
            watch
              ..reset()
              ..start();
            final restoredHash = await sha256
                .bind(
                  store
                      .read(key, cancellation: cancellation)
                      .map((chunk) {
                        downloaded += chunk.length;
                        return chunk;
                      })
                      .timeout(const Duration(seconds: 25)),
                )
                .single;
            watch.stop();
            final downloadSeconds = watch.elapsedMicroseconds / 1e6;
            report['${label}_download_seconds'] = downloadSeconds;
            report['${label}_download_mib_s'] = 100 / downloadSeconds;
            report['${label}_downloaded_bytes'] = downloaded;
            report['${label}_download_sha256'] = restoredHash.toString();
            report['${label}_sha256_ok'] =
                downloaded == _bytes && restoredHash.toString() == expectedHash;
            expect(downloaded, _bytes);
            expect(restoredHash.toString(), expectedHash);
          }
          final ratio =
              (report['baseline_upload_seconds']! as double) /
              (report['safe_upload_seconds']! as double);
          report['safe_to_baseline_upload_throughput_ratio'] = ratio;
          report['safe_to_baseline_download_throughput_ratio'] =
              (report['baseline_download_seconds']! as double) /
              (report['safe_download_seconds']! as double);
          report['performance_gate_passed'] = ratio >= 0.60;
          expect(
            ratio,
            greaterThanOrEqualTo(0.60),
            reason: 'Hard gate: safe-create throughput >= 60% ordinary PUT.',
          );
        })().timeout(const Duration(seconds: 100));
      } on TestFailure catch (error) {
        failure = error.message;
      } on Object catch (error) {
        // Never serialize server bodies, request URLs, headers or credentials.
        failure = 'Benchmark failed (${error.runtimeType}); details redacted.';
      } finally {
        deadline.cancel();
        expired = true;
        cancellation.cancel();
        dio.close(force: true);
        try {
          if (owns) {
            final deleted = await cleanupRequest('DELETE');
            report['cleanup_delete_status'] = deleted;
            final absent = await cleanupRequest('PROPFIND');
            report['cleanup_verify_status'] = absent;
            report['cleanup_success'] =
                (deleted == 200 || deleted == 204) && absent == 404;
            if (report['cleanup_success'] != true) {
              failure ??=
                  'Owned namespace cleanup/absence verification failed.';
            }
          }
        } on Object catch (error) {
          failure ??= 'Owned namespace cleanup failed (${error.runtimeType}).';
        } finally {
          cleanupDio.close(force: true);
          report['total_seconds'] = total.elapsedMicroseconds / 1e6;
          report['passed'] = failure == null;
          report['failure'] = failure;
          final directory = Directory('ui_test_results/auto-sync-20260919');
          await directory.create(recursive: true);
          await File(
            '${directory.path}/live-webdav-performance-$token.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
          stdout.writeln('LIVE_WEBDAV_PERFORMANCE ${jsonEncode(report)}');
        }
      }
      if (failure != null) fail(failure);
    },
    skip: Platform.environment['VELOCK_RUN_LIVE_WEBDAV'] != '1'
        ? 'Explicit VELOCK_RUN_LIVE_WEBDAV=1 required.'
        : false,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
