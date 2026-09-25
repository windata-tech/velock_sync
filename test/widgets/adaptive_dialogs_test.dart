import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],

    theme: ThemeData(platform: TargetPlatform.iOS),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('option picker selects every segment on iOS', (tester) async {
    int? selected;
    await tester.pumpWidget(
      host(
        AdaptiveOptionPicker<int>(
          label: '蜂窝网络单次上限',
          value: 50 * 1024 * 1024,
          options: const [
            ('10 MB', 10 * 1024 * 1024),
            ('50 MB', 50 * 1024 * 1024),
            ('100 MB', 100 * 1024 * 1024),
          ],
          onChanged: (value) => selected = value,
        ),
      ),
    );

    await tester.tap(find.text('100 MB'));
    await tester.pumpAndSettle();
    expect(selected, 100 * 1024 * 1024);

    await tester.tap(find.text('10 MB'));
    await tester.pumpAndSettle();
    expect(selected, 10 * 1024 * 1024);
  });

  testWidgets('option picker stays tappable while it looks dimmed', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      host(
        AdaptiveOptionPicker<int>(
          label: '蜂窝网络单次上限',
          value: 50 * 1024 * 1024,
          options: const [
            ('10 MB', 10 * 1024 * 1024),
            ('100 MB', 100 * 1024 * 1024),
          ],
          onChanged: (value) => selected = value,
        ),
      ),
    );

    await tester.tap(find.text('100 MB'));
    await tester.pumpAndSettle();
    expect(selected, 100 * 1024 * 1024);
  });

  testWidgets('text form returns entered values', (tester) async {
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],

        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: CupertinoButton(
                onPressed: () async {
                  result = await showAdaptiveTextInputs(
                    context: context,
                    title: '加入已有同步空间',
                    inputs: const [
                      AdaptiveTextInput(
                        label: 'Vault ID',
                        placeholder: 'Vault ID',
                      ),
                    ],
                    confirmLabel: '继续',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('加入已有同步空间'), findsOneWidget);

    await tester.enterText(find.byType(CupertinoTextField), 'vault-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(result, ['vault-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing the text form closes without assertions', (
    tester,
  ) async {
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],

        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: CupertinoButton(
                onPressed: () async {
                  result = await showAdaptiveTextInputs(
                    context: context,
                    title: '加入已有同步空间',
                    inputs: const [AdaptiveTextInput(label: 'Vault ID')],
                    confirmLabel: '继续',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
}
