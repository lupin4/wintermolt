# Copyright The Fantastic Planet - By David Clabaugh
#
# generate_banner.py -- the startup banner, from villa-straylight.png.
#
# Writes four files into src/banner/, which src/banner.zig embeds:
#   straylight.txt / straylight.roles   the full banner: WINTERMOLT in front of
#                                       Villa Straylight and its planet
#   wordmark.txt   / wordmark.roles     the lettering alone, for small windows
# and straylight-preview.png next to this script (One Half Dark, for the README).
#
# A .roles file mirrors its .txt character for character: each cell names the
# theme slot that colors it (A accent, P primary, S secondary, F foreground,
# M muted, W warning) or ' ' for a space. Plain mode turns roles into the
# terminal's 16 colors, the full-screen view into the active theme's colors, so
# the art follows whatever palette is in use. Pure ASCII, so a byte is a column.
#
# Run from the repo root (needs Pillow and pyfiglet, nothing at build time):
#   uv run --with pillow --with pyfiglet python -I docs/ANSI_art/wintermolt/generate_banner.py
#
# Deterministic: star and texture placement use fixed seeds.

import math
import os
import random
import sys

import pyfiglet
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(HERE, "villa-straylight.png")
OUT = os.path.join(ROOT, "src", "banner")

COLS = 78          # full banner width; 80-column terminals keep a spare column
ART_ROWS = 22      # rows the image is sampled into
OFFSET = 3         # the art starts this far down, so the name overlaps only its top
BOTTOM = 1         # extra rows under the art, for the planet
FILL = "."         # the hull's interior
MASK_THRESHOLD = 0.05
FONT = "slant"
NAME = "WINTERMOLT"
NAME_GRADIENT = "APS"  # accent -> primary -> secondary across the lettering

# The planet: a circle fitted to the outer edge of the lit crescent in the
# source image (topmost lit pixel per column, rightmost per row, least squares).
PLANET_CX, PLANET_CY, PLANET_R = 1073, 911, 166
PLANET_LIFT = 1    # rows the planet is raised, so the banner stays 26 rows tall
PLANET = [
    "    _.-'''''-._    ",
    "  .'           `.  ",
    " /               \\ ",
    "|                 |",
    "|                 |",
    " \\               / ",
    "  `.           .'  ",
    "    `-._____.-'    ",
]

NONE = (" ", " ")


def lum(p):
    r, g, b = p
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0


def role_of(p, l):
    """The theme slot a sampled pixel's color belongs to."""
    r, g, b = p
    if l < 0.07:
        return None
    if r > 90 and r > b * 1.6 and g > b * 1.2:
        return "W"  # amber windows
    if b > r * 1.35 and b > 60:
        return "A" if g > r * 1.3 and g > 90 else "P"  # blue rim light
    return "F" if l > 0.42 else "M"


def sample(img, cols, rows):
    small = img.filter(ImageFilter.GaussianBlur(3)).resize((cols, rows), Image.Resampling.BOX)
    return [[small.getpixel((x, y)) for x in range(cols)] for y in range(rows)]


def solid_mask(img, cols, rows):
    """One solid ship: heavy blur, threshold, fill holes, drop specks and slivers."""
    heavy = img.filter(ImageFilter.GaussianBlur(9)).resize((cols, rows), Image.Resampling.BOX)
    on = [[lum(heavy.getpixel((x, y))) > MASK_THRESHOLD for x in range(cols)] for y in range(rows)]

    outside = [[False] * cols for _ in range(rows)]
    stack = [(y, x) for y in range(rows) for x in (0, cols - 1)]
    stack += [(y, x) for x in range(cols) for y in (0, rows - 1)]
    while stack:
        y, x = stack.pop()
        if 0 <= y < rows and 0 <= x < cols and not outside[y][x] and not on[y][x]:
            outside[y][x] = True
            stack += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
    inside = [[not outside[y][x] for x in range(cols)] for y in range(rows)]

    def at(y, x):
        return 0 <= y < rows and 0 <= x < cols and inside[y][x]

    # Slivers: one cell wide, or hanging on by one neighbour. These are the
    # ragged bits under the blunt end. Two passes take two-cell legs too.
    for _ in range(2):
        drop = []
        for y in range(rows):
            for x in range(cols):
                if not inside[y][x]:
                    continue
                n = at(y - 1, x) + at(y + 1, x) + at(y, x - 1) + at(y, x + 1)
                if n <= 1 or (not at(y, x - 1) and not at(y, x + 1)):
                    drop.append((y, x))
        for y, x in drop:
            inside[y][x] = False

    seen = [[False] * cols for _ in range(rows)]
    for y0 in range(rows):
        for x0 in range(cols):
            if inside[y0][x0] and not seen[y0][x0]:
                comp, st = [], [(y0, x0)]
                while st:
                    y, x = st.pop()
                    if 0 <= y < rows and 0 <= x < cols and inside[y][x] and not seen[y][x]:
                        seen[y][x] = True
                        comp.append((y, x))
                        st += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
                if len(comp) < 6:
                    for y, x in comp:
                        inside[y][x] = False
    return inside


