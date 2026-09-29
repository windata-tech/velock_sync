/// The WebDAV wizard is the longest form in the connection feature, so it is
/// the one that proves `AdaptiveTextFormField` still behaves like a real
/// `FormField` on both design languages.
///
/// `flutter_platform_widgets` needed the label twice (a Material
/// `InputDecoration.labelText` plus a Cupertino prefix widget whose fixed 112pt
/// box overflowed on "Server Address"). The migration keeps one label and lets
/// it grow, so both branches are checked here: the labels are painted, the
/// controllers keep their values, and `Form.validate()` still reports the
/// validators' messages.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

Widget _app({required TargetPlatform platform}) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(platform: platform),
    home: const NewWebDav(),
  ),
);

Future<void> _pump(WidgetTester tester, TargetPlatform platform) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(platform: platform));
  await tester.pumpAndSettle();
}

Finder _fieldEditor(String name) => find.descendant(
  of: find.byKey(ValueKey('webdav_$name')),
  matching: find.byType(EditableText),
);

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform paints every WebDAV label without overflowing', (
      tester,
    ) async {
      await _pump(tester, platform);

      for (final label in [
        'Server Address',
        'Port',
        'Subpath',
        'Username',
        'Password',
        'Enable HTTPS',
        'Save',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // Five fields, all of them form fields on this platform.
      expect(find.byType(AdaptiveTextFormField), findsNWidgets(5));
      // The same label reaches both branches: the Apple row prefix, or the
      // Material floating label.
      expect(
        find.byType(AdaptiveFieldPrefix),
        platform == TargetPlatform.iOS ? findsNWidgets(5) : findsNothing,
      );
      // No RenderFlex overflow from the long English label, and no other
      // exception while building the migrated widgets.
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform keeps the field values and the HTTPS switch', (
      tester,
    ) async {
      await _pump(tester, platform);

      expect(
        tester
            .widget<AdaptiveTextFormField>(
              find.byKey(const ValueKey('webdav_address')),
            )
            .controller
            .text,
        'https://',
      );
      expect(
        tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch)).value,
        isTrue,
      );

      await tester.enterText(_fieldEditor('address'), 'https://nas.local');
      await tester.enterText(_fieldEditor('port'), '5006');
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<AdaptiveTextFormField>(
              find.byKey(const ValueKey('webdav_address')),
            )
            .controller
            .text,
        'https://nas.local',
      );
      expect(find.text('https://nas.local'), findsOneWidget);
      expect(find.text('5006'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform still runs the WebDAV validators on save', (
      tester,
    ) async {
      await _pump(tester, platform);

      await tester.enterText(_fieldEditor('address'), '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a server address'), findsOneWidget);
      expect(find.text('Enter a port'), findsOneWidget);

      await tester.enterText(_fieldEditor('address'), 'not-a-url');
      await tester.enterText(_fieldEditor('port'), '5006');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Enter the full address starting with http:// or https://, e.g. https://nas.example.com',
        ),
        findsOneWidget,
      );
      expect(find.text('Enter a port'), findsNothing);
      // Validation failed, so nothing was submitted to a repository or a probe.
      expect(find.text('Enter a server address'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the Apple branch shows the label as the row prefix', (
    tester,
  ) async {
    await _pump(tester, TargetPlatform.iOS);

    // One shared label, drawn in the growing prefix box rather than the fixed
    // 112pt box that clipped "Server Address".
    final prefixes = find.byType(AdaptiveFieldPrefix);
    expect(prefixes, findsNWidgets(5));
    for (final label in ['Server Address', 'Subpath', 'Username']) {
      expect(
        find.descendant(of: prefixes, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      tester.getSize(find.byType(AdaptiveFieldPrefix).first).width,
      greaterThanOrEqualTo(112),
    );
    expect(tester.takeException(), isNull);
  });
}
