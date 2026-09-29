# ADR 021: Visual target — flat top-down 16 px pixel art

- Status: accepted
- Date: 2026-09-22
- Deciders: project integrator (issue #301)

## Context

The first map renderer's default "art" view reused whichever atlas cell was
closest at hand for a given tile or object kind: water and trees shared
furniture cells, papered over with a flat-colour overlay
(`game/scripts/viewer/terrain_overlay.gd`) so the shapes at least read as
"not furniture". No two tile kinds were guaranteed visually distinct art,
there was no shoreline, and the base ground read as a diagnostic colour
rather than a legible biome.

The target is a flat top-down map that is readable at a glance: hard
silhouettes, a thin dark outline where a shape meets a contrasting
background, no gradients, a muted prairie with discrete (not animated)
variation, rock and trees recognisable at a glance, and a river whose banks
visibly differ from open water — all at 16 px per tile, matching the tile
size fixed by `docs/art/style.md` and ADR 018 (pc-map-presentation).

## Decision

1. **Tile size stays 16 px.** No change to `TILE_SIZE`/`texture_region_size`
   anywhere in the viewer or tileset.
2. **Every tile kind and every object kind gets its own distinct registered
   cell** in `game/data/tilesets/terrain_tileset.tres` — no sharing another
   kind's cell. The flat-colour overlay that only existed to compensate for
   that sharing is deleted.
3. **The art is original, procedurally generated placeholder pixel art.**
   `tools/generate_placeholder_art.py` (Python + Pillow) writes every PNG
   under `game/assets/generated/` deterministically; nothing is hand-painted
   and no external asset pack is used. The TileSet is not hand-typed: it is
   built by `game/scripts/tools/build_terrain_tileset.gd` through Godot's own
   `TileSet`/`TileSetAtlasSource`/`ResourceSaver` API, and colonist
   animations by `game/scripts/tools/build_colonist_frames.gd`. Replacing the
   placeholders with final art means regenerating or swapping PNGs at the
   same sizes, with no simulation or viewer logic change.
4. **Two-layer terrain: opaque base + grass overlay.** `map_view.gd` draws a
   base terrain `TileMapLayer`, a grass overlay layer
   (`_grass_overlay_layer`) and an object/decor layer. Water and rock tiles
   always draw their own plain, fully opaque cell, regardless of neighbours.
   A soil (prairie) tile next to water or rock gets a two-layer composite:
   its base cell is that neighbour's own opaque cell (the backing), and the
   overlay draws one of 12 directional grass "blob" cells (4 edges, 4 convex
   corners, 4 concave corners) whose transparent pixels let the backing
   show through as an irregular shoreline. Both layers are resolved from one
   neighbour selection (`tile_atlas_map.gd`'s `grass_shore_selection()` and
   `grass_shore_backing_offsets()`), so they can never disagree. Interior
   prairie draws no overlay and keeps a plain grass fill.
5. **Neighbour selection is a code-side 8-neighbour bitmask, not Godot
   terrain peering bits.** One foreign orthogonal side selects an edge cell;
   two adjacent foreign sides select a convex corner; a diagonal-only
   foreign neighbour selects a concave corner. When the two sides of a
   corner are different materials, the backing follows a fixed compass
   priority (N > E > S > W). The blob set has 12 directional cells, not the
   full 47-tile set, so two opposite sides (a one-tile channel), three sides
   (a cap) and four sides (an isolated tile) are approximated by the
   highest-priority edge/corner cell. `test_grass_shore_bitmask.gd` checks
   every configuration against literal expected coordinates, independent of
   the implementation's own tables, and asserts every approximation resolves
   to one of the 12 real directional cells.
6. **Prairie variation is a pure function of the map.** Each interior soil
   tile picks one of 3 grass variant cells by `hash(seed, x, y)`, never by
   frame count or a running animation, so it is stable across pan, zoom,
   save and load.
7. **Tree, hazard and planted tiles are base plus decor.** Each tile kind's
   `TILE_ATLAS_MAP` entry is a plain opaque ground fill (forest floor, dirt,
   plowed soil); a separate `TILE_DECOR_MAP` entry draws the
   transparent-background sprite (tree, hazard marker, sprout) on the object
   layer, exactly like a placed object. No cell can expose the viewport
   background.
8. **Oversize sprites are grounded, not squashed.** Props are registered at
   their native pixel size. Godot's `TileMapLayer` centres a texture larger
   than one cell on both axes when `texture_origin` is `(0, 0)`, so a
   standing prop only needs its `texture_origin` shifted down by half its
   excess height over its footprint (`(size.y - footprint_height) / 2`, no
   horizontal shift) to put its bottom edge on the footprint's bottom edge.
   Low ground clutter needs no shift.
9. **The flat-colour diagnostic view stays available** via the existing
   "Toggle Art" button, unchanged in mechanism; art is the default renderer
   on a fresh boot.

## Consequences

- `game/scripts/viewer/terrain_overlay.gd` is deleted.
- `tile_atlas_map.gd`'s `ATLAS_CELL_STRIDE` is 16: generated sheets have no
  separation between cells.
- `map_view.gd`'s incremental refresh re-resolves a dirty cell's 8
  neighbours (diagonals included, since concave corners depend on them) and
  both the base backing and the overlay of each affected soil neighbour.
  Repainting a whole layer per tick is never done.
- The art pipeline is fully reproducible from the repository: regenerate
  the PNGs, rebuild the TileSet and SpriteFrames resources, and the headless
  tests check the result.
- This ADR does not touch simulation, scheduling, generation or water
  rules. `WorldState.state_hash()` hashes tile-kind strings, never atlas
  coordinates, so every change here is presentation-only by construction.
