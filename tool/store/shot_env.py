#!/usr/bin/env python3
"""Shell assignments for store_shots.sh in one app language.

shot_env.py <lang>   (zh, en, zh-Hant, ja, …: SyncLanguage.storageValue)
Folder names come from shot_strings.json; the labels testStoreShots waits for
are looked up the way the app does: zh → the Chinese original, en → the English
key, anything else → tool/l10n/translations/<lang>/part*.json.
"""
import glob, json, os, shlex, sys

lang = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
names = json.load(open(os.path.join(root, 'tool/store/shot_strings.json')))[lang]
source = json.load(open(os.path.join(root, 'tool/l10n/sync_strings.json')))
table = {}
for part in glob.glob(os.path.join(root, f'tool/l10n/translations/{lang}/part*.json')):
    table.update(json.load(open(part)))


def tr(en):
    if lang == 'en':
        return en
    if lang == 'zh':
        return source[en]['zh']
    if en not in table:
        sys.exit(f'{lang}: no translation for {en!r}')
    return table[en]


out = {
    'locs': ';'.join(f'{names[k]}>{names[k]}>{d}' for k, d in (('photos', 'two'), ('documents', 'two'), ('work', 'up'))),
    'wizard': f"{names['music']}>{names['music']}",
    'browse': names['photos'],
    'home_nas': names['home_nas'],
    'my_velock': names['my_velock'],
    'rtl': '1' if lang == 'ar' else '0',
    'L_DONE': '|'.join(tr(s) for s in ('Up to date', 'Sync finished')),
    'L_BACKUP_DONE': tr('Last backup completed'),
    'L_LIST': tr('Show as list'),
    'L_TWO': tr('Two-way'),
    'L_UP': tr('Upload only'),
    'L_DOWN': tr('Download only'),
}
for k, v in out.items():
    print(f'{k}={shlex.quote(v)}')
