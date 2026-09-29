# Deepholm pixel-art style contract

## Visual target (ADR 021)

The default map view is flat top-down pixel art: hard silhouettes, a thin
dark outline where a shape meets a contrasting background, no gradients, no
anti-aliasing. Tile size is **16 px**. Colonists use 64x64 px source frames
displayed at native 1.0 scale, grounded on their own feet line (see
"Colonist frames, timing and grounding" below).

## Source of the art: generated placeholders

All current art is **original, procedurally generated placeholder pixel
art**. Nothing is hand-painted and no external asset pack is used.

- `tools/generate_placeholder_art.py` (Python + Pillow) deterministically
  writes every PNG under `game/assets/generated/`. Re-running it with the
  same script produces the same pixels.
- `game/scripts/tools/build_terrain_tileset.gd` builds
  `game/data/tilesets/terrain_tileset.tres` from those PNGs through Godot's
  own `TileSet` API; the `.tres` is never hand-edited.
- `game/scripts/tools/build_colonist_frames.gd` builds
  `game/data/sprite_frames/colonist_frames.tres` (a `SpriteFrames`
  resource) the same way.

The placeholders are deliberately simple, but they follow every rule in
this file, so final art can replace them later by swapping PNGs of the same
size and cell layout without touching simulation or viewer logic.

### What the generator produces

| Sheet / sprite | Size | Notes |
| --- | --- | --- |
| Terrain sheet (`terrain.png`) | 16x16 cells | 12 directional grass "blob" overlay cells (4 edges, 4 convex corners, 4 concave corners), 3 plain grass variants, built floor, plowed soil, planted, trench, and opaque ground bases for hazard and forest floor (tree tiles) |
| Water, rock (`water.png`, `rock.png`) | 16x16 | opaque base cells; never change with neighbours |
| Chair, table, bed, door, berry bush | up to 16x24 | 1x1-footprint standing props, grounded on their tile |
| Workbench (horizontal, 2x1 footprint) | 32x28 | grounded on its two-tile footprint |
| Workbench (vertical, 1x2 footprint) | 16x44 | grounded on its two-tile footprint |
| Wooden wall, stone wall | 16x16 | fill one tile exactly |
| Tree | 32x48 | drawn as decor over a forest-floor base; footprint is the trunk tile |
| Crop sprout (`sprout.png`) | 16x16 | decor drawn over the planted base |
| Tool icons (`tools.png`: pick, axe) | 16x16 cells | drawn as 8-10 px ground icons and held-tool markers |
| Resource icons (`resources.png`: hazard cluster, stone, wood) | 32x20 cells | ground clutter and item icons |
| Colonist frames | 64x64 per frame | feet at local row 47; see below |

## Rules every sprite follows

