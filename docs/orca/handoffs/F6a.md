# F6a handoff: forest zone, plant and grow

## Branch and commit

- Branch: `antonelmejor50-hub/f6a-forest-zone-plant-and`, rebased on `origin/main` `2750fe3`
  (F5a: save schema v10, ADR 064; plus viewer tasks B6 and B7).
- **Schema number (owner note).** F5a landed first and took v10, so F6a takes **v11**:
  - `_v10_to_v11()` (arm `10:`) sits after F5a's `_v9_to_v10()`, which is kept unchanged.
  - `SCHEMA_VERSION` is 11.
  - The new fixture is `save_schema_v11_fixture.json`. F5a's `save_schema_v10_fixture.json`
    is byte-identical to `main`.
- ADR: [067](../../decisions/067-forest-zones-and-saplings.md).

## What changed

- **Content:**
  - `game/content/forests.json` (+ `schemas/forests.schema.json`) is one forest:
    - stages `sapling_1..3`;
    - `grow_days` 8;
    - `grown_tile` `tree`;
    - `plant_job` `plant_sapling`.
  - `tiles.json` adds the three passable sapling stage tiles.
  - `jobs.json` adds `plant_sapling` (labour farm, no seed or item input).
  - `content_registry.gd` loads and validates `forests` through `forest_content.gd`.
- **Zone:**
  - `zone_add` takes `kind: "forest"`, and a forest zone that names a crop is rejected.
  - `zone_table.gd` adds `get_forest_zones()`.
  - Overlap rules are the existing ones.
- **Planting:** `core/zones/forest_giver.gd` (ForestGiver) runs after FarmGiver in
  FarmSystem's farming phase. On each forest zone it submits `plant_sapling` on every
  passable soil tile that no live farm job claims. A chopped tree leaves soil, so the zone
  replants it on the next tick.
- **Growth:** `core/farming/tree_growth.gd` (TreeGrowth) is composed by FarmSystem.
  - Each sapling's growth rises by one per tick, up to `grow_days * day_length_ticks`.
  - The tile flips through the stage tiles, and then to `tree`.
  - A ripe sapling under a colonist waits, because the tree is impassable.
  - It draws no RNG and iterates in sorted keys.
- **Felling:** unchanged. A tree is felled only by the manual `chop` order.
- **Save:**
  - The save gains `saplings: [{target{x,y,z}, forest, growth}]`, written in key order.
  - It is in `state_hash()` through FarmSystem.
  - It is validated by `farm_validator.gd`.
  - It ships with the v10 → v11 migration (adds an empty list) and the v11 fixture.
  - `game-state.schema.json` is updated.
- **Viewer:**
  - Control bar: a "Forest zone" tool (`controls.tool_forest_zone`).
  - `order_input` sends `kind: "forest"`.
  - Map views draw the sapling stage tiles.
  - The status label is `status.job.plant_sapling`.
- **Docs:**
  - `colonist-ai.md`: forest zones and saplings.
  - `orders-and-movement.md`: the forest zone kind.
  - `save-system.md`: saplings v11 and the v10 → v11 migration bullet.
  - `decisions/README.md`: the ADR row.
- `world_state.gd`: one line changed (+1 −1), still 767 lines. The diff adds no new
  coordinate arithmetic: cells go through `TileGrid` (`comma_key`, `coord_of_comma_key`,
  `index_of`, `tile_of`).

### Edits outside the listed owned paths (declared)

The owned paths are `core/zones/**`, `core/farming/**`, `game/data/content/**`, the viewer zone
tool, tests, migration plus fixture, and the ADR. A forest zone could not be wired without
touching these:

- **`game/content/*.json`:** the repo's content lives in `game/content/`, not
  `game/data/content/` (that directory does not exist). Files: `tiles.json`, `jobs.json`,
  the new `forests.json` and its schema.
- **`core/commands/handlers/zone_handler.gd`, `core/commands/command_checks.gd`,
  `core/objects/zone_table.gd`:** `zone_add` must accept and check `kind: "forest"`.
- **`core/content/content_registry.gd`:** registers `forests.json`.
- **`core/persistence/*`:** the migration and schema bump the task asks for
  (`save_migrations`, `state_codec`, `save_io`, `save_wire`), plus the `saplings` and
  forest-zone validators.
- **`core/world_state.gd`:** 1 line, passing the occupancy query to FarmSystem.
- **`game/data/text/en.json`:** two UI strings.
- **Viewer files beyond the zone tool:** `map_view.gd` and `tile_atlas_map.gd` draw the
  stage tiles.
- **`docs/architecture/*` and `contracts/game-state.schema.json`:** the contract docs for the
  new save field.
- **`tests/test_save_migration.gd`:**
  - F5a's v9 → v10 checks are kept.
  - A new v10 → v11 check: it migrates F5a's v10 fixture, compares the result with the v11
    fixture, and refuses a v10 state that already has saplings.
  - The v11 fixture re-encode check replaces the v10 one.
  - Older fixtures now load as schemaVersion 11.
  - No assertion was removed or loosened.
