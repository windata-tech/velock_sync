/// English-locale coverage for the global settings page.
///
/// The page used to be Chinese-only: it carried ~64 CJK literals and only three
/// `syncText` calls, so an English device still showed 后台同步, 删除保护,
/// 暂存空间, 隐私与诊断, 版本与许可 and every footer in Chinese. These tests are
/// the regression gate for that: they render the real page with `Locale('en')`
/// and fail if any Chinese character is painted (or announced) outside the one
/// intentional language endonym.
///
/// The page is a lazy `CustomScrollView`, so the check runs on every scroll
/// frame: a string that only leaks after scrolling still fails the test. The
/// last test freezes the honesty fix — the 新配置默认策略 footer may only
/// promise what the app really does.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_settings.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart'
    show GarbageCollectionDiagnostics;
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/l10n/sync_language_setting.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// Any CJK ideograph: the page must not paint one on an English device.
final _cjk = RegExp(r'[\u4e00-\u9fff]');

/// The one place Chinese is allowed in the English UI: the language picker
/// names a language in its own script. Every other string on the page must be
/// English, and the exception is spelled out so it cannot silently grow.
const _languageEndonym = '简体中文';

/// Frozen footer wording of the 新配置默认策略 section.
const settingsDefaultsFooterEn =
    'These options apply only to profiles you create from now on; existing '
    'profiles keep their own policy. New sync locations start with background '
    'sync off: turn on “Background sync” on the location’s own page.';
const settingsDefaultsFooterZh =
    '这些选项只用于此后新建的配置；已有配置保持自己的策略。'
    '新建的同步位置默认不开后台同步：还需要在它的详情页打开「后台同步」。';

