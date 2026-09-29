/// Disabled artwork keeps its own colour.
///
/// A disabled `CupertinoButton` repaints its child with
/// `CupertinoColors.quaternaryLabel`, which turned the Velock mark, the folder
/// glyphs and header icons grey whenever they could not be tapped. The app
/// fades them instead (same 45% opacity the rest of the design system uses), so
/// the colour that identifies the item survives.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/velock_brand_mark.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

Widget _host(Widget child) => MaterialApp(
  // isApplePlatform() reads Theme.of(context).platform, so the iOS branch
  // (Cupertino controls) is what these assertions exercise.
  theme: ThemeData(platform: TargetPlatform.iOS),
  home: Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => Theme(data: Theme.of(context), child: child),
      ),
    ),
  ),
);

void main() {
  testWidgets('a disabled icon button fades instead of turning grey', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AdaptiveIconButton(
          icon: Icon(CupertinoIcons.add),
          onPressed: null,
        ),
      ),
    );

    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byIcon(CupertinoIcons.add),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, AppOpacity.disabled);
    // The glyph keeps whatever colour it was given.
    expect(tester.widget<Icon>(find.byIcon(CupertinoIcons.add)).color, isNull);
  });

  testWidgets('a busy folder tile keeps the blue folder glyph', (tester) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 120,
          height: 120,
          child: RemoteFileItem(
            file: WebdavFile(
              path: '/share/USB_HDD_8T',
              isDir: true,
              name: 'USB_HDD_8T',
            ),
            inactive: true,
          ),
        ),
      ),
    );

    final icon = tester.widget<Icon>(find.byIcon(CupertinoIcons.folder_solid));
    expect(icon.color, isNotNull);
    expect(icon.color!.a, 1.0, reason: 'the hue stays fully saturated');
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byIcon(CupertinoIcons.folder_solid),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, AppOpacity.disabled);
  });

  testWidgets('an active folder tile is fully opaque', (tester) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 120,
          height: 120,
          child: RemoteFileItem(
            file: WebdavFile(
              path: '/share/Photos',
              isDir: true,
              name: 'Photos',
            ),
          ),
        ),
      ),
    );

    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byIcon(CupertinoIcons.folder_solid),
            matching: find.byType(Opacity),
          )
          .first,
    );
    // The tile keeps one widget shape and only animates its opacity, so a
    // refresh never rebuilds the listing's elements.
    expect(opacity.opacity, 1);
  });

  testWidgets('the brand mark is never repainted by a disabled parent', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AdaptiveIconButton(
          icon: VelockBrandMark(size: 24, flat: true),
          onPressed: null,
        ),
      ),
    );

    expect(find.byType(VelockBrandMark), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(VelockBrandMark),
        matching: find.byType(Opacity),
      ),
      findsWidgets,
    );
  });
}
