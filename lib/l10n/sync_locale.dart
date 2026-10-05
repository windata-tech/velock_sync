import 'package:flutter/widgets.dart';

import 'sync_language.dart';
import 'translations/sync_translations.dart';

/// Presentation only: follows the effective locale supplied by the app.
///
/// Call sites carry the Simplified Chinese and English texts. Every other
/// shipped language is looked up by the English text in the generated tables
/// (`tool/l10n/README.md`); anything missing falls back to English.
String syncText(BuildContext context, String zh, String en) =>
    syncTextFor(Localizations.localeOf(context), zh, en);

String syncTextFor(Locale locale, String zh, String en) {
  final language = SyncLanguage.forLocale(locale);
  if (language == SyncLanguage.chinese) return zh;
  if (language == null || language == SyncLanguage.english) return en;
  final table = syncTranslations[language.storageValue];
  if (table == null) return en;
  return translateFromEnglish(language.storageValue, table, en);
}

final Map<String, List<_Template>> _templates = {};

/// Exact lookup first; otherwise the English text was built from a template
/// with `{0}`-style placeholders, so match it against those and rebuild the
/// translated template with the captured values.
String translateFromEnglish(String code, Map<String, String> table, String en) {
  final exact = table[en];
  if (exact != null) return exact;
  final templates = _templates.putIfAbsent(code, () => _compile(table));
  for (final template in templates) {
    final match = template.pattern.firstMatch(en);
    if (match == null) continue;
    final translated = table[template.key]!;
    return translated.replaceAllMapped(_placeholder, (m) {
      final index = template.order.indexOf(int.parse(m[1]!));
      if (index < 0) return m[0]!;
      final value = match.group(index + 1) ?? '';
      // Placeholders sometimes carry a word chosen in English
      // (e.g. Upload / Download); translate those on their own.
      return table[value] ?? value;
    });
  }
  return en;
}

final RegExp _placeholder = RegExp(r'\{(\d+)\}');

class _Template {
  _Template(this.key, this.pattern, this.order, this.literalLength);
  final String key;
  final RegExp pattern;

  /// Placeholder numbers in the order they appear in the English text.
  final List<int> order;
  final int literalLength;
}

List<_Template> _compile(Map<String, String> table) {
  final templates = <_Template>[];
  for (final key in table.keys) {
    if (!_placeholder.hasMatch(key)) continue;
    final order = <int>[];
    final pattern = StringBuffer('^');
    var last = 0;
    var literal = 0;
    for (final m in _placeholder.allMatches(key)) {
      final text = key.substring(last, m.start);
      literal += text.length;
      pattern
        ..write(RegExp.escape(text))
        ..write('(.*?)');
      order.add(int.parse(m[1]!));
      last = m.end;
    }
    final tail = key.substring(last);
    literal += tail.length;
    pattern
      ..write(RegExp.escape(tail))
      ..write(r'$');
    // A template that is only placeholders and punctuation would match
    // almost anything; its translation is the same layout anyway.
    if (literal < 2) continue;
    templates.add(
      _Template(key, RegExp(pattern.toString(), dotAll: true), order, literal),
    );
  }
  // The most specific template wins.
  templates.sort((a, b) => b.literalLength.compareTo(a.literalLength));
  return templates;
}
