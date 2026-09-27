import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

const _targetPlatforms = [TargetPlatform.iOS, TargetPlatform.android];

Widget _app({
  required TargetPlatform platform,
  required Widget home,
  Locale locale = const Locale('en'),
}) => PlatformProvider(
  initialPlatform: platform,
  builder: (context) => PlatformApp(
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

Route<void> _routeTo(Widget page) => PageRouteBuilder<void>(
  pageBuilder: (context, animation, secondaryAnimation) => page,
  transitionDuration: Duration.zero,
  reverseTransitionDuration: Duration.zero,
);

class _RootPage extends StatelessWidget {
  const _RootPage();

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: WDAppBar(title: const Text('Root')),
    body: Center(
      child: PlatformTextButton(
        onPressed: () =>
            Navigator.of(context).push(_routeTo(const _PushedPage())),
        child: const Text('Push page'),
      ),
    ),
  );
}

class _PushedPage extends StatelessWidget {
  const _PushedPage();

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: WDAppBar(title: const Text('Pushed')),
    body: const SizedBox.shrink(),
  );
}

class _BlockedPage extends StatelessWidget {
  const _BlockedPage();

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: PlatformScaffold(
      appBar: WDAppBar(title: const Text('Blocked')),
      body: const SizedBox.shrink(),
    ),
  );
}

class _BlockingRootPage extends StatelessWidget {
  const _BlockingRootPage();

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: WDAppBar(title: const Text('Root')),
    body: Center(
      child: PlatformTextButton(
        onPressed: () =>
            Navigator.of(context).push(_routeTo(const _BlockedPage())),
        child: const Text('Push blocked page'),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in _targetPlatforms) {
    for (final large in [true, false]) {
      testWidgets(
        '$platform sliver header large=$large uses the same back button',
        (tester) async {
          Widget page() => AdaptiveSliverScaffold(
            title: 'Folders',
            useLargeTitle: large,
            slivers: const [SliverToBoxAdapter(child: Text('Content'))],
          );
          await tester.pumpWidget(_app(platform: platform, home: page()));
          expect(find.byType(AppBackButton), findsNothing);
          final context = tester.element(find.byType(AdaptiveSliverScaffold));
          Navigator.of(context).push(_routeTo(page()));
          await tester.pumpAndSettle();
          expect(find.byType(AppBackButton), findsOneWidget);
          expect(
            tester.getTopLeft(find.byIcon(Icons.chevron_left_rounded)).dx,
            closeTo(6, 0.01),
            reason: 'Sliver headers must not double-inset the visible arrow',
          );
          expect(find.byType(BackButton), findsNothing);
          expect(find.byType(CupertinoNavigationBarBackButton), findsNothing);
          await tester.tap(find.byType(AppBackButton));
          await tester.pumpAndSettle();
          expect(find.byType(AppBackButton), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '$platform root has no back and pushed page uses AppBackButton',
      (tester) async {
        await tester.pumpWidget(
          _app(platform: platform, home: const _RootPage()),
        );

        expect(find.byType(AppBackButton), findsNothing);

        await tester.tap(find.text('Push page'));
        await tester.pumpAndSettle();

        expect(find.byType(AppBackButton), findsOneWidget);
        expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
        expect(
          tester.getTopLeft(find.byIcon(Icons.chevron_left_rounded)).dx,
          closeTo(6, 0.01),
          reason:
              'Icon box starts at 6; visible tip aligns with the 16px page edge',
        );
        expect(find.byTooltip('Back'), findsOneWidget);
        expect(find.byType(BackButton), findsNothing);
        expect(find.byType(CupertinoNavigationBarBackButton), findsNothing);
        // Material's toolbar can allocate 56px; the shared affordance must
        // never shrink below its 44px accessible touch target.
        final size = tester.getSize(find.byType(AppBackButton));
        expect(size.width, greaterThanOrEqualTo(AppBackButton.touchTargetSize));
        expect(
          size.height,
          greaterThanOrEqualTo(AppBackButton.touchTargetSize),
        );
        expect(
          tester.widget<Icon>(find.byIcon(Icons.chevron_left_rounded)).size,
          AppBackButton.iconSize,
        );

        await tester.tap(find.byType(AppBackButton));
        await tester.pumpAndSettle();

        expect(find.text('Root'), findsOneWidget);
        expect(find.byType(AppBackButton), findsNothing);
      },
    );

    testWidgets('$platform chevron is at least 30px inside the 44px target', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        _app(
          platform: platform,
          home: PlatformScaffold(
            appBar: WDAppBar(
              title: const Text('Header'),
              leading: AppBackButton(onPressed: () => calls++),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );

      // The rounded Material glyph carries internal whitespace in its
      // design grid, so the icon box must stay large enough for the
      // visible chevron while the touch target keeps its 44px floor.
      expect(AppBackButton.iconSize, greaterThanOrEqualTo(30));
      expect(AppBackButton.touchTargetSize, greaterThanOrEqualTo(44));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.chevron_left_rounded)).size,
        greaterThanOrEqualTo(30),
      );
      final target = tester.getSize(find.byType(AppBackButton));
      expect(target.width, greaterThanOrEqualTo(44));
      expect(target.height, greaterThanOrEqualTo(44));

      // Enlarging the glyph must not change the affordance semantics or
      // its behavior.
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);
      final semantics = tester.getSemantics(find.bySemanticsLabel('Back'));
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.label, 'Back');

      await tester.tap(find.byType(AppBackButton));
      await tester.pump();

      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });

    for (final localizedCase in const [
      (locale: Locale('en'), label: 'Back'),
      (locale: Locale('zh'), label: '返回'),
    ]) {
      testWidgets(
        '$platform explicit callback and ${localizedCase.label} semantics',
        (tester) async {
          var calls = 0;
          await tester.pumpWidget(
            _app(
              platform: platform,
              locale: localizedCase.locale,
              home: PlatformScaffold(
                appBar: WDAppBar(
                  title: const Text('Header'),
                  leading: AppBackButton(onPressed: () => calls++),
                ),
                body: const SizedBox.shrink(),
              ),
            ),
          );

          expect(find.byType(AppBackButton), findsOneWidget);
          expect(find.byTooltip(localizedCase.label), findsOneWidget);
          expect(find.bySemanticsLabel(localizedCase.label), findsOneWidget);

          await tester.tap(find.byType(AppBackButton));
          await tester.pump();

          expect(calls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$platform disabled AppBackButton keeps its semantics', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        _app(
          platform: platform,
          home: PlatformScaffold(
            appBar: WDAppBar(
              title: const Text('Header'),
              leading: AppBackButton(onPressed: null),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);

      await tester.tap(find.byType(AppBackButton), warnIfMissed: false);
      await tester.pump();

      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform default back respects PopScope refusal', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(platform: platform, home: const _BlockingRootPage()),
      );
      await tester.tap(find.text('Push blocked page'));
      await tester.pumpAndSettle();

      expect(find.text('Blocked'), findsOneWidget);
      expect(find.byType(AppBackButton), findsOneWidget);

      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();

      expect(find.text('Blocked'), findsOneWidget);
      expect(find.byType(AppBackButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
