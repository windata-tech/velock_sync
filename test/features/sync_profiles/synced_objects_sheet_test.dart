import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace_shared.dart';
import 'package:velock_sync/widgets/app_components.dart';

void main() {
  setUpAll(() async {
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null && File(font).existsSync()) {
      final loader = FontLoader('SheetQA')
        ..addFont(
          File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
    for (final entry in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      final icons = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await icons.load();
    }
  });

  TransferJobRecord transfer({
    required String logicalKey,
    required int bytes,
    required DateTime at,
  }) => TransferJobRecord(
    transferId: 'job-$logicalKey-$bytes',
    profileId: 'profile-1',
    direction: TransferJobDirection.upload,
    state: TransferJobState.completed,
    logicalKey: logicalKey,
    expectedSize: bytes,
    completedBytes: bytes,
    expectedHash: null,
    retryCount: 0,
    nextRetryAt: null,
    providerCheckpoint: null,
    errorCode: null,
    createdAt: at,
    completedAt: at,
  );

  testWidgets('synced-object rows line up in their own columns', (
    tester,
  ) async {
    final at = DateTime(2026, 9, 26, 17, 20);
    final history = [
      transfer(logicalKey: 'commit:1', bytes: 296, at: at),
      transfer(logicalKey: 'batch:2', bytes: 767, at: at),
      transfer(logicalKey: 'batch:3', bytes: 1433, at: at),
    ];
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSyncedObjectsSheet(context, history),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Every amount shares the same right edge, and every timestamp starts at
    // the same x: the sheet is a table, not a ragged sentence.
    final amounts = [
      '296 B',
      '767 B',
      '1.4 KB',
    ].map((text) => tester.getRect(find.text(text))).toList();
    for (final rect in amounts) {
      expect(rect.right, closeTo(amounts.first.right, 0.5));
    }
    expect(amounts.first.width, lessThan(90));

    final stamps = ['2026-09-26 17:20'].map((text) => find.text(text)).toList();
    expect(stamps.first, findsNWidgets(3));
    final stampRects = tester
        .widgetList<Text>(find.text('2026-09-26 17:20'))
        .length;
    expect(stampRects, 3);
    final lefts = tester
        .renderObjectList<RenderBox>(find.text('2026-09-26 17:20'))
        .map((box) => box.localToGlobal(Offset.zero).dx)
        .toList();
    for (final left in lefts) {
      expect(left, closeTo(lefts.first, 0.5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sheet keeps its shape in a light fixture render', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFFF2F2F7),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: _SheetPreview(
              rows: [
                for (final entry in [
                  ('commit:1', 296),
                  ('batch:2', 767),
                  ('batch:3', 1433),
                ])
                  AppDetailSheetRow(
                    label: entry.$1.startsWith('commit')
                        ? '提交校验 · 上传'
                        : '增量批次 · 上传',
                    value: '2026-09-26 17:20',
                    trailing: entry.$2 == 1433 ? '1.4 KB' : '${entry.$2} B',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _SheetPreview extends StatelessWidget {
  const _SheetPreview({required this.rows});

  final List<AppDetailSheetRow> rows;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppRadii.sheet),
      ),
    ),
    padding: const EdgeInsets.all(AppSpacing.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('已同步对象明细', style: AppType.cardTitle),
        const SizedBox(height: AppSpacing.md),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: AppSpacing.labelColumn,
                  child: Text(
                    row.label,
                    style: AppType.rowSubtitle.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: Text(row.value)),
                const SizedBox(width: AppSpacing.sm),
                Text(row.trailing!),
              ],
            ),
          ),
      ],
    ),
  );
}