- **16 px grid.** Terrain cells are exactly 16x16 with no margin or
  separation (`tile_atlas_map.gd`'s `ATLAS_CELL_SIZE` and
  `ATLAS_CELL_STRIDE`, `map_view.gd`'s `TILE_SIZE`).
- **Nearest filtering, no mipmaps.** Every layer and sprite uses
  `TEXTURE_FILTER_NEAREST`; imported textures disable mipmaps so pixels stay
  crisp at every zoom.
- **Hard edges.** No anti-aliasing, gradients or soft shadows; a 1 px dark
  outline where a shape meets a contrasting background.
- **Opaque terrain.** Every base terrain cell is fully opaque, so no cell can
  expose the viewport background. Transparency only appears in the grass
  overlay and in object/decor sprites.
- **Native size, never squashed.** Sprites are registered at their own
  pixel size; the viewer never stretches non-uniformly.
- **Grounded oversize props.** A sprite taller than its footprint sits with
  its bottom edge on the footprint's bottom edge and overhangs *behind*
  (upwards), never below.
- **Readable at a glance.** Each tile kind and object kind has its own
  distinct cell; no kind borrows another's art.

## Colonist frames, timing and grounding

Colonists use **64x64 px source frames**. `TILE_SIZE` stays **16 px**. The
art-mode `AnimatedSprite2D` renderer uses a **uniform 1.0 (native) scale**
on both axes; never stretch non-uniformly.

Each 64x64 frame carries a consistent empty margin around the silhouette,
and the character's feet sit at local pixel row **47**, not row 63. The
sprite is therefore **anchored at its feet**: the point `FRAME_FEET_Y` (47)
pixels down from the frame's top edge, horizontally centred, sits at the
bottom-centre of the occupied tile. For tile `(x, y)` that ground point is
`(x * 16 + 8, y * 16 + 16)`; see `colonist_sprites.gd`'s
`SPRITE_POSITION_OFFSET` for the derived offset. The visible silhouette is
taller than, and about as wide as, one 16 px tile.

This scale/anchor rule governs only the art-mode renderer. The flat-colour
diagnostic renderer (Toggle Art, `map_view.gd`'s `_draw()` when art is off)
keeps drawing its own inset square.

`colonist_frames.tres` has these looping animations:

- `walk_down`, `walk_up`, `walk_side`, `carry_walk_down`, `carry_walk_up`,
  `carry_walk_side`: six frames at **3.0 fps**. At x1,
  `move_ticks_per_tile` is 4 and `TickDriver.BASE_TICKS_PER_SECOND` is 2.0,
  so crossing a tile takes 4 / 2.0 = 2.0 seconds; six frames / 2.0 seconds
  = 3.0 fps.
- `idle_down`, `idle_up`, `idle_side`, `carry_idle_down`, `carry_idle_up`,
  `carry_idle_side`: four frames at **2.0 fps**, a calm two-second loop;
  idle has no movement tick constraint.
- `build_down`, `build_up`, `build_side`: eight frames at **6.0 fps**, played while a
  colonist works on a construction site facing that way. If a facing's
  build animation is missing, the renderer falls back to that facing's idle
  animation.

All frames have duration weight 1.0. A single `side` animation serves right
and left; the renderer flips it horizontally for left.

## Palette

The placeholder palette is small and muted. `tools/generate_placeholder_art.py`
is the single source of truth; its main entries are:

| Purpose | Base colour | Notes |
| --- | --- | --- |
| Prairie grass | `#5d9440` | dark `#4a7a33`, light `#77ad52`, shoreline rim `#3f682c` |
| Forest floor (tree tiles) | `#3f6b31` | |
| Water | `#3569a8` | light `#5b8fcf`, dark `#2a5288` |
| Rock | `#75716b` | dark `#59554f`, light `#8f8b84` |
| Built floor | `#a39c8c` | joints `#7d7669` |
| Dirt (hazard base) | `#8a6440` | dark `#6e4e31` (trench) |
| Plowed soil | `#6b4a2d` | furrows `#4f3520`; the planted base is a slightly darker variant |
| Wood (props, wooden wall) | `#9a6a3a` | dark `#6f4a26`, light `#b98a55` |
| Foliage | `#3f8a3a` | dark `#2d6a2c`, light `#5fae4c`; berries `#c8323c` |
| Outline | `#1d1611` | the 1 px dark outline on props and characters |

The flat colours in `map_view.gd`'s `TILE_COLORS` belong only to the
diagnostic (Toggle Art) view.

## Shoreline rule (two-layer grass blob)

Water and rock *tiles* always render their own plain, fully opaque cell,
regardless of neighbours. A boundary soil (prairie) tile — one with a water
or rock neighbour — is a two-layer composite:

1. its **base** `TileMapLayer` cell is set to that neighbour's own plain
   water/rock cell (the backing), and
2. the **grass overlay** layer (`map_view.gd`'s `_grass_overlay_layer`)
   draws one of the 12 directional grass blob cells on top, whose
   transparent pixels let the backing show through as an irregular bank.

Both layers are resolved together from the same neighbour selection
(`tile_atlas_map.gd`'s `grass_shore_selection()`), so they cannot disagree:

- one orthogonal side foreign → an **edge** cell (N/S/E/W), backed by that
  side's material;
- two *adjacent* sides foreign → a **convex corner** cell (NE/NW/SE/SW),
  backed by the higher-priority side's material (N > E > S > W);
- no orthogonal side but a *diagonal* neighbour foreign → a **concave
  corner** cell, backed by that diagonal's material;
- no foreign neighbour → no overlay; the base is a plain grass variant.

The blob has 12 directional cells, not a full 47-tile set, so two opposite
sides (a channel), three sides (a cap) and four sides (isolated) resolve to
documented approximations using the highest-priority edge/corner cell
(ADR 021). `test_grass_shore_bitmask.gd` checks every configuration against
literal expected coordinates.

`map_view.gd`'s incremental refresh re-resolves a dirty cell's 8
neighbours (diagonals included, since concave corners depend on them) and
both the base backing and the overlay of each affected soil neighbour.

## Prairie variation and grid

- **Prairie variation:** one of 3 grass fill cells, chosen by
  `hash(seed, x, y)` (`map_view.gd`'s `_grass_variant_coords`) — a pure
  function of the map, never a running frame count, so it is stable across
  pan, zoom, save and load.
- No grid line is drawn per tile in either mode; the local grid only appears
  on hover or designation (`map_view.gd`'s `_preview_tiles`,
  `designation_overlay.gd`).

## Oversize sprite grounding

Godot's `TileMapLayer` centres a tile texture larger than one cell on both
axes when `texture_origin` is `(0, 0)`. A standing prop therefore only needs
its `texture_origin` shifted down by half its excess height over its
footprint, with no horizontal shift:

```text
texture_origin.y = (sprite_height - footprint_height) / 2
```

- 1x1 props (chair, table, bed, door, berry bush) and the tree:
  `footprint_height` is 16.
- The horizontal 2x1 workbench (32x28) has a one-tile-tall footprint, so
  the same formula applies unchanged.
- The vertical 1x2 workbench (16x44) has a 32 px tall footprint, so it is
  grounded against 32, not 16.
- Horizontal overhang needs no correction: Godot's own centring already
  handles a sprite wider than its footprint.
- Low ground clutter (the hazard marker, the sprout) needs no shift.

`build_terrain_tileset.gd` computes these origins; nothing is hand-tuned in
the `.tres`.

## Prop scale rule

All presentation props are measured at the native pixels registered by the
TileSet atlas. The governing ceilings are:

| Kind | Maximum registered size and placement |
| --- | --- |
| 1x1-footprint prop | **16 px wide x 24 px tall**; the bottom 16 px sit on the tile, with up to 8 px of overhang behind |
| 2x1-footprint prop | **32 px wide x 28 px tall**; the footprint remains grounded and the extra height overhangs behind |
| 1x2-footprint prop | **16 px wide x 44 px tall**; grounded on the two-tile footprint |
| Tree | **<=32x48**, footprint equal to the trunk tile |
| Ground item | **8-10 px icon**, centred on its tile |
| Marker | Carried-item, tool and trapped markers keep their current sizes |

## Item icons

Held tools resolve the same `ITEM_ATLAS_MAP` cells as ground item icons,
with no tint. Tool icons are 16x16 cells in `tools.png`; resource icons are
32x20 cells in `resources.png`. The ground-icon draw rectangle is 9.6x9.6 px (Prop scale rule:
Ground item, 8-10 px); the held-tool marker is 9.6x9.6 px at offset
`(-4, -4)` from the colonist sprite origin. Nearest-neighbour filtering and
disabled mipmaps preserve the original pixels.

The stockpile renderer combines stackable `get_items()` with ground-located
tools from `get_tool_items()`, counting each tool once and excluding held
tools. Both use the same registered atlas cells.

## Provenance

Every file under `game/assets/generated/` is produced by
`tools/generate_placeholder_art.py` in this repository; see
[`game/assets/CREDITS.md`](../../game/assets/CREDITS.md) for the asset
inventory and the regeneration commands. The generated art contains no
pixels taken from any external source.
