import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
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
          child: PlatformProvider(
            initialPlatform: TargetPlatform.iOS,
            builder: (context) => PlatformApp(home: const NewConnection()),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('选择远端协议'), findsOneWidget);
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
        child: PlatformProvider(
          initialPlatform: TargetPlatform.iOS,
          builder: (context) => PlatformApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择远端协议'));
    await tester.pumpAndSettle();
    expect(find.text('协议选择页'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('选择远端协议'), findsOneWidget);

    await tester.tap(find.text('选择远端协议'));
    await tester.pumpAndSettle();
    expect(find.text('协议选择页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
