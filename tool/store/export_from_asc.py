#!/usr/bin/env python3
"""Export every App Store listing asset (copy + screenshots) of both apps into
one folder, straight from App Store Connect — what the store page actually
shows right now, not what happens to be in this repo.

    python3 tool/store/export_from_asc.py <output-dir>

Needs the private API key outside this repo: ~/.velock-release/asc.py plus
asc_api_key.json (set VELOCK_RELEASE_DIR to point somewhere else). Read-only:
it never writes to App Store Connect.
"""
import os, re, sys, time, urllib.request

RELEASE_DIR = os.path.expanduser(os.environ.get('VELOCK_RELEASE_DIR', '~/.velock-release'))
if not os.path.isfile(f'{RELEASE_DIR}/asc.py'):
    sys.exit(f'no App Store Connect key helper at {RELEASE_DIR}/asc.py')
sys.path.insert(0, RELEASE_DIR)
from asc import call  # noqa: E402  (needs the path above)

APPS = [
    ('6748689303', '格间 Velock'),
    ('6818113511', '格间同步 Velock Sync'),
]

DISPLAY_NAMES = {
    'APP_IPHONE_67': 'iPhone 6.7 寸',
    'APP_IPHONE_69': 'iPhone 6.9 寸',
    'APP_IPHONE_65': 'iPhone 6.5 寸',
    'APP_IPHONE_61': 'iPhone 6.1 寸',
    'APP_IPHONE_58': 'iPhone 5.8 寸',
    'APP_IPHONE_55': 'iPhone 5.5 寸',
    'APP_IPHONE_47': 'iPhone 4.7 寸',
    'APP_IPAD_PRO_3GEN_129': 'iPad Pro 12.9 寸 (第三代)',
    'APP_IPAD_PRO_3GEN_11': 'iPad Pro 11 寸 (第三代)',
    'APP_IPAD_PRO_129': 'iPad Pro 12.9 寸',
    'APP_IPAD_105': 'iPad 10.5 寸',
    'APP_IPAD_97': 'iPad 9.7 寸',
    'APP_IPAD_11': 'iPad 11 寸',
    'APP_IPAD_13': 'iPad 13 寸',
}

# App Store Connect field -> (file name, character limit or None)
VERSION_FIELDS = [
    ('description', '04-描述 description', 4000),
    ('promotionalText', '05-推广文本 promotional_text', 170),
    ('keywords', '06-关键词 keywords', 100),
    ('whatsNew', '07-更新说明 whats_new', 4000),
    ('supportUrl', '08-支持网址 support_url', None),
    ('marketingUrl', '09-营销网址 marketing_url', None),
]
INFO_FIELDS = [
    ('name', '01-名称 name', 30),
    ('subtitle', '02-副标题 subtitle', 30),
    ('privacyPolicyUrl', '03-隐私政策网址 privacy_policy_url', None),
]


def get(path, attempts=5):
    """GET with retries: the API connection drops occasionally."""
    for attempt in range(1, attempts + 1):
        try:
            status, body = call('GET', path)
        except Exception as error:  # transient TLS/connection drop
            if attempt == attempts:
                raise
            print(f'  . 重试 {attempt}/{attempts}（{type(error).__name__}）')
            time.sleep(2 * attempt)
            continue
        if status == 200:
            return body
        if status in (429, 500, 502, 503, 504) and attempt < attempts:
            print(f'  . 重试 {attempt}/{attempts}（HTTP {status}）')
            time.sleep(2 * attempt)
            continue
        raise SystemExit(f'GET {path} -> {status}: {body}')


