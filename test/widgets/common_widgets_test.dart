import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses a SnackBar when a ScaffoldMessenger is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlatformMessage(context, '同步完成'),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();

    expect(find.text('同步完成'), findsOneWidget);
  });

  testWidgets('uses the toast channel in a Cupertino widget tree', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('PonnamKarthik/fluttertoast');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => showPlatformMessage(context, '同步完成'),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'showToast');
    expect(calls.single.arguments, containsPair('msg', '同步完成'));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'Cupertino page under MaterialApp does not use an empty messenger',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('PonnamKarthik/fluttertoast');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: CupertinoPageScaffold(
            child: Builder(
              builder: (context) => CupertinoButton(
                onPressed: () => showPlatformMessage(context, '同步完成'),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(calls, hasLength(1));
      expect(calls.single.arguments, containsPair('msg', '同步完成'));
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Cupertino app-bar icon builds without conflicting size arguments',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          // iOS design language: the trailing icon must resolve to the Cupertino
          // glyph without any conflicting size argument.
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: AdaptivePageScaffold(
            appBar: WDAppBar(
              title: const Text('连接详情'),
              trailingActions: [
                AdaptiveIconButton(
                  icon: const Icon(CupertinoIcons.refresh),
                  materialIcon: const Icon(Icons.refresh),
                  onPressed: () {},
                ),
              ],
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(CupertinoIcons.refresh), findsOneWidget);
    },
  );
}
