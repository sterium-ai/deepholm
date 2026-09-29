#!/usr/bin/env python3
"""Generates Deepholm's placeholder pixel art.

Every PNG under game/assets/generated/ is produced by this script from code:
no external artwork is read or embedded. The output is deterministic (fixed
seeds), so re-running the script reproduces byte-identical images.

    python tools/generate_placeholder_art.py

After regenerating, re-import the project and rebuild the Godot resources:

    godot --headless --path game --import
    godot --headless --path game --script res://scripts/tools/build_terrain_tileset.gd
    godot --headless --path game --script res://scripts/tools/build_colonist_frames.gd

Requires Pillow (pip install pillow).
"""

from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "game" / "assets" / "generated"
CELL = 16
CLEAR = (0, 0, 0, 0)


def hexc(value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), alpha)


def shade(color, amount: int):
    r, g, b, a = color
    clamp = lambda v: max(0, min(255, v))
    return (clamp(r + amount), clamp(g + amount), clamp(b + amount), a)


# ---------------------------------------------------------------- palette
GRASS = hexc("5d9440")
GRASS_DARK = hexc("4a7a33")
GRASS_LIGHT = hexc("77ad52")
GRASS_EDGE = hexc("3f682c")
FOREST = hexc("3f6b31")
DIRT = hexc("8a6440")
DIRT_DARK = hexc("6e4e31")
SOIL_TILLED = hexc("6b4a2d")
SOIL_FURROW = hexc("4f3520")
WATER = hexc("3569a8")
WATER_LIGHT = hexc("5b8fcf")
WATER_DARK = hexc("2a5288")
ROCK = hexc("75716b")
ROCK_DARK = hexc("59554f")
ROCK_LIGHT = hexc("8f8b84")
FLOOR = hexc("a39c8c")
FLOOR_GAP = hexc("7d7669")
WOOD = hexc("9a6a3a")
WOOD_DARK = hexc("6f4a26")
WOOD_LIGHT = hexc("b98a55")
OUTLINE = hexc("1d1611")
LEAF = hexc("3f8a3a")
LEAF_DARK = hexc("2d6a2c")
LEAF_LIGHT = hexc("5fae4c")
BERRY = hexc("c8323c")
METAL = hexc("9aa3ab")
METAL_DARK = hexc("68717a")
COAL = hexc("2f2d2c")
COAL_LIGHT = hexc("4a4745")
CLOTH = hexc("b7473f")
CLOTH_LIGHT = hexc("d9d2c3")


def new(w: int, h: int, fill=CLEAR) -> Image.Image:
    return Image.new("RGBA", (w, h), fill)


def speckle(img, x0, y0, w, h, base, variants, density, rng):
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            img.putpixel((x, y), base)
            if rng.random() < density:
                img.putpixel((x, y), rng.choice(variants))


def outline(img: Image.Image, color=OUTLINE, max_y: int | None = None) -> None:
    """Adds a 1px outline around every opaque pixel (4-neighbourhood)."""
    w, h = img.size
    src = img.copy()
    for y in range(h):
        if max_y is not None and y > max_y:
            continue
        for x in range(w):
            if src.getpixel((x, y))[3] != 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and src.getpixel((nx, ny))[3] != 0:
                    img.putpixel((x, y), color)
                    break


def rect(img, x0, y0, x1, y1, color):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            img.putpixel((x, y), color)


def ellipse(img, cx, cy, rx, ry, color):
    w, h = img.size
    for y in range(h):
        for x in range(w):
            if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0:
                img.putpixel((x, y), color)


# ---------------------------------------------------------------- terrain
def grass_cell(seed: int, flowers: bool = False) -> Image.Image:
    rng = random.Random(seed)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, GRASS, [GRASS_DARK, GRASS_LIGHT], 0.22, rng)
    for _ in range(3):
        x, y = rng.randrange(1, 15), rng.randrange(2, 15)
        img.putpixel((x, y), GRASS_LIGHT)
        img.putpixel((x, y - 1), GRASS_LIGHT)
    if flowers:
        for _ in range(2):
            x, y = rng.randrange(2, 14), rng.randrange(2, 14)
            img.putpixel((x, y), hexc("e8d86a"))
    return img


