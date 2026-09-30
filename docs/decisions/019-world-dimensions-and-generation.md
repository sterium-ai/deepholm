# ADR 019: World dimensions, pure worldgen module, and incremental map presentation

> **In short:** New games get a much larger map (256 by 256 tiles) generated from a seed, so the same seed always gives the same world, while the map display only redraws the parts that change.

- **Status:** accepted
- **Date:** 2026-09-21
- **Scope:** core (`world_state.gd`, worldgen, persistence), presentation (viewer); PC map milestone

## Context

The PC map milestone needs a large (256x256), seeded, reproducible new game
while keeping the existing 48x48 fixtures valid for tests, without exceeding
`world_state.gd`'s `core-budgets.json` cap and without rebuilding every tile
each simulation tick just to present a much larger map.

## Decision

**Dimensions are per-instance, not global.** `WorldState._width`/`_height`
replace hardcoded map bounds in every internal computation (passability,
route-search bounds, region/room maps, command validation, the "%d_%d" tile
index). `WorldState.MAP_WIDTH`/`MAP_HEIGHT` remain as 48x48 constructor
defaults so every existing fixture and test that constructs `WorldState.new(seed)`
with no explicit size keeps getting the historical 48x48 map unchanged. A
caller that wants a different size passes `p_width`/`p_height` to the
constructor; `WorldGenerator.resolve_size()` clamps the request into
`mapgen.json`'s `min_world_size`/`max_world_size` (16..512) before anything
else reads it.

**Generation is a pure module.** `game/scripts/core/worldgen/world_generator.gd`
holds the terrain algorithm (rock veins, spawn carve, hazards, trees, water),
extracted from `world_state.gd` to keep both within budget and to make the
algorithm independently testable without a full `WorldState`. It takes the
caller's own seeded `RandomNumberGenerator` and draws from it in the exact
historical order, so a request at the 48x48 reference size reproduces every
existing fixture's terrain byte-for-byte. `WorldGenerator.GENERATOR_VERSION`
is a plain integer bumped only when the algorithm itself changes; it travels
in every save's `map.generatorVersion` field for reproducibility diagnostics,
never checked against the running build's version on load (terrain is always
loaded from the stored tile array, never regenerated -- see below).

**Resource density scales with area, not a fixed count.** Every mapgen count
and placement-attempt budget scales by `(width*height) / (reference_width*reference_height)`
(`mapgen.json`'s new `reference_width`/`reference_height`, default 48x48,
ratio 1 so nothing about the 48x48 fixture case changes). This is what keeps
a 256x256 map from carrying the same 40 trees the 48x48 map has, which a
naive constant substitution would do.

**New-game size is content-driven.** `mapgen.json`'s `default_new_game_width`/
`default_new_game_height` (256x256) is what boot.gd's New Game control passes;
it is a data value, not a literal duplicated in presentation code.

**Save/load never regenerates terrain.** `map.width`/`map.height` were
already part of the schema before this change (schemaVersion 19 already
declared them, always encoded as 48 in practice); schemaVersion 20 adds
`map.generatorVersion` and the save's own session `epoch` (both backfilled on
migration -- `generatorVersion` to 1, the only worldgen algorithm that has
ever produced a save; `epoch` to 0, since every pre-v20 save necessarily
predates "New Game"). `StateCodec.decode()` restores a save's own
`map.width`/`map.height`/`map.generatorVersion` onto the reconstructed
`WorldState` exactly as stored, never re-clamped through
`WorldGenerator.resolve_size()` (that clamp only applies when generating a
brand-new world) -- a valid small fixture below `min_world_size` decodes at
its own exact size, and a re-saved world keeps recording the generator
version that actually produced its terrain rather than the running build's
own constant. `SaveIO._validate_state()` now also rejects a `tiles` array
whose length does not equal `width*height`, rejects `map.width`/`map.height`
above `mapgen.json`'s `max_world_size` (the only upper bound load enforces),
rejects non-positive `map.width`/`map.height` (a floor of 1, not
`mapgen.json`'s 16-tile new-game minimum -- restoring a small fixture below
that minimum is a distinct, supported case, see the small-map decode note
above), and rejects any persisted tile
coordinate outside `[0, width)`x`[0, height)` anywhere in the save --
entities, items, objects, zones, tool items, job targets/cells, scheduling
queue entries, pending route searches, assignments, and nested route
`start`/`target`/`frontier`/`visited`/`cameFrom`/`path` fields alike. None of
these checks existed before this change (only a non-negative lower bound was
checked, and only for entities/items/objects/zones/tool items), so a save
with mismatched dimensions or an out-of-bounds coordinate anywhere in the
tree is now refused before it can replace a working save or corrupt a loaded
world.

**Presentation updates only changed cells.** `WorldState.get_dirty_cells()`
is an append-only log of every `(x, y)` whose tile kind or object changed
(dig, chop, forage, till, sow, place_object, remove_object); `WorldState`
itself never clears it. `map_view.gd`'s `refresh()` (called once per tick)
keeps its own consumed-count cursor and replays only the newly-appended tail
of the log since its last call, updating just those `TileMapLayer` cells
instead of clearing and rebuilding the whole layer; a full rebuild still
happens exactly once, on `set_world()` (a fresh world or a freshly loaded
one), which also resets the cursor. Colonist sprites and the
designation overlay were already `O(colonists)`/`O(jobs)`, not `O(map)`, so
they need no change. The flat-colour debug renderer (no art assets) still
redraws every visible tile each frame -- inherent to Godot's immediate-mode
`CanvasItem._draw()` and the non-default fallback path, not the target of
the requirement that a tick must not rebuild all 65,536 cells, which names
the `TileMapLayer` rebuild specifically.

## Consequences

`world_state.gd` stays within its existing 1877-line `core-budgets.json` cap
(raising a core cap was ruled out for this change): the width/height
plumbing, dirty-cell tracking, generator-version provenance field, and new
getters added here are offset by extracting the terrain algorithm itself
into the pure `WorldGenerator` module and trimming comments elsewhere in the
file, rather than by raising the cap.

A v19 (or older) save migrates losslessly to v20: `map.generatorVersion` is
backfilled to `1` (the only generator algorithm that has ever produced a
save), `epoch` is backfilled to `0` (every pre-v20 save necessarily predates
"New Game"), and `map.width`/`map.height` need no migration since the schema
already required them at v19.

## Non-goals

No river, no biome set, no infinite/streamed world, and no mobile-specific
camera work.
