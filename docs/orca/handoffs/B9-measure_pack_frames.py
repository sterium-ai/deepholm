"""B9: rewrites game/data/sprite_frames/colonist_pack.json from the Pixel Crawler sheets.

Runs B2-measure_pack_frames.py's measurement unchanged, then adds:
  * plant_down/up/side: the pack has no planting strip; Collect_Base (kneel and reach
    to the ground) is the closest stand-in (owner note: pack strips only, no new art).
  * "tool_tip" on every work animation (chop/mine/dig/build): {"frame", "at": [x, y]},
    the frame pixel of the tool's tip on the impact frame. The impact frame is 3 for
    both Slice_Base and Crush_Base (the strip's lowest/farthest reach). "at" is the
    centroid of the extreme opaque pixels in the facing direction (largest x for side,
    which faces right; largest y for down; smallest y for up). On Crush_Up's impact
    frame the head hides the tool, so its "at" is the body's top edge there: the
    viewer only uses it to face and nudge the worker (colonist_sprites.gd).

Usage: python docs/orca/handoffs/B9-measure_pack_frames.py [pack_root] [--check]
"""
import importlib.util
import json
import os
import re
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("b2", os.path.join(HERE, "B2-measure_pack_frames.py"))
b2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b2)

IMPACT_FRAME = 3
WORK_PREFIXES = ("chop", "mine", "dig", "build")
PLANT = ("Collect_Base", "Collect", 6.0)


def strip_entry(root, sheet, fps):
    image = Image.open(os.path.join(root, sheet)).convert("RGBA")
    width, height = image.size
    boxes = [list(image.crop((i * height, 0, (i + 1) * height, height)).getchannel("A").getbbox())
             for i in range(width // height)]
    return {"sheet": sheet, "sheet_size": [width, height], "frames": width // height, "fps": fps,
            "alpha_bboxes": boxes}


def tool_tip(root, entry, facing):
    image = Image.open(os.path.join(root, entry["sheet"])).convert("RGBA")
    size = entry["sheet_size"][1]
    frame = image.crop((IMPACT_FRAME * size, 0, (IMPACT_FRAME + 1) * size, size))
    opaque = [(x, y) for y in range(size) for x in range(size) if frame.getpixel((x, y))[3] > 0]
    if facing == "side":
        edge = max(p[0] for p in opaque)
        points = [p for p in opaque if p[0] == edge]
    elif facing == "down":
        edge = max(p[1] for p in opaque)
        points = [p for p in opaque if p[1] == edge]
    else:
        edge = min(p[1] for p in opaque)
        points = [p for p in opaque if p[1] == edge]
    at = [round(sum(p[0] for p in points) / len(points)), round(sum(p[1] for p in points) / len(points))]
    return {"frame": IMPACT_FRAME, "at": at}


def measure(root):
    data = b2.measure(root)
    data["measured_by"] = "docs/orca/handoffs/B9-measure_pack_frames.py (extends B2-measure_pack_frames.py)"
    animations = data["animations"]
    folder, stem, fps = PLANT
    for facing, pack_facing in b2.FACINGS.items():
        sheet = "%s%s/%s_%s-Sheet.png" % (b2.BODY, folder, stem, pack_facing)
        animations["plant_%s" % facing] = strip_entry(root, sheet, fps)
    for name, entry in animations.items():
        prefix, facing = name.rsplit("_", 1)
        if prefix in WORK_PREFIXES:
            entry["tool_tip"] = tool_tip(root, entry, facing)
    return data


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else os.environ.get("DEEPHOLM_PACK") or r"C:\dev\assets\pixel-crawler"
    text = json.dumps(measure(root), indent=1) + "\n"
    text = re.sub(r"\[\s+([-\d.,\s]+?)\s+\]", lambda m: "[" + " ".join(m.group(1).split()) + "]", text)
    if "--check" in sys.argv:
        with open(b2.OUT, encoding="utf-8") as handle:
            same = handle.read() == text
        print("colonist_pack.json matches the sheets" if same else "colonist_pack.json DIFFERS from the sheets")
        sys.exit(0 if same else 1)
    with open(b2.OUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("wrote", b2.OUT)


if __name__ == "__main__":
    main()
