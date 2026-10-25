"""Writes game/data/sprite_frames/colonist_pack.json from the real Pixel Crawler sheets.

Every number in the JSON is read from the PNGs (sheet size, frame count, per-frame alpha
bounding box, feet row), never typed by hand. Re-run it after a pack update and diff the
JSON.

    python -I docs/orca/handoffs/B2-measure_pack_frames.py [pack_root] [--check]

pack_root defaults to $DEEPHOLM_PACK, then C:\\dev\\assets\\pixel-crawler. With --check the
script rewrites nothing and exits 1 if the committed JSON differs from the measurement.
"""
import json
import os
import re
import sys

from PIL import Image

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(REPO, "game", "data", "sprite_frames", "colonist_pack.json")
BODY = "Entities/Characters/Body_A/Animations/"
FACINGS = {"down": "Down", "up": "Up", "side": "Side"}

# viewer animation prefix -> (pack folder, pack file prefix, fps). The fps values are
# the placeholder's (docs/art/style.md): walk 3.0, idle 2.0, work 6.0.
ANIMATIONS = {
    "idle": ("Idle_Base", "Idle", 2.0),
    "walk": ("Walk_Base", "Walk", 3.0),
    "carry_idle": ("Carry_Idle", "Carry_Idle", 2.0),
    "carry_walk": ("Carry_Walk", "Carry_Walk", 3.0),
    "chop": ("Slice_Base", "Slice", 6.0),
    "mine": ("Crush_Base", "Crush", 6.0),
    "dig": ("Crush_Base", "Crush", 6.0),
    "build": ("Crush_Base", "Crush", 6.0),
}


def measure(root):
    animations = {}
    feet_rows = set()
    frame_size = None
    for prefix, (folder, stem, fps) in ANIMATIONS.items():
        for facing, pack_facing in FACINGS.items():
            sheet = "%s%s/%s_%s-Sheet.png" % (BODY, folder, stem, pack_facing)
            image = Image.open(os.path.join(root, sheet)).convert("RGBA")
            width, height = image.size
            if width % height != 0:
                raise SystemExit("%s: %dx%d is not a strip of square frames" % (sheet, width, height))
            frame_size = frame_size or height
            if height != frame_size:
                raise SystemExit("%s: frame height %d != %d" % (sheet, height, frame_size))
            boxes = []
            for index in range(width // height):
                box = image.crop((index * height, 0, (index + 1) * height, height)).getchannel("A").getbbox()
                boxes.append(list(box))
                feet_rows.add(box[3] - 1)
            animations["%s_%s" % (prefix, facing)] = {
                "sheet": sheet,
                "sheet_size": [width, height],
                "frames": width // height,
                "fps": fps,
                "alpha_bboxes": boxes,
            }
    idle_feet = {animations["idle_" + f]["alpha_bboxes"][0][3] - 1 for f in FACINGS}
    if len(idle_feet) != 1:
        raise SystemExit("idle feet rows differ between facings: %s" % sorted(idle_feet))
    return {
        "source": "Pixel Crawler by Anokolisa; local pack, never committed (tools/sync_pack_assets.ps1)",
        "measured_by": "docs/orca/handoffs/B2-measure_pack_frames.py",
        "frame_size": [frame_size, frame_size],
        "feet_y": idle_feet.pop(),
        "side_faces": "right",
        "animations": animations,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else os.environ.get("DEEPHOLM_PACK") or r"C:\dev\assets\pixel-crawler"
    text = json.dumps(measure(root), indent=1) + "\n"
    # One line per number list ([x0, y0, x1, y1], [w, h]) keeps the file readable.
    text = re.sub(r"\[\s+([-\d.,\s]+?)\s+\]", lambda m: "[" + " ".join(m.group(1).split()) + "]", text)
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as handle:
            same = handle.read() == text
        print("colonist_pack.json matches the sheets" if same else "colonist_pack.json DIFFERS from the sheets")
        sys.exit(0 if same else 1)
    with open(OUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
