# Deepholm — Godot project

> **In short:** This folder holds the playable game. It explains how to start it, where each part of the code lives, and how to run the automated tests.

This directory is the Godot 4 project. The authoritative simulation is written
from its own contracts (`docs/architecture/`) and never depends on scenes,
rendering or wall-clock time.

## Run

```text
godot --headless --path game --import      # once, builds the class cache
godot --path game                          # play (or open project.godot in the editor)
godot --headless --path game --quit-after 1   # headless boot check
```

`*.import` files are pinned to LF in `.gitattributes`, so the import leaves `git status` clean.

The boot scene (`scenes/boot.tscn` + `scripts/boot.gd`) starts a paused, seeded
New Game with the map viewer, order toolbar, colonist panel and work-priority
table. `WorldState` receives an explicit seed and advances only through
`tick()` and `apply(command)`.

## Layout

- `scripts/core/` — the deterministic simulation (world state, job engine,
  scheduling, routing, regions/rooms, combat, incidents, persistence, world
  generation). No scene, node or rendering dependencies.
- `scripts/viewer/` — presentation: map rendering, colonist sprites, panels,
  tick pacing. Talks to the core only through getters, `apply()` and `tick()`.
- `scripts/tools/` — resource builders (tile set, colonist frames) and a
  screenshot tool.
- `scripts/tests/` — headless test scripts, save fixtures and lints.
- `content/` + `content/schemas/` — gameplay rules as JSON, with schemas.
- `data/` — viewer text table, tile set and sprite frames, plus example
  records and schemas.
- `assets/generated/` — original placeholder pixel art produced by
  `tools/generate_placeholder_art.py`; see `assets/CREDITS.md`.

## Tests

No external test framework is required:

```text
godot --headless --path game --script res://scripts/tests/test_world_state_determinism.gd
tools/run_tests.sh [path-to-godot]                             # whole suite, from the repo root
pwsh game/scripts/tests/run_all_tests.ps1 -GodotPath <godot>   # whole suite, PowerShell
```

`test_world_state_determinism.gd` replays an identical command/tick sequence
against two seeded `WorldState` instances and asserts equal `state_hash()` and
event logs, plus map/spawn invariants, rejection categories, tick advancement,
event ordering and the read-only snapshot boundary (see
`scripts/core/commands/README.md` for the command contract).

### Running one subject

`tools\run_tests.ps1 -Filter <text>` runs every `test_*<text>*.gd` (a substring of the file
name). Filters by subject:

| Subject | `-Filter` | Files |
| --- | --- | --- |
| Tool items (content, reservations, fetch, handover, save) | `tool_items` | `test_tool_items*.gd` (5) |
| Combat (damage and death, flee, approach) | `combat` | `test_combat*.gd` (3) |
| Rescue (assignment, routing, persistence) | `rescue` | `test_rescue*.gd` (3) |
| Trench traps | `trap` | `test_trapped_actors.gd` |
| Needs and need jobs | `need` | `test_needs`, `test_need_jobs`, `test_haul_need_interrupt` |
| Hauling | `haul` | `test_haul_stockpile`, `test_haul_need_interrupt` |
| Building and construction sites | `build`, `construction`, `wall` | `test_build*`, `test_construction_*`, `test_wall_orders` |
| Incidents and visitors | `incident`, `wolf`, `trader`, `migrant` | one file each |
| Scheduling and labour | `schedul`, `labour` | `test_*scheduling*`, `test_labour_*` |
| Routing | `route` | `test_reroute*`, `test_route_search_recorded` |
| Factions | `faction` | `test_faction*`, `test_set_faction_command` |
| Saves | `save` | `test_save_*`, `test_autosave_trigger`, `test_tool_items_save` |
| Content and packs | `content`, `pack` | `test_content_*`, `test_*_content`, `test_*pack*` |
| World generation | `river`, `worldgen` | `test_river_*`, `test_worldgen_determinism` |
| Map view and viewer flows | `map` | `test_map_*`, `test_river_map_capture`, `test_tile_atlas_map` |
| Orders | `order` | `test_area_orders`, `test_order_input`, `test_*order*` |
| Determinism | `determinism` | world, worldgen and save determinism |
| Architecture rules | `architecture` | `test_architecture_rules` |

Tests read and set up simulation internals only through `TestAccess`
(`scripts/core/world/test_access.gd`), never through `world._field`. Shared scenario builders
are in `scripts/tests/support/scenarios.gd`. The tool-items, combat and rescue test files
extend `support/tool_items_base.gd`, `support/combat_base.gd` and `support/rescue_base.gd`,
which hold their shared helpers. `support/` is not scanned for tests, so never name a file
there `test_*.gd`.