def masked_grass(seed: int, inside) -> Image.Image:
    """Grass where inside(x, y) is true, transparent elsewhere, with a dark rim."""
    base = grass_cell(seed)
    img = new(CELL, CELL)
    for y in range(CELL):
        for x in range(CELL):
            if inside(x, y):
                img.putpixel((x, y), base.getpixel((x, y)))
    src = img.copy()
    for y in range(CELL):
        for x in range(CELL):
            if src.getpixel((x, y))[3] == 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < CELL and 0 <= ny < CELL and src.getpixel((nx, ny))[3] == 0:
                    img.putpixel((x, y), GRASS_EDGE)
                    break
    return img


def wobble(i: int) -> int:
    return (0, 1, 1, 0, 1, 2, 1, 0, 0, 1, 2, 1, 1, 0, 1, 1)[i % 16]


def blob_cells() -> dict[str, Image.Image]:
    """The 12 directional shoreline overlay cells.

    The named direction is the side (edge) or quadrant (corner) where the
    foreign neighbour (water or rock) shows through, i.e. where grass is absent.
    """
    lo, hi = 5, 10
    cells = {
        "edge_N": lambda x, y: y >= lo + wobble(x),
        "edge_S": lambda x, y: y <= hi - wobble(x),
        "edge_E": lambda x, y: x <= hi - wobble(y),
        "edge_W": lambda x, y: x >= lo + wobble(y),
        "corner_NE": lambda x, y: y >= lo + wobble(x) and x <= hi - wobble(y) and (x - 2) + (15 - y) <= 17,
        "corner_NW": lambda x, y: y >= lo + wobble(x) and x >= lo + wobble(y) and (13 - x) + (15 - y) <= 17,
        "corner_SE": lambda x, y: y <= hi - wobble(x) and x <= hi - wobble(y) and (x - 2) + y <= 17,
        "corner_SW": lambda x, y: y <= hi - wobble(x) and x >= lo + wobble(y) and (13 - x) + y <= 17,
        "concave_NE": lambda x, y: (x - 16) ** 2 + (y + 1) ** 2 > 42,
        "concave_NW": lambda x, y: (x + 1) ** 2 + (y + 1) ** 2 > 42,
        "concave_SE": lambda x, y: (x - 16) ** 2 + (y - 16) ** 2 > 42,
        "concave_SW": lambda x, y: (x + 1) ** 2 + (y - 16) ** 2 > 42,
    }
    return {name: masked_grass(100 + i, fn) for i, (name, fn) in enumerate(cells.items())}


def floor_cell() -> Image.Image:
    rng = random.Random(7)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, FLOOR, [shade(FLOOR, -10), shade(FLOOR, 8)], 0.18, rng)
    for i in range(CELL):
        img.putpixel((i, 7), FLOOR_GAP)
        img.putpixel((i, 15), FLOOR_GAP)
    for y in range(0, 7):
        img.putpixel((5, y), FLOOR_GAP)
    for y in range(8, 15):
        img.putpixel((11, y), FLOOR_GAP)
    return img


def furrowed(seed: int, base, furrow) -> Image.Image:
    rng = random.Random(seed)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, base, [shade(base, -8), shade(base, 10)], 0.2, rng)
    for y in (2, 6, 10, 14):
        for x in range(CELL):
            img.putpixel((x, y), furrow)
            img.putpixel((x, y - 1), shade(base, 14))
    return img


def dirt_cell(seed: int, base) -> Image.Image:
    rng = random.Random(seed)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, base, [shade(base, -14), shade(base, 12)], 0.25, rng)
    return img


