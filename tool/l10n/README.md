# Sync UI translations

Call sites use `syncText(context, '简体中文', 'English')`. Every other language is
looked up **by the English text** in `lib/l10n/translations/sync_translations.dart`,
generated from `tool/l10n/translations/<code>/part*.json`. Missing entries fall
back to English at run time.

1. `dart run tool/l10n/extract_sync_text.dart` — rebuilds `sync_strings.json`
   (English key → Chinese text and the Dart expressions behind `{0}`, `{1}`…).
2. `python3 tool/l10n/gen_translations.py --split` — rewrites `source/part1-4.json`.
3. Translate new/changed keys into `translations/<code>/partN.json` (same keys).
4. `python3 tool/l10n/gen_translations.py` — validates (every key, same
   placeholders, no Chinese in non-CJK languages) and regenerates the Dart table.

## Translator brief

- Output: a JSON object with exactly the same keys as the source part; each
  value is the translation of the key (the English). The `zh` field is the
  Simplified Chinese original, useful to disambiguate; `args` shows what each
  `{n}` placeholder holds.
- Keep every `{n}` placeholder exactly once (order may change). Keep `\n`
  line breaks, quotes style natural for the language, and punctuation.
- Product names: **Velock** (the companion vault app; Chinese 格间) and
  **Velock Sync** / **Sync** stay untranslated in every language except
  Traditional Chinese, which uses 格間 / 格間同步 (Sync alone stays “Sync”).
  WebDAV, NAS, Google Drive, OneDrive, Baidu Netdisk, Aliyun Drive, Face ID,
  iCloud, Wi‑Fi, App Store and URLs stay as they are.
- Terms already used by Velock's own UI should match its translations in
  `../velock_codex/lib/l10n/<code>.arb` (e.g. recovery card, space, Recently Deleted).
- Tone: short, plain, friendly iOS UI copy, second person, no exclamation marks.
  Buttons are short verbs. Don't add or drop meaning; never say data is
  “backed up/restored” where the English doesn't.
- Placeholder-only fragments such as `Upload`, `Download`, `Yes`, `No`,
  `Restore from`, `Save to` are translated on their own.
