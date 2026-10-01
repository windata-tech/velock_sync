/// Apple platforms show alerts, forms and menus as the app's own cards: capsule
/// buttons side by side when they fit, stacked otherwise, disabled buttons
/// dimmed rather than recoloured, and every key still reachable.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';

Future<BuildContext> _host(WidgetTester tester, TargetPlatform platform) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(platform: platform),
      home: Builder(
        builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('two short answers sit side by side, main one filled', (
    tester,
  ) async {
    final context = await _host(tester, TargetPlatform.iOS);
    final result = showAdaptiveConfirmation(
      context,
      title: '删除这个位置？',
      message: '本机和远端的文件都不会被删除。',
      confirmLabel: '删除',
      isDestructive: true,
      confirmKey: const Key('confirm'),
      cancelKey: const Key('cancel'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final cancel = tester.getRect(find.byKey(const Key('cancel')));
    final confirm = tester.getRect(find.byKey(const Key('confirm')));
    expect(cancel.center.dy, confirm.center.dy);
    expect(cancel.right, lessThan(confirm.left));
    expect(cancel.width, confirm.width);

    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('long answers stack with the main one on top', (tester) async {
    final context = await _host(tester, TargetPlatform.iOS);
    showAdaptiveAlert<int>(
      context: context,
      title: '还没收到格间的允许',
      actions: const [
        AdaptiveAlertAction(label: '取消这次配对并稍后再试', value: 0, key: Key('a')),
        AdaptiveAlertAction(
          label: '重新打开格间并允许连接',
          value: 1,
          key: Key('b'),
          isDefault: true,
        ),
      ],
    );
    await tester.pumpAndSettle();

    final back = tester.getRect(find.byKey(const Key('a')));
    final main = tester.getRect(find.byKey(const Key('b')));
    expect(main.bottom, lessThan(back.top));
    expect(main.width, back.width);
  });

  testWidgets('a disabled answer fades, keeps its colour and does nothing', (
    tester,
  ) async {
    final context = await _host(tester, TargetPlatform.iOS);
    var valid = false;
    final result = showAdaptiveForm<String>(
      context: context,
      title: '新建文件夹',
      barrierDismissible: false,
      builder: (context, setDialogState) => AdaptiveFormSpec(
        content: AppDialogTextField(
          key: const Key('field'),
          onChanged: (value) => setDialogState(() => valid = value.isNotEmpty),
        ),
        actions: [
          const AdaptiveAlertAction(label: '取消', key: Key('cancel')),
          AdaptiveAlertAction(
            label: '创建',
            value: 'made',
            key: const Key('create'),
            enabled: valid,
            isDefault: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    double opacityOf(Key key) => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(opacityOf(const Key('create')), 0.45);
    await tester.tap(find.byKey(const Key('create')));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);

    // The barrier does not dismiss a form that asks for input.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);

    await tester.enterText(find.byKey(const Key('field')), '照片');
    await tester.pumpAndSettle();
    expect(opacityOf(const Key('create')), 1);
    await tester.tap(find.byKey(const Key('create')));
    await tester.pumpAndSettle();
    expect(await result, 'made');
  });

  testWidgets('the choice menu is the app sheet with symbols and cancel', (
    tester,
  ) async {
    final context = await _host(tester, TargetPlatform.iOS);
    final picked = showAdaptiveActionSheet<String>(
      context: context,
      title: '更多操作',
      actions: const [
        AdaptiveAction(
          label: '修改连接',
          value: 'edit',
          key: Key('edit'),
          icon: Icon(IconData(0xe000)),
        ),
        AdaptiveAction(
          label: '删除连接',
          value: 'delete',
          key: Key('delete'),
          isDestructive: true,
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppActionSheet), findsOneWidget);
    expect(find.text('更多操作'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('edit')),
        matching: find.byType(Icon),
      ),
      findsOneWidget,
    );
    // The way out sits below every option.
    expect(
      tester.getRect(find.text('取消')).top,
      greaterThan(tester.getRect(find.byKey(const Key('delete'))).bottom),
    );

    await tester.tap(find.byKey(const Key('delete')));
    await tester.pumpAndSettle();
    expect(await picked, 'delete');
    expect(find.byType(AppActionSheet), findsNothing);

    final cancelled = showAdaptiveActionSheet<String>(
      context: context,
      actions: const [AdaptiveAction(label: '修改连接', value: 'edit')],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await cancelled, isNull);

    final dismissed = showAdaptiveActionSheet<String>(
      context: context,
      actions: const [AdaptiveAction(label: '修改连接', value: 'edit')],
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 120));
    await tester.pumpAndSettle();
    expect(await dismissed, isNull);
  });

  testWidgets('Material platforms keep the Material dialog', (tester) async {
    final context = await _host(tester, TargetPlatform.android);
    showAdaptiveNotice(context: context, title: '提示', message: '已保存');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(AppDialog), findsNothing);
  });
}