def trench_cell() -> Image.Image:
    img = dirt_cell(21, DIRT_DARK)
    for x in range(CELL):
        img.putpixel((x, 0), OUTLINE)
        img.putpixel((x, 1), shade(DIRT_DARK, -30))
        img.putpixel((x, 2), shade(DIRT_DARK, -18))
    return img


def water_cell() -> Image.Image:
    rng = random.Random(31)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, WATER, [WATER_DARK], 0.12, rng)
    for (x0, y) in ((2, 3), (9, 7), (4, 12), (11, 13)):
        for x in range(x0, x0 + 4):
            img.putpixel((x % CELL, y), WATER_LIGHT)
    return img


def rock_cell() -> Image.Image:
    rng = random.Random(41)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, ROCK, [ROCK_DARK, ROCK_LIGHT], 0.25, rng)
    for (x, y) in ((3, 4), (4, 5), (5, 5), (6, 6), (10, 9), (11, 10), (11, 11), (12, 12), (7, 12), (8, 13)):
        img.putpixel((x, y), ROCK_DARK)
    for (x, y) in ((3, 3), (10, 8), (7, 11)):
        img.putpixel((x, y), ROCK_LIGHT)
    return img


def build_terrain() -> Image.Image:
    sheet = new(5 * CELL, 7 * CELL)
    blob = blob_cells()
    # Must match tile_atlas_map.gd's GRASS_EDGE/CORNER/CONCAVE_COORDS.
    layout = {
        "edge_N": (2, 4), "edge_S": (2, 0), "edge_E": (0, 2), "edge_W": (4, 2),
        "corner_NE": (1, 3), "corner_NW": (3, 3), "corner_SE": (1, 1), "corner_SW": (3, 1),
        "concave_NE": (1, 4), "concave_NW": (3, 4), "concave_SE": (1, 0), "concave_SW": (3, 0),
    }
    for name, (cx, cy) in layout.items():
        sheet.paste(blob[name], (cx * CELL, cy * CELL))
    row5 = [grass_cell(1), grass_cell(2, flowers=True), grass_cell(3), trench_cell(), floor_cell()]
    row6 = [
        furrowed(11, SOIL_TILLED, SOIL_FURROW),       # plowed soil
        furrowed(12, shade(SOIL_TILLED, -6), shade(SOIL_FURROW, -6)),  # planted base
        dirt_cell(13, DIRT),                          # hazard base
        dirt_cell(15, FOREST),                        # forest floor
    ]
    for i, cell in enumerate(row5):
        sheet.paste(cell, (i * CELL, 5 * CELL))
    for i, cell in enumerate(row6):
        sheet.paste(cell, (i * CELL, 6 * CELL))
    return sheet


# ---------------------------------------------------------------- walls
def wooden_wall() -> Image.Image:
    rng = random.Random(51)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, WOOD, [WOOD_LIGHT, shade(WOOD, -8)], 0.15, rng)
    for x in (0, 5, 10, 15):
        for y in range(CELL):
            img.putpixel((x, y), WOOD_DARK)
    for y in (0, 15):
        for x in range(CELL):
            img.putpixel((x, y), WOOD_DARK)
    for (x, y) in ((2, 4), (7, 10), (12, 6)):
        img.putpixel((x, y), WOOD_DARK)
    return img


def stone_wall() -> Image.Image:
    rng = random.Random(52)
    img = new(CELL, CELL)
    speckle(img, 0, 0, CELL, CELL, ROCK_LIGHT, [ROCK, shade(ROCK_LIGHT, 10)], 0.2, rng)
    for y in (0, 5, 10, 15):
        for x in range(CELL):
            img.putpixel((x, y), ROCK_DARK)
    for row, offset in ((0, 0), (1, 4), (2, 0)):
        for x in range(offset, CELL, 8):
            for y in range(row * 5, row * 5 + 5):
                img.putpixel((x, y), ROCK_DARK)
    return img


