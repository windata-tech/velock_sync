#!/usr/bin/env python3
"""App Store marketing frames from raw simulator screenshots.

compose.py <raw-dir> <out-dir> <lang> [style]   (lang: a key of shot_strings.json)

Output keeps the raw pixel size (iPhone 1320x2868, iPad 2064x2752): the caption
on a brand background, below it the screenshot inside a device that actually
looks like the hardware — iPhone corner radius, Dynamic Island, titanium band
and side buttons; iPad its thicker bezel and camera. Shots missing from
<raw-dir> (iPad has no Velock screens) are skipped.
"""
import glob, json, math, os, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

FONT = (glob.glob('/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc') or [None])[0]
SF = '/System/Library/Fonts/SFNS.ttf'

ORDER = ['2-file-sync', '1-velock-home', '3-wizard', '4-location-detail', '5-browser',
         '7-protocols', '8-velock-detail', '6-connections']
STRINGS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'shot_strings.json')))
HIRAGINO = '/System/Library/Fonts/ヒラギノ角ゴシック W%d.ttc'

BRAND = (63, 99, 217)  # AppColors.brand


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
    f = ImageFont.truetype(SF, size, layout_engine=raqm)
    try:
        f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception:
        pass
    return f


def mix(a, b, t):
    return tuple(int(round(p + (q - p) * t)) for p, q in zip(a, b))


def ramp(height, stops):
    """A 1px-wide vertical gradient from (position, colour) stops."""
    g = Image.new('RGB', (1, height))
    px = g.load()
    for y in range(height):
        t = y / max(1, height - 1)
        lo = max((s for s in stops if s[0] <= t), key=lambda s: s[0], default=stops[0])
        hi = min((s for s in stops if s[0] >= t), key=lambda s: s[0], default=stops[-1])
        span = hi[0] - lo[0]
        px[0, y] = mix(lo[1], hi[1], 0 if span <= 0 else (t - lo[0]) / span)
    return g


def rounded(size, radius, aa=3):
    """An anti-aliased rounded-rectangle mask."""
    w, h = size
    m = Image.new('L', (w * aa, h * aa), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * aa - 1, h * aa - 1), radius * aa, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def blob(size, center, radius, strength):
    """A soft round glow as an L mask — used for the lighting behind the device."""
    w, h = size
    small = max(16, int(min(w, h) / 24))
    sx, sy = small, max(16, int(small * h / w))
    m = Image.new('L', (sx, sy), 0)
    cx, cy = center[0] * sx, center[1] * sy
    r = radius * sx
    d = ImageDraw.Draw(m)
    for i in range(14, 0, -1):  # concentric discs → smooth falloff
        t = i / 14
        d.ellipse((cx - r * t, cy - r * t, cx + r * t, cy + r * t),
                  fill=int(strength * 255 * (1 - t) ** 1.7))
    return m.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(small / 2))


# Hardware proportions, as a fraction of the screen's own width / height.
# iPhone 16 Pro Max: 62pt display corner radius on a 440pt-wide screen, the
# Dynamic Island 126x37pt sitting 11pt down.
GEOMETRY = {
    'iphone': dict(radius=0.141, surround=0.0092, band=0.0120,
                   island=(0.286, 0.084, 0.025),
                   buttons=[('left', 0.150, 0.047), ('left', 0.223, 0.078),
                            ('left', 0.313, 0.078), ('right', 0.228, 0.112)]),
    'ipad': dict(radius=0.030, surround=0.019, band=0.012, island=None,
                 buttons=[('top', 0.76, 0.055), ('right', 0.055, 0.052),
                          ('right', 0.120, 0.052)]),
}

_CHROME = {}


