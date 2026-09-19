import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/selected_folder/ui/selected_folder_empty_state.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 740),
    double scale = 1,
    Brightness brightness = Brightness.light,
    VoidCallback? onCreate,
    VoidCallback? onRecover,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS, brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: SelectedFolderEmptyState(
              onCreate: onCreate,
              onRecover: onRecover,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Create and recovery invoke their own callbacks', (tester) async {
    var creates = 0;
    var recoveries = 0;
    await mount(
      tester,
      onCreate: () => creates++,
      onRecover: () => recoveries++,
    );
    await tester.tap(find.byKey(const Key('selected-folder-empty-create')));
    await tester.tap(find.byKey(const Key('selected-folder-empty-recover')));
    expect(creates, 1);
    expect(recoveries, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Busy state disables both actions', (tester) async {
    await mount(tester);
    for (final button in tester.widgetList<CupertinoButton>(
      find.byType(CupertinoButton),
    )) {
      expect(button.onPressed, isNull);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('Small screen and large text remain usable in $brightness', (
      tester,
    ) async {
      var recovered = false;
      await mount(
        tester,
        size: const Size(320, 480),
        scale: 2,
        brightness: brightness,
        onCreate: () {},
        onRecover: () => recovered = true,
      );
      expect(tester.takeException(), isNull);
      final recovery = find.byKey(const Key('selected-folder-empty-recover'));
      await tester.ensureVisible(recovery);
      await tester.pumpAndSettle();
      await tester.tap(recovery);
      expect(recovered, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
