import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/network/sync_http.dart';

void main() {
  // The shape a desktop proxy tool typically installs.
  final proxy = SystemProxySettings.fromPlatform({
    'httpEnable': true,
    'httpHost': '127.0.0.1',
    'httpPort': 7890,
    'httpsEnable': true,
    'httpsHost': '127.0.0.1',
    'httpsPort': 7890,
    'exceptions': [
      '192.168.0.0/16',
      '10.0.0.0/8',
      '*.local',
      '.lan',
      'nas.example.com',
      'fd00::/8',
    ],
    'excludeSimpleHostnames': true,
  });

  test('a public host goes through the proxy', () {
    expect(
      proxy.findProxy(Uri.parse('https://oauth2.googleapis.com/token')),
      'PROXY 127.0.0.1:7890',
    );
    expect(
      proxy.findProxy(Uri.parse('http://example.org/')),
      'PROXY 127.0.0.1:7890',
    );
  });

  test('loopback, link-local and the exception list go direct', () {
    for (final url in [
      'http://127.0.0.1:8888/dav',
      'http://localhost:8888/',
      'http://[::1]:8888/',
      'http://169.254.10.2/',
      'http://192.168.1.20:5005/',
      'http://10.1.2.3/',
      'http://printer.local/',
      'http://printer.local.evil.test.local/',
      'http://nas.lan/',
      'http://lan/',
      'https://nas.example.com/dav',
      'http://nas/',
      'http://[fd12::1]/',
    ]) {
      expect(proxy.findProxy(Uri.parse(url)), 'DIRECT', reason: url);
    }
  });

  test('an exception never widens to a look-alike host', () {
    for (final url in [
      'https://evilnas.example.com/',
      'https://nas.example.com.evil.test/',
      'http://192.169.1.1/',
      'http://11.0.0.1/',
      'http://x.notlocal/',
    ]) {
      expect(
        proxy.findProxy(Uri.parse(url)),
        'PROXY 127.0.0.1:7890',
        reason: url,
      );
    }
  });

  test('a disabled or malformed setting means direct', () {
    for (final raw in <Map<String, Object?>?>[
      null,
      {},
      {'httpsEnable': false, 'httpsHost': '127.0.0.1', 'httpsPort': 7890},
      {'httpsEnable': true, 'httpsHost': '127.0.0.1'},
      {'httpsEnable': true, 'httpsHost': '127.0.0.1', 'httpsPort': 0},
      {'httpsEnable': true, 'httpsHost': 'a b', 'httpsPort': 7890},
      {'httpsEnable': true, 'httpsHost': 'h;DIRECT', 'httpsPort': 7890},
      {'httpsEnable': 'yes', 'httpsHost': '127.0.0.1', 'httpsPort': 7890},
    ]) {
      expect(
        SystemProxySettings.fromPlatform(
          raw,
        ).findProxy(Uri.parse('https://oauth2.googleapis.com/')),
        'DIRECT',
        reason: '$raw',
      );
    }
  });

  test('schemes are proxied independently', () {
    final httpsOnly = SystemProxySettings.fromPlatform({
      'httpsEnable': true,
      'httpsHost': 'proxy.test',
      'httpsPort': 3128,
    });
    expect(
      httpsOnly.findProxy(Uri.parse('https://a.test/')),
      'PROXY proxy.test:3128',
    );
    expect(httpsOnly.findProxy(Uri.parse('http://a.test/')), 'DIRECT');
  });

  test('clients get finite timeouts', () {
    final dio = newSyncDio();
    expect(dio.options.connectTimeout, const Duration(seconds: 30));
    expect(dio.options.receiveTimeout, const Duration(minutes: 5));
    expect(dio.options.sendTimeout, const Duration(minutes: 5));
  });
}
