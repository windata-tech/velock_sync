/// The "edit connection" glyph paints in the colour it is given, at any size,
/// and sits in a header row next to the system icons.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/connection_settings_glyph.dart';

void main() {
  testWidgets('paints only in its own colour', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            // ignore: prefer_const_constructors
            child: ColoredBox(
              color: Color(0xFFFFFFFF),
              child: ConnectionSettingsGlyph(
                size: 48,
                color: Color(0xFF3366DD),
              ),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage());
    final bytes = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    var inked = 0;
    for (var i = 0; i < bytes.lengthInBytes; i += 4) {
      final r = bytes.getUint8(i), g = bytes.getUint8(i + 1);
      final b = bytes.getUint8(i + 2);
      if (r == 255 && g == 255 && b == 255) continue;
      inked++;
      // Anti-aliased edges blend toward white; nothing else is drawn.
      expect(b, greaterThanOrEqualTo(r), reason: 'pixel ${i ~/ 4}');
    }
    // Visible but not a solid block.
    expect(inked, inInclusiveRange(48 * 48 * 0.15, 48 * 48 * 0.6));
  });

  testWidgets('reads its label and follows the icon theme', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: IconThemeData(color: Color(0xFF00AA00)),
          child: Center(child: ConnectionSettingsGlyph(semanticLabel: '修改连接')),
        ),
      ),
    );
    expect(find.bySemanticsLabel('修改连接'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ConnectionSettingsGlyph)),
      const Size(24, 24),
    );
  });

  // Visual check against the neighbouring header icons. Writes a PNG only when
  // GLYPH_PREVIEW names a file.
  testWidgets('preview next to the header icons', (tester) async {
    final out = Platform.environment['GLYPH_PREVIEW'];
    if (out == null) return;
    await tester.runAsync(() async {
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          ))
          .load();
    });
    final key = GlobalKey();
    const blue = Color(0xFF3366DD);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            // ignore: prefer_const_constructors
            child: ColoredBox(
              color: Color(0xFFF2F2F7),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.info_circle, color: blue, size: 28),
                    SizedBox(width: 24),
                    ConnectionSettingsGlyph(color: blue, size: 28),
                    SizedBox(width: 24),
                    Icon(CupertinoIcons.arrow_clockwise, color: blue, size: 28),
                    SizedBox(width: 24),
                    Icon(
                      CupertinoIcons.folder_badge_plus,
                      color: blue,
                      size: 28,
                    ),
                    SizedBox(width: 24),
                    ConnectionSettingsGlyph(color: blue, size: 96),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(out).writeAsBytes(png!.buffer.asUint8List());
    });
  });
}
