import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// UI automation (XCUITest, UiAutomator) finds controls by the platform
/// accessibility identifier. The identifier must sit on the node that also
/// carries the control's own label and tap action, otherwise a test would find
/// the id but tap or read the wrong thing.
void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group(platform.name, () {
      Future<void> pump(WidgetTester tester, Widget child) =>
          tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(body: ListView(children: [child])),
            ),
          );

      void expectTappable(WidgetTester tester, String id, String label) {
        final finder = find.bySemanticsIdentifier(id);
        expect(finder, findsOneWidget, reason: id);
        // Cupertino controls merge into the identified node. Material buttons
        // keep their own container, so the button is its only child; tapping
        // the identified frame still lands on it.
        var node = tester.getSemantics(finder);
        if (!node.getSemanticsData().hasAction(SemanticsAction.tap)) {
          final children = <SemanticsNode>[];
          node.visitChildren((child) {
            children.add(child);
            return true;
          });
          expect(children, hasLength(1), reason: id);
          node = children.single;
          expect(node.rect.size, tester.getSemantics(finder).rect.size);
        }
        final data = node.getSemanticsData();
        expect(data.label, contains(label), reason: id);
        expect(data.hasAction(SemanticsAction.tap), isTrue, reason: id);
      }

      testWidgets('keyed controls expose their key as the identifier', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          Column(
            children: [
              BackupActionButton(
                key: const Key('e2e-primary'),
                label: '开始备份',
                onPressed: () {},
              ),
              AdaptiveListTile(
                widgetKey: const Key('e2e-row'),
                title: const Text('WebDAV'),
                onTap: () {},
              ),
              AdaptiveTextButton(
                key: const Key('e2e-text'),
                onPressed: () {},
                child: const Text('保存'),
              ),
              AdaptiveTextFormField(
                key: const Key('e2e-field'),
                label: '端口',
                controller: TextEditingController(),
              ),
            ],
          ),
        );
        expectTappable(tester, 'e2e-primary', '开始备份');
        expectTappable(tester, 'e2e-row', 'WebDAV');
        expectTappable(tester, 'e2e-text', '保存');
        // A text field keeps its own node; the identified node wraps it.
        expect(
          find.descendant(
            of: find.bySemanticsIdentifier('e2e-field'),
            matching: find.byType(EditableText),
          ),
          findsOneWidget,
        );
        handle.dispose();
      });

      testWidgets('unkeyed controls stay as they were', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          BackupActionButton(label: '开始备份', onPressed: () {}),
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.identifier != null,
          ),
          findsNothing,
        );
        handle.dispose();
      });

      testWidgets('dialog actions carry their key as the identifier', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          Builder(
            builder: (context) => BackupActionButton(
              label: 'open',
              onPressed: () => showAdaptiveConfirmation(
                context,
                title: 'HTTP?',
                message: 'm',
                confirmLabel: '仍然使用 HTTP',
                cancelLabel: '保持 HTTPS',
                confirmKey: const Key('e2e-confirm'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expectTappable(tester, 'e2e-confirm', '仍然使用 HTTP');
        handle.dispose();
      });
    });
  }
}
