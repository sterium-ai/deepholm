# Map experience: PC camera and designation

Issue #298 delivers the current map as a clipped play area.
PC is the temporary validation target; mobile remains part of the product
vision. This slice adds no touch gestures or simulation/save/content changes.
See [ADR 018](../decisions/018-pc-map-presentation.md).

## Controls and layout

- The wrapping toolbar and help line stay above the map. The status, labour
  table, calendar banner and colonist information remain in a separate panel
  with horizontal and vertical scrolling. They never inherit camera movement.
- Middle-button drag pans; Space + left-button drag is the alternative; a plain left-button drag pans too when no tool is selected.
- The wheel zooms around the cursor from 0.5x through 3x. At a map boundary,
  clamping takes precedence over preserving the cursor anchor. A map smaller
  than the available area is centered independently on each axis.
- **Center colonists** centers their mean tile center, subject to those same
  bounds, without changing zoom or issuing gameplay commands.
- Start in **Navigate**, with no active tool and no reticle. Tool buttons show
  the selected tool. Escape or Navigate leaves the tool. Tool switching,
  panning, zooming, focus loss, loading, and centering discard an unfinished
  rectangle. A release over the HUD cannot commit a map order.
- Only active tools show a local hover/rectangle grid. Green cells are valid;
  red cells with a slash are invalid. Validity uses read-only
  `WorldState.preview()` checks; no live events or jobs are created by preview.
  Tick refresh rechecks changed world conditions.
- Release confirms through the existing command boundary (one command per
  tile, or one rectangle command for Zone and Wall). Actual rejection reasons still
  appear in the panel. The grid disappears on confirmation until another mouse
  movement. Pending jobs remain visible as faint yellow fills, without tile
  borders; existing job/colonist information and Cancel remain available.
- Wall arms the existing filled rectangle gesture (a click is a 1x1 rectangle).
  Wooden (default) and Stone toggle buttons select `wooden_wall` / `stone_wall`.
  Release submits exactly one `build_line` with the entire row-major tile list.
  Preview checks that same batch once: skipped tiles are red, surviving tiles
  green, and a whole-batch rejection makes every candidate red. Changing material
  refreshes preview immediately, without persistent state. There is no instant
  wall placement or single-tile `build` wall toolbar path.
- Door, Bed and Workbench retain their click-to-build buttons. Rotatable
  kinds expose a Rotate button and the `R` key; both toggle the pending
  orientation before commit. A rotated preview resolves every footprint tile
  and colours each tile green/red from `WorldState.preview()`'s placement rules.
- Construction sites draw the placed-object sprite at approximately 50% alpha
  in their current orientation. A 32x3px two-colour countdown bar sits one tile
  above the sprite and drains from full to empty using the site's public
  `progress` and `build_ticks` values; the viewer does not own progress state.

## Large-map presentation (issue #299)

`map_view.gd` sizes itself to the attached world's own `get_map_width()`/
`get_map_height()`, not a fixed constant, so `map_viewport.gd`'s pan/zoom
bounds always match whichever world is live (48x48 fixture or a 256x256
game). `set_world()` performs one full `TileMapLayer` rebuild; every
subsequent `refresh()` (called once per tick) instead replays only the
newly-appended tail of `WorldState.get_dirty_cells()` (an append-only log of
every cell whose tile kind or object changed) since the last call, so a tick
with no dig/chop/forage/till/sow/place_object/remove_object touches zero
`TileMapLayer` cells rather than clearing and rebuilding all of them. Loading
a different world resets the consumed-log cursor and forces a fresh full
rebuild, invalidating any stale cached cell content. Colonist sprites and the
designation overlay were already `O(colonists)`/`O(jobs)`, not `O(map)`, so
neither needed a change. See
[ADR 019](../decisions/019-world-dimensions-and-generation.md).

## Shared coordinates and transient state

`viewer/map_viewport.gd` owns a clipped Control and the map child's position
and scale. Rendering in both art and flat modes uses that child transform.
`screen_to_world()` uses its inverse global canvas transform;
`screen_to_tile()` floors world pixels divided by the existing tile size.
Every forwarded mouse position uses that same inverse. Preview and commit
share `MapView.tiles_in_rectangle()`, including row-major order and map bounds.
No camera, tool, hover, or drag data is serialized.

| State | Trigger | Next state | Persisted data |
| --- | --- | --- | --- |
| Navigate | Choose tool | Tool hover | None |
| Navigate | Left press, no tool | Pending pan | None |
| Pending pan | Motion beyond dead zone | Panning | None |
| Pending pan | Release, no motion beyond dead zone | Navigate | None |
| Tool hover | Left press on map tile | Rectangle preview | None |
| Rectangle preview | Move | Updated bounded preview | None |
| Wall hover/rectangle | Choose Wooden/Stone | Same candidates, refreshed batch validity | None |
| Rectangle preview | Left release on map | Tool, grid cleared | Existing order command effects only |
| Any tool/rectangle | Escape or Navigate | Navigate, grid cleared | None |
| Any tool/rectangle | Pan press | Panning, rectangle discarded | None |
| Panning | Matching release | Selected tool, grid cleared | None |
| Rectangle | Release over HUD | Selected tool, rectangle discarded | None |
| Any gesture | Zoom, center, load or focus loss | Gesture discarded | None |
| Any | Viewer destruction/restart | Navigate with fresh camera | None |

