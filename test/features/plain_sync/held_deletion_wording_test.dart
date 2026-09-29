import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_run.dart';

/// QA 2026-09-29 (finding 14): the held-deletion review said it would delete
/// "the matching files locally and remotely", while each held deletion only
/// removes the copy left on one side. It also claimed both sides matched while
/// deletions were still waiting.
void main() {
  MirrorAction deletion(MirrorActionType type, String path) => MirrorAction(
    type: type,
    relativePath: path,
    outcome: MirrorPathOutcome.unchanged,
  );

  MirrorRunOutcome held(List<MirrorAction> actions) => MirrorRunOutcome(
    stats: MirrorRunStats(
      runId: 'run',
      profileId: 'p',
      startedAt: DateTime.utc(2026, 9, 29),
      heldDeletionCount: actions.length,
    ),
    conflicts: const [],
    heldDeletions: MirrorHeldDeletions(
      actions: actions,
      knownEntryCount: 10,
      limit: 2,
    ),
  );

  Future<String> reviewText(
    WidgetTester tester,
    List<MirrorAction> actions, {
    Locale locale = const Locale('zh'),
  }) async {
    final outcome = held(actions);
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: TargetPlatform.android),
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    reviewHeldDeletions(captured, outcome.heldDeletions!, outcome);
    await tester.pumpAndSettle();
    return tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join('\n');
  }

  testWidgets('files deleted on this device remove only the remote copy', (
    tester,
  ) async {
    final text = await reviewText(tester, [
      deletion(MirrorActionType.deleteRemoteEntry, 'a.txt'),
      deletion(MirrorActionType.deleteRemoteEntry, 'b.txt'),
    ]);
    expect(text, contains('a.txt'));
    expect(text, contains('这些文件已经在本机删除，确认后会删除远端剩下的那份'));
    expect(text, isNot(contains('本地和远端')));
    expect(text, isNot(contains('两边内容已经一致')));
    expect(text, contains('待确认删除 2 项（本次未删除）'));
  });

  testWidgets('files deleted on the remote remove only the local copy', (
    tester,
  ) async {
    final text = await reviewText(tester, [
      deletion(MirrorActionType.deleteLocalEntry, 'c.txt'),
    ]);
    expect(text, contains('这些文件已经在远端删除，确认后会删除本机剩下的那份'));
    expect(text, isNot(contains('两边内容已经一致')));
  });

  testWidgets('a mix names both directions without claiming both copies', (
    tester,
  ) async {
    final text = await reviewText(tester, [
      deletion(MirrorActionType.deleteLocalEntry, 'c.txt'),
      deletion(MirrorActionType.deleteRemoteEntry, 'd.txt'),
    ], locale: const Locale('en'));
    expect(
      text,
      contains(
        'These files were already deleted on one side. Confirming deletes '
        'the copy left on the other side',
      ),
    );
    expect(text, isNot(contains('Both sides already match')));
    expect(text, isNot(matches(RegExp(r'[一-鿿]'))));
  });
}
