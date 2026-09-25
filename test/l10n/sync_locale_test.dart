import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/new_sync_profile.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/l10n/sync_language.dart';
import 'package:velock_sync/l10n/sync_language_setting.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/app_format.dart';

const _delegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
const _locales = [Locale('zh', 'CN'), Locale('en')];

class _LanguageHost extends ConsumerWidget {
  const _LanguageHost({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    locale: ref.watch(syncLanguageProvider).locale,
    supportedLocales: _locales,
    localizationsDelegates: _delegates,
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unset and unknown settings keep Chinese; system is explicit', () {
    expect(SyncLanguage.fromStored(null), SyncLanguage.chinese);
    expect(SyncLanguage.fromStored('invalid'), SyncLanguage.chinese);
    expect(SyncLanguage.fromStored('zh_Hans'), SyncLanguage.chinese);
    expect(SyncLanguage.fromStored('en-US'), SyncLanguage.english);
    expect(SyncLanguage.fromStored('en'), SyncLanguage.english);
    expect(SyncLanguage.fromStored('system').locale, isNull);
  });

  test(
    'selection is persisted through the actual app preferences API',
    () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await LocalDataManager.instance.init();
      final first = ProviderContainer();
      addTearDown(first.dispose);
      await first
          .read(syncLanguageProvider.notifier)
          .select(SyncLanguage.english);
      await LocalDataManager.instance.init();
      final stored = LocalDataManager.instance.getString(AppKeys.languageCode);
      expect(stored, 'en');
      final restarted = ProviderContainer(
        overrides: [
          syncLanguageBootstrapProvider.overrideWithValue(
            SyncLanguage.fromStored(stored),
          ),
        ],
      );
      addTearDown(restarted.dispose);
      expect(restarted.read(syncLanguageProvider), SyncLanguage.english);
      await restarted
          .read(syncLanguageProvider.notifier)
          .select(SyncLanguage.system);
      await LocalDataManager.instance.init();
      expect(
        LocalDataManager.instance.getString(AppKeys.languageCode),
        'system',
      );
    },
  );

  testWidgets(
    'language entry opens a real page, saves and changes locale live',
    (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncLanguageWriterProvider.overrideWithValue((value) async {
              saved.add(value);
            }),
          ],
          child: const _LanguageHost(
            child: Scaffold(body: SyncLanguageSetting()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('语言'),
        findsOneWidget,
      ); // Default remains Chinese on English test host.
      await tester.tap(find.byKey(const Key('sync-language-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync-language-en')));
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsWidgets);
      expect(find.text('Follow system'), findsOneWidget);
      expect(saved, ['en']);
      await tester.tap(find.byKey(const Key('sync-language-zh')));
      await tester.pumpAndSettle();
      expect(find.text('跟随系统'), findsOneWidget);
      expect(saved, ['en', 'zh']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('follow-system tracks locale changes; explicit selection wins', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = [const Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final container = ProviderContainer(
      overrides: [
        syncLanguageBootstrapProvider.overrideWithValue(SyncLanguage.system),
        syncLanguageWriterProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _LanguageHost(
          child: Builder(
            builder: (context) =>
                Text(syncText(context, '中文内容', 'English content')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('English content'), findsOneWidget);
    tester.platformDispatcher.localesTestValue = [const Locale('zh', 'CN')];
    await tester.pumpAndSettle();
    expect(find.text('中文内容'), findsOneWidget);
    await container
        .read(syncLanguageProvider.notifier)
        .select(SyncLanguage.english);
    await tester.pumpAndSettle();
    expect(find.text('English content'), findsOneWidget);
  });

  testWidgets(
    'failed preference write keeps the prior language and shows an error',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncLanguageWriterProvider.overrideWithValue((_) async {
              throw StateError('write failed');
            }),
          ],
          child: const _LanguageHost(child: SyncLanguagePage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync-language-en')));
      await tester.pumpAndSettle();
      expect(find.text('无法保存语言设置，请重试。'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);
    },
  );

  testWidgets(
    'English home and new-profile UI have real English labels and stable keys',
    (tester) async {
      final db = await SyncStateDatabase.inMemory();
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncLanguageBootstrapProvider.overrideWithValue(
              SyncLanguage.english,
            ),
            syncStateDatabaseProvider.overrideWithValue(db),
            syncProfileRepositoryProvider.overrideWithValue(
              SyncProfileRepository(db),
            ),
          ],
          child: const _LanguageHost(child: SyncProfilesHome()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Backup & Sync'), findsWidgets);
      expect(find.text('Enable Velock backup'), findsOneWidget);
      expect(find.byKey(const Key('velock-backup-enable')), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('en'),
          supportedLocales: _locales,
          localizationsDelegates: _delegates,
          home: NewSyncProfile(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Back up Velock data'), findsOneWidget);
      expect(find.byKey(const Key('new-velock-backup')), findsOneWidget);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text.data ?? ''), isFalse);
      }
    },
  );

  testWidgets(
    'every readiness state, result, and relative date has English presentation',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: _locales,
          localizationsDelegates: _delegates,
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      for (final state in VelockWizardAvailability.values) {
        for (final label in [
          velockReadinessTitle(state, context: context),
          velockReadinessMessage(state, context: context),
          velockAvailabilityLabel(state, context: context),
          velockAvailabilitySubtitle(state, context: context),
        ]) {
          expect(
            RegExp(r'[\u4e00-\u9fff]').hasMatch(label),
            isFalse,
            reason: '$state: $label',
          );
        }
      }
      expect(
        velockReadinessTitle(VelockWizardAvailability.ready, context: context),
        'Ready for secure Velock pairing',
      );
      expect(
        firstSyncResultMessage(
          const SyncProfileDispatchResult(
            profileId: 'test',
            status: SyncProfileDispatchStatus.completed,
          ),
          context: context,
        ),
        'Sync profile created. There is no new data to sync.',
      );
      expect(
        AppFormat.relativeTime(
          DateTime(2026, 9, 19, 10),
          now: DateTime(2026, 9, 19, 10, 5),
          context: context,
        ),
        '5 min ago',
      );
      expect(
        AppFormat.errorSummary('provider.http.401', context: context),
        'Remote access was denied. Authorize access again and retry.',
      );
    },
  );

  testWidgets('sync progress uses English while preserving its identifier', (
    tester,
  ) async {
    final pending = Completer<SyncProfileDispatchResult>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncLanguageBootstrapProvider.overrideWithValue(SyncLanguage.english),
          syncProfileRunServiceProvider.overrideWithValue(_Run(pending.future)),
        ],
        child: _LanguageHost(
          child: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => runSyncWithProgress(context, ref, 'profile'),
                child: const Text('Run'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Run'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sync-progress-dialog')), findsOneWidget);
    expect(find.text('Syncing…'), findsOneWidget);
    pending.complete(
      const SyncProfileDispatchResult(
        profileId: 'profile',
        status: SyncProfileDispatchStatus.completed,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
  });
}

class _Run implements SyncProfileRunService {
  _Run(this.result);
  final Future<SyncProfileDispatchResult> result;
  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) => result;
}
