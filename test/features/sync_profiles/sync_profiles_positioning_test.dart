import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/new_sync_profile.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sync home presents backup and folder sync as two domains', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(database),
          syncProfileRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: SyncProfilesHome()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('备份与同步'), findsWidgets);
    expect(find.text('格间备份 · 未开启'), findsOneWidget);
    expect(find.text('开启格间备份'), findsOneWidget);
    expect(find.text('尚未开启'), findsNothing);
    expect(find.byKey(const Key('velock-backup-not-configured')), findsNothing);
    expect(find.text('其他文件'), findsOneWidget);
    expect(find.text('新建文件夹同步'), findsOneWidget);
    expect(find.text('开始同步格间数据'), findsNothing);
    expect(find.textContaining('换机助手'), findsNothing);
  });

  testWidgets('new sync chooser explains both supported data categories', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NewSyncProfile())),
    );
    await tester.pumpAndSettle();

    expect(find.text('新建同步'), findsOneWidget);
    expect(find.text('备份格间数据'), findsOneWidget);
    expect(find.text('同步文件夹'), findsOneWidget);
    expect(find.textContaining('持续'), findsWidgets);
  });
}
