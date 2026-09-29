import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/ui/new_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'new connection route builds without mutating a provider during build',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: const NewConnection(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Choose Remote Protocol'), findsOneWidget);
    },
  );

  testWidgets('new connection forward and back keeps the page interactive', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/connection/new',
      routes: [
        GoRoute(
          name: 'newConnection',
          path: '/connection/new',
          builder: (context, state) => const NewConnection(),
        ),
        GoRoute(
          name: 'protocols',
          path: '/protocols',
          builder: (context, state) => const Text('协议选择页'),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.iOS),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose Remote Protocol'));
    await tester.pumpAndSettle();
    expect(find.text('协议选择页'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('Choose Remote Protocol'), findsOneWidget);

    await tester.tap(find.text('Choose Remote Protocol'));
    await tester.pumpAndSettle();
    expect(find.text('协议选择页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
