/// Disabled filled buttons keep their fill and only fade.
///
/// `CupertinoButton` swaps its fill for a near-white system grey when
/// `onPressed` is null, and our labels are explicitly white, so a disabled
/// primary button read as white text on white-ish grey. A busy button (an
/// action in progress) is not unavailable and keeps full colour.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.iOS),
  home: Scaffold(
    body: Center(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

Color? _fill(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(CupertinoButton),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return switch (box.decoration) {
    final BoxDecoration d => d.color,
    final ShapeDecoration d => d.color,
    _ => null,
  };
}

double _opacity(WidgetTester tester) {
  final faded = find.ancestor(
    of: find.byType(CupertinoButton),
    matching: find.byType(Opacity),
  );
  if (faded.evaluate().isEmpty) return 1;
  return tester.widget<Opacity>(faded.first).opacity;
}

void main() {
  testWidgets('a disabled backup button keeps the brand fill and fades', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BackupActionButton(label: 'Back up', onPressed: null)),
    );
    expect(_fill(tester), AppColors.brand);
    expect(_opacity(tester), AppOpacity.disabled);
  });

  testWidgets('a busy backup button stays at full colour', (tester) async {
    await tester.pumpWidget(
      _host(
        const BackupActionButton(
          label: 'Backing up…',
          onPressed: null,
          busy: true,
        ),
      ),
    );
    expect(_fill(tester), AppColors.brand);
    expect(_opacity(tester), 1);
    final label = tester.widget<Text>(find.text('Backing up…'));
    expect(label.style?.color, Colors.white);
  });

  testWidgets('an enabled backup button is not faded', (tester) async {
    await tester.pumpWidget(
      _host(BackupActionButton(label: 'Back up', onPressed: () {})),
    );
    expect(_fill(tester), AppColors.brand);
    expect(_opacity(tester), 1);
  });

  testWidgets('the shared primary and secondary buttons keep their fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const AppPrimaryButton(label: 'Save', onPressed: null)),
    );
    expect(_fill(tester), AppColors.brand);
    expect(_opacity(tester), AppOpacity.disabled);

    await tester.pumpWidget(
      _host(const AppSecondaryButton(label: 'More', onPressed: null)),
    );
    expect(_fill(tester), AppColors.brand.withValues(alpha: 0.12));
    expect(_opacity(tester), AppOpacity.disabled);
  });

  testWidgets('a disabled adaptive filled button keeps the theme fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const AdaptiveElevatedButton(onPressed: null, child: Text('Go'))),
    );
    expect(_fill(tester), isNot(CupertinoColors.tertiarySystemFill));
    expect(_fill(tester), isNot(CupertinoColors.quaternarySystemFill));
    expect(_opacity(tester), AppOpacity.disabled);
  });
}
