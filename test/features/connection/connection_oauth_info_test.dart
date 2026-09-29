import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

class _Detail extends ConnectionDetail {
  _Detail(this.provider);
  final RemoteProviderType provider;
  @override
  Future<ConnectionModel?> build(String id) async => ConnectionModel(
    id: id,
    name: 'Cloud connection',
    source: 'test',
    target: 'Test account',
    protocol: OAuthProtocolModel(
      providerType: provider,
      clientId: 'test',
      credentialRef: 'not-read',
      rootId: 'root',
    ),
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    status: ConnectionStatus.active,
  );
}

void main() {
  for (final provider in [
    RemoteProviderType.googleDrive,
    RemoteProviderType.oneDrive,
  ]) {
    testWidgets(
      '$provider moves technical details into a read-only info sheet',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              connectionDetailProvider(
                'test',
              ).overrideWith(() => _Detail(provider)),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              supportedLocales: const [Locale('zh'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: ThemeData(platform: TargetPlatform.iOS),
              home: const Connection('test'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('账号与目录'), findsOneWidget);
        expect(find.text('支持能力'), findsNothing);
        expect(find.text('使用限制'), findsNothing);
        expect(find.textContaining('PKCE'), findsNothing);
        await tester.tap(find.byKey(const Key('connection-info')));
        await tester.pumpAndSettle();
        expect(find.text('连接说明'), findsOneWidget);
        expect(find.textContaining('不是当前服务器的检测结果'), findsOneWidget);
        expect(find.textContaining('PKCE'), findsOneWidget);
        await tester.ensureVisible(find.text('关闭'));
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('账号与目录'), findsOneWidget);
        expect(find.textContaining('PKCE'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
