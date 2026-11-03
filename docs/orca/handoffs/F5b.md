# F5b handoff: labours cook and heal; cooking

## Branch and commit

- Branch: `antonelmejor50-hub/f5b-labours-cook-and-heal`, rebased (on the owner's note) onto
  `origin/main` `5724053` (F6a, #53: schema v11, ADR 067; F5a's v10 is under it). One commit,
  not pushed.
- **Schema number.** Save schema **v12**, the owner's allocation: F5b's step is
  `_v11_to_v12()`, after F5a's v9 -> v10 and F6a's v10 -> v11, which are kept unchanged.
- ADR: **065** (owner's allocation), `docs/decisions/065-cook-and-heal-labours-and-cooking.md`.

## What changed

Design: BACKLOG F5b (closed with the owner on 2026-10-30), recorded in ADR 065.

Content:
- `objects.json`: `kitchen`, rotatable 2x1 impassable bench (`build_ticks` 120,
  `max_builders` 2, cost 2 wood + 5 stone), same shape as `workbench`.
- `recipes.json`: `meal` (bench `kitchen`, `job: "cook_work"`, 2 `food` -> 1 `meal`).
  `recipes.schema.json`: optional `job`, enum `craft_work | cook_work`.
- `items.json`: `meal`; optional `satiety` (`food` 40, `meal` 100). `items.schema.json`:
  `satiety` integer >= 1.
- `jobs.json`: `cook_work` (labour `cook`, toils `reserve, go_to, work, release_all`,
  `work_ticks` 60): `craft_work`'s shape under the cook labour.
- `actors.json` labour table and `WorldState.LABOUR_KINDS` (one line in `world_state.gd`,
  still 767 lines): `heal` appended as the eighth labour. `skills.schema.json` and
  `scenarios.schema.json` accept `heal`. `en.json`: `work_table.labour.heal` ("Heal") and
  `status.job.cook_work` ("Cooking").

Simulation:
- `recipe_book.gd`: `WORK_KINDS` and `work_kind_of(recipe)` (the recipe's `job`, default
  `craft_work`).
- `craft_giver.gd`: submits `work_kind_of(recipe)` instead of a literal `craft_work`.
- `crafting_system.gd`: watches `["craft_fetch"] + RecipeBook.WORK_KINDS`.
- `toil_bindings.gd`: `cook_work`'s `work` completion goes to the same bill completion as
  `craft_work`.
- `needs_system.gd`: food sources are berry bushes (restore 100) and tiles holding an
  unreserved edible ground item (restore = best `satiety` on the tile).
  `need_source_ranks(kind)` gives each source tile its best restore in one pass over the
  items. `consume` eats what ranked the tile: a berry when the tile has one and no item beats
  it, else one unit of the most filling unreserved item; a gone target fails typed
  (`source_gone`). Items reserved by a haul/fetch are never eaten.
- `need_giver.gd`: an optional `source_ranks` callable. Each colonist's candidates (after its
  own reachability filter, claimed and reserved tiles dropped) sort by rank, then distance;
  the search stops at the first lower-ranked candidate once a route is found. So the best
  source that colonist can reach and use wins, the nearest within it. Without the callable
  every source ranks equally (other needs: unchanged).

Persistence (schema v12):
- `save_migrations.gd`: `_v11_to_v12()` adds `heal` to every colonist's `labourTable`
  (level 3) and, when present, `skills` (`{level: 0, xp: 0}`), keys sorted. `skills` is
  optional in a save (seeded on load), so a colonist without it migrates unchanged there. It
  refuses a colonist that already has `heal`, lacks `labourTable`, or has a non-map `skills`.
  Arm `11:`.
- `state_codec.gd`: `SCHEMA_VERSION` 12. `entity_validator.gd`: `heal` added to its two labour
  key lists. `game-state.schema.json`: `const 12`, `heal` in both maps, `cook_work` in the
  job kind enum.
- Fixture: `game/scripts/tests/fixtures/save_schema_v12_fixture.json`, written by
  `docs/orca/handoffs/F5b-write-save.gd` on the rebased branch (state hash `237246710`).

Docs: ADR 065, `decisions/README.md` row, `save-system.md` (v11 -> v12 step),
`colonist-ai.md` (food sources and satiety tier), BACKLOG F5b status row.

## Files outside the owned paths (approved)

The owned paths are the labour table content, `objects.json`, `recipes.json`, `items.json`,
`needs_system.gd`, `core/crafting/`, tests and this report. The design needs these other
files; each change is the minimum for it. **Approved** by the owner as F5b's scope (review
round 1): BACKLOG F5b "Approved amendment (owner's interface, 2026-11-03, review round 1):
scope", main commit `1198125` (docs only).

| File | Why |
|---|---|
| `jobs.json`, `toil_bindings.gd`, `craft_giver.gd` | `cook_work` must exist as a job kind under labour `cook`, be submitted by the bench giver and complete the bill (design: "only colonists with cook enabled cook"). |
| `world_state.gd` (2 lines, still 767) | `LABOUR_KINDS` is the code-side labour table; `heal` appended. The `NeedGiver` construction passes `_needs_system.need_source_ranks` (an argument on an existing line). |
| `jobs/givers/need_giver.gd` | Per-colonist ranking of food sources (review blocking item 1): the rank must apply after each colonist's reachability filter and claims, which live in the giver. |
| `items.schema.json`, `recipes.schema.json`, `skills.schema.json`, `scenarios.schema.json` | New fields/values must validate (REVIEW: new content has a schema entry). |
| `save_migrations.gd`, `state_codec.gd`, `entity_validator.gd`, `game-state.schema.json`, `save-system.md` | `heal` in persisted labour tables and skills is a save format change: bump, migration, fixture (REVIEW "Save format"). |
| `en.json` | Work-table label for `heal` and the status text for `cook_work`. |
| `colonist-ai.md`, `decisions/README.md`, ADR 065 | Docs of the changed behaviour; ADR 065 is the owner's allocation. |
| `docs/orca/handoffs/F5b-write-save.gd` | Fixture writer, same pattern as `F3-write-save.gd`. |
| `docs/orca/handoffs/F5b-write-noskills-save.gd` | Writer of the skill-less v11 fixture (review blocking item 3). |
| `docs/orca/handoffs/F5b-hash_projection.gd` | Evidence for the dig/chop hash literal move, same pattern as `L2-hash_projection.gd`. |
| `docs/orca/handoffs/F5b-baseline_projection.gd` | Evidence for the determinism baseline literal move. |
| `game/data/sprite_frames/world_pack.json` | `test_world_pack` requires every object kind and item to have pack art or a placeholder entry: `kitchen` and `meal` get placeholder entries with a reason (no art chosen yet). |

The branch changes BACKLOG F5b only in its status line; the scope approval is main's amendment
(`1198125`), which the branch does not duplicate. Zones, `ZoneTable` and `world_state.gd` beyond those two
lines are untouched.

## Tests

- New `test_cooking.gd` (6 checks, all through commands and ticks):
  - acceptance: a built kitchen, 6 raw food, cook enabled on one colonist only, "keep 2
    meals" -> 2 meals in the stockpile, exactly 2 raw food left, only the cook ran
    `cook_work`, no `craft_work`, no bill left, a twin world with the same seed matches
    `state_hash()` every 100 ticks and at the end;
  - a hungry colonist eats a meal 7 tiles away before raw food 1 tile away (need >= 95), and
    with no meal eats one raw food (need 35..40);
  - a meal the colonist cannot reach (walled off by rock) or whose tile another job holds
    does not stop it eating raw food (food 3 -> 2, meal kept, need 35..40);
  - a tile with a berry and raw food: the berry is eaten (need >= 95), the food stays;
  - save/load mid-`craft_fetch` (carrying) and mid-`cook_work` continue identically for 300
    ticks;
  - a session recorded through the viewer's `CommandRecorder` replays every checkpoint.
- Changed tests (no assertion removed or loosened; `_check_|_expect(|_fail(` counts vs
  `main`):
  - `test_save_migration.gd` 235 -> 255: the v11 -> v12 step (F6a's v11 fixture migrates and
    gains only `heal`), the committed `save_schema_v11_noskills_fixture.json` (the v11
    fixture with colonist `skills` dropped, written by
    `docs/orca/handoffs/F5b-write-noskills-save.gd` through `SaveIO.commit_body()`, whose
    read-back migrates and validates it) migrates with `heal` in the labour table only and loads
    through `SaveIO.read()`, its
    refusals, the v12 fixture loads and re-encodes unchanged; older
    fixtures now migrate through v12. F5a's v9 -> v10 check expects the current version instead
    of a literal 11.
  - `test_architecture_rules.gd` 75 -> 76: execution trace for the kitchen.
  - `test_labour_table.gd` 34 -> 34: the expected key list has 8 labours.
  - `test_crafting.gd` 79 -> 79: the base bundle ships 5 recipes (was 4).
  - `test_toils_dig_chop_regression.gd` 16 -> 16: `jobs.json` declares 22 kinds (was 21),
    `cook_work` among them. Its hash literals moved, 195318204 / 4154555954 ->
    3133873738 / 2587936448: both colonists' labour table and skills gain a `heal` entry.
    `docs/orca/handoffs/F5b-hash_projection.gd` runs the test's scenario, drops `heal` from the
    snapshot and gets both old literals back (`MATCH`), so stepping did not change. The literals
    were printed by that run, not derived by hand.
  - `test_world_state_determinism.gd` (count unchanged): `PRE_INCIDENT_BASELINE_HASH`
    2778412269 -> 2396113793. Seeding draws one more skill per colonist (`heal`) from the shared
    skill RNG, so every colonist's starting levels change, and each map gains a `heal` entry.
    `docs/orca/handoffs/F5b-baseline_projection.gd` builds the test's world, re-draws the skills
    over the pre-F5b labours from the same RNG, runs the 650 ticks, drops `heal` and gets
    2778412269 back (`MATCH`). The new literal was printed by that run (and the test).
  - `test_world_pack.gd`: unchanged; it passes through the two new placeholder entries in
    `world_pack.json`.
  - `test_save_bounds_validation.gd` 24 -> 24: its hand-built current-schema colonist has
    `heal` in its labour table.
  - `test_farm_zone.gd` 61 -> 61: harvested `food` is now edible, so hungry colonists ate it
    and the stockpile counts fell short. `_feed()` puts one 1000-berry patch per colonist at
    (0, 0..5) as bootstrap state (so the replay check has it too); berries (restore 100) go before
    raw food (40), and the checks count what the farm makes, unchanged. One patch per colonist
    since round 1: the food ranking is now per colonist after claims, so with a single patch the
    five colonists not holding it ate stockpiled food (29 < 32), as ADR 065 now says they should.
- Test files: 135 `test_*.gd` on `main`, 136 on the branch.

## Validation

Run from the repo root (Windows PowerShell):

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_cooking
python tools/check_core_budgets.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check_core_warnings.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/measure_core.ps1
```

Hash projection (from `game/`, `$G` = the Godot 4.7.2 console binary), expected last lines
`F5b-hash_projection: MATCH` and `F5b-baseline_projection: MATCH`:

```
"$G" --headless --path . --script ../docs/orca/handoffs/F5b-hash_projection.gd
"$G" --headless --path . --script ../docs/orca/handoffs/F5b-baseline_projection.gd
```

Results on the branch head:

- Full suite, final line: `run_tests: all 136 test(s) PASS  [869s]`
- `check_core_budgets`: OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file
  cap(s), 1 file and 3 function exception(s)). No cap raised.
- `check_core_warnings`: OK, 2798. Below the old baseline 2801 (typed locals in the new code
  also cleared three old `unsafe_call_argument` sites), so `docs/architecture/warnings-baseline.txt`
  is lowered to 2798 with `-Update`, as the gate asks.
- `measure_core`: `core total: 22910 lines in 112 files`. Touched core files:

  | File | Total | Code | Longest function | Its lines |
  |---|---|---|---|---|
  | `world_state.gd` | 767 | 593 | `state_hash` | 30 |
  | `crafting/crafting_system.gd` | 573 | 456 | `apply_command` | 34 |
  | `persistence/state_codec.gd` | 596 | 436 | `decode` | 70 |
  | `jobs/toil_bindings.gd` | 499 | 375 | `_init` | 49 |
  | `actors/needs_system.gd` | 451 | 354 | `ensure_needs` | 45 |
  | `jobs/givers/need_giver.gd` | 371 | 283 | `_start_search` | 39 |
  | `persistence/save_migrations.gd` | 275 | 188 | `_migrate_step` | 30 |
  | `persistence/validators/entity_validator.gd` | 299 | 265 | `_valid_entity` | 65 |

## Review fixes (Codex, REQUEST_CHANGES, 2026-11-03)

Blocking:
1. *Global satiety tier before reachability and claims.* Removed. `NeedGiver` ranks per
   colonist after its own filter (see `need_giver.gd` above). Test: unreachable meal and held
   meal both fall back to raw food.
2. *Mixed berry + raw food tile ranked 100 but ate the raw item.* `apply_need_effect` now eats
   what ranked the tile (berry unless an item's satiety beats it). Test: mixed tile.
3. *Migration refused v11 colonists without `skills`.* `skills` is optional; the step adds
   `heal` only to the maps present. Committed fixture `save_schema_v11_noskills_fixture.json`
   and `_check_v11_without_skills_migrates` in `test_save_migration.gd`.
4. *Files outside the owned paths.* **Approved** by the owner as listed (BACKLOG F5b approved
   amendment, main commit `1198125`).

Non-blocking:
- Quadratic item scan: `need_source_ranks` builds the tile ranks in one pass.
- Suite not rerun by the reviewer: rerun on the new head (the full-suite line under "Results on the branch head").

## Known limitations

- `kitchen` and `meal` draw the placeholder art (entries in `world_pack.json`); choosing pack
  art is a follow-up.
- No viewer art and no build-menu entry for the kitchen: it is placed by content/scenario
  (the viewer is outside F5b's owned paths). Follow-up for the owner to schedule.
- A meal ties with a berry bush (both 100); the nearer wins.
- Raw `food` is now edible: with no bush reachable, hungry colonists eat stockpiled food as
  well as cook it. Nothing reserves food for the kitchen.
- `heal` shows in the labour table and skills but enables no job yet.
- New worlds draw one more seeded skill per colonist, so a given seed gives different
  starting levels than before F5b. Saves are unaffected (migrated colonists keep theirs).

## Next action

Codex review round 2 of the head.
