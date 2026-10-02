import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';

enum SyncLanguage {
  system('system', null, ''),
  chinese('zh', Locale('zh', 'CN'), '简体中文'),
  traditionalChinese(
    'zh-Hant',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    '繁體中文',
  ),
  english('en', Locale('en'), 'English'),
  arabic('ar', Locale('ar'), 'العربية'),
  german('de', Locale('de'), 'Deutsch'),
  spanish('es', Locale('es'), 'Español'),
  french('fr', Locale('fr'), 'Français'),
  hindi('hi', Locale('hi'), 'हिन्दी'),
  indonesian('id', Locale('id'), 'Bahasa Indonesia'),
  italian('it', Locale('it'), 'Italiano'),
  japanese('ja', Locale('ja'), '日本語'),
  korean('ko', Locale('ko'), '한국어'),
  dutch('nl', Locale('nl'), 'Nederlands'),
  polish('pl', Locale('pl'), 'Polski'),
  portuguese('pt', Locale('pt'), 'Português'),
  russian('ru', Locale('ru'), 'Русский'),
  turkish('tr', Locale('tr'), 'Türkçe'),
  vietnamese('vi', Locale('vi'), 'Tiếng Việt');

  const SyncLanguage(this.storageValue, this.locale, this.nativeName);
  final String storageValue;
  final Locale? locale;

  /// The language's own name, shown untranslated in the picker.
  final String nativeName;

  /// Every locale the app ships, Simplified Chinese first.
  static final List<Locale> supportedLocales = [
    for (final language in values)
      if (language.locale != null) language.locale!,
  ];

  /// Missing preferences follow the device; unknown values fall back to it.
  static SyncLanguage fromStored(String? value) {
    final normalized = value?.replaceAll('_', '-').toLowerCase();
    if (normalized == null || normalized == 'system') return system;
    if (normalized == 'zh-hant' ||
        normalized.startsWith('zh-hant-') ||
        normalized == 'zh-tw' ||
        normalized == 'zh-hk' ||
        normalized == 'zh-mo') {
      return traditionalChinese;
    }
    final language = normalized.split('-').first;
    for (final candidate in values) {
      if (candidate.locale?.languageCode == language) return candidate;
    }
    return system;
  }

  /// The shipped language for [locale], or null when we don't ship it.
  static SyncLanguage? forLocale(Locale locale) {
    if (locale.languageCode == 'zh') {
      final hant =
          locale.scriptCode == 'Hant' ||
          (locale.scriptCode == null &&
              const {'TW', 'HK', 'MO'}.contains(locale.countryCode));
      return hant ? traditionalChinese : chinese;
    }
    for (final candidate in values) {
      if (candidate.locale?.languageCode == locale.languageCode) {
        return candidate;
      }
    }
    return null;
  }
}

/// Picks the shipped locale for the device's preferred languages: Traditional
/// Chinese for Hant / Taiwan / Hong Kong / Macao, otherwise the first language
/// we ship, and English when none matches.
Locale resolveSyncLocale(Iterable<Locale>? preferred) {
  for (final locale in preferred ?? const <Locale>[]) {
    final language = SyncLanguage.forLocale(locale);
    if (language != null) return language.locale!;
  }
  return SyncLanguage.english.locale!;
}

/// Loaded once after local preferences initialize, before runApp.
final syncLanguageBootstrapProvider = Provider<SyncLanguage>(
  (ref) => SyncLanguage.system,
);

final syncLanguageWriterProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (value) =>
          LocalDataManager.instance.setString(AppKeys.languageCode, value),
);

final syncLanguageProvider =
    NotifierProvider<SyncLanguageController, SyncLanguage>(
      SyncLanguageController.new,
    );

class SyncLanguageController extends Notifier<SyncLanguage> {
  @override
  SyncLanguage build() => ref.watch(syncLanguageBootstrapProvider);

  Future<void> select(SyncLanguage language) async {
    await ref.read(syncLanguageWriterProvider)(language.storageValue);
    if (ref.mounted) state = language;
  }
}
