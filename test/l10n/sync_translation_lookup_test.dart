import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/l10n/sync_language.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

void main() {
  const table = {
    'Upload': 'Hochladen',
    'Download': 'Herunterladen',
    'Retry': 'Erneut versuchen',
    '{0} · {1}': '{0} · {1}',
    'Deleted {0} items': '{0} Elemente gelöscht',
    'Copied {0} of {1}': '{1} gesamt, {0} kopiert',
    'Last sync failed: {0}': 'Letzte Synchronisierung fehlgeschlagen: {0}',
  };

  String de(String en) => translateFromEnglish('test-de', table, en);

  test('exact texts are looked up directly', () {
    expect(de('Retry'), 'Erneut versuchen');
  });

  test('templates rebuild the translation with the captured values', () {
    expect(de('Deleted 12 items'), '12 Elemente gelöscht');
    // Placeholders may move.
    expect(de('Copied 3 of 9'), '9 gesamt, 3 kopiert');
  });

  test('a captured English word is translated on its own', () {
    expect(de('Upload · Retry'), 'Hochladen · Erneut versuchen');
  });

  test('multi-line values are captured whole', () {
    expect(
      de('Last sync failed: line one\nline two'),
      'Letzte Synchronisierung fehlgeschlagen: line one\nline two',
    );
  });

  test('unknown text falls back to English', () {
    expect(de('Something new'), 'Something new');
  });

  test('locales map to the right text', () {
    expect(syncTextFor(const Locale('zh', 'CN'), '中', 'en'), '中');
    expect(syncTextFor(const Locale('en'), '中', 'en'), 'en');
    // A language we don't ship shows English, never Chinese.
    expect(syncTextFor(const Locale('th'), '中', 'en'), 'en');
  });

  test('device locales resolve to a shipped language', () {
    expect(resolveSyncLocale(const [Locale('de', 'AT')]), const Locale('de'));
    expect(
      resolveSyncLocale(const [Locale('zh', 'TW')]),
      SyncLanguage.traditionalChinese.locale,
    );
    expect(
      resolveSyncLocale([
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ]),
      SyncLanguage.chinese.locale,
    );
    expect(
      resolveSyncLocale(const [Locale('th'), Locale('ja')]),
      const Locale('ja'),
    );
    expect(resolveSyncLocale(const [Locale('th')]), const Locale('en'));
  });

  test('stored preferences', () {
    expect(SyncLanguage.fromStored(null), SyncLanguage.system);
    expect(SyncLanguage.fromStored('zh'), SyncLanguage.chinese);
    expect(SyncLanguage.fromStored('zh-Hant'), SyncLanguage.traditionalChinese);
    expect(SyncLanguage.fromStored('de'), SyncLanguage.german);
    expect(SyncLanguage.fromStored('invalid'), SyncLanguage.system);
  });
}
