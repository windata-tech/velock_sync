import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

void _expectBodyStyle(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  final style = paragraph.text.style!;
  expect(style.fontSize, inInclusiveRange(14, 18));
  expect(style.fontWeight, isNot(FontWeight.w700));
  expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      testWidgets('$platform $brightness page, tabs and popup body styles', (
        tester,
      ) async {
        Widget app(Widget home) => MaterialApp(
          theme: ThemeData(platform: platform, brightness: brightness),
          home: home,
        );

        await tester.pumpWidget(
          app(
            AdaptivePageScaffold(
              appBar: WDAppBar(title: const Text('Connection')),
              body: Builder(
                builder: (context) => Column(
                  children: [
                    const Text(
                      '/USB_HDD_8T/6',
                      style: TextStyle(color: Colors.grey),
                    ),
                    TextButton(
                      onPressed: () => showAppDetailSheet(
                        context,
                        title: '同步记录 · 失败',
                        closeLabel: '关闭',
                        rows: const [
                          AppDetailSheetRow(label: '结果', value: '失败'),
                        ],
                        footnote: '技术详情',
                      ),
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectBodyStyle(tester, '/USB_HDD_8T/6');
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        for (final text in ['同步记录 · 失败', '结果', '失败', '技术详情']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(text),
          );
          expect(
            paragraph.text.style!.decoration ?? TextDecoration.none,
            TextDecoration.none,
            reason: text,
          );
        }
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('同步记录 · 失败'), findsNothing);

        await tester.pumpWidget(
          app(
            AdaptiveTabScaffold(
              currentIndex: 0,
              onChanged: (_) {},
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.folder),
                  label: 'Files',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
              body: const Center(child: Text('Body')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectBodyStyle(tester, 'Body');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
