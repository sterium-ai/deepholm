# ADR 020: Main river, correlated vegetation, and river-aware spawn placement

> **In short:** New maps now have one continuous river, trees and berry bushes
> that grow in clusters, and a starting spot for the colonists that is chosen so
> water, food and wood are close by on the same side of the river.

- **Status:** accepted
- **Date:** 2026-09-21
- **Scope:** core (worldgen, `world_state.gd`), content (`mapgen.json` and its
  schema), presentation (`boot.gd`, viewer), tests
- **Extends:** [ADR 019](019-world-dimensions-and-generation.md)

## Context

ADR 019 delivered a large (256x256), seeded, reproducible new game, but:

- water was scattered tile by tile, independently;
- the spawn rectangle was a fixed `(2, 2)`-`(8, 8)` corner regardless of
  terrain;
- the `food` need had no generator-placed source outside the debug scenario,
  and the `rest` need had no source at all in a normal new game;
- the running viewer started in the seeded debug scenario.

This decision replaces the water scatter with a single main river, composes
vegetation and rock into correlated zones, chooses the colonist spawn against
the real terrain, and makes a real, paused New Game the viewer's default.

## Decision

### The river: a band around a monotonic centerline, carved last

`WorldGenerator._carve_river()` picks a dominant axis (west to east, or north
to south) and walks every integer position from one edge to the other. The
centerline's transversal offset and the band's width are each linearly
interpolated between random control points, `river_control_point_spacing`
tiles apart. Consecutive offsets differ by at most
`river_max_transversal_delta`, and widths are drawn from
`[river_min_width, river_max_width]` (default 6-12).

- Because the centerline is a single-valued function of the dominant
  coordinate, it cannot self-intersect by construction.
- Every transversal cross-section meets the river in exactly one contiguous
  run of tiles. That run's length is the river's *width* at that position,
  measurable directly from the tile array.
- Drift per step is much smaller than the minimum width, so consecutive
  cross-sections overlap and the river is a single 4-connected component with
  no isolated tile.
- Both width bounds are at least `NECK_FLOOR = 4`, and every control point's
  width is clamped into the range, so interpolation never produces a corridor
  narrower than `river_min_width`, curves included.

The river is carved *after* rock veins, hazards and tree groves, so nothing
already placed can plug or narrow it, and *before* berry bush groves and the
spawn clearing, which only ever write onto `TILE_SOIL`. Later placement steps
therefore cannot break the channel, structurally rather than by convention.

### Vegetation and food: correlated groves

`_scatter_tree_groves()` and `_scatter_berry_bush_groves()` split their
area-scaled count and attempt budget across a small number of grove centers.
Each center scatters its share within a fixed radius (`tree_grove_radius`,
`berry_bush_grove_radius`). The radius is not area-scaled: like the river's
width, it is a spatial extent, not a count. Rock veins already scatter as a
connected random walk and are unchanged.

Berry bush groves are new: previously a New Game placed no `berry_bush`
objects at all.

### Food and rest source chains

The food chain is *forage, then ground berries, then `eat_food`*; colonists
never eat a bush directly:

1. `needs.json`'s `source_kind: "berry_bush"` only tells `ContentRegistry`'s
   schema check that `food` resolves to a declared object kind.
2. `forage` is a player-order command (`world.apply({"type": "forage", ...})`).
   `NeedGiver` never submits it; its `JOB_KIND_BY_NEED` maps only to
   `eat_food`, `drink_water` and `sleep`.
3. When a forage job completes, `_toil_on_work_complete()` clears the bush and
   calls `_spawn_berries_item()`, leaving exactly one ground berry. Bushes do
   not regrow.
4. A separate `eat_food` need job (toils `reserve`, `go_to`, `consume`),
   submitted by `NeedGiver`, consumes the ground berry.

