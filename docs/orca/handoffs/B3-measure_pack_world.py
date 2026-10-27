"""Writes game/data/sprite_frames/world_pack.json from the real Pixel Crawler sheets.

B3: terrain, props, trees, walls, workbench, berries, ground items, tools and the three
non-colonist actors. Which pack sprite stands for which kind is a choice, written once in
SPEC/ACTORS below as a search window on a sheet; every number in the JSON (sheet size,
the sprite's alpha bounding box inside its window, frame count, per-frame boxes, feet
row) is measured from the PNGs, never typed by hand. The script also refuses a choice
that breaks the art rules (docs/art/style.md): opaque terrain, the grass blob's
directions, the owner's "props <= 1 tile except trees" ceilings.

    python -I docs/orca/handoffs/B3-measure_pack_world.py [pack_root] [--check]

pack_root defaults to $DEEPHOLM_PACK, then C:\\dev\\assets\\pixel-crawler. With --check the
script rewrites nothing and exits 1 if the committed JSON differs from the measurement.
"""
import json
import os
import sys

from PIL import Image

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(REPO, "game", "data", "sprite_frames", "world_pack.json")

FLOORS = "Environment/Tilesets/Floors_Tiles.png"
WATER = "Environment/Tilesets/Water_tiles.png"
WALLS = "Environment/Tilesets/Wall_Tiles.png"
FURNITURE = "Environment/Props/Static/Furniture.png"
FARM = "Environment/Props/Static/Farm.png"
ROCKS = "Environment/Props/Static/Rocks.png"
RESOURCES = "Environment/Props/Static/Resources.png"
TREE = "Environment/Props/Static/Trees/Model_01/Size_02.png"
TREE_SMALL = "Environment/Props/Static/Trees/Model_03/Size_02.png"
WORKBENCH = "Environment/Structures/Stations/Workbench/Workbench.png"
WEAPONS = "Weapons/Wood/Wood.png"


def cell(col, row):
    """The 16x16 grid window (col, row) of a tile sheet."""
    return [col * 16, row * 16, 16, 16]


# Ceilings (owner, 2026-10-25: "props <= 1 casilla salvo arboles"). Trees are exempt from
# the one-tile rule; their pack ceiling is two tiles wide by four tall (style.md).
CEILING_1X1 = (16, 24)
CEILING_2X1 = (32, 28)
CEILING_TREE = (32, 64)

