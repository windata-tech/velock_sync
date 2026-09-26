import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  const scopedSegments = ['中文 空格', '%', '#', '?'];

  test('empty scope returns the original protocol unchanged', () {
    final protocol = _webDavProtocol();
    expect(
      identical(
        RemoteObjectStoreFactory.scopeProtocol(protocol, const []),
        protocol,
      ),
      isTrue,
    );
  });

  test('appends decoded segments once without mutating the connection', () {
    final protocol = _webDavProtocol();
    final scoped = RemoteObjectStoreFactory.scopeProtocol(
      protocol,
      scopedSegments,
    );

    expect(protocol.address, 'https://dav.example.test:8443/root/中文 空格');
    expect(protocol.path, '/provider');
    expect(scoped, isA<WebDavProtocolModel>());
    final webDav = scoped as WebDavProtocolModel;
    expect(webDav.address, _expectedScopedAddress);
    expect(webDav.path, isNull);
    expect(webDav.port, protocol.port);
    expect(webDav.username, protocol.username);
    expect(webDav.credentialRef, protocol.credentialRef);
    expect(RemoteObjectStoreFactory.webDavUri(webDav).pathSegments, [
      'root',
      '中文 空格',
      'provider',
      ...scopedSegments,
    ]);
    expect(_expectedScopedAddress.split('/%25').length - 1, 1);
    expect(_expectedScopedAddress.split('/%23').length - 1, 1);
    expect(_expectedScopedAddress.split('/%3F').length - 1, 1);
  });

  test(
    'accepts root and trailing-slash configured paths without duplicating them',
    () {
      final root = _webDavProtocol().copyWith(
        address: 'https://dav.example.test',
        path: '/',
      );
      expect(
        RemoteObjectStoreFactory.webDavUri(
          root,
        ).pathSegments.where((s) => s.isNotEmpty),
        isEmpty,
      );
      final folder = root.copyWith(path: '/共享/');
      final scoped =
          RemoteObjectStoreFactory.scopeProtocol(folder, ['备份'])
              as WebDavProtocolModel;
      expect(RemoteObjectStoreFactory.webDavUri(scoped).pathSegments, [
        '共享',
        '备份',
      ]);
    },
  );

  test('rejects a non-WebDAV protocol with a non-empty scope', () {
    final protocol = ProtocolModel.oauth(
      providerType: RemoteProviderType.googleDrive,
      clientId: 'public-client-id',
      credentialRef: 'opaque-ref',
      rootId: 'root',
    );
    expect(
      () => RemoteObjectStoreFactory.scopeProtocol(protocol, const ['folder']),
      throwsArgumentError,
    );
  });

  for (final invalid in <String>['', '.', '..', 'a/b', 'a\\b', 'a\nb']) {
    test('rejects invalid scope segment ${invalid.codeUnits}', () {
      expect(
        () => RemoteObjectStoreFactory.scopeProtocol(_webDavProtocol(), [
          invalid,
        ]),
        throwsArgumentError,
      );
    });
  }
}

WebDavProtocolModel _webDavProtocol() => const WebDavProtocolModel(
  protocolType: WebDavProtocolType.https,
  address: 'https://dav.example.test:8443/root/中文 空格',
  port: '8443',
  username: 'alice',
  credentialRef: 'opaque-ref',
  path: '/provider',
);
const _expectedScopedAddress =
    'https://dav.example.test:8443/root/%E4%B8%AD%E6%96%87%20%E7%A9%BA%E6%A0%BC/provider/%E4%B8%AD%E6%96%87%20%E7%A9%BA%E6%A0%BC/%25/%23/%3F';