## Acceptance tests

`test_map_camera.gd` sends events through the actual Viewport GUI dispatch,
not directly into a fake command fixture. At 1280x720 and 1920x1080 it verifies
0.5x/1x/3x conversion after pan, exact preview/confirmation equality, real chop
jobs for valid cells, map edges, cursor anchoring, bounds, small-map centering,
HUD isolation, both pan gestures, Escape, and the Center button. It runs in
the existing automatic `run_all_tests.ps1` discovery. No runner change needed.

```powershell
godot --headless --path game --script res://scripts/tests/test_map_camera.gd
godot --path game --script res://scripts/tests/test_map_camera.gd -- --capture
```

The second command renders the real build and writes viewport PNG captures
for visual review; it must run with a graphical display. Captures are review
material, not committed files. Automated input is not a claim of human
testing: manual panning, zooming, centering and designating at two zooms
remain part of acceptance.

## Performance instrumentation (issue #299)

`test_map_experience_benchmark.gd` (`game/scripts/tests/`) measures a
256x256, seed-42 world's generation, save/load, `TileMapLayer` full rebuild
and no-op-refresh cost, and `MapViewport.pan_by()` cost, and prints them. It
runs in the automatic test discovery and always passes -- it is CPU-bound
headless instrumentation (world generation and `MapViewport`'s own transform
math, not a rendered GPU frame), not a pass/fail performance gate a slower or
faster machine should fail on. The rendered-frame counterpart, with a real
display/GPU active, is `test_map_experience_seed42_flow.gd` below.

```powershell
godot --headless --path game --script res://scripts/tests/test_map_experience_benchmark.gd
```

Representative headless figures on a development machine:

```text
world generation: ~21 ms
encode: ~12 ms, write_atomic: ~390 ms, read+integrity: ~310 ms, decode: ~23 ms
TileMapLayer full rebuild (set_world): ~30 ms over 65536 cells
TileMapLayer no-op refresh (no terrain change): ~0.04 ms, 0 cells touched
camera pan_by(): ~0.001 ms/call over 200 calls
```

`write_atomic`/`read+integrity` are dominated by exact seed/rng restoration
through a structural JSON walk (see "Seed fidelity" in
`docs/architecture/save-system.md`): `write_atomic` reads its own
just-written candidate back through the same structural walk before
accepting it, so it pays this cost too, not just `SaveIO.read()`.

The no-op-refresh row makes the incremental-refresh requirement concrete: a
tick with no terrain change touches 0 of 65536 cells, not a full rebuild.

## Graphical round trip (issue #299)

`test_map_experience_seed42_flow.gd` (`game/scripts/tests/`) is an automated
graphical exercise of the full flow -- New Game with seed 42, a reproducible
60-step pan sequence to the opposite (far) corner, a real dig order issued
through the actual pointer/tool path, Save, Load -- run through the real Boot
scene's own button handlers (`_on_new_game_pressed`/
`_on_new_game_confirmed`/`_on_save_pressed`/`_on_load_pressed`), not a
headless StateCodec-level round trip. It asserts terrain, colonist positions,
and the far-corner order are identical after the real Save/Load round trip.
With `--capture` (non-headless) it also captures rendered screenshots and
separately times New Game (generation), the pan sequence (per frame, waiting
on `RenderingServer.frame_post_draw` so each sample is real GPU-rendered frame
time, not just queued work), Save, and Load, each on its own. It runs in the
automatic test discovery (headless, no capture) and always passes there;
graphical capture is a separate, explicit run. It uses an isolated
SaveManager directory, never the default `user://saves`.

```powershell
godot --headless --path game --script res://scripts/tests/test_map_experience_seed42_flow.gd
godot --path game --script res://scripts/tests/test_map_experience_seed42_flow.gd -- --capture
```

Representative figures with a real display and GPU at 1280x720
(`gl_compatibility` renderer):

```text
New Game (create 256x256, seed 42): ~129 ms
rendered pan: ~5.8 ms/frame avg over 60 steps (RenderingServer.frame_post_draw per step)
Save: ~399 ms, Load: ~1051 ms
```

Save/Load cost comes from exact seed/rng restoration walking the save's JSON
structurally (`SaveIO._scan_object_members()`,
`docs/architecture/save-system.md`), a GDScript-interpreted parse chosen for
correctness against escaped keys and envelope decoys that a native regex
search could not handle. That cost is deliberate and must not be reduced by
weakening those checks.

## Main river and correlated vegetation (issue #300)

The scattered-water terrain from issue #299 is replaced by a single main
river and grove-correlated vegetation/food; the fixed `(2, 2)`-`(8, 8)` spawn
rectangle is replaced by a river-aware, resource-validated search. The full
algorithm, its width contract, the spawn search's bounded-attempts/documented-
fallback design, and the default-boot/debug-scenario split are in
[ADR 020](../decisions/020-river-vegetation-and-spawn-generation.md); this
section only records the acceptance tests.