# ---------------------------------------------------------------- props
def chair() -> Image.Image:
    img = new(16, 24)
    rect(img, 4, 6, 11, 7, WOOD_DARK)         # back top rail
    rect(img, 4, 8, 5, 21, WOOD)               # back posts
    rect(img, 10, 8, 11, 21, WOOD)
    rect(img, 6, 10, 9, 10, WOOD_LIGHT)        # back slat
    rect(img, 3, 14, 12, 16, WOOD_LIGHT)       # seat
    rect(img, 3, 17, 12, 17, WOOD_DARK)
    rect(img, 3, 18, 4, 21, WOOD_DARK)         # front legs
    rect(img, 11, 18, 12, 21, WOOD_DARK)
    outline(img)
    return img


def table() -> Image.Image:
    img = new(16, 24)
    rect(img, 1, 10, 14, 14, WOOD_LIGHT)
    rect(img, 1, 15, 14, 16, WOOD_DARK)
    rect(img, 2, 17, 3, 22, WOOD_DARK)
    rect(img, 12, 17, 13, 22, WOOD_DARK)
    for x in range(2, 14, 4):
        img.putpixel((x, 12), WOOD)
    outline(img)
    return img


def bed() -> Image.Image:
    img = new(16, 24)
    rect(img, 1, 3, 14, 7, WOOD_DARK)          # headboard
    rect(img, 2, 8, 13, 22, WOOD)              # frame
    rect(img, 3, 8, 12, 11, CLOTH_LIGHT)       # pillow
    rect(img, 3, 12, 12, 21, CLOTH)            # blanket
    rect(img, 3, 12, 12, 12, shade(CLOTH, 30))
    outline(img)
    return img


def door() -> Image.Image:
    img = new(16, 24)
    rect(img, 1, 2, 14, 23, WOOD_DARK)         # frame
    rect(img, 3, 4, 12, 23, WOOD)              # leaf
    for x in (5, 8, 11):
        for y in range(4, 24):
            img.putpixel((x, y), shade(WOOD, -14))
    rect(img, 10, 13, 11, 14, METAL)           # handle
    outline(img)
    return img


def berry_bush() -> Image.Image:
    img = new(16, 24)
    ellipse(img, 8, 16.5, 7.5, 7, LEAF)
    ellipse(img, 6, 14, 3.5, 3, LEAF_LIGHT)
    rng = random.Random(61)
    for _ in range(18):
        x, y = rng.randrange(2, 14), rng.randrange(11, 23)
        if img.getpixel((x, y))[3]:
            img.putpixel((x, y), LEAF_DARK)
    for (x, y) in ((5, 16), (9, 13), (11, 18), (7, 20), (12, 14), (4, 19)):
        img.putpixel((x, y), BERRY)
    outline(img, max_y=23)
    return img


def sprout() -> Image.Image:
    img = new(16, 16)
    for cx in (4, 11):
        for cy in (5, 12):
            img.putpixel((cx, cy), LEAF_DARK)
            img.putpixel((cx, cy - 1), LEAF)
            img.putpixel((cx - 1, cy - 2), LEAF_LIGHT)
            img.putpixel((cx + 1, cy - 2), LEAF_LIGHT)
    return img


def tree() -> Image.Image:
    img = new(32, 48)
    rect(img, 14, 30, 17, 46, WOOD_DARK)
    rect(img, 15, 30, 16, 46, WOOD)
    rect(img, 12, 46, 19, 47, WOOD_DARK)       # root flare
    ellipse(img, 16, 18, 13, 14, LEAF)
    ellipse(img, 12, 13, 6, 5, LEAF_LIGHT)
    rng = random.Random(71)
    for _ in range(90):
        x, y = rng.randrange(3, 29), rng.randrange(4, 32)
        if img.getpixel((x, y)) in (LEAF, LEAF_LIGHT):
            img.putpixel((x, y), LEAF_DARK if y > 16 else LEAF)
    outline(img, max_y=47)
    return img


