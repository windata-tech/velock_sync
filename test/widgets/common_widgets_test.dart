import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
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
    'Cupertino app-bar icon builds without conflicting size arguments',
    (tester) async {
      await tester.pumpWidget(
        PlatformProvider(
          initialPlatform: TargetPlatform.iOS,
          builder: (context) => PlatformApp(
            home: PlatformScaffold(
              appBar: WDAppBar(
                title: const Text('连接详情'),
                trailingActions: [
                  PlatformIconButton(
                    padding: EdgeInsets.zero,
                    cupertino: (context, platform) => CupertinoIconButtonData(
                      icon: const Icon(CupertinoIcons.refresh),
                    ),
                    onPressed: () {},
                  ),
                ],
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(CupertinoIcons.refresh), findsOneWidget);
    },
  );
}
