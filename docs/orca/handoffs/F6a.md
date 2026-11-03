# F6a handoff: forest zone, plant and grow

## Branch and commit

- Branch: `antonelmejor50-hub/f6a-forest-zone-plant-and`, rebased on `origin/main` `2bc29b9`
  (the owner's F6a amendments in BACKLOG.md, docs only) on top of `2750fe3` (F5a: save schema
  v10, ADR 064; plus viewer tasks B6 and B7).
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
  - `content_registry.gd` loads and validates `forests` through `forest_content.gd`, passing
    its `TILE_SOIL` constant to `ForestContent.check()`, so no tile id is written outside the
    registry.
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
  - A ripe sapling under an actor (colonist or creature) waits, because the tree is
    impassable. A ground item, such as the felled tree's wood, does not hold it back: the
    query is WorldState's actor-only `_colonist_at`.
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
- **`core/world_state.gd`:** 1 line, passing the actor-only query `_colonist_at` to FarmSystem.
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

### Scope amendment: approved by the owner (`2bc29b9`)

REVIEW.md's scope gate asks for an owner-approved amendment for every edit above that falls
outside the owned paths. The owner approved this list unchanged as F6a's scope in BACKLOG.md,
commit `2bc29b9` ("Approved amendments ... (1) **scope**"):

> the edits declared in the F6a handoff ("Edits outside the listed owned paths") are approved as
> F6a's scope [...] each being the minimum needed to wire the zone

## Acceptance (test_forest_zone.gd, through zone_add/chop commands and tick())

| Criterion | Check |
|---|---|
| 3×3 soil + 1 farmer → 9 saplings within 2 days | `_check_plant_grow_replant_and_replay` |
| Trees after ~8 days (none before day 8; all but the tile the idle farmer stands on by day 10; every stage seen) | same |
| Chopped tree → replanted within a day | same (chop order + axe; felled tile back to a stage within one day) |
| Replanted sapling regrows into a tree with the chop's wood still on its tile | same (a second chop draws the farmer away; the felled tile is `tree` within `grow_days + 1` days, and the wood is still there) |
| Replay identical | same, A11 `ReplayLog.replay()` ok |
| Save/load identical | `_check_mid_growth_save_matches_uninterrupted_world` (saved at day 4 through SaveIO; hash compared every 100 ticks to day 11) |
| `state_hash` deterministic | `_check_same_seed_same_hash` |
| zone_add rules | `_check_zone_add_forest_rules` (crop rejected, unknown kind rejected, stockpile overlap rejected) |

### Owner decision: a ripe sapling under an actor waits (`2bc29b9`)

The owner decided the growth rule in BACKLOG.md, commit `2bc29b9` ("Approved amendments ...
(2) **growth and occupancy**"):

> a sapling only advances to the impassable `tree` stage while **no actor** stands on its tile (a
> tree must never trap a colonist); **ground items never block growth** (wood left by chopping
> must not stop the replanted sapling: occupancy query is actor-only). Acceptance keeps "all 9
> tiles are trees after ~8 days" for tiles no colonist stands on, and adds a chop → replant →
> regrow cycle with the wood still on the tile.

The branch matches it:
- TreeGrowth's query is WorldState's actor-only `_colonist_at` (colonists and creatures).
- The test asserts that the idle farmer's tile waits, and that the tree grows once a `chop`
  order sends the farmer away.
- The chop → replant → regrow row above covers the wood case.
- A "step off" toil for an idle colonist on a ripe sapling remains a possible follow-up (ADR 067,
  Consequences). It is not done here.

## Review fixes (Codex verdict REQUEST_CHANGES)

| Review item | Fix |
|---|---|
| `forest_content.gd` `SOIL_TILE` literal fails `lint_content_literals.ps1` | Constant removed; `check(raw_by_kind, soil_tile)` takes the registry's `TILE_SOIL`. Lint passes. |
| Growth query counted ground items, so chop wood held back the replanted sapling | TreeGrowth and ForestGiver now take WorldState's actor-only `_colonist_at` (colonists and creatures). New acceptance row: chop → replant → regrow with the wood still on the tile. ADR 067 and `colonist-ai.md` wording updated. |
| Out-of-scope edits need an owner-approved amendment | Approved by the owner in `2bc29b9`, quoted above. |
| Occupied-sapling exception needs an owner decision | Decided by the owner in `2bc29b9`, quoted above; the acceptance table states it. |

## Review round 2 (Codex verdict APPROVE, no blocking items)

| Non-blocking note | Response |
|---|---|
| `test_forest_zone.gd:136` checked the tick when eight trees exist, not when the first one grows | Fixed. The growth loop now records the first tick on which any forest tile is a tree, checking every tick, and asserts it is no earlier than day 8. The test also asserts there are no trees right after planting, so the planting ticks are covered too. Run output: `first tree at tick 17654 (day 8.02)`. |
| The reviewer could not rerun the suite in a read-only sandbox | Rerun here after the test change; the line is under Gate. |
| Owner confirmation on the native build after merge | Still pending (see Pending). |

## Gate

- Branch head after the round-2 test fix (the round-2 commit on top of `f00c5e8`), full suite: `run_tests: all 135 test(s) PASS  [815s]`
  - `test_forest_zone` alone: `run_tests: all 1 test(s) PASS  [22s]`; the A11 replay of the forest run still matches.
- Earlier, after the round-1 review fixes, rebased on `2bc29b9` (`f74e94d`): `run_tests: all 135 test(s) PASS  [814s]`
  - The first run after the rebase ended `run_tests: 1 of 135 test(s) failed: test_map_experience_fps_measurement  [870s]`. That test is a wall-clock FPS measurement. Run alone it passed (`run_tests: all 1 test(s) PASS  [68s]`, avg 128.44 FPS, min 127), and the full rerun above passed on the same tree with no change. The rebase itself only brought in the docs-only `2bc29b9`.
- `game/scripts/tests/lint_content_literals.ps1`:
  `lint_content_literals: PASS (no tile-id/work-ticks/move-ticks literal found outside the registry)`
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
  - New files: `tree_growth.gd` 158, `forest_giver.gd` 60, `forest_content.gd` 48 lines.
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
powershell -NoProfile -File game/scripts/tests/lint_content_literals.ps1
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