def paged(path):
    """Yield every record of a collection, following ASC cursors."""
    while path:
        body = get(path)
        yield from body['data']
        path = body.get('links', {}).get('next')


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def download(url, path, attempts=5):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return os.path.getsize(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                data = r.read()
            break
        except Exception as error:
            if attempt == attempts:
                raise
            print(f'  . 重下 {attempt}/{attempts}（{type(error).__name__}）')
            time.sleep(2 * attempt)
    with open(path, 'wb') as f:
        f.write(data)
    return os.path.getsize(path)


def newest_version(app_id):
    """The newest version record plus the recent history, newest first."""
    versions = list(paged(
        f'/v1/apps/{app_id}/appStoreVersions?limit=10&fields[appStoreVersions]='
        'versionString,appStoreState,releaseType,createdDate'))
    versions.sort(key=lambda v: v['attributes']['createdDate'], reverse=True)
    return versions[0], versions


def build_of(version_id):
    body = get(f'/v1/appStoreVersions/{version_id}/build?fields[builds]=version')
    data = body.get('data')
    return data['attributes']['version'] if data else None


def export_copy(version_id, app_id, copy_root):
    """Write one text file per App Store Connect field, per language."""
    info_id = get(f'/v1/apps/{app_id}/appInfos')['data'][0]['id']
    info = {loc['attributes']['locale']: loc['attributes'] for loc in paged(
        f'/v1/appInfos/{info_id}/appInfoLocalizations?limit=50'
        '&fields[appInfoLocalizations]=locale,name,subtitle,privacyPolicyUrl')}
    rows = []
    for loc in paged(
            f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations'
            '?limit=50&fields[appStoreVersionLocalizations]=locale,description,'
            'keywords,promotionalText,whatsNew,marketingUrl,supportUrl'):
        a = loc['attributes']
        locale = a['locale']
        fields = list(INFO_FIELDS) + list(VERSION_FIELDS)
        values = dict(info.get(locale, {}))
        values.update(a)
        for key, filename, limit in fields:
            value = values.get(key)
            if not value:
                continue
            note = ''
            if limit:
                note = f'（{len(value)}/{limit} 字符）\n\n'
            write(f'{copy_root}/{locale}/{filename}.txt', note + value + '\n')
        rows.append((locale, values.get('name', ''), values.get('subtitle', ''),
                     values.get('keywords', '')))
    rows.sort()
    lines = ['语言\t名称 (≤30)\t副标题 (≤30)\t关键词 (≤100)']
    for locale, name, subtitle, keywords in rows:
        lines.append(f'{locale}\t{name} ({len(name)})\t{subtitle} '
                     f'({len(subtitle)})\t{keywords} ({len(keywords)})')
    write(f'{copy_root}/所有语言汇总.tsv', '\n'.join(lines) + '\n')
    return [r[0] for r in rows]


def export_screenshots(version_id, shot_root):
    """Download every uploaded screenshot, grouped by language and device."""
    tally = []
    for loc in paged(f'/v1/appStoreVersions/{version_id}'
                     '/appStoreVersionLocalizations?limit=50'
                     '&fields[appStoreVersionLocalizations]=locale'):
        locale = loc['attributes']['locale']
        for s in paged(f"/v1/appStoreVersionLocalizations/{loc['id']}"
                       '/appScreenshotSets?limit=20'
                       '&fields[appScreenshotSets]=screenshotDisplayType'):
            kind = s['attributes']['screenshotDisplayType']
            folder = f'{shot_root}/{locale}/{DISPLAY_NAMES.get(kind, kind)}'
            shots = list(paged(
                f"/v1/appScreenshotSets/{s['id']}/appScreenshots?limit=20"
                '&fields[appScreenshots]=fileName,imageAsset,'
                'assetDeliveryState'))
            for index, shot in enumerate(shots, start=1):
                a = shot['attributes']
                asset = a.get('imageAsset')
                if not asset:
                    print(f'  ! {locale}/{kind} #{index} 还没有可下载的图片')
                    continue
                url = (asset['templateUrl']
                       .replace('{w}', str(asset['width']))
                       .replace('{h}', str(asset['height']))
                       .replace('{f}', 'png'))
                # The prefix is the order the screenshot appears on the store;
                # drop the uploaded file's own number when it says the same.
                name = a.get('fileName') or f'{index:02d}.png'
                name = re.sub(rf'^0*{index}-', '', name)
                download(url, f'{folder}/{index:02d}-{name}')
            tally.append((locale, kind, len(shots)))
    return tally


def export_app(app_id, label, out_dir):
    app = get(f'/v1/apps/{app_id}?fields[apps]=name,bundleId,sku,'
              'primaryLocale')['data']['attributes']
    version, history = newest_version(app_id)
    v = version['attributes']
    root = f"{out_dir}/{label} {v['versionString']}"
    print(f"\n=== {label} {v['versionString']} ({v['appStoreState']}) ===")
    locales = export_copy(version['id'], app_id, f'{root}/文案')
    print(f'  文案：{len(locales)} 种语言')
    tally = export_screenshots(version['id'], f'{root}/截图')
    total = sum(n for _, _, n in tally)
    print(f'  截图：{total} 张')

    kinds = sorted({k for _, k, _ in tally})
    lines = [f'# {label} {v["versionString"]}', '',
             f'- App Store Connect ID：`{app_id}`',
             f'- Bundle ID：`{app["bundleId"]}`',
             f'- 状态：**{v["appStoreState"]}**，发布方式 {v["releaseType"]}',
             f'- 构建号：{build_of(version["id"])}',
             f'- 主语言：{app["primaryLocale"]}',
             f'- 文案语言：{len(locales)} 种（{", ".join(locales)}）',
             f'- 截图：共 {total} 张，设备尺寸 {len(kinds)} 种',
             '']
    for kind in kinds:
        per = sorted((loc, n) for loc, k, n in tally if k == kind)
        lines.append(f'  - {DISPLAY_NAMES.get(kind, kind)}：'
                     f'{sum(n for _, n in per)} 张，{len(per)} 种语言')
    lines += ['', '## 版本历史', '']
    for item in history:
        h = item['attributes']
        lines.append(f'- {h["versionString"]} — {h["appStoreState"]}'
                     f'（创建于 {h["createdDate"][:10]}）')
    write(f'{root}/说明.md', '\n'.join(lines) + '\n')
    return root, v, locales, total, kinds


def main():
    out_dir = os.path.abspath(sys.argv[1])
    os.makedirs(out_dir, exist_ok=True)
    summary = []
    for app_id, label in APPS:
        summary.append((label, app_id) + export_app(app_id, label, out_dir)[1:])

    lines = ['# App Store 上架资料', '',
             '这些内容是直接从 App Store Connect 导出的，就是商店页面上实际使用的'
             '文案和截图。', '']
    for label, app_id, v, locales, total, kinds in summary:
        lines += [f'## {label} {v["versionString"]}', '',
                  f'- 状态：**{v["appStoreState"]}**（发布方式 {v["releaseType"]}）',
                  f'- App ID：`{app_id}`',
                  f'- 文案：{len(locales)} 种语言，每种一个文件夹，'
                  '文件名就是 App Store Connect 里的字段',
                  f'- 截图：{total} 张，设备尺寸 {len(kinds)} 种', '']
    lines += ['## 文件夹结构', '', '```',
              '<App 名称> <版本>/',
              '  说明.md            本版本的状态、语言和截图统计',
              '  文案/',
              '    所有语言汇总.tsv  名称/副标题/关键词一览（带字数）',
              '    <语言>/           01-名称、02-副标题、04-描述、06-关键词…',
              '  截图/',
              '    <语言>/<设备尺寸>/01-….png',
              '```', '',
              '字符上限：名称 30、副标题 30、关键词 100、推广文本 170、描述 4000。',
              '每个文案文件第一行标注了实际字数。', '']
    write(f'{out_dir}/README.md', '\n'.join(lines) + '\n')
    print(f'\n写入 {out_dir}')


if __name__ == '__main__':
    main()
