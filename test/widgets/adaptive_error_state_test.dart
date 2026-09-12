import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('keeps raw exception text collapsed and retries on demand', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      wrap(
        AdaptiveErrorState(
          title: '无法连接到远端服务器',
          message: '服务器拒绝了连接。请检查网络后重试。',
          details: 'DioException: Connection refused',
          onRetry: () => retried = true,
        ),
      ),
    );

    expect(find.text('无法连接到远端服务器'), findsOneWidget);
    expect(find.text('服务器拒绝了连接。请检查网络后重试。'), findsOneWidget);
    expect(find.text('查看错误详情'), findsOneWidget);
    expect(find.text('DioException: Connection refused'), findsNothing);

    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });

  testWidgets('expands and copies technical details on demand', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      wrap(
        AdaptiveErrorState(
          title: '无法连接到远端服务器',
          message: '服务器拒绝了连接。',
          details: 'DioException: Connection refused',
          onRetry: () {},
        ),
      ),
    );

    await tester.tap(find.text('查看错误详情'));
    await tester.pumpAndSettle();

    expect(find.text('收起错误详情'), findsOneWidget);
    expect(find.text('技术详情'), findsOneWidget);
    expect(find.text('DioException: Connection refused'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pump();

    expect(copied, ['DioException: Connection refused']);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
