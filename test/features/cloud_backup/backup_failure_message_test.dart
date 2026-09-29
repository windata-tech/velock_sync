import 'package:material_ui/material_ui.dart';
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

    const expected =
        '当前选中的位置无法创建文件夹。请进入服务里一个真实存在、且这个账号有权限写入的文件夹；只读入口、共享入口或聚合视图都不行。';
    expect(find.text(expected), findsNWidgets(2));
    // One provider-neutral sentence for every WebDAV service, not just NAS.
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('NAS')));
      expect(text.data, isNot(contains('共享文件夹')));
    }
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
        'The selected location cannot create folders. Open a real folder in the service that this account may write to; read-only entry points, share entries and aggregate views will not work.';
    expect(find.text(expected), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('NAS')));
    }
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('cannot safely save backups')));
      expect(text.data, isNot(contains('405')));
      expect(text.data, isNot(contains('MOVE')));
    }
  });

  /// A full cloud drive used to fall through to 「同步未完成，请稍后重试。」 while
  /// the stored suggested action already said to free space.
  Future<void> showMessage(
    WidgetTester tester,
    Locale locale,
    String? failureCode,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              children: [
                Text(AppFormat.errorSummary(failureCode, context: context)),
                Text(backupFailureMessage(context, failureCode)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a full remote drive tells the user to free up cloud space', (
    tester,
  ) async {
    await showMessage(tester, const Locale('zh'), 'provider.http.507');

    const expected = '云端空间不足，请清理云端文件或扩容后重试。';
    expect(find.text(expected), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('507')));
      expect(text.data, isNot(contains('provider.http')));
      expect(text.data, isNot('同步未完成，请稍后重试。'));
    }
  });

  testWidgets('a full remote drive has the same English instruction', (
    tester,
  ) async {
    await showMessage(tester, const Locale('en'), 'provider.http.507');

    const expected =
        'The cloud drive is out of space. Free up space or add more, then try again.';
    expect(find.text(expected), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('507')));
      expect(text.data, isNot(contains('provider.http')));
    }
  });

  testWidgets('a missing network is never reported as an unknown failure', (
    tester,
  ) async {
    await showMessage(tester, const Locale('zh'), 'network.offline');

    const expected = '没有网络连接，连上网络后再试。';
    expect(find.text(expected), findsNWidgets(2));
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(contains('network.offline')));
      expect(text.data, isNot(contains('sync.unexpected')));
    }
  });

  testWidgets('a stored code is never the sentence a user reads', (
    tester,
  ) async {
    for (final failureCode in const [
      'sync.unexpected',
      'provider.http.507',
      'provider.webdav.atomic_create_unsupported',
      'future.unknown_code',
    ]) {
      await showMessage(tester, const Locale('zh'), failureCode);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data, isNot(contains(failureCode)), reason: failureCode);
      }
    }
  });
}
