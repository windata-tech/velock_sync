/// Regression for the option rows that used to clip their explanation.
///
/// The direction and conflict explanations carry the deletion and conflict
/// semantics, so they must be shown in full and wrap over as many lines as they
/// need instead of ending in an ellipsis.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_option_row.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';

void main() {
  testWidgets('an option row shows its whole explanation', (tester) async {
    const explanation = '两边改动互相同步；同一条文件两边都改过时按冲突处理方式保留。本机删除会同步删除远端文件。';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: PlainOptionRow(
              selected: true,
              title: '双向同步',
              explanation: explanation,
            ),
          ),
        ),
      ),
    );

    final rendered = tester.widget<Text>(find.text(explanation));
    // No line cap and no ellipsis: the sentence simply wraps.
    expect(rendered.maxLines, isNull);
    expect(rendered.overflow, isNot(TextOverflow.ellipsis));

    // The row is taller than one line, proving the text wrapped rather than
    // being clipped to a single line.
    final size = tester.getSize(find.byType(PlainOptionRow));
    expect(size.height, greaterThan(56));
  });

  testWidgets('every direction and conflict explanation is a full sentence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => Column(
            children: [
              for (final direction in MirrorDirection.values)
                PlainOptionRow(
                  widgetKey: Key('plain-direction-${direction.name}'),
                  selected: false,
                  title: directionLabel(context, direction),
                  explanation: directionExplanation(context, direction),
                ),
              for (final policy in MirrorConflictPolicy.values)
                PlainOptionRow(
                  widgetKey: Key('plain-conflict-${policy.name}'),
                  selected: false,
                  title: conflictPolicyLabel(context, policy),
                  explanation: conflictPolicyExplanation(context, policy),
                ),
            ],
          ),
        ),
      ),
    );

    for (final direction in MirrorDirection.values) {
      expect(
        find.byKey(Key('plain-direction-${direction.name}')),
        findsOneWidget,
      );
    }
    for (final policy in MirrorConflictPolicy.values) {
      expect(find.byKey(Key('plain-conflict-${policy.name}')), findsOneWidget);
    }
    // The longest explanation is present as one unclipped paragraph.
    expect(
      tester.widget<Text>(find.textContaining('本机对已同步文件的修改会被远端版本覆盖')).maxLines,
      isNull,
    );
  });
}
