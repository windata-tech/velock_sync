import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/sync_profiles/ui/new_sync_profile.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/l10n/sync_language.dart';
import 'package:velock_sync/l10n/sync_language_setting.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/app_format.dart';

const _delegates = [...GlobalMaterialLocalizations.delegates];
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
      expect(find.text('Velock backup'), findsWidgets);
      expect(find.text('Start backup'), findsOneWidget);
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
      // Scope note: this loop only covers the two screens mounted above, and
      // `NewSyncProfile` is not reachable from the running app. The guard for
      // the pages a user really opens (settings, activity, connection help,
      // connection detail, Baidu token) lives in
      // `test/l10n/sync_english_pages_test.dart`.
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
        'No new changes to transfer were found in this check.',
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
        'The server did not accept the saved sign-in. Edit the connection to check the username and password (or authorize the cloud drive again), then retry.',
      );
    },
  );

  testWidgets(
    'pending transfer shows English inline progress on the stable primary action',
    (tester) async {
      final pending = Completer<SyncProfileDispatchResult>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncLanguageBootstrapProvider.overrideWithValue(
              SyncLanguage.english,
            ),
            syncProfileRunServiceProvider.overrideWithValue(
              _Run(pending.future),
            ),
          ],
          child: const _LanguageHost(child: _InlineProgressHost()),
        ),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const Key('backup-primary-action'));
      expect(primary, findsOneWidget);
      expect(find.text('Back up now'), findsOneWidget);

      await tester.tap(primary);
      // The inline spinner animates forever, so pump explicit frames while the
      // transfer state must be visible.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The identifier stays stable while the in-flight state is localized.
      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(primary, findsOneWidget);
      expect(find.text('Transferring your data'), findsOneWidget);
      expect(find.text('Transferring…'), findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).busy, isTrue);
      expect(
        find.descendant(
          of: primary,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      pending.complete(
        const SyncProfileDispatchResult(
          profileId: 'profile',
          status: SyncProfileDispatchStatus.completed,
        ),
      );
      await tester.pumpAndSettle();

      // A finished run shows no dialog, and the action is usable again.
      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(find.text('Transferring your data'), findsNothing);
      expect(find.text('Back up now'), findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).busy, isFalse);
      expect(tester.widget<BackupActionButton>(primary).onPressed, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Drives the shared runner exactly like the home/detail screens do: the status
/// card is busy for as long as the run is in flight, with no modal dialog.
class _InlineProgressHost extends ConsumerStatefulWidget {
  const _InlineProgressHost();
  @override
  ConsumerState<_InlineProgressHost> createState() =>
      _InlineProgressHostState();
}

class _InlineProgressHostState extends ConsumerState<_InlineProgressHost> {
  bool _running = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        BackupStatusCard(
          name: 'Velock',
          presentation: BackupPresentation.from(
            state: SyncProfileState.active,
            running: _running,
          ),
          onAction: () async {
            setState(() => _running = true);
            try {
              await runSyncWithProgress(context, ref, 'profile');
            } finally {
              if (mounted) setState(() => _running = false);
            }
          },
        ),
      ],
    ),
  );
}

class _Run implements SyncProfileRunService {
  _Run(this.result);
  final Future<SyncProfileDispatchResult> result;
  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) => result;
}