The `rest` need has `source_kind: "bed"`, but normal generation placed no bed,
so rest was never served (`need_unmet:rest`) on a fresh New Game. `boot.gd`'s
`_spawn_starting_beds()` now places one bed per colonist through the same
`place_object` command path a player-built bed uses.

### Spawn placement: a bounded, deterministic, resource-validated search

`WorldGenerator.place_spawn()` is a pure static function. Its doc comment is
the authoritative description; in summary:

- **Distance fields.** Three whole-map multi-source BFS distance fields
  (`_distance_field()`, 4-connected, over `TILE_SOIL` only) give the real
  route distance from every tile to a tile adjacent to water, a tree and a
  berry bush. The fields only expand across land, so a resource across the
  (impassable) river is never counted: "same bank" falls out of the
  construction, with no separate bank bookkeeping.
- **Compliance.** A candidate footprint must be all `TILE_SOIL` (nothing
  already placed is bulldozed) and every one of its tiles must reach water,
  trees and food within `spawn_water_step_limit` / `spawn_tree_step_limit` /
  `spawn_food_step_limit` (default 40/50/40).
- **Distinct food.** Each forage feeds exactly one colonist once, so a
  single bush close to everyone is not enough.
  `_count_reachable_food_sources()` counts *distinct* bushes within
  `spawn_food_step_limit`, and a fully compliant candidate needs at least
  `colonist_count * FOOD_SOURCES_PER_COLONIST` (currently 1 per colonist, so
  3). Because the later Fisher-Yates shuffle can give any reserved tile to any
  colonist, the count is the worst case over the whole footprint: a cheap
  multi-source BFS from the footprint finds candidate bushes within budget of
  its nearest tile, then one bounded BFS outward from each candidate bush
  confirms every footprint tile is within budget (`_reaches_every_tile()`). A
  shortfall is scored like an over-budget distance in the fallback ordering.
- **Four strictly ordered tiers**, each bounded by map size, never "retry
  until lucky":
  1. A random search of up to `spawn_search_attempts` anchors, biased near a
     random river tile, that accepts only a fully compliant candidate.
  2. `_scan_for_clearing()`, an exhaustive row-major scan that always runs
     when tier 1 finds nothing. It prefers full compliance and otherwise
     takes the least-over-budget candidate whose resources are all reachable.
  3. `_repair_land_clearing()`, reached only when no
     `clearing_width x clearing_height` all-soil rectangle exists anywhere. It
     scores every 4-connected land component like tier 2; only if no
     component can reach resources at all does it take the first component
     large enough for `colonist_count` colonists, reporting `-1` for any
     distance that truly cannot be reached.
  4. A last-resort expanding-ring scan from `mapgen.json`'s `spawn_area_x` /
     `spawn_area_y`, reached only when no land component has even
     `colonist_count` soil tiles. It may return fewer than `colonist_count`
     positions rather than bulldoze rock, hazard or tree terrain.

  Every tier paints only tiles it has verified are soil, so the river is
  never touched. Using any tier after the first sets the result's
  `"fallback"` flag. `spawn_area_x` / `spawn_area_y` are now only this
  last-resort anchor, no longer a fixed spawn position.
- **Outputs.** The result includes the clearing, each measured distance,
  `food_sources` (achieved) and `required_food_sources` (the contract value),
  and `land_tiles`, a pool of safe land tiles. A berry bush inside the chosen
  clearing is dropped from the returned `berry_bush_tiles`, so no bush is
  placed as a blocking object on the new floor. None of this is persisted;
  `_spawn_clearing` is scratch state outside the save schema.

`WorldState.get_spawn_clearing()` exposes the result, so `debug_scenario.gd`
and `boot.gd` anchor relative to the real spawn instead of the removed
`SPAWN_AREA_X`/`SPAWN_AREA_Y`/`SPAWN_AREA_WIDTH`/`SPAWN_AREA_HEIGHT`
constants. `boot.gd`'s `_spawn_starting_tools()` and `_spawn_starting_beds()`
draw from `land_tiles` through a shared `_claim_starting_tiles()` helper,
instead of rectangle-offset arithmetic that could land on water or fail for
non-rectangular clearings.

