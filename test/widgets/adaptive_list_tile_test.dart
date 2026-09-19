import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// The pressed background `CupertinoListTile` paints while it is held down.
final Finder _pressedRow = find.descendant(
  of: find.byType(CupertinoListTile),
  matching: find.byWidgetPredicate(
    (widget) => widget is ColoredBox && widget.color.a > 0,
  ),
);

void main() {
  testWidgets('tapped row drops its highlight even if onTap never completes', (
    tester,
  ) async {
    // go_router's push() future only completes when the pushed route is popped,
    // and navigating away with go() drops the route without completing it.
    final pendingRoute = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: AdaptiveListSection(
            children: [
              AdaptiveListTile(
                widgetKey: const Key('row'),
                title: const Text('test1 的 Velock'),
                subtitle: const Text('格间备份 · 后台同步已开启'),
                onTap: () => pendingRoute.future,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('row')));
    await tester.pump();

    expect(_pressedRow, findsNothing, reason: '手指抬起后行必须回弹，不能停在按下态');
  });

  testWidgets('row returns to rest when the pushed route is dropped by go()', (
    tester,
  ) async {
    // Mirrors the reported path: home row → pushed detail →「前往」replaces the
    // stack with another tab → back to the home tab.
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => Scaffold(
            body: AdaptiveListSection(
              children: [
                AdaptiveListTile(
                  widgetKey: const Key('row'),
                  title: const Text('test1 的 Velock'),
                  onTap: () => context.push('/detail'),
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/detail',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.go('/activity'),
                child: const Text('前往'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/activity',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.go('/home'),
                child: const Text('同步'),
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.iOS),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('row')));
    await tester.pumpAndSettle();
    expect(find.text('前往'), findsOneWidget);

    await tester.tap(find.text('前往'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('row')), findsOneWidget);
    expect(_pressedRow, findsNothing, reason: '回到同步页时该行不能仍停在按下态');
  });

  testWidgets(
    'kept-alive home branch returns to rest after go() drops a push',
    (tester) async {
      // The app shell keeps the four tabs alive in an IndexedStack, so the home
      // row survives a tab switch. This mirrors the reported path end to end:
      // home row → pushed detail →「前往活动页」go('/activity') → back to 同步.
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) => Scaffold(
              body: shell,
              bottomNavigationBar: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    onPressed: () => shell.goBranch(0),
                    child: const Text('同步'),
                  ),
                  TextButton(
                    onPressed: () => shell.goBranch(1),
                    child: const Text('活动'),
                  ),
                ],
              ),
            ),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/home',
                    builder: (context, state) => AdaptiveListSection(
                      children: [
                        AdaptiveListTile(
                          widgetKey: const Key('row'),
                          title: const Text('test1 的 Velock'),
                          subtitle: const Text('格间备份 · 后台同步已开启'),
                          onTap: () => context.push('/detail'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/activity',
                    builder: (context, state) =>
                        const Center(child: Text('活动页')),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/detail',
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.go('/activity'),
                  child: const Text('前往'),
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.iOS),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('row')), findsOneWidget);

      await tester.tap(find.byKey(const Key('row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('前往'));
      await tester.pumpAndSettle();
      expect(find.text('活动页'), findsOneWidget);

      await tester.tap(find.text('同步'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('row')), findsOneWidget);
      expect(_pressedRow, findsNothing, reason: '切回同步页时该行不能仍停在按下态');
    },
  );

  testWidgets('tapping a row still runs its callback on both platforms', (
    tester,
  ) async {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: AdaptiveListSection(
              children: [
                AdaptiveListTile(
                  widgetKey: const Key('row'),
                  title: const Text('test1 的 Velock'),
                  onTap: () {
                    taps += 1;
                  },
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('row')));
      await tester.pumpAndSettle();

      expect(taps, 1, reason: '$platform 上点击行仍必须触发回调');
      expect(_pressedRow, findsNothing, reason: '$platform 上点击后行必须回弹');
    }
  });

  testWidgets('switch row drops its highlight when the save never resolves', (
    tester,
  ) async {
    // Switches save asynchronously: `onChanged: (value) => _save(...)` returns a
    // future, and a failing save must not leave the row pressed.
    final pendingSave = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: AdaptiveListSection(
            children: [
              AdaptiveSwitchListTile(
                widgetKey: const Key('switch-row'),
                title: const Text('后台同步'),
                subtitle: const Text('仅在系统允许且配置处于活动状态时运行。'),
                value: true,
                onChanged: (value) => pendingSave.future,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('switch-row')));
    await tester.pump();

    expect(_pressedRow, findsNothing, reason: '开关行点击后也必须回弹');
  });
}