- **`tests/test_architecture_rules.gd`:** its job-kind check needs one scenario per `jobs.json`
  kind, so it gains a `plant_sapling` scenario (a forest zone on one soil tile) and the kind
  in `expected_kinds`.
- **`tests/test_content_registry.gd`:** the exact tile count goes 11 → 14 (the three sapling
  stage tiles), and a new check resolves every forest's stages, `grown_tile` and `plant_job`.
  Both are extended coverage, not weakened.
- **`tests/test_save_bounds_validation.gd`, `test_save_dimensions.gd`, `test_save_seed_fidelity.gd`:**
  their hand-built save states gain the now-required `"saplings": []` (and the seed-fidelity
  key-order list gains `saplings` after `crops`, as `save_io.TOP_LEVEL_FIELDS` writes it).
- **`docs/architecture/warnings-baseline.txt`:** lowered by `check_core_warnings.ps1 -Update`,
  as that tool asks when counts fall. The total goes 2803 → 2801, and no count rises.
- **`tests/test_toils_dig_chop_regression.gd`:** the exact job-kind check goes 20 → 21 and
  names `plant_sapling`. No assertion removed or loosened.

## Acceptance (test_forest_zone.gd, through zone_add/chop commands and tick())

| Criterion | Check |
|---|---|
| 3×3 soil + 1 farmer → 9 saplings within 2 days | `_check_plant_grow_replant_and_replay` |
| Trees after ~8 days (none before day 8; all but the farmer's tile by day 10; every stage seen) | same |
| Chopped tree → replanted within a day | same (chop order + axe; felled tile back to a stage within one day) |
| Replay identical | same, A11 `ReplayLog.replay()` ok |
| Save/load identical | `_check_mid_growth_save_matches_uninterrupted_world` (saved at day 4 through SaveIO; hash compared every 100 ticks to day 11) |
| `state_hash` deterministic | `_check_same_seed_same_hash` |
| zone_add rules | `_check_zone_add_forest_rules` (crop rejected, unknown kind rejected, stockpile overlap rejected) |

**Design deviation (consequence, not a choice).** A colonist that stands on a ripe sapling
blocks it from becoming a tree, because the tree is impassable. This happens when the idle
farmer parks on its last planted tile. The test asserts the wait, and that the tree grows
once the farmer leaves (sent to fetch the axe for the chop).

Suggested follow-up (not done here): a "step off" toil for an idle colonist on a ripe
sapling. ADR 067 lists it under Consequences.

## Gate

- Branch head, full suite: `run_tests: all 135 test(s) PASS  [815s]` (rebased on `2750fe3`)
- `tools/check_core_warnings.ps1`: `check_core_warnings: OK, 2801 warning(s), none above baseline`.
  - The first run after the rebase failed: `unsafe_call_argument` was +7 in `zone_handler.gd`,
    `farm_system.gd`, `tree_growth.gd` and `forest_giver.gd`.
  - The fix was typed locals for those `Variant` arguments, with no behaviour change.
  - The total is now 2 below the old baseline, and the baseline was lowered to match.
- `python tools/check_core_budgets.py`:
  `OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file cap(s), 1 file and 3 function exception(s))`.
  No cap was raised.
- `tools/measure_core.ps1` figures:

  | | Core total | Files |
  |---|---|---|
  | Branch | 22766 lines | 112 |
  | `main` `2750fe3` | 22417 lines | 109 |

  - `world_state.gd` is 767 lines on both.
  - New files: `tree_growth.gd` 157, `forest_giver.gd` 60, `forest_content.gd` 49 lines.
  - `farm_system.gd` goes 248 → 279 lines.
- `manifest.json` lists only a version (no content file list), so it needed no change.
- Tests: 134 `test_*.gd` on `main`, 135 on the branch (`test_forest_zone.gd` is new). None
  removed or weakened.

## Verification commands

From the repo root (`$GODOT` = `C:\dev\Going Deeper\tools\godot\Godot_v4.7.2-stable_win64_console.exe`):

```
powershell -NoProfile -File tools/run_tests.ps1
powershell -NoProfile -File tools/run_tests.ps1 -Filter test_forest_zone -SkipImport
powershell -NoProfile -File tools/run_tests.ps1 -Filter test_save_migration -SkipImport
python tools/check_core_budgets.py
powershell -NoProfile -File tools/measure_core.ps1
powershell -NoProfile -File tools/check_core_warnings.ps1
# regenerate the v11 fixture (must come out byte-identical):
"$GODOT" --headless --path game --script ../docs/orca/handoffs/F6a-write-save.gd -- "<abs repo>/game/scripts/tests/fixtures/save_schema_v11_fixture.json"
git diff --exit-code game/scripts/tests/fixtures/save_schema_v11_fixture.json
```

## Pending

- Owner confirmation on the native build (post-merge): paint a forest zone with the
  control-bar tool and watch the saplings grow.