def ship(cells, inside):
    """Outline the mask's boundary; fill the interior with one calm character."""
    rows, cols = len(cells), len(cells[0])
    L = [[lum(p) for p in row] for row in cells]

    def m(y, x):
        return 0 <= y < rows and 0 <= x < cols and inside[y][x]

    out = []
    for y in range(rows):
        line = []
        for x in range(cols):
            if not inside[y][x]:
                line.append(NONE)
                continue
            role = role_of(cells[y][x], L[y][x])
            up, dn, lf, rt = m(y - 1, x), m(y + 1, x), m(y, x - 1), m(y, x + 1)
            if not (up and dn and lf and rt):
                if not up and not lf:
                    ch = "/"
                elif not up and not rt:
                    ch = "\\"
                elif not dn and not lf:
                    ch = "\\"
                elif not dn and not rt:
                    ch = "/"
                elif not up:
                    ch = "_" if m(y - 1, x - 1) or m(y - 1, x + 1) else "-"
                elif not dn:
                    ch = "_"
                else:
                    ch = "|"
                line.append((ch, "P" if role in (None, "M", "F") else role))
            elif role == "W":
                line.append((":", "W"))
            elif role in ("A", "P"):
                line.append((FILL, role))
            else:
                # Darker seams between hull rings read as bands.
                darker = L[y][x] < 0.75 * max(L[y][x - 1], L[y][x + 1])
                dim = darker or L[y][x] < 0.32
                line.append(("|" if darker else FILL, "M" if dim else "F"))
        out.append(line)
    return out


