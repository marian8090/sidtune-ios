"""Renders the App Store featuring artwork (header and search results) in the SIDtune Purple theme.

Run from the repo root: python3 AppStore/Artwork/make_artwork.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONT = ROOT / "SIDtune/Resources/Fonts/PetMe64.ttf"
OUT = Path(__file__).resolve().parent

BG = (0x12, 0x0E, 0x27)
BG2 = (0x1A, 0x15, 0x38)
ACCENT = (0xA8, 0x9D, 0xFF)
TRI = (0x5F, 0xD7, 0xFF)
SAW = (0xFF, 0xD7, 0x5F)
PULSE = (0xFF, 0x7A, 0xB6)


def background(w, h):
    img = Image.new("RGB", (w, h), BG)
    glow = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(glow)
    r = int(max(w, h) * 0.45)
    d.ellipse((w / 2 - r, h / 2 - r * 0.8, w / 2 + r, h / 2 + r * 0.8), fill=(0x2C, 0x24, 0x60))
    glow = glow.filter(ImageFilter.GaussianBlur(r * 0.45))
    img = Image.blend(img, glow, 0.9)
    # Faint CRT scanlines.
    lines = Image.new("L", (w, h), 0)
    ld = ImageDraw.Draw(lines)
    step = max(4, h // 400)
    for y in range(0, h, step):
        ld.line((0, y, w, y), fill=18)
    img.paste((0, 0, 0), mask=lines)
    return img


def wave_points(kind, w, y0, amp, period, phase):
    pts = []
    for x in range(-20, w + 21, 3):
        t = ((x + phase) / period) % 1.0
        if kind == "tri":
            v = 4 * abs(t - 0.5) - 1
        elif kind == "saw":
            v = 1 - 2 * t
        else:
            v = 1 if t < 0.35 else -1
        pts.append((x, y0 + v * amp))
    if kind != "tri":
        # Vertical edges: insert the jump explicitly so the line is crisp.
        fixed = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            if abs(b[1] - a[1]) > amp:
                fixed.append((b[0], a[1]))
            fixed.append(b)
        pts = fixed
    return pts


def fade_mask(w, h, cx, cy, rx, ry):
    """Waves dim around the logo so it stays readable."""
    m = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(m)
    d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=0)
    return m.filter(ImageFilter.GaussianBlur(min(rx, ry) * 0.5))


def waves(img, band_top, band_bottom, logo_box):
    w, h = img.size
    layer = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    band = band_bottom - band_top
    amp = band * 0.11
    width = max(4, int(h * 0.006))
    specs = [("tri", TRI, 0.18, w / 5.5, 0), ("saw", SAW, 0.5, w / 7.0, w * 0.13), ("pulse", PULSE, 0.82, w / 6.2, w * 0.31)]
    for kind, col, rel, period, phase in specs:
        y0 = band_top + band * rel
        d.line(wave_points(kind, w, y0, amp, period, phase), fill=col, width=width, joint="curve")
    glow = layer.filter(ImageFilter.GaussianBlur(width * 3))
    cx, cy = (logo_box[0] + logo_box[2]) / 2, (logo_box[1] + logo_box[3]) / 2
    rx, ry = (logo_box[2] - logo_box[0]) * 0.85, (logo_box[3] - logo_box[1]) * 0.95
    mask = fade_mask(w, h, cx, cy, rx, ry)
    from PIL import ImageChops
    combined = ImageChops.add(ImageChops.multiply(glow, Image.new("RGB", (w, h), (200, 200, 200))), layer)
    combined = ImageChops.multiply(combined, Image.merge("RGB", [mask] * 3))
    dim = Image.new("RGB", (w, h), (150, 150, 150))
    return ImageChops.add(img, ImageChops.multiply(combined, dim))


def logo(img, cx, cy, sid_size):
    w, h = img.size
    big = ImageFont.truetype(str(FONT), sid_size)
    small = ImageFont.truetype(str(FONT), int(sid_size * 0.5))
    layer = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    gap = sid_size * 0.32
    sb = d.textbbox((0, 0), "SID", font=big)
    tb = d.textbbox((0, 0), "tune", font=small)
    total = (sb[3] - sb[1]) + gap + (tb[3] - tb[1])
    top = cy - total / 2
    sx = cx - (sb[2] - sb[0]) / 2 - sb[0]
    d.text((sx, top - sb[1]), "SID", font=big, fill=ACCENT)
    tx = cx - (tb[2] - tb[0]) / 2 - tb[0]
    ty = top + (sb[3] - sb[1]) + gap
    d.text((tx, ty - tb[1]), "tune", font=small, fill=ACCENT)
    from PIL import ImageChops
    glow = layer.filter(ImageFilter.GaussianBlur(sid_size * 0.18))
    glow = ImageChops.multiply(glow, Image.new("RGB", (w, h), (130, 130, 130)))
    img = ImageChops.screen(img, glow)
    mask = layer.convert("L").point(lambda v: 255 if v > 0 else 0)
    img.paste(layer, mask=mask)
    width = max(sb[2] - sb[0], tb[2] - tb[0])
    return img, (cx - width / 2, top, cx + width / 2, top + total)


def render(w, h, name):
    img = background(w, h)
    sid_size = int(min(h * 0.26, w * 0.12))
    # Measure the logo first so the waves can fade around it.
    probe, box = logo(Image.new("RGB", (w, h)), w / 2, h / 2, sid_size)
    img = waves(img, h * 0.12, h * 0.88, box)
    img, _ = logo(img, w / 2, h / 2, sid_size)
    img.save(OUT / name, optimize=True)
    print(name, img.size)


if __name__ == "__main__":
    render(3840, 1646, "header-3840x1646.png")
    render(5244, 2950, "header-5244x2950.png")
    render(3840, 2560, "search-3840x2560.png")
    render(1920, 1280, "search-1920x1280.png")
