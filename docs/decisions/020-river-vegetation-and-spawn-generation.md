# ADR 020: Main river, correlated vegetation, and river-aware spawn placement

- Status: accepted for issue #300 (PC map milestone)
- Date: 2026-09-21
- Scope: core (worldgen, world_state.gd), content (mapgen.json/schema),
  presentation (boot.gd, viewer), tests

## Context

Issue #299 (ADR 019) delivered a large (256x256), seeded, reproducible new
game whose water was scattered tile-by-tile independently, whose spawn
rectangle was a fixed `(2, 2)`-`(8, 8)` corner regardless of terrain, and
whose "food" need had no generator-placed source at all outside the debug
scenario. Issue #300 replaces the water scatter with a single main river,
composes vegetation/rock into correlated zones instead of independent
per-tile placement, chooses the colonist spawn dynamically against real
terrain, and stops defaulting the running viewer to the seeded debug/diagnostic
scenario.

## Decision

**The river is a band around a continuous, monotonic centerline, carved
last.** `WorldGenerator._carve_river()` picks a dominant axis (horizontal:
west→east, or vertical: north→south) and walks every integer position from
edge 0 to the far edge; the centerline's transversal offset and the band's
width are each linearly interpolated between randomly-drawn control points
(`river_control_point_spacing` tiles apart, consecutive offsets differing by
at most `river_max_transversal_delta`, widths independently drawn from
`[river_min_width, river_max_width]`, default 6-12). Because the centerline is
a single-valued function of the dominant coordinate, it cannot self-intersect
by construction (not merely by tuning), and every transversal cross-section
intersects the river in exactly one contiguous run of tiles -- **this run's
length is this task's own definition of "width"** at that position, directly
measurable off the generated tile array. Consecutive cross-sections overlap
(drift per step is far smaller than the minimum width), so the whole band is
a single 4-connected component with no isolated tile, and every control
point's width is clamped into `[river_min_width, river_max_width]` (both
`>= NECK_FLOOR = 4`), so linear interpolation never produces a corridor
narrower than `river_min_width` anywhere, curves included. The river is
carved *after* rock veins, hazards and tree groves specifically so nothing
already placed can plug or narrow it, and *before* berry bush groves and the
spawn clearing, both of which only ever write onto `TILE_SOIL` and so can
never touch water either -- "later placement steps can never break the
river channel" holds structurally, not by convention.

**Vegetation and food are placed as correlated groves, not independent
per-tile scatter.** `_scatter_tree_groves()`/`_scatter_berry_bush_groves()`
split their area-scaled total count/attempts budget across a small number of
grove centers, each scattering its share within a fixed-radius circle
(`tree_grove_radius`/`berry_bush_grove_radius`, *not* area-scaled -- a grove's
own footprint is a spatial extent, like the river's width, not a count).
Rock veins already scatter as a connected random walk, satisfying "masas de
roca" unchanged. Berry bush groves are new: a fresh New Game previously placed
*zero* `berry_bush` objects (only the debug scenario placed one,
unconditionally), leaving the `food` need's only source (`needs.json`'s
`source_kind: "berry_bush"`) permanently unreachable in real play.

**The spawn clearing is a bounded, deterministic, resource-validated search,
never a fixed rectangle.** `WorldGenerator.place_spawn()` samples up to
`spawn_search_attempts` candidate anchors biased near a random river tile,
accepts a candidate only if its whole footprint is `TILE_SOIL` (so nothing
already placed is ever bulldozed) and every one of its tiles has a finite,
in-bounds real-route distance -- computed once as three whole-map
multi-source BFS distance fields (`_distance_field()`, 4-connected, over
`TILE_SOIL` only) to a water/tree/berry-bush-adjacent tile -- within
`spawn_water_step_limit`/`spawn_tree_step_limit`/`spawn_food_step_limit`
(default 40/50/40). Because the distance fields only ever expand across land,
a candidate can only succeed using resources reachable without crossing the
(impassable) river, which is exactly "same bank" without any separate
bank-side bookkeeping. No loop retries until success: `attempts` is a hard
cap; the least-over-budget valid candidate seen is used if none fully
satisfies every bound, and `mapgen.json`'s own `spawn_area_x`/`spawn_area_y`
(now only a fallback anchor, no longer read as a fixed spawn position) is the
last-resort documented fallback if no valid candidate exists at all. Either
fallback path is recorded on the result's own `"fallback"` flag, which
`test_river_generation.gd` asserts stays `false` across its whole seed suite
-- proving the fallback is real and reachable in principle, but never actually
needed for the seeds this task ships. `WorldState.get_spawn_clearing()`
exposes the chosen rectangle (and each distance actually measured) so
`debug_scenario.gd` and `boot.gd`'s starting-tool placement can anchor
relative to the real spawn instead of the removed
`SPAWN_AREA_X`/`SPAWN_AREA_Y` constants (`SPAWN_AREA_WIDTH`/`HEIGHT` also
removed: nothing read them once the clearing footprint size is looked up from
`mapgen.json` directly inside `place_spawn()`).

**Distance is a real 4-connected route, never Chebyshev/Euclidean.** Both
`place_spawn()`'s own distance fields and `test_river_generation.gd`'s
independent from-scratch BFS (a second implementation, not a re-use of the
first, so a bug in one would not be masked by the other) measure hops over
passable tiles plus one interaction step -- "never confuse geometric
distance with route distance" is enforced by construction, not by comment.

