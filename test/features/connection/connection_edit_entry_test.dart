/// The connections list "more actions" menu must offer the same entries the
/// connection page does: the read-only connection notes, plus editing.
///
/// Editing reuses the detail page's pencil routes — WebDAV reopens the WebDAV
/// form with `replace=<id>`, an OAuth connection reopens its provider's
/// authorization flow with the same parameter — and the notes entry is the
/// shared `showConnectionInfoSheet`, which never probes or writes anything.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart'
    as state;
import 'package:velock_sync/features/connection/ui/connections.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

class _TestConnections extends state.Connections {
  _TestConnections(this.connections);
  final List<ConnectionModel> connections;

  @override
  Future<List<ConnectionModel>> build() async => connections;
}

ConnectionModel _webDav() => ConnectionModel(
  id: 'conn-webdav',
  name: '家里 NAS',
  source: 'nas.local',
  target: 'https://nas.local:5006/share',
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: 'https://nas.local',
    port: '5006',
    path: '/share',
    username: 'parcool',
    credentialRef: 'cred-1',
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

ConnectionModel _oAuth() => ConnectionModel(
  id: 'conn-oauth',
  name: 'Google Drive',
  source: 'googleDrive',
  target: 'Google Drive',
  protocol: const OAuthProtocolModel(
    providerType: RemoteProviderType.googleDrive,
    clientId: 'client-1',
    credentialRef: 'cred-2',
    rootId: 'root',
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

Future<GoRouter> _mount(WidgetTester tester, ConnectionModel connection) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      state.connectionsProvider.overrideWith(
        () => _TestConnections([connection]),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Connections()),
      GoRoute(
        name: 'newWebDav',
        path: '/protocol/webdav/new',
        builder: (context, state) => Column(
          children: [
            Text('WebDAV 表单 replace=${state.uri.queryParameters['replace']}'),
            TextButton(
              onPressed: () => leaveConnectionEditor(
                context,
                state.uri.queryParameters['returnTo'],
              ),
              child: const Text('fake-save'),
            ),
          ],
        ),
      ),
      GoRoute(
        path: '/connections',
        builder: (_, _) => const Text('replaced-connections-stack'),
      ),
      GoRoute(
        name: 'newOAuth',
        path: '/protocol/:provider/oauth/new',
        builder: (_, state) => Text(
          'OAuth 授权页 ${state.pathParameters['provider']} '
          'replace=${state.uri.queryParameters['replace']}',
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: TargetPlatform.iOS),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _openEdit(WidgetTester tester) async {
  // iOS renders the action menu as a Cupertino "..." button whose tooltip
  // lives in a Semantics label rather than a Tooltip widget.
  await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
  await tester.pumpAndSettle();

  // Deleting was the only action before; editing sits next to it.
  expect(find.text('修改连接'), findsOneWidget);
  expect(find.text('删除连接'), findsOneWidget);

  await tester.tap(find.text('修改连接'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the menu opens the read-only connection notes', (tester) async {
    await _mount(tester, _webDav());
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();

    expect(find.text('连接说明'), findsOneWidget);
    await tester.tap(find.text('连接说明'));
    await tester.pumpAndSettle();

    // The technical notes, with their non-probing disclaimer intact.
    expect(find.text('这些是连接方式的技术说明，不是当前服务器的检测结果。'), findsOneWidget);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(
      find.text(
        '浏览、上传和下载服务里的文件\n'
        '新文件先写临时文件、再原子改名：不会覆盖服务上已有的同名文件',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('不支持断点续传：大文件中断后要从头重新上传'), findsOneWidget);
    expect(find.text('密码存在系统安全存储里，不写进连接记录、备份或日志'), findsOneWidget);
    expect(find.text('浏览文件夹不需要设置这些项目。能否备份，以实际连接和备份检查为准。'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a WebDAV connection reopens its form prefilled', (tester) async {
    await _mount(tester, _webDav());
    await _openEdit(tester);

    // The prefilled WebDAV form is what opens, not a fresh connection form.
    expect(find.text('WebDAV 表单 replace=conn-webdav'), findsOneWidget);
  });

  // QA 2026-09-29: saving an edit started from the list used to replace the
  // stack with a bare connections page — no back button, no tab bar.
  testWidgets('saving an edit returns to the page that opened the editor', (
    tester,
  ) async {
    final router = await _mount(tester, _webDav());
    await _openEdit(tester);
    await tester.tap(find.text('fake-save'));
    await tester.pumpAndSettle();

    expect(find.text('replaced-connections-stack'), findsNothing);
    expect(find.byType(Connections), findsOneWidget);
    expect(router.state.uri.path, '/');
  });

  testWidgets('an OAuth connection reopens its provider authorization', (
    tester,
  ) async {
    await _mount(tester, _oAuth());
    await _openEdit(tester);

    expect(
      find.text('OAuth 授权页 googleDrive replace=conn-oauth'),
      findsOneWidget,
    );
  });
}
