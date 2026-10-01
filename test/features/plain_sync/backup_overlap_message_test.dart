import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/features/plain_sync/ui/add_plain_location.dart';

/// A refused folder names itself and the backup's folder, so the user can
/// see why (QA 2026-10-01: picking the drive root that holds `111`, the
/// backup's folder, only said "same place, or its parent/child").
void main() {
  Future<String> message(
    WidgetTester tester,
    BackupFolderOverlapException failure, {
    Locale locale = const Locale('zh'),
  }) async {
    late String text;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) {
            text = backupOverlapMessage(context, failure);
            return const SizedBox();
          },
        ),
      ),
    );
    return text;
  }

  testWidgets('a parent of the backup folder says which child is the backup', (
    tester,
  ) async {
    final text = await message(
      tester,
      const BackupFolderOverlapException(
        'test1 的 Velock',
        chosenSegments: ['USB_HDD_8T'],
        backupSegments: ['USB_HDD_8T', '111'],
      ),
    );
    expect(text, contains('你选的文件夹 /USB_HDD_8T 里面'));
    expect(text, contains('「test1 的 Velock」用的文件夹 /USB_HDD_8T/111'));
    expect(text, contains('不含「111」'));
    expect(text, contains('新建一个专门用于同步的文件夹'));
  });

  testWidgets('inside and equal read differently', (tester) async {
    final inside = await message(
      tester,
      const BackupFolderOverlapException(
        'B',
        chosenSegments: ['111', 'x'],
        backupSegments: ['111'],
      ),
    );
    expect(inside, contains('/111/x 在格间备份「B」用的文件夹 /111 里面'));
    final same = await message(
      tester,
      const BackupFolderOverlapException(
        'B',
        chosenSegments: ['111'],
        backupSegments: ['111'],
      ),
    );
    expect(same, contains('/111 就是格间备份「B」用的文件夹'));
  });

  testWidgets('the English message has no Chinese', (tester) async {
    final text = await message(
      tester,
      const BackupFolderOverlapException(
        'Mine',
        chosenSegments: ['USB'],
        backupSegments: ['USB', '111'],
      ),
      locale: const Locale('en'),
    );
    expect(text, contains('does not contain “111”'));
    expect(RegExp(r'[一-鿿]').hasMatch(text), isFalse);
  });
}