def stars(grid, seed):
    rnd = random.Random(seed)
    rows, cols = len(grid), len(grid[0])
    for _ in range(cols * rows // 55):
        y, x = rnd.randrange(rows), rnd.randrange(cols)
        if grid[y][x][0] == " ":
            grid[y][x] = (rnd.choice(".*+."), "M")


def planet(grid, cx, cy):
    """Hand-drawn round outline; lighting picks each character's role and the crescent fill."""
    rows, cols = len(grid), len(grid[0])
    h, w = len(PLANET), len(PLANET[0])
    top, left = round(cy - h / 2), round(cx - w / 2)
    # Light from behind, up and to the right: the lit limb runs from the upper
    # left over the top and down the right side, as in the source image.
    lx, ly, lz = 0.60, -0.35, -0.50
    n = math.sqrt(lx * lx + ly * ly + lz * lz)
    lx, ly, lz = lx / n, ly / n, lz / n
    rx, ry = (w - 1) / 2, (h - 1) / 2
    rnd = random.Random(7)
    for r in range(h):
        line = PLANET[r]
        first = len(line) - len(line.lstrip())
        last = len(line.rstrip()) - 1
        for c in range(w):
            gy, gx = top + r, left + c
            if not (0 <= gy < rows and 0 <= gx < cols):
                continue
            grid[gy][gx] = NONE  # clear what the image conversion drew here
            if c < first or c > last:
                continue
            dx, dy = (c - rx) / rx, (r - ry) / ry
            nz = math.sqrt(1.0 - min(1.0, dx * dx + dy * dy))
            s = dx * lx + dy * ly + nz * lz
            ch = line[c]
            if ch != " ":
                grid[gy][gx] = (ch, "A" if s > 0.25 else "P" if s > -0.05 else "M")
            elif s > 0.25:
                grid[gy][gx] = (":", "A")
            elif s > 0.0:
                grid[gy][gx] = (".", "P")
            elif rnd.random() < 0.10:
                grid[gy][gx] = (".", "M")  # faint texture on the dark side


def lettering():
    lines = pyfiglet.figlet_format(NAME, font=FONT, width=200).splitlines()
    return [l.rstrip() for l in lines if l.strip()]


def overlay(grid, text, top, left):
    """The name in front: a one-cell clear halo around every glyph, then the glyphs."""
    rows, cols = len(grid), len(grid[0])
    width = max(len(t) for t in text)
    for dy, t in enumerate(text):
        for dx, ch in enumerate(t):
            if ch != " ":
                for yy in range(top + dy - 1, top + dy + 2):
                    for xx in range(left + dx - 1, left + dx + 2):
                        if 0 <= yy < rows and 0 <= xx < cols:
                            grid[yy][xx] = NONE
    for dy, t in enumerate(text):
        for dx, ch in enumerate(t):
            if ch != " " and 0 <= top + dy < rows and 0 <= left + dx < cols:
                band = NAME_GRADIENT[min(len(NAME_GRADIENT) - 1, dx * len(NAME_GRADIENT) // width)]
                grid[top + dy][left + dx] = (ch, band)


def write(grid, stem):
    text = "\n".join("".join(c for c, _ in row).rstrip() for row in grid) + "\n"
    roles = "\n".join("".join(r for _, r in row).rstrip() for row in grid) + "\n"
    for suffix, body in ((".txt", text), (".roles", roles)):
        with open(os.path.join(OUT, stem + suffix), "w", encoding="ascii", newline="\n") as f:
            f.write(body)


# One Half Dark, for the preview image only.
PREVIEW = {
    " ": None, "A": (0x56, 0xB6, 0xC2), "P": (0x61, 0xAF, 0xEF), "S": (0xC6, 0x78, 0xDD),
    "F": (0xDC, 0xDF, 0xE4), "M": (0x5A, 0x63, 0x74), "W": (0xE5, 0xC0, 0x7B),
}


def preview(grid, path):
    font = ImageFont.truetype(r"C:\Windows\Fonts\CascadiaMono.ttf", 16) if os.name == "nt" else ImageFont.load_default()
    cw, chh = font.getbbox("M")[2], 19
    img = Image.new("RGB", (len(grid[0]) * cw + 32, len(grid) * chh + 32), (0x28, 0x2C, 0x34))
    d = ImageDraw.Draw(img)
    for y, row in enumerate(grid):
        for x, (c, r) in enumerate(row):
            if c != " ":
                d.text((16 + x * cw, 16 + y * chh), c, font=font, fill=PREVIEW[r])
    img.save(path)


def main():
    img = Image.open(SRC).convert("RGB")
    iw, ih = img.size
    os.makedirs(OUT, exist_ok=True)

    art = ship(sample(img, COLS, ART_ROWS), solid_mask(img, COLS, ART_ROWS))
    grid = [[NONE] * COLS for _ in range(OFFSET)] + art + [[NONE] * COLS for _ in range(BOTTOM)]
    stars(grid, COLS)
    planet(grid, PLANET_CX / iw * COLS, OFFSET + PLANET_CY / ih * ART_ROWS - PLANET_LIFT)
    name = lettering()
    overlay(grid, name, 0, 1)
    write(grid, "straylight")
    preview(grid, os.path.join(HERE, "straylight-preview.png"))

    mark = [[NONE] * (max(len(t) for t in name) + 1) for _ in name]
    overlay(mark, name, 0, 1)
    write(mark, "wordmark")

    print(f"straylight {len(grid[0])}x{len(grid)}  wordmark {len(mark[0])}x{len(mark)}  -> {OUT}")


if __name__ == "__main__":
    sys.exit(main())