# One entry per TileSet source the pack replaces (ids and coords: tile_atlas_map.gd).
# kind: "fill"   -- opaque 16x16 terrain/wall cell, window taken as is;
#       "blob"   -- grass overlay cell, window taken as is, direction checked from alpha;
#       "sprite" -- the alpha bounding box inside the window, bottom-centred in the cell.
# grounded_on: footprint height the sprite stands on (texture_origin, style.md), or None
# for clutter/icons centred on their tile (the placeholder's own rule for that source).
SPEC = [
    {"source_id": 0, "name": "terrain", "kind": "fill", "tiles": [
        # The pack's grass blob uses the placeholder's 5x5 layout cell for cell.
        ((2, 4), "grass edge N", FLOORS, cell(2, 4), "blob"),
        ((2, 0), "grass edge S", FLOORS, cell(2, 0), "blob"),
        ((0, 2), "grass edge E", FLOORS, cell(0, 2), "blob"),
        ((4, 2), "grass edge W", FLOORS, cell(4, 2), "blob"),
        ((1, 3), "grass corner NE", FLOORS, cell(1, 3), "blob"),
        ((3, 3), "grass corner NW", FLOORS, cell(3, 3), "blob"),
        ((1, 1), "grass corner SE", FLOORS, cell(1, 1), "blob"),
        ((3, 1), "grass corner SW", FLOORS, cell(3, 1), "blob"),
        ((1, 4), "grass concave NE", FLOORS, cell(1, 4), "blob"),
        ((3, 4), "grass concave NW", FLOORS, cell(3, 4), "blob"),
        ((1, 0), "grass concave SE", FLOORS, cell(1, 0), "blob"),
        ((3, 0), "grass concave SW", FLOORS, cell(3, 0), "blob"),
        ((0, 5), "grass variant 0", FLOORS, cell(1, 10), "fill"),
        ((1, 5), "grass variant 1", FLOORS, cell(2, 10), "fill"),
        ((2, 5), "grass variant 2", FLOORS, cell(3, 10), "fill"),
        ((3, 5), "trench (dug pit floor)", WALLS, cell(2, 22), "fill"),
        ((4, 5), "built floor (stone bricks)", FLOORS, cell(17, 2), "fill"),
        ((0, 6), "plowed soil (dirt)", FLOORS, cell(11, 10), "fill"),
        ((1, 6), "planted base (dirt)", FLOORS, cell(12, 11), "fill"),
        ((2, 6), "hazard base (cobbles)", FLOORS, cell(7, 10), "fill"),
        ((3, 6), "forest floor (grass)", FLOORS, cell(2, 11), "fill"),
    ]},
    {"source_id": 1, "name": "water", "kind": "fill", "tiles": [
        ((0, 0), "water", WATER, cell(2, 7), "fill")]},
    {"source_id": 2, "name": "rock", "kind": "fill", "tiles": [
        ((0, 0), "rock (grey cliff top)", WALLS, cell(8, 3), "fill")]},
    {"source_id": 3, "name": "wooden_wall", "kind": "fill", "tiles": [
        ((0, 0), "wooden wall (planks)", WALLS, cell(1, 16), "fill")]},
    {"source_id": 15, "name": "stone_wall", "kind": "fill", "tiles": [
        ((0, 0), "stone wall (stone courses)", WALLS, cell(7, 16), "fill")]},
    {"source_id": 4, "name": "chair", "kind": "sprite", "grounded_on": 16, "ceiling": CEILING_1X1, "tiles": [
        ((0, 0), "chair", FURNITURE, [112, 486, 16, 28], "sprite")]},
    {"source_id": 5, "name": "table", "kind": "sprite", "grounded_on": 16, "ceiling": CEILING_1X1, "tiles": [
        ((0, 0), "table", FURNITURE, [112, 512, 16, 18], "sprite")]},
    {"source_id": 8, "name": "berry_bush", "kind": "sprite", "grounded_on": 16, "ceiling": CEILING_1X1, "tiles": [
        ((0, 0), "berry bush (red-fruit crop)", FARM, [80, 44, 16, 20], "sprite")]},
    {"source_id": 9, "name": "sprout", "kind": "sprite", "grounded_on": None, "ceiling": (16, 16), "tiles": [
        ((0, 0), "sprout (seedling)", FARM, [48, 20, 16, 12], "sprite")]},
    {"source_id": 10, "name": "tree", "kind": "sprite", "grounded_on": 16, "ceiling": CEILING_TREE, "tiles": [
        # Three sizes; map_view.gd picks one per tile by hash(seed, x, y).
        ((0, 0), "tree small", TREE_SMALL, [50, 52, 14, 28], "sprite"),
        ((1, 0), "tree medium", TREE_SMALL, [32, 48, 16, 32], "sprite"),
        ((2, 0), "tree large", TREE, [32, 0, 32, 64], "sprite"),
    ]},
    {"source_id": 11, "name": "resources", "kind": "sprite", "grounded_on": None, "ceiling": (32, 32), "tiles": [
        ((0, 0), "hazard (crystal)", ROCKS, [144, 276, 16, 30], "sprite"),
        ((1, 0), "stone", ROCKS, [176, 16, 16, 16], "sprite"),
        ((2, 0), "wood (log)", RESOURCES, [32, 66, 32, 10], "sprite"),
    ]},
    {"source_id": 12, "name": "workbench", "kind": "sprite", "grounded_on": 16, "ceiling": CEILING_2X1, "tiles": [
        ((0, 0), "workbench (horizontal)", WORKBENCH, [0, 80, 32, 32], "sprite")]},
    {"source_id": 14, "name": "tools", "kind": "sprite", "grounded_on": None, "ceiling": (16, 32), "tiles": [
        ((0, 0), "pick (wooden pickaxe)", WEAPONS, [0, 48, 16, 32], "sprite"),
        ((1, 0), "axe (wooden axe)", WEAPONS, [32, 48, 16, 32], "sprite"),
    ]},
]

# Kinds that keep their generated placeholder on purpose, with the reason. tile kinds,
# objects, actors and items in game/content must each be in the pack or here
# (test_world_pack.gd).
PLACEHOLDER = {
    "objects": {
        "bed": "every pack bed is about 2 tiles tall (Interior_Props_01, Furniture); owner rule: props <= 1 tile",
        "door": "the pack's doors are about 18x38 px (Structures/Buildings/Props); owner rule: props <= 1 tile",
        "workbench_vertical": "the pack has no vertical workbench; rotating art is not allowed",
        "test_multi_source_crate": "test-only content kind, never placed by the game; no art at all",
        "test_footprint_crate": "test-only content kind, never placed by the game; no art at all",
    },
    "items": {
        "seed": "no ground icon today (not in ITEM_ATLAS_MAP)",
        "sand": "no ground icon today (not in ITEM_ATLAS_MAP)",
        "gold_coin": "no ground icon today (not in ITEM_ATLAS_MAP)",
        "flint": "no ground icon today (not in ITEM_ATLAS_MAP)",
        "coal": "no ground icon today (not in ITEM_ATLAS_MAP)",
    },
}

# Non-colonist actors (owner picks): art key -> animation -> (sheet, fps). "raider" is a
# wolf-def actor of faction "raiders" (content/incidents.json raider_incursion).
ACTORS = {
    "wolf": {
        "idle": ("Entities/Mobs/Wolf/Idle/Idle_Side-Sheet.png", 2.0),
        "walk": ("Entities/Mobs/Wolf/Walk/Walk_Side-Sheet.png", 3.0),
    },
    "raider": {
        "idle": ("Entities/Mobs/Orc Crew/Orc/Idle/Idle-Sheet.png", 2.0),
        "walk": ("Entities/Mobs/Orc Crew/Orc/Run/Run-Sheet.png", 3.0),
    },
    "trader": {
        "idle": ("Entities/Npc's/Citizen_F/Peasant_A/Idle/Idle-Sheet.png", 2.0),
        "walk": ("Entities/Npc's/Citizen_F/Peasant_A/Walk/Walk-Sheet.png", 3.0),
    },
}


