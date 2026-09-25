import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/widgets/app_format.dart';

void main() {
  const code = 'provider.webdav.collection_not_writable';

  Future<void> showMessages(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              children: [
                Text(AppFormat.errorSummary(code, context: context)),
                Text(backupFailureMessage(context, code)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('collection failure gives actionable Chinese guidance', (
    tester,
  ) async {
    await showMessages(tester, const Locale('zh'));

    const expected = '当前选中的位置不能新建备份文件夹。请打开共享文件夹，选择一个有写入权限的实际文件夹，不要只选 NAS 入口。';
    expect(find.text(expected), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('不支持安全保存')));
      expect(text.data, isNot(contains('405')));
      expect(text.data, isNot(contains('MOVE')));
    }
  });

  testWidgets('collection failure gives equivalent English guidance', (
    tester,
  ) async {
    await showMessages(tester, const Locale('en'));

    const expected =
        'The selected location cannot create a backup folder. Open the shared folder and choose an actual folder with write access; do not select only the NAS entry point.';
    expect(find.text(expected), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('cannot safely save backups')));
      expect(text.data, isNot(contains('405')));
      expect(text.data, isNot(contains('MOVE')));
    }
  });
}