**The viewer's default is now a real New Game, never the seeded debug
scenario.** `boot.gd`'s `_init()` used to build `DebugScenario.build()`
unconditionally: a 48x48 map with a random 24-order dig queue and forced
furniture, auto-ticking at `Speed.X1` the instant the scene loaded. It now
calls the new `Boot.build_default_world()` -- the same 256x256
`default_new_game_width`/`height` generator `_start_new_game()` uses, with
real starting tools and no random dig queue -- and `TickDriver.speed`
defaults to `Speed.PAUSED` (covering the boot default, every `New Game`, and
a resumed save alike), satisfying "a normal new game starts paused; the
debug scenario is never the default experience". `DebugScenario` itself is
unchanged and remains reachable explicitly: by a test calling
`DebugScenario.build()` directly (unaffected by any of this), or from the
running viewer via a new, explicit "Debug Scenario" button
(`_on_debug_scenario_pressed()`), never at startup.

**`TILE_WATER`'s art-mode atlas cell no longer aliases `TILE_HAZARD`'s.**
#299 had reused `TILE_HAZARD`'s atlas cell for water (`terrain_tileset.tres`
registers only 8 cells and adding a ninth is outside every worldgen task's
owned paths), making a river visually identical to scattered hazard tiles in
the default art renderer -- exactly the ambiguity this task's "unambiguous
interim representation" requirement forbids. `tile_atlas_map.gd` now points `TILE_WATER` at
the already-registered "chair"/"bed" cell instead: still a reuse (a real water
tile still needs the same out-of-scope `terrain_tileset.tres` edit), but at
least distinct from every other *terrain-layer* kind a colonist needs to tell
it apart from (rock/soil/floor/hazard). The flat-colour renderer
(`map_view.gd`'s `TILE_COLORS`, reachable via `toggle_art_enabled()`) already
drew water in a distinct blue versus hazard's red before this task and
remains the fully unambiguous fallback.

While capturing this task's own graphical checks, `TILE_TREE` turned out to
have **no** `TILE_ATLAS_MAP` entry at all -- a pre-existing gap (since #299,
and #298/before): with no mapping, `map_view.gd`'s `_set_tile_map_cell()`
erases the TileMapLayer cell instead of drawing anything, so a grove of trees
was invisible (a blank hole) in the default art renderer, undermining this
task's own "see ... masses of vegetation" acceptance. Fixed the same way as
`TILE_WATER`: mapped to the already-registered "table" cell, distinct from
every other terrain-layer kind.

**`GENERATOR_VERSION` is 2.** The algorithm itself changed (river instead of
scatter, grove-correlated vegetation, dynamic spawn); no save schema field
changes (schemaVersion stays whatever `state_codec.gd` already declares --
`map.generatorVersion` already existed since ADR 019/schemaVersion 20). Save
files are unaffected: `StateCodec.decode()` never regenerates terrain (ADR
019's "save/load never regenerates terrain" is unchanged and untouched by
this task), so an old save's own stored tiles/generatorVersion decode exactly
as before regardless of which algorithm produced them.

## Consequences

`world_state.gd`'s `core-budgets.json` cap moves from 2026 to 2060 lines (an
ADR in the same change, per the cap's own rule): `_spawn_colonists()` now
delegates the search itself to `WorldGeneratorType.place_spawn()` and only
turns its pure output into real `_objects`/colonist state, and two small
scratch fields (`_pending_water_tiles`/`_pending_berry_bush_tiles`) carry
`WorldGenerator`'s river/berry-bush output from `_generate_map()` into the
very next `_init()` call without changing either method's signature -- the
rest of this task's algorithmic weight lives in the uncapped
`worldgen/world_generator.gd` instead.

`water_count`/`water_placement_attempts` remain declared in `mapgen.json`/its
schema (unread by the generator now) rather than removed, so the existing
minimal `ContentRegistry`-only test fixtures that declare them (which never
construct a real `WorldState`/run generation) need no change.

A `WorldState` can now carry generator-placed objects (`berry_bush`) at
construction, something no earlier task's generation ever did. Several
existing tests build a scenario by overwriting `_tiles`/`_colonists` directly
(`world._tiles.fill(...)`) without also clearing `_objects`/`_object_factions`
-- previously always empty at that point, so never needed clearing. Fixed at
each affected fixture (a one-line `_objects.clear()`/`_object_factions.clear()`
addition) rather than centrally, since only fixtures whose own coordinates a
stray bush could plausibly collide with needed it; two content-contract tests
(`test_object_storage.gd`, `test_place_object_command.gd`,
`test_save_determinism.gd`'s save-schema check) that asserted "a fresh world
has zero objects" as a literal invariant were updated to the new one ("zero
objects the generator itself would never place"). Two more tests
(`test_map_view_cell_contents.gd`, `test_faction_reservations.gd`) picked a
dig/chop/reserve target by scanning from the map origin or a fixed 47x47
region, which the fixed `(2, 2)` spawn always happened to sit near; with
spawn now dynamic those targets could land arbitrarily far away (or, in one
observed case, past a rock/river obstruction the target-pick never checked
for), so both now search in expanding rings from a real colonist's own tile
instead. `debug_scenario.gd`'s own till-plot bootstrap (`_till_starting_plot()`)
needed the same kind of fix for a different reason: with real need decay
active and its own colonists' need sources now legitimately up to 40 steps
away (this task's own contract, not a bug), a till job whose target ended up
several tiles from spawn could get need-interrupted, reassigned to a
scattered dig order, and never accumulate a full uninterrupted `work_ticks`
run within the old `TILL_TICK_BUDGET` -- needs are now topped up for the
duration of that one bootstrap loop only, exactly like `test_new_game_dig_chop.gd`
already did for the same reason. `test_incidents.gd`'s `TICK_BUDGET` (600) was
also raised (to 1500): its real-boot-scene checks now build a 256x256 world
instead of the old 48x48 debug scenario, so finding a valid edge spawn tile
and walking in takes longer (one case observed completing at tick 642).

## Non-goals carried over

No erosion, fluids, seasons, additional biomes, fauna, expeditions, or
underground generation (this task's own Non-goals). No bridges/swimming added
to paper over a generation failure -- guaranteed-reachable resources that
require crossing the river do not count, by the BFS's own construction (see
above). Indefinite food sustainability (bush regrowth, farming at scale) is
also out of scope: this task only guarantees the *starting* resources are
enough to get a fresh colony through its initial needs (see "Starting
resource sufficiency" below), proven by a bounded real-decay test, not an
unbounded economy.

## Round 1 revision (review findings)

**Correction: the food need's real source chain is forage -> ground berries
-> eat_food, not a colonist eating a `berry_bush` object directly.** The
original text above calling `berry_bush` "the food need's only source" was
imprecise: `needs.json`'s `source_kind: "berry_bush"` only tells
`ContentRegistry`'s schema check that "food" resolves to a declared object
kind; `NeedGiver` submits a `forage` job against the berry_bush tile (world_
state.gd's `_toil_on_work_complete()` clears the bush object and calls
`_spawn_berries_item()`, leaving ground berries), and a separate `eat_food`
job (toils `reserve, go_to, consume`) then consumes one ground berry from that
tile per meal. A generator that places bushes but nothing ever forages them
leaves zero ground berries and the food need permanently unmet -- this is why
`test_new_game_forage_chop.gd` (below) asserts an `eat_food` job actually
*completes*, not merely that a bush was cleared.

**Starting resource sufficiency is now defined, not just single-nearest-
instance distance.** "Sufficient" for this task's acceptance means: each of
the three spawned colonists has, on its own shore, at least one water-
adjacent tile, one berry_bush, and one tree tile each within its own
documented real-route bound (`spawn_water_step_limit`/`spawn_food_step_limit`/
`spawn_tree_step_limit`, default 40/40/50 -- test_river_generation.gd's
`_check_spawn_accessibility()` now checks this per colonist, see below) --
enough to perform one real forage, one real drink, and one real chop/build
each without crossing the river. This is deliberately a *starting* guarantee,
not a sustained-economy one (mapgen.json's `berry_bush_count` default of 8
bushes per map is not regrown once foraged): `test_new_game_forage_chop.gd`
proves the starting guarantee is enough to survive real need decay through
one full forage/eat/chop cycle with a real fetched tool, not indefinitely.

**A new real-decay New Game test replaces needs-are-topped-up-every-tick as
this task's own proof of "normal initial gameplay."**
`test_new_game_dig_chop.gd` (issue #299/#300 round 1's own dig/chop check)
resets every colonist's needs to 100 every tick specifically so it tests only
the tool-fetch path, not need service -- it was never meant to stand in for
"can a fresh colony actually feed/water/rest itself while working," and round
1 review correctly flagged it as insufficient proof of that. `game/
scripts/tests/test_new_game_forage_chop.gd` boots a real New Game (same
`boot.gd` path, a different seed), submits one `forage` order against the
nearest berry_bush and one `chop` order against the nearest tree (needing a
real fetched axe, same as the dig/chop test), then ticks the world under
*real, unmodified* need decay -- eat_food/drink_water/sleep jobs interleave
with the two player orders exactly as in real play -- up to a generous but
bounded 20,000-tick budget, and asserts: both orders complete, at least one
`eat_food` job completes (proving the forage -> ground-berries -> eat_food
chain above actually closes), and no colonist's food/water/rest need ever
reaches 0. Both tests are kept: dig/chop's own needs-pinned run isolates the
tool-fetch path (issue #299's own regression), the new test proves the
resource/need loop as a whole.

**`WorldGenerator.place_spawn()`'s undocumented fallback could erase river
tiles and leave a blocking berry-bush object under a colonist.** The
`best.is_empty()` last-resort branch previously painted `TILE_FLOOR`
unconditionally over `mapgen.json`'s own `spawn_area_x`/`spawn_area_y`
rectangle with no soil/water/bush check at all -- reachable only when
`spawn_search_attempts` random samples (biased near the river) never produced
even one resource-reachable, all-soil, bush-free candidate. Two more
deterministic, bounded tiers now run first: an exhaustive row-major scan of
every possible anchor still requiring resource reachability, then the same
scan relaxed to "all-soil, no bush" only -- both reuse the same
`_evaluate_clearing()` the random search already used, so neither can ever
accept a footprint touching water or a berry-bush tile, and both are still
bounded by map size (never "until luck"). Only if no all-soil footprint of the
requested size exists anywhere (never observed for any real generated map)
does the true last-resort anchor apply -- and even then, the paint step now
skips any tile that is still `TILE_WATER`, and the returned clearing's
colonist positions are built only from tiles that actually became
`TILE_FLOOR`, so the river survives and no colonist is ever placed on it. A
berry bush whose tile falls inside the finally-chosen clearing (any tier) is
dropped from `place_spawn()`'s own returned `berry_bush_tiles` list, so
`WorldState._spawn_colonists()` never places that bush as a blocking object
over the new floor.

**Terrain/decoration generation and the spawn search now consume their own
seed-derived RNG streams, never `WorldState`'s own simulation stream.**
`_generate_map()`/`_spawn_colonists()` previously drew from the same
`_random` object `AssignmentType` (the job scheduler) keeps consuming for the
rest of the game, so a mapgen.json tuning change that drew a different number
of decoration values (more tree groves, a different berry-bush count) shifted
`_random`'s position and silently changed every subsequent scheduling
decision -- decoration was never meant to be simulation-relevant randomness.
Both methods now seed their own local `RandomNumberGenerator` from
`_seed + GEOGRAPHY_SEED_SALT` / `_seed + PLACEMENT_SEED_SALT` respectively
(distinct salts, world_state.gd, same pattern `incident_scheduler.gd`'s own
`SEED_SALT` already established), so `_random` is left exactly as a fresh
`RandomNumberGenerator.seed = _seed` would be, regardless of how much
terrain/decoration/spawn-search randomness generation drew.
`test_river_generation.gd`'s `_check_generation_does_not_perturb_simulation_
stream()` asserts this directly via `WorldState.get_simulation_random_state()`
(a small test-only accessor).

**The river/tree default art-mode look was ambiguous furniture, not water or
vegetation.** `TILE_WATER`/`TILE_TREE` still point at reused atlas cells
(chair/table -- registering real cells needs `terrain_tileset.tres`, outside
every worldgen task's owned paths so far); round 1 review correctly found
that "distinct from hazard" is not the same as "reads as water." `map_view.gd`
now draws an opaque flat-colour overlay (its existing `TILE_COLORS`, the same
palette the colour-mode fallback already used) for exactly these two kinds,
on top of the TileMapLayer's mismatched sprite, in art mode -- reusing
`world.get_tiles()` once per frame exactly like the already-accepted
colour-mode renderer already does, so the TileMapLayer's own incremental
refresh is untouched. The default art-mode view now reads unambiguously as
water/vegetation; registering real atlas cells remains a future,
out-of-scope follow-up.

**The width/connectivity validator now checks corridor continuity between
adjacent cross-sections, not just each cross-section's own longest run, and
rejects a braided (multi-run) cross-section.** Two individually-6-wide,
4-connected bands offset to overlap by only one or two tiles pass every prior
check (single component, every run >= NECK_FLOOR) while still being a real
neck/over-sharp bend a colonist would experience as a bottleneck.
`test_river_generation.gd` now computes every disjoint water run per
dominant-axis position (`_cross_section_runs()`) and the transversal overlap
between each pair of adjacent positions' single runs
(`_corridor_overlap_violation()`, floor = `NECK_FLOOR`), applied to every real
seed in the suite; a position with more than one run is rejected outright.
Synthetic fixtures (`_check_one_cell_neck_detected()`,
`_check_sharp_bend_neck_detected()`, `_check_multi_run_cross_section_
detected()`) prove the validator actually rejects these shapes, and
`_check_smooth_curve_not_flagged()` proves it does not false-positive on a
legitimate smooth curve.

**Spawn accessibility is now checked per colonist, through real
`passability()`, not a merged multi-source BFS over raw tile kind.** The
previous check seeded one BFS with all three colonists' tiles and reported
the minimum distance to each resource, so two of three colonists being
unreachable or over-budget could still pass; it also treated every soil/floor
tile as walkable without consulting `passability()`, so a route could
"cheat" through an impassable berry-bush tile. `test_river_generation.gd`'s
`_check_spawn_accessibility()` now runs one BFS per colonist
(`_bfs_route_distance()`, expanding only through `world.passability(x,
y)["passable"]`) and fails if any one of the three misses its bound.
`_check_only_one_colonist_reachable_detected()` and
`_check_bush_blocked_route_detected()` are synthetic negative fixtures
proving the fixed predicate actually rejects both failure shapes.

**Full-map captures now show the whole map, not a colonist-centered crop.**
`test_river_map_capture.gd`'s "full-map" screenshots were captured centered
on the colonists at the UI's normal minimum 0.5x zoom, which crops most of a
256x256 map on any realistic window and never reliably showed both river
endpoints. The capture now temporarily enlarges the SceneTree root viewport
(capture-only; `map_viewport.gd`'s own camera contract -- 0.5x-3x zoom,
clamped in `zoom_at()` -- is unchanged, still the real path a player's own
0.5x zoom uses) so the whole map's extent fits inside it at that same real
0.5x zoom; `map_viewport.gd`'s existing `_constrain()` then centers the whole
map unconditionally (extent <= size on both axes), no tiled/stitched capture
needed. The spawn close-up capture is unchanged (1.0x, centered on the three
colonists, normal 1920x1080 window).

**`test_incidents.gd`'s shared `TICK_BUDGET` is restored to 600.** Round 1's
fix for the one real (256x256 boot-scene) incident check that ticks its own
world -- `_check_viewer_dispatches_spawn_incident()`'s wait for a
viewer-triggered actor to enter the world, which needs materially longer on a
5x-wider/taller map -- had raised the *shared* default from 600 to 1500,
silently loosening every other, unrelated small-`_build_controlled_world()`
regression's own bound. A new `BOOT_TICK_BUDGET := 1500` constant is now
passed explicitly only at that one call site; every other check keeps
`TICK_BUDGET`'s original 600-tick bound.

**`core-budgets.json`'s `world_state.gd` cap moves from 2060 to 2090.** The
RNG-stream separation above needs two local-RNG constructions (one per
generation method, each seeded from its own salt constant) plus a small
test-only `get_simulation_random_state()` accessor, all inside this file
(`_generate_map()`/`_spawn_colonists()`/a new getter) rather than
`worldgen/world_generator.gd`, since the salts are combined with `_seed`
(a `WorldState`-only field) before the module is even called.

## Round 2 revision (review findings)

**`WorldGenerator.place_spawn()`'s fallback tiers are now four strictly
ordered, always-fully-run stages, never a soft "best" that could silently
suppress a later, better-searching stage.** Round 1's random tier kept an
over-budget candidate as a "best" whenever one was found; because the
exhaustive tiers below it only ran when that "best" was still empty, a single
over-budget random hit could suppress the exhaustive scan even when a fully
compliant anchor existed elsewhere. Round 1's own exhaustive fallback also
never checked the step-limit budget at all (only reachability), and its final
relaxed tier explicitly accepted a candidate with an *unreachable* (`-1`)
resource distance -- directly violating this task's own "guaranteed
resources do not count if they are unreachable". The redesigned tiers
(`place_spawn()`'s own doc comment carries the authoritative description):
1) a random search that only ever accepts a fully-compliant candidate outright
(never a soft match); 2) `_scan_for_clearing()`, an exhaustive row-major scan
that always runs whenever tier 1 did not find one, itself preferring full
compliance and only falling back, within that same scan, to the
least-over-budget still-*reachable* anchor; 3) `_repair_land_clearing()`, a
deterministic repair/construct tier reached only when no
`clearing_width x clearing_height` all-soil rectangle exists anywhere: it
finds every 4-connected land component on the map and scores each one exactly
like tier 2 (full compliance, then least-over-budget-but-reachable, then --
only if no component anywhere is resource-reachable at all -- the first
component simply big enough for `colonist_count` colonists, honestly
reporting `-1` for any dimension that truly cannot be reached rather than
silently accepting it); 4) an absolute last-resort bounded expanding-ring
scan from `mapgen.json`'s own `spawn_area_x/y`, reached only when the entire
map has no connected land component with even `colonist_count` soil tiles
(never observed for any real generated map), which may legitimately return
fewer than `colonist_count` positions rather than ever bulldozing rock/hazard/
tree terrain. Every tier paints only tiles it already verified are soil, so
the river is never touched by any of them.

**`place_spawn()` now also returns a guaranteed-safe land-tile pool
(`clearing.land_tiles`) for starting tools and beds, replacing boot.gd's own
`clearing_x + i % clearing_width` rectangle-offset arithmetic.** That
arithmetic could point at a still-water cell whenever a fallback tier's own
rectangle was not fully painted (round 1's last-resort tier only skipped
water inside its rectangle, it did not guarantee every offset the formula
could produce was floor), and could not work at all for tier 3/4's own
scattered, non-rectangular clearings. `boot.gd`'s `_spawn_starting_tools()`/
`_spawn_starting_beds()` (see below) now draw from this pool instead, via a
shared `_claim_starting_tiles()` helper so both agree on exactly how many
pool tiles the other already claimed.

**Forced-fallback fixtures (`test_spawn_fallback.gd`, new) call
`place_spawn()` directly** (a pure static function, no `WorldState` needed)
against small synthetic maps engineered so its fast rectangle tiers cannot
succeed: the documented `spawn_area_x/y` anchor sitting in water and a berry
bush while real land exists elsewhere; a map with a perfectly good land
clearing but no water/tree/bush anywhere at all (resources genuinely
unreachable); and a map whose only connected land component is exactly
`colonist_count` tiles (too small even to reserve room for starting tools/
beds). Every fixture asserts the same invariants: exactly `colonist_count`
colonist positions, all mutually reachable through the painted floor (one
connected clearing -- same-bank connectivity), every reserved land-tile-pool
entry also connected and safe (tool/bed accessibility), and the map's own
original water tiles left byte-for-byte untouched. The seed suite
(`test_river_generation.gd`) is unchanged and still asserts `fallback` stays
`false` for every real seed; these new fixtures are what actually exercises
the tiers that suite never reaches.

**Starting-resource sufficiency is redefined around real forage yield and a
now-real rest source, not nearest-instance distance.** Each forage yields
exactly one ground berry (`world_state.gd`'s `_spawn_berries_item()`) with no
regrowth, so counting the same bush three times (once per colonist) was never
a real "sufficient" guarantee. `place_spawn()` itself only ever guarantees
ONE reachable bush per colonist (the nearest one, within
`spawn_food_step_limit`) -- never a distinct one for each of the three, since
trees are plentiful (40 by default) but bushes are scarce (8) -- so
`test_new_game_forage_chop.gd` (rewritten below) forages every distinct bush
within a wide net of the colony's own centroid instead of hand-assigning one
per colonist, and lets real need-driven `eat_food` distribute the resulting
ground berries to whichever hungry colonist reaches one first, exactly like
real play. Trees keep one distinct target per colonist (chop is not
yield-limited the way forage is). **`boot.gd` now places one "bed" object per
colonist**
(`_spawn_starting_beds()`, via the same `place_object` command path a
player-built bed would use), correcting a real gap: `content/needs.json`'s
"rest" need has `source_kind: "bed"`, but normal generation previously placed
none at all, so the rest need was permanently unmet (`need_unmet:rest`,
never once served) on every fresh New Game. With a real starting bed, sleep
now genuinely interleaves with the two other player orders under real decay,
which round 1's own text incorrectly claimed was already happening.

**Three corrections to round 1's own text above**, since round 2 review found
each contradicted the actual code: (1) "`NeedGiver` submits a `forage` job
against the berry_bush tile" is wrong -- `forage` is a player-order command
type (`world.apply({"type": "forage", ...})`), submitted directly, never by
`NeedGiver` (`need_giver.gd`'s own `JOB_KIND_BY_NEED` only ever maps to
`eat_food`/`drink_water`/`sleep`); the corrected chain is: a player or test
submits `forage` directly, which clears the bush and spawns a ground berry,
and a *separate* `eat_food` need job (submitted by `NeedGiver`) later
consumes it. (2) round 1's claim that its own test's tick loop had
`eat_food`/`drink_water`/`sleep` "interleave... exactly as they would in a
real session" was aspirational, not actual, for `sleep`: with no starting bed
anywhere, every sleep search onset-failed (`need_unmet:rest`) and never once
interleaved; this is now true, now that a bed exists. (3) round 1's own text
claimed its test "asserts: ... no colonist's food/water/rest need ever
reaches 0" -- the test's own code, both before and after this revision, does
not contain that assertion at all (and, as `test_new_game_forage_chop.gd`'s
own doc comment now explains, cannot honestly make it: `NeedGiver`, out of
this task's owned paths, only searches reactively once a need crosses
"urgent", so a source near the documented 40-step travel bound can
legitimately let a need reach 0 en route to it). That sentence is removed
rather than carried forward.

**`test_new_game_forage_chop.gd` now exercises all three colonists, not just
the first.** Round 1's version picked one forage and one chop target near
`colonists[0]` only and asserted a single aggregate `eat_food` completion;
round 2 review correctly found this proved nothing about the other two
colonists. The rewritten test forages every distinct bush within a wide net
of the colony's centroid (up to `colonist_count + 2`, since a strictly
per-colonist exclusive search could walk a colonist's own target arbitrarily
far chasing distinctness once the nearest one or two bushes were already
claimed -- observed directly while validating this revision, on this test's
own seed) and submits one chop order per colonist against its own distinct
tree, then ticks real, unmodified need decay and asserts *per colonist*: its
own chop order completes, and it individually experiences at least one real
`food`, `water`, and `rest` need restore (detected as a large single-tick
jump in that colonist's own need value, never merely inferred from a bush
being cleared) -- proving the colony's foraged berries actually reach every
colonist through the real, unmodified `eat_food` search, not that this test
hand-assigned each one its own. The tick budget
stays a generous but bounded 20000 -- empirically necessary, not arbitrary: a
colonist's in-progress `work` toil is interruptible by its own critical need
(`NeedGiver._evaluate()`, out of this task's owned paths), and with three
colonists all starting at full needs simultaneously, their first few urgent/
critical onsets land in a similar tick window, so a 25-40-tick work session
can lose a race against a fresh interruption several times before timing
desynchronises enough for an uninterrupted stretch to complete it -- observed
directly while validating this revision.

**`test_save_dimensions.gd`'s far-edge check now carves a short, deterministic
land corridor instead of falling back to whichever corner happened to be
reachable.** Round 1's version picked whichever of the four map corners was
real-route-reachable from spawn (a river can strand one corner across the
water), but round 2 review correctly found this let the check silently pass
on a low-coordinate corner like `(1, 1)`, losing the regression protection
against the legacy 48x48 bounds this item exists to catch. It now carves a
straight land corridor (direct `_tiles`/`_objects` mutation, the same pattern
`test_toils_dig_chop_regression.gd` already uses) from the real spawned
colonist's own tile to `(254, 254)`, touching no tile outside that one
corridor, so the far coordinate itself is always exercised regardless of
where the river happened to land for this seed.

**`map_view.gd`'s water/tree overlay moved from a per-frame full-map
`draw_rect` pass to a cached, incrementally-updated node between the two
TileMapLayers.** Round 1's overlay drew via this Control's own `_draw()`,
which (via `show_behind_parent` on both TileMapLayers) painted on top of
*both* of them, including the object layer -- an object `place_object`
already permits on a water/tree tile (it does not reject those cells) was
hidden underneath the overlay. It also rescanned the entire `width*height`
tile array every frame regardless of whether anything changed, undermining
this task's own "does not rebuild every cell" incremental-refresh intent.
A new `terrain_overlay.gd` node is now inserted between the base terrain
TileMapLayer and the object TileMapLayer (so an object layer cell still
paints over this overlay's water/tree rect), and is only ever repainted
through `rebuild()` (a full pass, for `set_world()`/an art-mode toggle) or
`update_cell()` (one cell, through the exact same dirty-cell boundary
`map_view.gd`'s own `TileMapLayer` refresh already uses) -- never rescanned
on an unrelated redraw (a hover change, a colonist moving).

**Two-seed interactive verification, executed through the running
viewer.** The check is "load
the running viewer with seeds 1337 and 20260919, confirm the river reads as
water at a glance, find food/water near the colonists, and complete one
player-chosen order without the river blocking access to it".
`test_river_seed_viewer_interaction.gd` (round 8) performs it through the
viewer's own input path, not through `WorldState.apply()`: for each of the
two seeds it types the seed into the visible seed field, clicks the real
"New Game" button and the real confirmation dialog's OK button, asserts the
game starts paused with an empty job queue and the HUD's active-seed label
set, verifies food and water within the documented 40-step route bound for
every colonist by an independent BFS through `passability()`, verifies the
art-mode terrain overlay paints exactly one water cell per river tile in its
blue water colour, clicks the real "Forage" tool button, left-clicks the map
on a reachable berry bush (the event travels `Viewport.push_input` ->
`MapViewport._gui_input` -> `MapView._gui_input` -> `rectangle_committed` ->
`Boot._commit_rectangle` -> `WorldState.apply()`, the player's exact path),
asserts one forage job was queued at that tile with no rejection, clicks the
real "x1" button and lets the real `TickDriver` advance the world until the
bush is foraged and ground berries lie on its tile. Run graphically
(`godot --path game --script res://scripts/tests/test_river_seed_viewer_interaction.gd -- --capture`,
OpenGL 3.3) it additionally samples the rendered frame --
the nearest river tile to colonist_0 must render blue-dominant and a plain
soil tile must not -- and writes spawn / order-placed / order-done
captures for review. Recorded
result of that graphical run (PASS, both seeds): seed 1337, colonist_0 at
(170, 252), forage clicked at (150, 255), 23 route steps, nearest bank
(170, 246), order completed after 2029 ticks at x1; seed 20260919,
colonist_0 at (191, 19), forage clicked at (187, 15), 8 route steps, nearest
bank (206, 19), order completed after 814 ticks at x1. The two orders take
hundreds of ticks because need-driven drink/eat jobs (water decays 2/tick,
food 1/tick under the current `needs.json`) interleave with the player's
order; that balance predates this task and belongs to a later
food-economy milestone, not a generator or reachability defect: the order is
never blocked by the river. Whether the art reads well remains a visual
judgement made from the captures; no merge gate rests on it.

## Round 3 revision (pre-review finding)

**`WorldState._need_source_candidates()` now filters every kind's candidates
through a new `_reachable_candidates_only()`, against the already-maintained
`RegionMap` (`_get_regions()`).** `test_new_game_forage_chop.gd` failed on a
full run: `NeedGiver`'s own per-candidate search (`jobs/givers/need_giver.gd`, out
of this task's owned paths) has no early "impossible" signal, so an
unreachable candidate only gives up after flood-filling the colonist's entire
reachable component. `_need_source_candidates("water")` names every water
tile on the map -- with issue #300's river now spanning thousands of them,
most on the far, river-crossed shore -- that turned catastrophic: two
colonists spent 1500+ ticks re-running full-map flood-fills against
near-Manhattan-distance far-shore tiles before ever reaching their own bank's
water. Filtering candidates to those reachable from a living colonist, via the
same connectivity `RouteSearch` itself resolves to, is also what the task's
own contract requires directly ("guaranteed resources do not count if they
are unreachable or on the other side of the river"): an unreachable candidate should
never have been offered to `NeedGiver` in the first place.

**`test_new_game_forage_chop.gd`'s forage/chop orders now each name their own
colonist as `assignee`.** Fixing the water hang above surfaced a second,
independent failure: colonist_0 never completed a single real `eat_food`
restore across the full 20000-tick budget, even though its own nearest bush
was reachable and berries were produced throughout the run. Root-caused by
tracing `NeedGiver`'s own `_pending`/`_searching` state tick-by-tick: an
UNRESTRICTED `forage`/`chop` order lets the fair scheduler hand it to *any*
idle colonist, with no floor on how many any one of them ends up doing. On
seed 555002, colonist_2 alone completed (and ate from) 4 of the colony's 5
one-time, non-regrowing berries. The mechanism: the instant `NeedGiver`'s own
search finds food candidates momentarily empty, it gives up without
reserving anything (`_onset_failed`, no `_pending` entry) -- so the SAME tick,
the fair scheduler (which runs immediately after `NeedGiver.advance()` inside
`WorldState.tick()`) sees that colonist as fully idle and can hand it a fresh,
multi-tick regular-job route. `NeedGiver._evaluate()` has no interrupt at all
for "en route to a regular job, toil not yet started" (only for "already
working", and only at the critical threshold) -- a gap in `need_giver.gd`,
out of this task's owned paths. Each order now sets `payload.assignee` to the
colonist it was already picked for (F3, issue #290's existing dig/chop/forage
restriction, not a new mechanism), so the fair scheduler can never hand one
colonist's own guaranteed order to a different colonist, closing off the
specific starvation path without touching `NeedGiver` itself. Verified on
seed 555002: all three colonists now complete a real `eat_food` restore
within budget.

**`core-budgets.json`'s `world_state.gd` cap moves from 2090 to 2100.** The
reachability filter above needs one new method
(`_reachable_candidates_only()`) plus its call site inside
`_need_source_candidates()`, both necessarily in this file since the RNG/
region/colonist state they read is `WorldState`-only.

## Round 5 revision (review findings)

**Starting-food sufficiency is now a concrete, enforced count of DISTINCT
reachable bushes, not a per-colonist nearest-distance check three colonists
could all pass against the very same bush.** Round 5 review correctly found
that `place_spawn()`'s own accessibility check only ever asked "is the nearest
bush within budget for this tile", so a single reachable bush satisfied that
question for all three colonists identically while forage can only ever feed
one of them (`_spawn_berries_item()`, one non-regrowing meal per bush).
`WorldGenerator._count_reachable_food_sources()` (new) now counts DISTINCT
bush tiles reachable within `spawn_food_step_limit`, required to be at least
`colonist_count * FOOD_SOURCES_PER_COLONIST` (currently 1, i.e. 3 for this
task's colony) before any tier accepts a candidate as fully compliant; a
candidate short of that count is scored exactly like an over-budget distance
(summed into the same relaxed-fallback ordering the existing tiers already
use). Because the later Fisher-Yates shuffle can hand any reserved land tile
to any colonist, the count is the WORST case over the whole candidate
footprint, not the best: a cheap multi-source BFS from the footprint first
finds every bush within budget of the footprint's NEAREST tile (a superset of
the true answer), then one bounded BFS per surviving candidate bush,
outward from the bush itself, confirms every footprint tile -- not just the
closest one -- is still within budget (`_reaches_every_tile()`). An earlier,
simpler version of this check (distance from the footprint's best tile only)
passed all 23 acceptance seeds but was provably wrong: it let seed 17's
`test_river_generation.gd` run silently overcount a bush that was in budget
from the clearing's near edge but out of budget from a colonist landing on
the clearing's far corner -- caught only once `test_river_generation.gd`'s own
independent re-count (below) used real per-colonist BFS distances instead of
the generator's own footprint-wide estimate. `test_spawn_fallback.gd`'s new
`_check_single_shared_bush_reported_insufficient()` proves the production
algorithm actually rejects the single-shared-bush shape (nearest-distance
in budget, distinct count honestly reported as 1 of a required 3, search
falls through to its documented `fallback=true` tier instead of silently
accepting it). `place_spawn()`'s returned `clearing` dict gains two read-only
fields, `food_sources` (achieved) and `required_food_sources` (the contract
value), neither persisted (`_spawn_clearing` was already scratch-only, never
part of the save schema).

**`test_river_generation.gd` independently re-verifies the same distinct-food
requirement for every acceptance seed, with its own from-scratch
implementation.** `_count_reachable_food_sources()` (test-local, never reusing
`WorldGenerator`'s own) runs a real multi-source BFS through
`world.passability()` from all three actually-spawned colonists, counting
distinct reachable `berry_bush` objects, and fails any seed with fewer than
`colonists.size()`. `_check_single_shared_bush_insufficient_food_detected()`
is the synthetic negative fixture proving this independent counter itself
correctly flags the shape the production fix now rejects, matching this
task's existing pattern of proving every checker rigorous, not just trusting
real generator output.

**`WorldState._water_tile_cache`'s lifetime invariant is now maintained
across any tile mutation that changes water membership, not assumed
immutable.** Round 5 review correctly found the round-4 perf cache false:
`_apply_place_object_command()` only rejects a tree tile, a colonist, or an
already-occupied tile -- never water -- so a `berry_bush` can be placed
directly on a `TILE_WATER` tile through the supported `place_object` command;
forage then accepts that bush and `_toil_on_work_complete()` converts the
tile to `TILE_FLOOR` exactly like any other forage target, while a cache
already built before that mutation kept offering the now-floor tile as a
"water" need source forever after -- a divergence a fresh, decoded copy
(which always rebuilds from current `_tiles`) would never exhibit.
`_update_water_tile_cache()` (new) is hooked into the exact "tile actually
changed kind" boundary `_toil_on_work_complete()` already uses to drive
dirty-cell/region/room refreshes, not a special case for forage: any future
tile-mutating toil keeps the cache correct for free.
`test_water_cache_invalidation.gd` (new) builds the cache, places and forages
a bush on a reachable water tile through supported commands, then asserts the
live world's own water candidates exclude the former water tile and match a
save/load-restored copy's independently-rebuilt candidates exactly, plus a
matching `state_hash()`.

**`core-budgets.json`'s `world_state.gd` cap moves from 2100 to 2125.** The
cache-invalidation fix above needs one new method
(`_update_water_tile_cache()`) plus its call site inside
`_toil_on_work_complete()`.

**The two-seed interactive verification is automated.**
`test_river_seed_order_completion.gd` boots the real New Game path for
exactly seeds 1337 and 20260919, independently re-verifies food/water are
within their documented step bounds per colonist, and submits and drives to
completion one forage order through `WorldState.apply()` and hand-driven
ticks. `test_river_seed_viewer_interaction.gd` (below) performs the same check
through the viewer.

## Round 8: the interactive check runs through the viewer

`test_map_camera.gd` had already been driving the real viewer with synthetic
`InputEventMouseButton` events through `Viewport.push_input` since issue
#298, so a mouse click and a look at the screen can be exercised by a test.
`test_river_seed_viewer_interaction.gd` performs the whole two-seed check
through the running viewer's own buttons, dialog, tool selection, map click
and tick driver, samples the rendered pixels in a graphical run, and records
the result in the two-seed verification paragraph above. The headless run of
the same test is a regression gate (everything but pixel sampling and PNG
output). No generator, world-state or viewer code changed in this round.