def chrome(kind, sw, sh):
    """The device around a screen of `sw`x`sh`: an RGBA layer that goes on top
    of the pasted screenshot, the mask the screenshot is pasted through, and
    where in the layer the screen sits. Cached — every shot shares the shape.
    """
    key = (kind, sw, sh)
    if key in _CHROME:
        return _CHROME[key]
    g = GEOMETRY[kind]
    surround = max(2, round(sw * g['surround']))
    band = max(3, round(sw * g['band']))
    edge = surround + band
    sr = sw * g['radius']  # screen corner radius
    W, H = sw + 2 * edge, sh + 2 * edge
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))

    # The polished band: a metallic ramp clipped to the outer silhouette.
    metal = ramp(H, [(0.0, (150, 157, 176)), (0.04, (214, 219, 232)),
                     (0.16, (128, 136, 158)), (0.5, (86, 93, 114)),
                     (0.84, (124, 132, 154)), (0.96, (205, 210, 224)),
                     (1.0, (142, 149, 168))]).resize((W, H))
    layer.paste(metal, (0, 0), rounded((W, H), round(sr + edge)))
    # Inside the band, the black display surround.
    inner = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    inner.paste((11, 11, 14, 255), (band, band),
                rounded((sw + 2 * surround, sh + 2 * surround), round(sr + surround)))
    layer.alpha_composite(inner)

    screen_xy = (edge, edge)
    screen_mask = rounded((sw, sh), round(sr))

    # Punch the screen out, so the screenshot pasted underneath shows through.
    hole = Image.new('L', (W, H), 255)
    hole.paste(Image.eval(screen_mask, lambda v: 255 - v), screen_xy)
    layer.putalpha(ImageChops.darker(layer.getchannel('A'), hole))

    d = ImageDraw.Draw(layer)
    if g['island']:
        iw, ih, itop = (v * sw for v in g['island'])
        ix, iy = edge + (sw - iw) / 2, edge + itop
        d.rounded_rectangle((ix, iy, ix + iw, iy + ih), ih / 2, fill=(7, 7, 9, 255))
        # The lens is all but invisible on a real screen: a hair lighter only.
        lr = ih * 0.26
        lx, ly = ix + iw - ih * 0.58, iy + ih / 2
        d.ellipse((lx - lr, ly - lr, lx + lr, ly + lr), fill=(15, 16, 20, 255))
    else:  # iPad: the front camera on the top bezel
        cr = max(2, surround * 0.22)
        cx, cy = W / 2, band + surround / 2
        d.ellipse((cx - cr, cy - cr, cx + cr, cy + cr), fill=(34, 35, 40, 255))
    _CHROME[key] = (layer, screen_xy, screen_mask, (W, H), band, edge)
    return _CHROME[key]


