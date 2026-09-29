#!/usr/bin/env python3
"""Builds the Velock Sync app icon SVGs and every platform PNG from one design.

Design: the 格间 shield (same green #1EAA39 family, white V) held inside two
white sync arrows. The geometry lives here so the full icon, the Android
adaptive foreground and the preview stay identical.

Usage: python3 tool/app_icon/generate.py   (needs cairosvg + Pillow)
"""

import io
import json
import math
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent
SIZE = 1024
CENTER = SIZE / 2

GREEN_TOP = "#2DC24E"
GREEN_BOTTOM = "#12913A"
V_GREEN = "#1EAA39"

RING_RADIUS = 338
RING_STROKE = 64
ARROW_HEAD = 118  # length of the arrowhead along the ring


def _point(angle_deg: float, radius: float = RING_RADIUS) -> tuple[float, float]:
    angle = math.radians(angle_deg)
    return CENTER + radius * math.cos(angle), CENTER + radius * math.sin(angle)


def _arrow(start_deg: float, end_deg: float) -> str:
    """A clockwise arc from start to end, finished with a solid arrowhead."""
    # Leave room for the head so the stroke never pokes past its tip.
    head_span = math.degrees(ARROW_HEAD / RING_RADIUS)
    arc_end = end_deg - head_span * 0.55
    sx, sy = _point(start_deg)
    ex, ey = _point(arc_end)
    large = 1 if (arc_end - start_deg) % 360 > 180 else 0
    arc = (
        f'<path d="M{sx:.1f} {sy:.1f} A{RING_RADIUS} {RING_RADIUS} 0 {large} 1 '
        f'{ex:.1f} {ey:.1f}" fill="none" stroke="#FFFFFF" '
        f'stroke-width="{RING_STROKE}" stroke-linecap="round"/>'
    )
    tip = _point(end_deg)
    base_angle = end_deg - head_span
    half = RING_STROKE * 1.28
    outer = _point(base_angle, RING_RADIUS + half)
    inner = _point(base_angle, RING_RADIUS - half)
    head = (
        f'<path d="M{tip[0]:.1f} {tip[1]:.1f} L{outer[0]:.1f} {outer[1]:.1f} '
        f'L{inner[0]:.1f} {inner[1]:.1f} Z" fill="#FFFFFF" '
        f'stroke="#FFFFFF" stroke-width="10" stroke-linejoin="round"/>'
    )
    return arc + head


def _glyph(scale: float = 1.0) -> str:
    """Shield + V + sync arrows, drawn around the canvas centre."""
    shield = (
        "M512 322 C574 356 634 366 690 362 L690 522 "
        "C690 618 622 680 512 716 C402 680 334 618 334 522 "
        "L334 362 C390 366 450 356 512 322 Z"
    )
    v_mark = "M424 424 L478 424 L512 552 L546 424 L600 424 L540 624 L484 624 Z"
    arrows = _arrow(198, 332) + _arrow(18, 152)
    body = (
        f'<path d="{shield}" fill="#FFFFFF"/>'
        f'<path d="{v_mark}" fill="{V_GREEN}" stroke="{V_GREEN}" '
        f'stroke-width="6" stroke-linejoin="round"/>'
        f"{arrows}"
    )
    if scale == 1.0:
        return body
    offset = CENTER * (1 - scale)
    return f'<g transform="translate({offset:.1f} {offset:.1f}) scale({scale})">{body}</g>'


def _background() -> str:
    return (
        '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{GREEN_TOP}"/>'
        f'<stop offset="1" stop-color="{GREEN_BOTTOM}"/>'
        "</linearGradient></defs>"
        f'<rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>'
    )


def _svg(content: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
        f'viewBox="0 0 {SIZE} {SIZE}">{content}</svg>\n'
    )


def _render(svg: str, px: int, *, opaque: bool) -> Image.Image:
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    return image.convert("RGB") if opaque else image


def _rounded(image: Image.Image, radius_ratio: float) -> Image.Image:
    from PIL import ImageDraw

    mask = Image.new("L", image.size, 0)
    radius = int(image.size[0] * radius_ratio)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.size[0] - 1, image.size[1] - 1), radius=radius, fill=255
    )
    rounded = image.convert("RGBA")
    rounded.putalpha(mask)
    return rounded


def main() -> None:
    full = _svg(_background() + _glyph())
    # Android adaptive icons crop to the central 72/108; keep the glyph inside
    # the 66/108 safe-zone circle (ring radius 0.72 x 0.8 of the half-width).
    foreground = _svg(_glyph(scale=0.8))
    background = _svg(_background())
    (OUT_DIR / "velock_sync_icon.svg").write_text(full)
    (OUT_DIR / "velock_sync_icon_foreground.svg").write_text(foreground)
    (OUT_DIR / "velock_sync_icon_background.svg").write_text(background)

    # iOS: square, opaque (App Store rejects alpha); the system applies the mask.
    ios_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((ios_dir / "Contents.json").read_text())
    for entry in contents["images"]:
        points = float(entry["size"].split("x")[0])
        px = round(points * int(entry["scale"].rstrip("x")))
        _render(full, px, opaque=True).save(ios_dir / entry["filename"])

    # Android legacy launcher (pre-26) with the usual rounded square, plus the
    # adaptive layers for API 26+.
    res = ROOT / "android/app/src/main/res"
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, factor in densities.items():
        folder = res / f"mipmap-{name}"
        folder.mkdir(exist_ok=True)
        legacy = _rounded(_render(full, round(48 * factor), opaque=False), 0.22)
        legacy.save(folder / "ic_launcher.png")
        layer = round(108 * factor)
        _render(foreground, layer, opaque=False).save(folder / "ic_launcher_foreground.png")
        _render(background, layer, opaque=True).save(folder / "ic_launcher_background.png")
    adaptive = res / "mipmap-anydpi-v26"
    adaptive.mkdir(exist_ok=True)
    (adaptive / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )

    # Store listing / review preview.
    _render(full, 512, opaque=True).save(OUT_DIR / "velock_sync_icon_512.png")


if __name__ == "__main__":
    main()