### Distance is always a real 4-connected route

Both `place_spawn()` and the tests measure hops over passable tiles plus one
interaction step, never Chebyshev or Euclidean distance. The tests use their
own from-scratch BFS, not the generator's distance fields, so a bug in one
cannot hide behind the other.

### Generation uses its own RNG streams

`_generate_map()` and `_spawn_colonists()` each seed a local
`RandomNumberGenerator` from `_seed + GEOGRAPHY_SEED_SALT` and
`_seed + PLACEMENT_SEED_SALT` respectively, following the pattern of
`incident_scheduler.gd`'s `SEED_SALT`. Previously they drew from
`WorldState._random`, which the scheduler keeps using for the rest of the
game, so tuning `mapgen.json` (for example, more tree groves) silently changed
every later scheduling decision. `_random` is now left exactly as a fresh
generator seeded with `_seed`, however much randomness generation consumed.
`get_simulation_random_state()` is a small test-only accessor for checking
this.

### Need sources are filtered by reachability

With a river of thousands of water tiles, most on the far bank,
`_need_source_candidates("water")` offered `NeedGiver` many unreachable
candidates. `NeedGiver` has no early "impossible" signal: an unreachable
candidate is abandoned only after flood-filling the colonist's whole
component. In testing, two colonists spent over 1500 ticks on such searches
before reaching water on their own bank. `_need_source_candidates()` now
filters every kind through `_reachable_candidates_only()`, using the
already-maintained `RegionMap` (`_get_regions()`), the same connectivity
`RouteSearch` resolves to. An unreachable source is never offered.

`_water_tile_cache` stays correct when tiles change. `place_object` does not
reject water tiles, so a `berry_bush` can be placed on water; foraging it
turns the tile into `TILE_FLOOR`. `_update_water_tile_cache()` is called at
the same "tile changed kind" boundary in `_toil_on_work_complete()` that
drives dirty-cell, region and room refreshes, so any tile-mutating toil keeps
the cache in step with the tiles, matching what a freshly decoded save
rebuilds.

### The viewer starts a real, paused New Game

`boot.gd`'s `_init()` used to build `DebugScenario.build()` unconditionally: a
48x48 map with a random 24-order dig queue and forced furniture, auto-ticking
at `Speed.X1` as soon as the scene loaded. It now calls
`Boot.build_default_world()`, the same 256x256
`default_new_game_width`/`height` generator that `_start_new_game()` uses,
with real starting tools and no dig queue. `TickDriver.speed` defaults to
`Speed.PAUSED` for the boot default, every New Game and every loaded save.
`DebugScenario` is unchanged and remains available to tests that call
`DebugScenario.build()` and through an explicit "Debug Scenario" button
(`_on_debug_scenario_pressed()`), never at startup.

### Interim rendering of water and trees

The terrain tileset had no water or tree cells. Water previously reused the
hazard cell, making a river indistinguishable from hazards, and `TILE_TREE`
had no `TILE_ATLAS_MAP` entry at all, so `_set_tile_map_cell()` erased the
cell and groves rendered as blank holes. As an interim measure both kinds
were mapped to distinct reused cells and drawn with a flat-colour overlay (a
node between the terrain and object layers, repainted only through the
existing dirty-cell boundary) so they read as water and vegetation.
[ADR 022](022-visual-target-16px-pixel-art.md) later replaced this with real
water and tree art and removed the overlay.

### `GENERATOR_VERSION` is 2

The algorithm changed; the save schema did not. `map.generatorVersion`
already existed (ADR 019, schema version 20), and `StateCodec.decode()` never
regenerates terrain, so existing saves decode exactly as before, whichever
algorithm produced them.

## Consequences

