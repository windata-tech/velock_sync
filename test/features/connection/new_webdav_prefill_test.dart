/// Editing a WebDAV connection opens the form with its saved address, port,
/// subpath and account, so a user fixing one value does not retype the rest.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

ConnectionModel _connection({String? credentialRef}) => ConnectionModel(
  id: 'conn-1',
  name: '我的云端',
  source: 'http://127.0.0.1',
  target: 'http://127.0.0.1:18991/dav',
  protocol: WebDavProtocolModel(
    protocolType: WebDavProtocolType.http,
    address: 'http://127.0.0.1',
    port: '18991',
    path: '/dav',
    username: 'velock',
    credentialRef: credentialRef,
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

String _text(WidgetTester tester, String name) => tester
    .widget<AdaptiveTextFormField>(find.byKey(ValueKey('webdav_$name')))
    .controller
    .text;

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final (cached, password) in [
      (false, true),
      (true, true),
      // A server without a password stores no credential reference; the
      // form used to wait for that reference to change before filling in.
      (false, false),
    ]) {
      testWidgets('$platform fills the form with the saved connection'
          '${cached ? ' already loaded elsewhere' : ''}'
          '${password ? '' : ' that has no password'}', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final container = ProviderContainer(
          overrides: [
            connectionDetailProvider('conn-1').overrideWith(
              () => _FixedDetail(
                _connection(credentialRef: password ? 'cred-1' : null),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        // The connection detail page usually read it already.
        if (cached) {
          container.listen(connectionDetailProvider('conn-1'), (_, _) {});
          await container.read(connectionDetailProvider('conn-1').future);
        }
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('zh'),
              supportedLocales: const [Locale('zh'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: ThemeData(platform: platform),
              home: const NewWebDav(replacementConnectionId: 'conn-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(_text(tester, 'address'), 'http://127.0.0.1');
        expect(_text(tester, 'port'), '18991');
        expect(_text(tester, 'path'), '/dav');
        expect(_text(tester, 'user'), 'velock');
        expect(_text(tester, 'name'), '我的云端');
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _FixedDetail extends ConnectionDetail {
  _FixedDetail(this.value);
  final ConnectionModel value;

  @override
  Future<ConnectionModel?> build(String id) async => value;
}
