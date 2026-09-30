import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/providers/webdav/webdav_auth_race_guard.dart';

void main() {
  late SyncStateDatabase database;
  late _Credentials credentials;
  late ConnectionRepository connections;
  late String credentialRef;

  setUp(() async {
    WebDavAuthRaceGuard.resetForTesting();
    database = await SyncStateDatabase.inMemory();
    credentials = _Credentials('secret');
    connections = ConnectionRepository(
      LocalDataManager.instance,
      credentials,
      database,
    );
    credentialRef = 'velock-sync/webdav/test';
    addTearDown(database.close);
  });

  WebDavProtocolModel protocol({
    String address = 'http://dav.example.test/address%20root',
    String path = 'configured%20path',
    String? username = 'alice',
  }) => WebDavProtocolModel(
    protocolType: WebDavProtocolType.http,
    address: address,
    port: '80',
    username: username,
    credentialRef: credentialRef,
    path: path,
  );

  test(
    'lists immediate DAV collections and uses a confined read-only request',
    () async {
      final response = _xml('''
      <d:response>
        <d:href>http://dav.example.test/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/%E4%B8%AD%E6%96%87%20%E7%9B%AE%E5%BD%95/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/100%25/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/%252F/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/%E4%B8%AD%E6%96%87%20%E7%9B%AE%E5%BD%95/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/file.txt</d:href>
        <d:propstat>
          <d:prop><d:resourcetype/></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/not-a-collection/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/missing-resource-type/</d:href>
        <d:propstat>
          <d:prop><d:displayname>not trusted</d:displayname></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/malformed-status/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>not-a-status</d:status>
        </d:propstat>
      </d:response>
      <x:response xmlns:x="urn:not-dav">
        <x:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/wrong-namespace/</x:href>
        <x:propstat>
          <x:prop><x:resourcetype><x:collection/></x:resourcetype></x:prop>
          <x:status>HTTP/1.1 200 OK</x:status>
        </x:propstat>
      </x:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/child/grandchild/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/sibling/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>https://evil.example/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/evil/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    ''');
      final adapter = _Adapter((_) async => _response(207, response));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      final folders = await browser.list(
        protocol: protocol(),
        relativeSegments: const ['目录'],
      );

      expect(
        folders.map((folder) => folder.name),
        orderedEquals(['%2F', '100%', '中文 目录']),
      );
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.method, 'PROPFIND');
      expect(
        request.uri.toString(),
        'http://dav.example.test/address%20root/configured%20path/%E7%9B%AE%E5%BD%95/',
      );
      expect(request.headers['Depth'], '1');
      expect(request.headers['Accept'], contains('xml'));
      expect(
        request.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('alice:secret'))}',
      );
      expect(request.followRedirects, isFalse);
      expect(request.connectTimeout, const Duration(seconds: 20));
      expect(request.receiveTimeout, const Duration(seconds: 20));
      expect(adapter.lastBody, contains('<d:resourcetype/>'));
      expect(credentials.reads, 1);
      expect(credentials.writes, 0);
    },
  );

  test(
    'supports absolute and path-absolute hrefs with encoded characters',
    () async {
      final response = _xml('''
      <d:response>
        <d:href>http://dav.example.test/address%20root/configured%20path/a%20b%20%25/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/address%20root/configured%20path/%E4%B8%AD%E6%96%87/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    ''');
      final adapter = _Adapter((_) async => _response(207, response));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      final folders = await browser.list(protocol: protocol());

      expect(
        folders.map((folder) => folder.name),
        orderedEquals(['a b %', '中文']),
      );
    },
  );

  test(
    'ignores traversal, encoded separators, external origins and non-children',
    () async {
      final response = _xml('''
      <d:response>
        <d:href>/root/child/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/../escape/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/%2e%2e/escape/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/../child/reentered/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/%2e%2e/child/encoded-reentered/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/a%2Fb/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/a%5Cb/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/child/nested/grandchild/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/root/other/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>http://evil.example/root/child/evil/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>child/relative/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    ''');
      final adapter = _Adapter((_) async => _response(207, response));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      final folders = await browser.list(
        protocol: protocol(address: 'http://dav.example.test', path: 'root'),
        relativeSegments: const ['child'],
      );

      expect(folders, isEmpty);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('creates one encoded collection with no request body', () async {
    final adapter = _Adapter((_) async => _response(201, ''));
    final browser = WebDavBackupFolderBrowser(
      connections: connections,
      dio: Dio()..httpClientAdapter = adapter,
    );

    await browser.createFolder(
      protocol: protocol(),
      relativeSegments: const ['目录'],
      name: '中文 % # ?',
    );

    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.method, 'MKCOL');
    expect(
      request.uri.toString(),
      'http://dav.example.test/address%20root/configured%20path/'
      '%E7%9B%AE%E5%BD%95/'
      '%E4%B8%AD%E6%96%87%20%25%20%23%20%3F/',
    );
    expect(
      request.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('alice:secret'))}',
    );
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
    expect(request.connectTimeout, const Duration(seconds: 20));
    expect(request.sendTimeout, const Duration(seconds: 20));
    expect(request.receiveTimeout, const Duration(seconds: 20));
    expect(adapter.lastBody, isEmpty);
    expect(credentials.reads, 1);
    expect(credentials.writes, 0);
  });

  test('classifies new collection names without over-rejecting literals', () {
    expect(WebDavBackupFolderBrowser.folderNameError(''), 'empty_name');
    expect(WebDavBackupFolderBrowser.folderNameError(' \t\n'), 'empty_name');
    expect(WebDavBackupFolderBrowser.folderNameError(' name'), 'invalid_name');
    expect(WebDavBackupFolderBrowser.folderNameError('name '), 'invalid_name');
    expect(WebDavBackupFolderBrowser.folderNameError('.'), 'invalid_name');
    expect(WebDavBackupFolderBrowser.folderNameError('..'), 'invalid_name');
    expect(WebDavBackupFolderBrowser.folderNameError('a/b'), 'invalid_name');
    expect(WebDavBackupFolderBrowser.folderNameError(r'a\b'), 'invalid_name');
    expect(
      WebDavBackupFolderBrowser.folderNameError('bad\nname'),
      'invalid_name',
    );
    expect(
      WebDavBackupFolderBrowser.folderNameError(List.filled(86, '中').join()),
      'name_too_long',
    );
    expect(
      WebDavBackupFolderBrowser.folderNameError(List.filled(85, '中').join()),
      isNull,
    );
    expect(WebDavBackupFolderBrowser.folderNameError('中文 内部 % # ?'), isNull);
  });

  test('rejects invalid names before credentials or network', () async {
    final cases = <String, String>{
      '': 'empty_name',
      '   ': 'empty_name',
      ' name': 'invalid_name',
      '.': 'invalid_name',
      '..': 'invalid_name',
      'a/b': 'invalid_name',
      r'a\b': 'invalid_name',
      'bad\nname': 'invalid_name',
      List.filled(86, '中').join(): 'name_too_long',
    };

    for (final entry in cases.entries) {
      final adapter = _Adapter((_) async => _response(201, ''));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        browser.createFolder(protocol: protocol(), name: entry.key),
        throwsA(
          isA<WebDavBackupFolderException>().having(
            (error) => error.code,
            'code',
            'provider.webdav.${entry.value}',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      expect(credentials.reads, 0);
    }
  });

  test(
    'rejects invalid parent segments before credentials or network',
    () async {
      final adapter = _Adapter((_) async => _response(201, ''));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        browser.createFolder(
          protocol: protocol(),
          relativeSegments: const ['valid', 'bad/segment'],
          name: 'child',
        ),
        throwsArgumentError,
      );
      expect(adapter.requests, isEmpty);
      expect(credentials.reads, 0);
    },
  );

  test('does not use an existing folder after one MKCOL 405', () async {
    final adapter = _Adapter((_) async => _response(405, ''));
    final browser = WebDavBackupFolderBrowser(
      connections: connections,
      dio: Dio()..httpClientAdapter = adapter,
    );

    await expectLater(
      browser.createFolder(protocol: protocol(), name: 'existing'),
      throwsA(
        isA<ProviderRequestException>()
            .having((error) => error.statusCode, 'statusCode', 405)
            .having(
              (error) => error.errorCode,
              'errorCode',
              'provider.http.405',
            ),
      ),
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.method, 'MKCOL');
    expect(adapter.lastBody, isEmpty);
  });

  for (final status in <int>[401, 403, 409]) {
    // A relay can reject valid credentials under concurrency, so an unproven
    // account gets exactly one retry on 401; other statuses are never retried.
    test('maps MKCOL HTTP $status with at most one 401 retry', () async {
      final adapter = _Adapter((_) async => _response(status, ''));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        browser.createFolder(protocol: protocol(), name: 'child'),
        throwsA(
          isA<ProviderRequestException>()
              .having((error) => error.statusCode, 'statusCode', status)
              .having(
                (error) => error.errorCode,
                'errorCode',
                'provider.http.$status',
              ),
        ),
      );
      expect(adapter.requests, hasLength(status == 401 ? 2 : 1));
      expect(adapter.requests.map((r) => r.method), everyElement('MKCOL'));
    });
  }

  for (final status in <int>[500, 200, 204]) {
    test('treats MKCOL HTTP $status as an unknown outcome', () async {
      final adapter = _Adapter((_) async => _response(status, ''));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        browser.createFolder(protocol: protocol(), name: 'child'),
        throwsA(
          isA<WebDavBackupFolderException>().having(
            (error) => error.code,
            'code',
            'provider.webdav.create_outcome_unknown',
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'MKCOL');
    });
  }

  test('bounds create requests and treats a timeout as unknown', () async {
    final responseCompleter = Completer<ResponseBody>();
    final adapter = _Adapter((_) => responseCompleter.future);
    final browser = WebDavBackupFolderBrowser(
      connections: connections,
      dio: Dio()..httpClientAdapter = adapter,
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      browser.createFolder(protocol: protocol(), name: 'child'),
      throwsA(
        isA<WebDavBackupFolderException>().having(
          (error) => error.code,
          'code',
          'provider.webdav.create_outcome_unknown',
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
    responseCompleter.complete(_response(201, ''));
    await Future<void>.delayed(Duration.zero);
  });

  test('treats an unconfirmed transport failure as unknown', () async {
    final adapter = _Adapter(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );
    final browser = WebDavBackupFolderBrowser(
      connections: connections,
      dio: Dio()..httpClientAdapter = adapter,
    );

    await expectLater(
      browser.createFolder(protocol: protocol(), name: 'child'),
      throwsA(
        isA<WebDavBackupFolderException>().having(
          (error) => error.code,
          'code',
          'provider.webdav.create_outcome_unknown',
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
  });

  for (final segment in <String>['', '.', '..', 'a/b', r'a\b', 'bad\nname']) {
    test('rejects invalid relative segment ${jsonEncode(segment)}', () async {
      final adapter = _Adapter((_) async => _response(207, _xml('')));
      final browser = WebDavBackupFolderBrowser(
        connections: connections,
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        browser.list(protocol: protocol(), relativeSegments: [segment]),
        throwsArgumentError,
      );
      expect(adapter.requests, isEmpty);
      expect(credentials.reads, 0);
    });
  }

  for (final status in <int>[401, 403, 405, 500]) {
    test(
      'maps HTTP $status to a stable error, one retry only for 401',
      () async {
        final adapter = _Adapter((_) async => _response(status, ''));
        final browser = WebDavBackupFolderBrowser(
          connections: connections,
          dio: Dio()..httpClientAdapter = adapter,
        );

        await expectLater(
          browser.list(protocol: protocol()),
          throwsA(
            isA<ProviderRequestException>()
                .having(
                  (error) => error.errorCode,
                  'errorCode',
                  'provider.http.$status',
                )
                .having((error) => error.statusCode, 'statusCode', status),
          ),
        );
        expect(adapter.requests, hasLength(status == 401 ? 2 : 1));
      },
    );
  }

  test('sanitizes malformed XML responses', () async {
    final adapter = _Adapter((_) async => _response(207, '<d:multistatus'));
    final browser = WebDavBackupFolderBrowser(
      connections: connections,
      dio: Dio()..httpClientAdapter = adapter,
    );

    Object? error;
    try {
      await browser.list(protocol: protocol());
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<FormatException>());
    expect(error.toString(), contains('WebDAV response is invalid.'));
    expect(error.toString(), isNot(contains('dav.example.test')));
    expect(error.toString(), isNot(contains('secret')));
  });

  test('bounds requests and returns a sanitized timeout error', () async {
    final responseCompleter = Completer<ResponseBody>();
    final adapter = _Adapter((_) => responseCompleter.future);
    final browser = WebDavBackupFolderBrowser(
      connections: connections,
      dio: Dio()..httpClientAdapter = adapter,
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      browser.list(protocol: protocol()),
      throwsA(
        isA<WebDavBackupFolderException>().having(
          (error) => error.code,
          'code',
          'provider.webdav.browse_timeout',
        ),
      ),
    );
    responseCompleter.complete(_response(207, _xml('')));
    await Future<void>.delayed(Duration.zero);
  });
}

String _xml(String responses) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">$responses</d:multistatus>';

ResponseBody _response(int status, String body) => ResponseBody.fromString(
  body,
  status,
  headers: const {
    Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];
  String? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = <int>[];
    await for (final chunk in requestStream ?? Stream<Uint8List>.empty()) {
      body.addAll(chunk);
    }
    lastBody = utf8.decode(body);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class _Credentials implements CredentialStore {
  _Credentials(this.password);

  final String? password;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> readWebDavPassword(String credentialRef) async {
    reads++;
    return password;
  }

  @override
  Future<String> writeWebDavPassword(String password) async {
    writes++;
    throw StateError('The browser must not persist credentials.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