def fail(message):
    raise SystemExit("B3-measure: " + message)


def opaque(image):
    return image.getchannel("A").getextrema()[0] == 255


def check_blob(label, image):
    """The blob cell's transparency is on the side/corner its label names."""
    a = image.getchannel("A").load()
    probes = {"N": (8, 0), "S": (8, 15), "E": (15, 8), "W": (0, 8),
              "NE": (15, 0), "NW": (0, 0), "SE": (15, 15), "SW": (0, 15)}
    opposite = {"N": "S", "S": "N", "E": "W", "W": "E", "NE": "SW", "NW": "SE", "SE": "NW", "SW": "NE"}
    shape, direction = label.split()[1], label.split()[2]
    if a[probes[direction]] != 0:
        fail("%s: no transparency at %s" % (label, direction))
    if a[probes[opposite[direction]]] == 0:
        fail("%s: not opaque at %s" % (label, opposite[direction]))
    if shape == "concave":
        for side in direction:
            if a[probes[side]] == 0:
                fail("%s: concave cell open on side %s" % (label, side))


def measure_tiles(root):
    sheets = {}
    sources = []
    for source in SPEC:
        tiles = []
        for coords, label, sheet, window, kind in source["tiles"]:
            if sheet not in sheets:
                sheets[sheet] = Image.open(os.path.join(root, sheet)).convert("RGBA")
            image = sheets[sheet]
            x, y, w, h = window
            crop = image.crop((x, y, x + w, y + h))
            if kind == "fill":
                if not opaque(crop):
                    fail("%s: %s window %s is not fully opaque" % (label, sheet, window))
                rect = window
            elif kind == "blob":
                check_blob(label, crop)
                rect = window
            else:
                box = crop.getchannel("A").getbbox()
                if box is None:
                    fail("%s: empty window %s on %s" % (label, window, sheet))
                rect = [x + box[0], y + box[1], box[2] - box[0], box[3] - box[1]]
                ceiling = source["ceiling"]
                if rect[2] > ceiling[0] or rect[3] > ceiling[1]:
                    fail("%s: %dx%d exceeds the %dx%d ceiling" % (label, rect[2], rect[3], ceiling[0], ceiling[1]))
            tiles.append({"coords": list(coords), "label": label, "sheet": sheet,
                          "sheet_size": list(image.size), "rect": rect})
        if source["kind"] == "fill":
            cell_size = [16, 16]
        else:
            cell_size = [max(t["rect"][2] for t in tiles), max(t["rect"][3] for t in tiles)]
        entry = {"source_id": source["source_id"], "name": source["name"], "cell_size": cell_size,
                 "grounded_on": source.get("grounded_on"), "tiles": tiles}
        sources.append(entry)
    return sources


def measure_actors(root):
    actors = {}
    for key, animations in ACTORS.items():
        entry = {}
        for name, (sheet, fps) in animations.items():
            image = Image.open(os.path.join(root, sheet)).convert("RGBA")
            width, height = image.size
            if width % height != 0:
                fail("%s: %dx%d is not a strip of square frames" % (sheet, width, height))
            boxes = []
            for index in range(width // height):
                box = image.crop((index * height, 0, (index + 1) * height, height)).getchannel("A").getbbox()
                boxes.append(list(box))
            entry[name] = {"sheet": sheet, "sheet_size": [width, height], "frames": width // height,
                           "fps": fps, "feet_y": max(b[3] for b in boxes) - 1, "alpha_bboxes": boxes}
        actors[key] = {"animations": entry}
    return actors


def measure(root):
    return {
        "source": "Pixel Crawler by Anokolisa; local pack, never committed (tools/sync_pack_assets.ps1)",
        "measured_by": "docs/orca/handoffs/B3-measure_pack_world.py",
        "layout": "each source's texture is composed at runtime by pack_assets.gd: a grid of cell_size cells at the "
                  "placeholder's coords, each rect bottom-centred in its cell; texture_origin.y = (cell height - "
                  "grounded_on) / 2 when grounded_on is set",
        "sources": measure_tiles(root),
        "actors": measure_actors(root),
        "side_faces": "right",
        "placeholder": PLACEHOLDER,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else os.environ.get("DEEPHOLM_PACK") or r"C:\dev\assets\pixel-crawler"
    text = json.dumps(measure(root), indent=1) + "\n"
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as handle:
            if handle.read() != text:
                print("world_pack.json differs from the sheets; re-run without --check")
                sys.exit(1)
        print("world_pack.json matches the sheets")
        return
    with open(OUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
