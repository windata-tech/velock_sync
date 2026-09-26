import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';

class _Repository implements ConnectionRepository {
  @override
  Future<String?> readWebDavPassword(String? ref) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late HttpServer server;
  late ProviderContainer container;
  late RemoteFileBrowser browser;
  late RemoteFileBrowserProvider provider;
  late List<String> requests;
  Future<void> Function(HttpRequest)? intercept;

  setUp(() async {
    requests = [];
    intercept = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      requests.add(request.uri.path);
      expect(request.method, 'PROPFIND');
      if (intercept != null) {
        await intercept!(request);
      } else {
        request.response.statusCode = 207;
        request.response.write('<d:multistatus xmlns:d="DAV:"/>');
        await request.response.close();
      }
    });
    container = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(_Repository()),
      ],
    );
    final connection = ConnectionModel(
      id: 'test',
      name: 'Test NAS',
      source: 'test',
      target: 'test',
      protocol: WebDavProtocolModel(
        protocolType: WebDavProtocolType.http,
        address: 'http://127.0.0.1',
        port: '${server.port}',
        path: '/backup',
      ),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      status: ConnectionStatus.active,
    );
    provider = remoteFileBrowserProvider(connectionModel: connection);
    container.listen(provider, (_, _) {});
    await container.read(provider.future);
    browser = container.read(provider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await server.close(force: true);
  });

  test(
    'nested navigation returns one parent and never goes above configured root',
    () async {
      expect(browser.canGoBack, isFalse);
      await browser.go('/backup/one');
      await browser.go('/backup/one/two');
      expect(browser.canGoBack, isTrue);
      final count = requests.length;
      await browser.goBack();
      expect(container.read(provider).requireValue.path, '/backup/one');
      await browser.goBack();
      expect(container.read(provider).requireValue.path, '/backup');
      expect(browser.canGoBack, isFalse);
      await browser.goBack();
      expect(requests.length, count, reason: 'Parents use cached listings');
      await expectLater(browser.go('/backup/../outside'), throwsArgumentError);
      expect(requests.length, count);
    },
  );

  test(
    'refresh keeps current directory and failed child can return to parent',
    () async {
      await browser.go('/backup/one');
      await browser.refresh();
      expect(requests.last, '/backup/one/');
      intercept = (request) async {
        request.response.statusCode = 403;
        await request.response.close();
      };
      await browser.go('/backup/one/private');
      expect(container.read(provider).hasError, isTrue);
      expect(browser.canGoBack, isTrue);
      await browser.goBack();
      expect(container.read(provider).requireValue.path, '/backup/one');
      expect(browser.currentPath, '/backup/one');
    },
  );

  test('back during child load ignores its late response', () async {
    final received = Completer<void>();
    final release = Completer<void>();
    intercept = (request) async {
      received.complete();
      await release.future;
      request.response.statusCode = 207;
      request.response.write('<d:multistatus xmlns:d="DAV:"/>');
      await request.response.close();
    };
    final pending = browser.go('/backup/slow');
    await received.future;
    expect(browser.canGoBack, isTrue);
    expect(container.read(provider).isLoading, isTrue);
    expect(
      browser.visibleState?.path,
      '/backup',
      reason: 'Keep the last listing visible until navigation completes',
    );
    await browser.goBack();
    expect(container.read(provider).requireValue.path, '/backup');
    release.complete();
    await pending;
    expect(container.read(provider).requireValue.path, '/backup');
    expect(browser.canGoBack, isFalse);
  });
}