void main() {
  testWidgets('the settings page paints no Chinese on an English device', (
    tester,
  ) async {
    await _pumpSettings(tester, locale: const Locale('en'));

    // The language row is on screen from the first frame. Its own script name
    // is the only Chinese the page may show; anything else already fails the
    // scan below.
    expect(_pickerCjkTexts(tester), {_languageEndonym});

    final seen = await _scanWholePage(tester);

    // The sections that used to be Chinese-only must really be there, in
    // English, or the scan above proves nothing.
    for (final header in const [
      'Background sync',
      'Defaults for new profiles',
      'Deletion protection',
      'Privacy & Diagnostics',
      'Version & Licenses',
    ]) {
      expect(seen, contains(header), reason: 'missing section: $header');
    }
    // The staging card is gone: nothing writes app-private staging batches any
    // more, so a permanent "0 B" card with a no-op button was only noise.
    expect(seen, isNot(contains('Staging space')));
    expect(seen, isNot(contains('Cleanup keeps recoverable batches')));
    for (final row in const [
      'Last cleanup',
      'Waiting for confirmation',
      'Active devices',
      'Export sanitized diagnostics',
      'About & open-source licenses',
    ]) {
      expect(seen, contains(row), reason: 'missing row: $row');
    }
  });

  testWidgets('the settings loading state is English', (tester) async {
    // A never-completing load keeps the page on its loading state.
    await _pumpSettings(
      tester,
      locale: const Locale('en'),
      service: _FakeSettingsService(pending: Completer<void>().future),
      settle: false,
    );
    await tester.pump();

    expect(find.byType(AdaptiveLoadingState), findsOneWidget);
    expect(_semanticLabels(tester), contains('Loading sync settings'));
    _expectNoChinese(tester);
  });

  testWidgets('the settings failure state is English', (tester) async {
    await _pumpSettings(
      tester,
      locale: const Locale('en'),
      service: _FakeSettingsService(failure: StateError('load failed')),
    );

    expect(find.text('Could not read the sync settings.'), findsOneWidget);
    _expectNoChinese(tester);
  });

  testWidgets('the sanitized diagnostics sheet is English', (tester) async {
    await _pumpSettings(tester, locale: const Locale('en'));
    await _scrollToKey(tester, const Key('export-sanitized-diagnostics'));
    await tester.tap(find.byKey(const Key('export-sanitized-diagnostics')));
    await tester.pumpAndSettle();

    expect(find.text('Sanitized diagnostics'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    _expectNoChinese(tester);
  });

  testWidgets('the new-profile defaults footer promises only what happens', (
    tester,
  ) async {
    await _pumpSettings(tester, locale: const Locale('en'));
    final seenEn = await _scanWholePage(tester);

    expect(
      seenEn,
      contains(settingsDefaultsFooterEn),
      reason: 'the footer is frozen: it is the page’s honest scope statement',
    );
    // The whole point of the wording: it names the switch the user still has to
    // turn on, because a new sync location is stored with background off.
    expect(settingsDefaultsFooterEn, contains('turn on “Background sync”'));

    // A fresh mount for the Chinese page: that string must stay unchanged.
    await _pumpSettings(tester, locale: const Locale('zh', 'CN'));
    // The Chinese page is supposed to be Chinese, so only the wording is read.
    final seenZh = await _scanWholePage(tester, expectEnglish: false);
    expect(seenZh, contains(settingsDefaultsFooterZh));
    expect(settingsDefaultsFooterZh, contains('打开「后台同步」'));
  });
}

/// Drags the page until [key] is built and visible.
Future<void> _scrollToKey(
  WidgetTester tester,
  Key key, {
  int steps = 16,
}) async {
  for (var step = 0; step < steps; step++) {
    if (find.byKey(key).evaluate().isNotEmpty) {
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      return;
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  fail('$key was never built while scrolling the settings page');
}

/// Scrolls the page top to bottom, checking every frame, and returns every text
/// the page built on the way.
Future<Set<String>> _scanWholePage(
  WidgetTester tester, {
  int steps = 16,
  bool expectEnglish = true,
}) async {
  final seen = <String>{};
  for (var step = 0; step <= steps; step++) {
    if (expectEnglish) _expectNoChinese(tester);
    seen.addAll(_pageTexts(tester));
    seen.addAll(_semanticLabels(tester));
    if (step == steps) break;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  return seen;
}

/// Text inside the language picker row, which names languages in their own
/// script.
Iterable<String> _pickerTexts(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byType(SyncLanguageSetting),
        matching: find.byType(Text),
      ),
    )
    .map((text) => text.data ?? '');

Set<String> _pickerCjkTexts(WidgetTester tester) =>
    _pickerTexts(tester).where(_cjk.hasMatch).toSet();

/// Every [Text] on screen, minus the language picker's own rows.
Iterable<String> _pageTexts(WidgetTester tester) {
  final picker = _pickerTexts(tester).toSet();
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .where((data) => !picker.contains(data));
}

/// Semantics labels the page publishes (the loading spinner announces itself
/// here instead of painting text).
Iterable<String> _semanticLabels(WidgetTester tester) => tester
    .widgetList<Semantics>(find.byType(Semantics))
    .map((widget) => widget.properties.label)
    .whereType<String>();

/// Nothing on this page may be Chinese in en, except the language endonym.
void _expectNoChinese(WidgetTester tester) {
  for (final data in _pageTexts(tester)) {
    expect(
      _cjk.hasMatch(data),
      isFalse,
      reason: 'Chinese text is still painted in en: “$data”',
    );
  }
  for (final label in _semanticLabels(tester)) {
    expect(
      _cjk.hasMatch(label),
      isFalse,
      reason: 'Chinese semantics label is still announced in en: “$label”',
    );
  }
  expect(
    _pickerCjkTexts(tester).difference({_languageEndonym}),
    isEmpty,
    reason: 'the language row may only name a language in its own script',
  );
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required Locale locale,
  SyncSettingsService? service,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        syncSettingsServiceProvider.overrideWithValue(
          service ?? _FakeSettingsService(),
        ),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const SyncSettings(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// A settings service with real-looking content, so every section renders its
/// explanatory copy instead of an empty placeholder.
class _FakeSettingsService implements SyncSettingsService {
  _FakeSettingsService({this.pending, this.failure});

  /// Never completes: keeps the page in its loading state.
  final Future<void>? pending;

  /// Thrown by [load]: keeps the page in its error state.
  final Object? failure;

  static final _snapshot = SyncSettingsSnapshot(
    settings: const SyncGlobalSettings(
      backgroundEnabled: true,
      defaultAllowCellular: true,
      defaultRequiresCharging: true,
    ),
    backgroundSupported: true,
    backgroundEligibleProfileCount: 2,
    staging: const StagingSpaceSummary(
      totalBytes: 3 * 1024 * 1024,
      fileCount: 4,
      batchCount: 2,
    ),
    garbageCollection: GarbageCollectionDiagnostics(
      runId: 'gc-1',
      profileId: 'profile-1',
      vaultId: 'vault-1',
      state: 'completed',
      startedAt: DateTime.utc(2026, 9, 27, 1),
      completedAt: DateTime.utc(2026, 9, 27, 1, 0, 2),
      checkpointId: 'checkpoint-1',
      retentionCutoff: DateTime.utc(2026, 8, 28),
      activeDeviceCount: 2,
      unackedDeviceCount: 1,
      candidateCount: 4,
      eligibleCandidateCount: 1,
      deletedObjectCount: 3,
      retentionManifestComplete: true,
      planId: 'plan-1',
      skipReason: null,
    ),
  );

  @override
  Future<SyncSettingsSnapshot> load() async {
    if (pending != null) await pending;
    final error = failure;
    if (error != null) throw error;
    return _snapshot;
  }

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) => load();

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async =>
      const SyncSettingsCleanupSummary(
        freedBytes: 1024,
        preservedRecoverableBatchCount: 1,
      );

  @override
  Future<String> exportSanitizedDiagnostics() async => '{}';
}
