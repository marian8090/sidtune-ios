# Renders the 1024x1024 app icon: "SID" over a smaller "tune" in Pet Me 64, SIDtune theme colours (Theme.swift).
# Glyphs are drawn at the font's native 8px grid without anti-aliasing, then scaled up nearest-neighbour so the
# C64 pixels stay sharp.
import sys
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
BG = (0x12, 0x0E, 0x27)
INK = (0xA8, 0x9D, 0xFF)
SID_SCALE = 32   # 8px glyph -> 256px
TUNE_SCALE = 20  # 8px glyph -> 160px
GAP = 64

font_path, out_path = sys.argv[1], sys.argv[2]
font = ImageFont.truetype(font_path, 8)

def word(text, scale):
    img = Image.new("1", (8 * len(text) + 8, 16), 0)
    d = ImageDraw.Draw(img)
    d.fontmode = "1"
    d.text((0, 0), text, font=font, fill=1)
    img = img.crop(img.getbbox())
    return img.resize((img.width * scale, img.height * scale), Image.NEAREST)

sid, tune = word("SID", SID_SCALE), word("tune", TUNE_SCALE)
icon = Image.new("RGB", (SIZE, SIZE), BG)
top = (SIZE - (sid.height + GAP + tune.height)) // 2
for w, y in ((sid, top), (tune, top + sid.height + GAP)):
    icon.paste(Image.new("RGB", w.size, INK), ((SIZE - w.width) // 2, y), w.convert("L"))
icon.save(out_path)