def stone_pile(seed: int, base, dark, light) -> Image.Image:
    img = new(32, 20)
    rng = random.Random(seed)
    for (cx, cy, rx, ry) in ((10, 13, 6, 4.5), (20, 12, 7, 5), (15, 8, 5, 4), (24, 15, 4, 3)):
        ellipse(img, cx, cy, rx, ry, base)
        for _ in range(8):
            x, y = int(cx + rng.uniform(-rx + 1, rx - 1)), int(cy + rng.uniform(-ry + 1, ry - 1))
            img.putpixel((x, y), dark)
        img.putpixel((int(cx - rx / 2), int(cy - ry / 2)), light)
    outline(img)
    return img


def log_pile() -> Image.Image:
    img = new(32, 20)
    for (y0, x0, x1) in ((12, 4, 27), (7, 7, 24)):
        rect(img, x0, y0, x1, y0 + 4, WOOD)
        rect(img, x0, y0, x1, y0, WOOD_LIGHT)
        rect(img, x1 - 2, y0, x1, y0 + 4, WOOD_LIGHT)   # cut end
        img.putpixel((x1 - 1, y0 + 2), WOOD_DARK)
    outline(img)
    return img


def resources() -> Image.Image:
    sheet = new(96, 20)
    sheet.paste(stone_pile(81, COAL, OUTLINE, COAL_LIGHT), (0, 0))      # hazard cluster
    sheet.paste(stone_pile(82, ROCK_LIGHT, ROCK_DARK, hexc("b5b0a8")), (32, 0))  # stone
    sheet.paste(log_pile(), (64, 0))                                     # wood
    return sheet


def workbench(w: int, h: int, vertical: bool) -> Image.Image:
    img = new(w, h)
    if not vertical:
        rect(img, 1, 11, w - 2, 17, WOOD_LIGHT)
        rect(img, 1, 18, w - 2, 19, WOOD_DARK)
        rect(img, 2, 20, 4, 27, WOOD_DARK)
        rect(img, w - 5, 20, w - 3, 27, WOOD_DARK)
        rect(img, 6, 22, w - 7, 23, WOOD)             # stretcher
        rect(img, 5, 7, 9, 10, METAL)                 # vice
        rect(img, 18, 9, 26, 10, METAL_DARK)          # saw blade
        rect(img, 26, 8, 28, 10, WOOD_DARK)
    else:
        rect(img, 1, 10, w - 2, 37, WOOD_LIGHT)
        rect(img, 1, 38, w - 2, 39, WOOD_DARK)
        rect(img, 2, 40, 4, 43, WOOD_DARK)
        rect(img, w - 5, 40, w - 3, 43, WOOD_DARK)
        rect(img, 4, 13, 8, 16, METAL)
        rect(img, 9, 24, 10, 33, METAL_DARK)
    outline(img)
    return img


def tools() -> Image.Image:
    """Two 16x16 icons: pick at (0,0) and axe at (1,0), each a head set across a haft."""
    sheet = new(32, 16)
    # Pick: a wide curved head over a thin haft.
    for x in range(2, 14):
        sheet.putpixel((x, 3), METAL)
    for x in range(1, 15):
        sheet.putpixel((x, 4), METAL_DARK if x in (1, 14) else METAL)
    for x in range(4, 12):
        sheet.putpixel((x, 5), METAL_DARK)
    rect(sheet, 6, 6, 9, 6, WOOD_DARK)            # collar
    rect(sheet, 7, 7, 8, 14, WOOD)                # haft
    # Axe: a blade to one side of a thin haft.
    ox = 16
    rect(sheet, ox + 3, 2, ox + 9, 6, METAL)
    rect(sheet, ox + 3, 2, ox + 3, 6, METAL_DARK)
    rect(sheet, ox + 8, 2, ox + 12, 5, WOOD_DARK)
    rect(sheet, ox + 9, 6, ox + 10, 14, WOOD)
    return sheet