def buttons(bg, kind, box, band):
    """Side buttons, drawn on the background so they sit outside the body."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    out, thick = max(2, round(band * 0.30)), max(3, round(band * 0.70))
    d = ImageDraw.Draw(bg, 'RGBA')
    for side, at, length in GEOMETRY[kind]['buttons']:
        if side == 'top':
            bx, by, bw, bh = x0 + w * at, y0 - out, h * length * 0.45, out + thick
        elif side == 'left':
            bx, by, bw, bh = x0 - out, y0 + h * at, out + thick, h * length
        else:
            bx, by, bw, bh = x1 - thick, y0 + h * at, out + thick, h * length
        r = min(bw, bh) * 0.42
        d.rounded_rectangle((bx, by, bx + bw, by + bh), r, fill=(108, 116, 138))
        # A lit sliver along the outer edge: what reads as machined metal.
        lit, w2 = (182, 189, 206), max(1, out * 0.42)
        if side == 'left':
            d.rounded_rectangle((bx, by, bx + w2, by + bh), r * 0.5, fill=lit)
        elif side == 'right':
            d.rounded_rectangle((bx + bw - w2, by, bx + bw, by + bh), r * 0.5, fill=lit)
        else:
            d.rounded_rectangle((bx, by, bx + bw, by + w2), r * 0.5, fill=lit)


STYLES = {
    # Deep brand gradient, light type. Lit from behind the device.
    'deep': dict(
        title=(255, 255, 255), sub=(205, 219, 255),
        base=[(0.0, (23, 42, 120)), (0.42, (48, 78, 198)), (1.0, (104, 146, 248))],
        glow=[(0.5, 0.26, 0.62, 0.40, (190, 214, 255)),
              (0.12, 0.88, 0.55, 0.16, (142, 232, 255))],
        shadow=(10, 18, 54, 150), shadow_blur=0.030),
    # Cool pale room, dark type, brand only as tinted light. Deep enough that
    # the app's own white screen still reads as a screen.
    'light': dict(
        title=(16, 24, 52), sub=(84, 98, 134),
        base=[(0.0, (225, 231, 245)), (0.5, (205, 215, 238)), (1.0, (178, 192, 226))],
        glow=[(0.74, 0.12, 0.50, 0.26, (120, 152, 240)),
              (0.16, 0.84, 0.52, 0.20, (255, 255, 255))],
        shadow=(26, 38, 82, 150), shadow_blur=0.034),
}


def background(size, style):
    W, H = size
    s = STYLES[style]
    bg = ramp(H, s['base']).resize((W, H))
    for cx, cy, r, strength, colour in s['glow']:
        bg.paste(Image.new('RGB', (W, H), colour), (0, 0),
                 blob((W, H), (cx, cy), r, strength))
    return bg


def caption(bg, title, subtitle, lang, style, top, limit):
    """Centred title and subtitle, wrapped to two balanced lines if needed."""
    W = bg.width
    s = STYLES[style]
    d = ImageDraw.Draw(bg)
    y = top
    for text, size, bold, colour, gap in (
            (title, 0.073, True, s['title'], 0.020),
            (subtitle, 0.0355, False, s['sub'], 0)):
        f = font(int(W * size), bold, lang)
        lines = [text]
        if d.textlength(text, font=f) > limit * 1.12 and ' ' in text:
            cuts = [i for i, c in enumerate(text) if c == ' ']
            cut = min(cuts, key=lambda i: abs(i - len(text) / 2))
            lines = [text[:cut], text[cut + 1:]]
        widest = max(d.textlength(line, font=f) for line in lines)
        if widest > limit:  # shrink rather than wrap a third time
            f = font(int(f.size * limit / widest), bold, lang)
        for line in lines:
            w = d.textlength(line, font=f)
            d.text(((W - w) / 2, y), line, font=f, fill=colour)
            y += int(f.size * (1.20 if len(lines) > 1 else 1.0))
        y += int(bg.height * gap)
    return y


def frame(raw, title, subtitle, lang, style='deep'):
    W, H = raw.size
    kind = 'ipad' if H / W < 1.6 else 'iphone'
    g, s = GEOMETRY[kind], STYLES[style]
    bg = background((W, H), style)
    caption(bg, title, subtitle, lang, style, int(H * (0.050 if kind == 'iphone' else 0.058)),
            W * 0.86)

    # Largest whole device that fits under the caption.
    box_top, box_bottom, box_w = H * (0.205 if kind == 'iphone' else 0.235), H * 0.972, W * 0.84
    f = g['surround'] + g['band']
    ar = H / W
    sw = int(min(box_w / (1 + 2 * f), (box_bottom - box_top) / (ar + 2 * f)))
    sh = int(round(sw * ar))
    layer, screen_xy, screen_mask, (dw, dh), band, edge = chrome(kind, sw, sh)
    dx, dy = (W - dw) // 2, int(box_top + ((box_bottom - box_top) - dh) / 2)

    shadow = Image.new('L', (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (dx, dy + int(H * 0.006), dx + dw, dy + dh + int(H * 0.010)),
        int(sw * g['radius'] + edge), fill=s['shadow'][3])
    bg.paste(Image.new('RGB', (W, H), s['shadow'][:3]), (0, 0),
             shadow.filter(ImageFilter.GaussianBlur(int(W * s['shadow_blur']))))

    buttons(bg, kind, (dx, dy, dx + dw, dy + dh), band)
    bg.paste(raw.convert('RGB').resize((sw, sh), Image.LANCZOS),
             (dx + screen_xy[0], dy + screen_xy[1]), screen_mask)
    bg.paste(layer, (dx, dy), layer)
    return bg


def main():
    raw_dir, out_dir, lang = sys.argv[1], sys.argv[2], sys.argv[3]
    style = sys.argv[4] if len(sys.argv) > 4 else os.environ.get('SHOT_STYLE', 'deep')
    if style not in STYLES:
        sys.exit(f'unknown style {style!r} (have: {", ".join(STYLES)})')
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    captions = STRINGS[lang]['captions']
    for name in ORDER:
        path = os.path.join(raw_dir, name + '.png')
        if not os.path.exists(path):
            continue
        n += 1
        title, sub = captions[name]
        frame(Image.open(path), title, sub, lang, style).save(
            os.path.join(out_dir, f'{n:02d}-{name}.png'))
    print(f'{n} frames -> {out_dir}')


main()
