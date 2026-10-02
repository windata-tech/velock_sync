#!/usr/bin/env python3
"""App Store marketing frames from raw simulator screenshots.

compose.py <raw-dir> <out-dir> <lang>   (a key of shot_strings.json)
Output keeps the raw pixel size (iPhone 1320x2868, iPad 2064x2752): caption on a
brand gradient, the screenshot below it in a thin bezel, bleeding off the bottom.
Shots missing from <raw-dir> (iPad has no Velock screens) are skipped.
"""
import glob, json, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = (glob.glob('/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc') or [None])[0]
SF = '/System/Library/Fonts/SFNS.ttf'

ORDER = ['2-file-sync', '1-velock-home', '3-wizard', '4-location-detail', '5-browser',
         '7-protocols', '8-velock-detail', '6-connections']
STRINGS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'shot_strings.json')))
HIRAGINO = '/System/Library/Fonts/ヒラギノ角ゴシック W%d.ttc'
TOP, BOTTOM = (47, 91, 224), (98, 146, 246)


def font(size, bold, lang):
    raqm = ImageFont.Layout.RAQM
    if lang in ('zh', 'zh-Hant') and FONT:  # PingFang SC / TC, Semibold or Regular
        return ImageFont.truetype(FONT, size, index={'zh': (3, 11), 'zh-Hant': (2, 10)}[lang][bold])
    if lang == 'ja':
        return ImageFont.truetype(HIRAGINO % (6 if bold else 3), size)
    if lang == 'ko':
        return ImageFont.truetype('/System/Library/Fonts/AppleSDGothicNeo.ttc', size, index=6 if bold else 0)
    if lang == 'hi':
        return ImageFont.truetype('/System/Library/Fonts/Kohinoor.ttc', size, index=2 if bold else 0, layout_engine=raqm)
    if lang == 'ar':  # SF Arabic has no Latin for the product names; Arial has both
        return ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial%s.ttf' % (' Bold' if bold else ''),
                                  size, layout_engine=raqm)
    path = SF
    f = ImageFont.truetype(path, size, layout_engine=raqm)
    try:
        f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception:
        pass
    return f


def frame(raw, title, subtitle, lang):
    W, H = raw.size
    bg = Image.new('RGB', (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    tf, sf = font(int(W * 0.072), True, lang), font(int(W * 0.036), False, lang)
    y = int(H * 0.055)
    for text, f, bold, color, gap in ((title, tf, True, (255, 255, 255), 0.022), (subtitle, sf, False, (226, 234, 255), 0)):
        lines = [text]
        if d.textlength(text, font=f) > W * 0.9 * 1.15 and ' ' in text:
            # Much too long: two balanced lines instead of a tiny one.
            cuts = [i for i, c in enumerate(text) if c == ' ']
            cut = min(cuts, key=lambda i: abs(i - len(text) / 2))
            lines = [text[:cut], text[cut + 1:]]
        widest = max(d.textlength(line, font=f) for line in lines)
        if widest > W * 0.9:  # shrink long lines to fit
            f = font(int(f.size * W * 0.9 / widest), bold, lang)
        for line in lines:
            w = d.textlength(line, font=f)
            d.text(((W - w) / 2, y), line, font=f, fill=color)
            y += int(f.size * (1.18 if len(lines) > 1 else 1))
        y += int(H * gap)
    scale = 0.80 if H / W > 1.6 else 0.78
    sw = int(W * scale); sh = int(raw.height * sw / raw.width)
    shot = raw.convert('RGB').resize((sw, sh), Image.LANCZOS)
    bezel = int(W * 0.016); r = int(sw * 0.075)
    top = int(H * 0.215)
    x = (W - sw) // 2
    shadow = Image.new('L', (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x - bezel, top - bezel + 18, x + sw + bezel, top + sh + bezel + 18), r + bezel, fill=110)
    bg.paste((20, 30, 70), mask=shadow.filter(ImageFilter.GaussianBlur(40)))
    d = ImageDraw.Draw(bg)
    d.rounded_rectangle((x - bezel, top - bezel, x + sw + bezel, top + sh + bezel), r + bezel, fill=(18, 18, 22))
    mask = Image.new('L', (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw, sh), r, fill=255)
    bg.paste(shot, (x, top), mask)
    return bg


def main():
    raw_dir, out_dir, lang = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    captions = STRINGS[lang]['captions']
    for name in ORDER:
        path = os.path.join(raw_dir, name + '.png')
        if not os.path.exists(path):
            continue
        n += 1
        title, sub = captions[name]
        frame(Image.open(path), title, sub, lang).save(os.path.join(out_dir, f'{n:02d}-{name}.png'))
    print(f'{n} frames -> {out_dir}')


main()