```powershell
godot --headless --path game --script res://scripts/tests/test_river_generation.gd
godot --headless --path game --script res://scripts/tests/test_river_map_capture.gd
godot --path game --script res://scripts/tests/test_river_map_capture.gd -- --capture
godot --headless --path game --script res://scripts/tests/test_river_seed_viewer_interaction.gd
godot --path game --script res://scripts/tests/test_river_seed_viewer_interaction.gd -- --capture
```

`test_river_generation.gd` covers a fixed >=20-seed suite (reproducibility,
crossing two opposite edges, single 4-connected water component, no isolated
water tile, width >= the 4-tile neck floor including curves, no width spike),
proves its own connectivity check against a synthetic broken (multi-component)
river and a synthetic diagonal-only-connected river, and verifies -- via an
independent from-scratch BFS, not a reuse of `WorldGenerator`'s own distance
fields -- that all three spawned colonists reach water/food/trees within
40/40/50 real route steps, with the search's own `"fallback"` flag `false`
for every seed. `test_spawn_fallback.gd` calls `WorldGenerator.place_spawn()`
directly against small synthetic maps that force its repair/construct tiers
to actually run (a hostile documented anchor, resources reachable nowhere on
the map, a connected land component with only exactly `colonist_count`
tiles), asserting three connected colonist positions, an untouched river, and
honestly-reported (`-1`, never fabricated) resource distances when a resource
truly cannot be reached. `test_river_map_capture.gd` drives the real New Game
button path (never a hand-built fixture) for seeds 42, 1337 and 20260919
through the real (default, art-mode) renderer; with `-- --capture` it renders
the real build and captures a full-map overview and a spawn close-up per
seed. The full-map overview temporarily enlarges the capture-only root
viewport so the whole map fits at the real 0.5x zoom; `map_viewport.gd`'s
camera contract (0.5x-3x zoom, clamped in `zoom_at()`) is untouched, and its
`_constrain()` centers the entire map in frame, showing both river endpoints
and every edge -- not a colonist-centered crop, and not a stitched capture.
The spawn close-up restores the normal 1920x1080 window and captures at 1.0x
centered on the three colonists.

`test_river_seed_viewer_interaction.gd` checks the player-facing acceptance
-- the river is recognisable at a glance, food and water are near the
colonists, and a first order completes without the river blocking it --
through the running viewer for seeds 1337 and 20260919: the visible seed
field, the real New Game button and confirmation dialog, a paused start with
an empty job queue, the HUD's active-seed label, food and water within 40
real route steps of every colonist, the art-mode renderer painting every
river tile as water, the real Forage tool button, a real left click on the
map at a reachable bush (routed through `Viewport.push_input` ->
`MapViewport` -> `MapView` -> `Boot` -> `WorldState.apply()`), the real x1
button and the real `TickDriver` until the bush is foraged. The graphical
`-- --capture` run also samples the rendered frame (river tile
blue-dominant, soil tile not) and writes spawn / order-placed / order-done
captures.

## Sustained-load measurement (issue #344)

Two graphical tests exercise the map under realistic use, following the same
real-`Boot`-scene, real-pointer-path pattern as
`test_map_experience_seed42_flow.gd` above:

- `test_map_pc_playtest_flow.gd` (`game/scripts/tests/`) drives a 9-step
  session: new seed, pan, zoom, center, designate, complete, save, load,
  continue. In its opt-in graphical mode (`--capture`, real display) it paces
  the session to a measured >=300 s total and asserts the HUD
  (`Boot._ui_scroll`/`Boot._controls`) stays visible across every gesture.
- `test_map_experience_fps_measurement.gd` (`game/scripts/tests/`) drives a
  60-second sustained-load window (3 colonists, 30 local `till` orders,
  alternating pan/zoom, 256x256 at 1920x1080). It samples the rendered frame
  interval (with `--capture`), buckets it per real second, and asserts that
  no single `MapView` refresh during the whole window reconstructs all 65536
  cells -- the same invariant `test_map_view_incremental.gd` proves in
  isolation.

Measured result: average 161 FPS and p95 frame time 5.89 ms both clear the
>=30 FPS / <=50 ms target with a wide margin, and at most 1 of 65536 cells
was touched by any single refresh in the window (no full-map rebuild). The
strict *sustained* criterion (every real second's own frame count >=30 FPS)
is not yet met: one reproducible ~1-second stall, paid before rendering (not
inside the GPU pipeline), recurs near the 30 s mark of the window. Its
responsible subsystem (core vs. viewer presentation callbacks) is not yet
profiled; that profiling is open follow-up work.

```powershell
godot --headless --path game --script res://scripts/tests/test_map_pc_playtest_flow.gd
godot --path game --script res://scripts/tests/test_map_pc_playtest_flow.gd -- --capture
godot --headless --path game --script res://scripts/tests/test_map_experience_fps_measurement.gd
godot --path game --script res://scripts/tests/test_map_experience_fps_measurement.gd -- --capture
```