- **Core line budget.** `world_state.gd`'s cap in `core-budgets.json` rose
  from 2026 to 2125 lines across this decision: spawn delegation and two
  scratch fields (`_pending_water_tiles`, `_pending_berry_bush_tiles`) that
  carry generator output from `_generate_map()` into `_init()` without
  changing either signature; the salted RNG streams and their test accessor;
  `_reachable_candidates_only()`; and `_update_water_tile_cache()`. These need
  `WorldState`-only state (`_seed`, regions, colonists, tiles). The rest of
  the algorithm lives in the uncapped `worldgen/world_generator.gd`.
- **Unused content fields kept.** `water_count` and `water_placement_attempts`
  remain declared in `mapgen.json` and its schema, though no longer read, so
  minimal `ContentRegistry`-only fixtures that declare them need no change.
- **Worlds now start with objects.** A new `WorldState` can carry
  generator-placed `berry_bush` objects. Tests that overwrite `_tiles` or
  `_colonists` directly now also clear `_objects`/`_object_factions` where a
  stray bush could collide with their coordinates. Three tests that asserted
  "a fresh world has zero objects" (`test_object_storage.gd`,
  `test_place_object_command.gd`, and the save-schema check in
  `test_save_determinism.gd`) now assert "zero objects the generator would
  never place".
- **Tests no longer assume a corner spawn.** `test_map_view_cell_contents.gd`
  and `test_faction_reservations.gd` picked targets by scanning from the map
  origin or a fixed 47x47 region; they now search in expanding rings from a
  real colonist's tile. `test_save_dimensions.gd`'s far-edge check carves a
  straight land corridor from the spawned colonist to `(254, 254)`, so the
  far coordinate is always exercised wherever the river lands.
- **Debug scenario bootstrap.** Need sources can now legitimately be up to 40
  steps away, so `debug_scenario.gd`'s `_till_starting_plot()` tops up needs
  for the duration of its bootstrap loop, as `test_new_game_dig_chop.gd`
  already did, so the till job is not repeatedly interrupted.
- **Boot-scene tick budget.** `test_incidents.gd` keeps its shared
  `TICK_BUDGET` of 600; only `_check_viewer_dispatches_spawn_incident()`,
  which ticks a real 256x256 boot world, uses a separate
  `BOOT_TICK_BUDGET := 1500`.

## Verification

- `test_river_generation.gd` runs a fixed suite of more than 20 seeds:
  reproducibility, the river crossing two opposite edges, a single
  4-connected water component, no isolated water tile, width at least
  `NECK_FLOOR` everywhere, exactly one run per cross-section, and an overlap
  of at least `NECK_FLOOR` between adjacent cross-sections
  (`_cross_section_runs()`, `_corridor_overlap_violation()`). Per colonist, a
  BFS through `world.passability()` (`_bfs_route_distance()`) checks water,
  food and trees within their bounds, and a test-local
  `_count_reachable_food_sources()` checks there are at least as many
  distinct reachable bushes as colonists. The `"fallback"` flag must be
  `false` for every seed, and generation must leave the simulation RNG
  untouched. Synthetic negative fixtures prove each checker rejects what it
  should (a one-cell neck, a sharp bend, a multi-run cross-section, only one
  colonist reachable, a route blocked by a bush, a single shared bush) and
  that a smooth curve is not flagged.
- `test_spawn_fallback.gd` calls `place_spawn()` directly on small synthetic
  maps that force the later tiers: the `spawn_area_x/y` anchor in water and on
  a bush, a map with land but no reachable resources, a map whose only land
  component has exactly `colonist_count` tiles, and a single shared bush
  (`_check_single_shared_bush_reported_insufficient()`). Each asserts
  `colonist_count` mutually connected positions, a connected and safe
  land-tile pool, and original water tiles left unchanged.