# ---------------------------------------------------------------- colonist
HAIR = hexc("5b3a1e")
SKIN = hexc("e0b48a")
EYE = hexc("2a1d14")
SHIRT = hexc("3d6fb6")
SHIRT_DARK = hexc("2f5791")
BELT = hexc("4a3222")
PANTS = hexc("5a4a3a")
SHOE = hexc("2e241c")
BOX = hexc("a8763f")

PAL = {"H": HAIR, "S": SKIN, "E": EYE, "C": SHIRT, "D": SHIRT_DARK, "B": BELT,
       "P": PANTS, "F": SHOE, "W": BOX, "w": WOOD_DARK, "M": METAL, ".": None}

HEAD_DOWN = ["...HHHH...", "..HHHHHH..", "..HSSSSH..", "..SESSES..", "..SSSSSS..", "...SSSS..."]
HEAD_UP = ["...HHHH...", "..HHHHHH..", "..HHHHHH..", "..HHHHHH..", "..HHHHHH..", "...SSSS..."]
HEAD_SIDE = ["...HHHH...", "..HHHHHH..", "..HHHSSS..", "..HHSSES..", "...SSSSS..", "....SSS..."]
TORSO_FRONT = ["..CCCCCC..", "..CCCCCC..", "..CCCCCC..", "..CDDDDC..", "..BBBBBB.."]
TORSO_SIDE = ["...CCCC...", "...CCCC...", "...CCCC...", "...CDDC...", "...BBBB..."]


def paint(img, rows, ox, oy):
    for dy, row in enumerate(rows):
        for dx, ch in enumerate(row):
            color = PAL.get(ch)
            if color is not None:
                img.putpixel((ox + dx, oy + dy), color)


def colonist_frame(facing: str, leg_phase: int, bob: int, carrying: bool, tool_angle: int | None) -> Image.Image:
    """One 64x64 frame; feet rest on y=47, the figure is centred on x=32."""
    img = new(64, 64)
    ox = 27                        # 10-px-wide templates centred on x=32
    top = 32 + bob                 # head top; 6 head + 5 torso + 4 legs + 1 shoe
    head = {"down": HEAD_DOWN, "up": HEAD_UP, "side": HEAD_SIDE}[facing]
    torso = TORSO_SIDE if facing == "side" else TORSO_FRONT
    paint(img, head, ox, top)
    paint(img, torso, ox, top + 6)
    leg_top = top + 11
    # Legs: 4 rows of pants + 1 row of shoes, the lifted leg 1px shorter.
    if facing == "side":
        spread = abs(leg_phase)
        xs = (ox + 3, ox + 6) if spread == 0 else (ox + 2, ox + 7)
        for x in xs:
            rect(img, x, leg_top, x + (1 if spread == 0 else 0), 46, PANTS)
            rect(img, x, 47, x + 1, 47, SHOE)
    else:
        for i, x in enumerate((ox + 2, ox + 6)):
            lifted = (leg_phase == 1 and i == 0) or (leg_phase == -1 and i == 1)
            bottom = 46 if not lifted else 45
            rect(img, x, leg_top, x + 1, bottom, PANTS)
            rect(img, x, bottom + 1, x + 1, bottom + 1, SHOE)
    # Arms.
    arm_y = top + 6
    if carrying:
        if facing == "side":
            rect(img, ox + 7, arm_y + 1, ox + 11, arm_y + 4, BOX)
            rect(img, ox + 7, arm_y + 1, ox + 11, arm_y + 1, shade(BOX, 25))
            rect(img, ox + 6, arm_y + 2, ox + 6, arm_y + 3, SKIN)
        elif facing == "down":
            rect(img, ox + 2, arm_y + 1, ox + 7, arm_y + 4, BOX)
            rect(img, ox + 2, arm_y + 1, ox + 7, arm_y + 1, shade(BOX, 25))
            rect(img, ox + 1, arm_y + 2, ox + 1, arm_y + 3, SKIN)
            rect(img, ox + 8, arm_y + 2, ox + 8, arm_y + 3, SKIN)
        else:
            rect(img, ox + 2, arm_y - 2, ox + 7, arm_y, BOX)   # load over the shoulders
            rect(img, ox + 1, arm_y - 1, ox + 1, arm_y + 1, SKIN)
            rect(img, ox + 8, arm_y - 1, ox + 8, arm_y + 1, SKIN)
    else:
        swing = leg_phase
        if facing == "side":
            rect(img, ox + 4 + swing, arm_y + 1, ox + 4 + swing, arm_y + 3, SHIRT_DARK)
            img.putpixel((ox + 4 + swing, arm_y + 4), SKIN)
        else:
            for x, s in ((ox + 1, swing), (ox + 8, -swing)):
                rect(img, x, arm_y + max(0, s), x, arm_y + 3 + max(0, s), SHIRT_DARK)
                img.putpixel((x, arm_y + 4 + max(0, s)), SKIN)
    if tool_angle is not None:
        # A hammer swung by the right hand: 0 = raised, 3 = striking.
        hx, hy = ox + 9, arm_y + 2
        dx, dy = [(1, -4), (3, -3), (4, -1), (4, 2)][tool_angle]
        steps = 5
        for s in range(steps + 1):
            img.putpixel((hx + round(dx * s / steps), hy + round(dy * s / steps)), WOOD_DARK)
        tx, ty = hx + dx, hy + dy
        rect(img, tx - 1, ty - 1, tx + 1, ty, METAL)
        img.putpixel((hx, hy), SKIN)
    outline(img, max_y=47)
    return img


