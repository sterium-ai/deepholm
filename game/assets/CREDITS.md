# Asset credits

> **In short:** Every image stored in this repository is simple placeholder art drawn by a script, so it is all original and covered by the same licence as the code. When the owner's copy of the Pixel Crawler pack by Anokolisa is present, the game draws its colonists with that pack instead; those files are never stored here.

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

## Pixel Crawler pack (not in this repository)

Colonist sprites, when available, come from **Pixel Crawler** by
**Anokolisa** (https://www.patreon.com/Anokolisa), used under the pack's
terms: free for commercial projects, not to be sold or redistributed as
assets. For that reason none of its files are committed: `game/assets/pack/`
is git-ignored and filled locally by `tools/sync_pack_assets.ps1` from the
owner's licensed copy. Credit is not required by the terms but is given
here gladly.

| Local path (git-ignored) | What it is | Author | Licence |
| --- | --- | --- | --- |
| `pack/Entities/Characters/Body_A/Animations/**` | Colonist idle, walk, carry, Slice (chop) and Crush (mine, dig, build) sheets, 64x64 frames, feet on y = 47 (list: `game/data/sprite_frames/pack_manifest.json`) | Anokolisa | Pixel Crawler terms (`Terms.txt` in the pack) |

Fonts: the viewer uses Godot's built-in default font (part of the engine, MIT).