- `test_new_game_forage_chop.gd` boots a real New Game under unmodified need
  decay. It forages every distinct bush near the colony's centroid (up to
  `colonist_count + 2`) and gives each colonist its own chop target. Each
  order names its colonist as `payload.assignee`, using the existing
  dig/chop/forage assignee restriction; otherwise the fair scheduler could
  give one colonist most of the orders and berries while another starved. The
  test asserts, per colonist, that its chop completes and that it experiences
  at least one real `food`, `water` and `rest` restore. The bounded
  20,000-tick budget is needed because a critical need can interrupt a
  25-40-tick work toil, and three colonists with synchronised needs lose
  several such races before one completes. The test does not assert that no
  need ever reaches 0: `NeedGiver` searches only once a need is urgent, so a
  source near the 40-step bound can let a need hit 0 on the way.
- `test_new_game_dig_chop.gd` keeps needs pinned to isolate the tool-fetch
  path.
- `test_water_cache_invalidation.gd` places and forages a bush on a reachable
  water tile through supported commands, then checks that the live world's
  water candidates match a save/load copy's and that `state_hash()` matches.
- `test_river_map_capture.gd` drives the real New Game path for seeds 42,
  1337 and 20260919. With `-- --capture` it writes a full-map overview (the
  capture-only root viewport is enlarged so the whole map fits at the real
  0.5x zoom; the camera contract is unchanged) and a 1.0x spawn close-up.
- `test_river_seed_order_completion.gd` boots seeds 1337 and 20260919,
  re-checks food and water bounds per colonist, and drives one forage order to
  completion through `WorldState.apply()`.
- `test_river_seed_viewer_interaction.gd` performs the same check through the
  running viewer's own input path (`Viewport.push_input` to
  `WorldState.apply()`): it enters the seed, clicks New Game and the
  confirmation dialog, checks a paused start with an empty job queue and the
  HUD's seed label, checks resource bounds, selects Forage, clicks a
  reachable bush, clicks x1 and lets `TickDriver` run until ground berries
  appear. Headless, it is a regression gate; with `-- --capture` it also
  samples rendered pixels (a river tile must be blue-dominant, soil must not)
  and writes captures.

A recorded graphical run passed for both seeds:

| Seed | colonist_0 | Forage target | Route steps | Nearest bank | Ticks to complete (x1) |
| --- | --- | --- | --- | --- | --- |
| 1337 | (170, 252) | (150, 255) | 23 | (170, 246) | 2029 |
| 20260919 | (191, 19) | (187, 15) | 8 | (206, 19) | 814 |

Orders take hundreds of ticks because need-driven drink and eat jobs (water
decays 2 per tick, food 1 per tick under the `needs.json` of the time)
interleave with them. That is a food-economy balance question, not a
generation or reachability defect: the river never blocked the order.

## Non-goals

No erosion, fluids, seasons, additional biomes, fauna, expeditions or
underground generation. No bridges or swimming to work around generation
failures: resources across the river do not count. Indefinite food
sustainability (bush regrowth, farming at scale) is out of scope; the
guarantee covers only the *starting* resources a fresh colony needs for its
first needs cycle.

## Revision notes

The design was tightened after its first implementation:

- The first spawn fallback painted floor over the `spawn_area_x/y` rectangle
  unchecked, which could erase river tiles and leave a bush under a colonist;
  a later version let one over-budget random hit suppress the exhaustive scan.
  Both were replaced by the four ordered tiers above.
- Food sufficiency was first a per-colonist nearest-bush distance, which three
  colonists could all satisfy with the same bush, and then a footprint check
  measured from the clearing's nearest tile, which overcounted on seed 17. The
  worst-case distinct count above replaced both.
- The first tests merged all colonists into one BFS over raw tile kinds; they
  now run one BFS per colonist through `passability()`.
- The first water/tree overlay was drawn over both tile layers every frame,
  hiding objects; it became a cached node between the layers before ADR 022
  removed it.