def sheet(frames: list[Image.Image]) -> Image.Image:
    out = new(64 * len(frames), 64)
    for i, frame in enumerate(frames):
        out.paste(frame, (64 * i, 0))
    return out


def build_colonist() -> dict[str, Image.Image]:
    sheets = {}
    walk_phases = [0, 1, 1, 0, -1, -1]
    walk_bob = [0, -1, 0, 0, -1, 0]
    idle_bob = [0, 0, 1, 0]
    for facing in ("down", "up", "side"):
        for carrying in (False, True):
            prefix = "carry_" if carrying else ""
            sheets[f"{prefix}walk_{facing}"] = sheet([
                colonist_frame(facing, walk_phases[i], walk_bob[i], carrying, None) for i in range(6)])
            sheets[f"{prefix}idle_{facing}"] = sheet([
                colonist_frame(facing, 0, idle_bob[i], carrying, None) for i in range(4)])
        swing = [0, 1, 2, 3, 3, 2, 1, 0]
        sheets[f"build_{facing}"] = sheet([
            colonist_frame(facing, 0, 1 if swing[i] == 3 else 0, False, swing[i]) for i in range(8)])
    return sheets


# ---------------------------------------------------------------- main
def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "colonist").mkdir(exist_ok=True)
    outputs = {
        "terrain.png": build_terrain(),
        "water.png": water_cell(),
        "rock.png": rock_cell(),
        "wooden_wall.png": wooden_wall(),
        "stone_wall.png": stone_wall(),
        "chair.png": chair(),
        "table.png": table(),
        "bed.png": bed(),
        "door.png": door(),
        "berry_bush.png": berry_bush(),
        "sprout.png": sprout(),
        "tree.png": tree(),
        "resources.png": resources(),
        "workbench.png": workbench(32, 28, vertical=False),
        "workbench_vertical.png": workbench(16, 44, vertical=True),
        "tools.png": tools(),
    }
    for name, image in build_colonist().items():
        outputs[f"colonist/{name}.png"] = image
    for name, image in outputs.items():
        image.save(OUT / name, optimize=True)
    print(f"generated {len(outputs)} images in {OUT}")


if __name__ == "__main__":
    main()
