# Asset credits

All art currently shipped in this repository is **original placeholder pixel
art generated from code** by [`tools/generate_placeholder_art.py`](../../tools/generate_placeholder_art.py).
No external image packs or AI-image-generator outputs are included.

| Path | What it is | Author | Licence |
| --- | --- | --- | --- |
| `generated/terrain.png` | 16 px terrain sheet: 12-cell grass shoreline overlay, 3 grass variants, trench, floor, plowed soil, planted, hazard ground, forest floor | Sterium AI (procedural) | MIT, same as the code |
| `generated/water.png`, `generated/rock.png` | Opaque 16 px base cells | Sterium AI (procedural) | MIT |
| `generated/wooden_wall.png`, `generated/stone_wall.png` | 16 px wall cells | Sterium AI (procedural) | MIT |
| `generated/chair.png`, `table.png`, `bed.png`, `door.png`, `berry_bush.png` | 16x24 props, grounded on their tile | Sterium AI (procedural) | MIT |
| `generated/tree.png`, `generated/sprout.png` | Tree canopy (32x48) and crop sprout decor | Sterium AI (procedural) | MIT |
| `generated/workbench.png`, `generated/workbench_vertical.png` | 2x1 and 1x2 workbench sprites | Sterium AI (procedural) | MIT |
| `generated/resources.png` | Hazard cluster, stone and wood icons (32x20 cells) | Sterium AI (procedural) | MIT |
| `generated/tools.png` | Pick and axe icons (16x16) | Sterium AI (procedural) | MIT |
| `generated/colonist/*.png` | Colonist walk/idle/carry/build strips, 64x64 frames, feet on y = 47 | Sterium AI (procedural) | MIT |

Regenerating the art and the Godot resources that reference it:

```text
python tools/generate_placeholder_art.py
godot --headless --path game --import
godot --headless --path game --script res://scripts/tools/build_terrain_tileset.gd
godot --headless --path game --script res://scripts/tools/build_colonist_frames.gd
```

Fonts: the viewer uses Godot's built-in default font (part of the engine, MIT).
