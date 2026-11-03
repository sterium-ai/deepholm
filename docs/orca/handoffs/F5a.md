# F5a handoff: stockpile filters and priorities

> **In short:** A stockpile now accepts a set of item groups and has a priority from 1 to 3.
> Haulers take each item to the highest-priority stockpile that accepts it and has room, the
> nearest one first; an item in a stockpile that stops accepting it is hauled out. A new
> stockpile accepts everything at priority 2 (the old behaviour, byte for byte in the save and
> the hash). New command `zone_set_stockpile`, a stockpile panel in the viewer, a save schema bump
> (**v9 -> v10**, after L2's v8 -> v9), ADR 064. `world_state.gd` did not grow (767 lines, as on
> `main`). Suite green; line below.

## Resumed 2026-11-03: rebased onto L2

The pause ("Pendiente al reanudar") is closed: L2 is on `origin/main` (558f00b, schema v9,
`Vector2i` -> `Vector3i` across the core, `TileGrid` layers), and the owner asked: "fetch +
rebase sobre origin/main (resuelve conflictos manteniendo la semantica de L2), renumera tu bump
de esquema a v10 (migracion v9->v10 + fixture v10, conservando el paso v9 de L2)".

- **History:** the branch's two commits (feature; rebase onto F3) were squashed into one and
  rebased onto `origin/main` 3e7ba13 (L2 558f00b + one Orca tooling commit). The pre-rebase head
  is kept locally as branch `f5a-pre-l2-backup` (c8ba3d1); the pushed branch now needs a
  force-push, which is the owner's call (not done).
- **L2 kept as is:** `_v8_to_v9` (layers, `z: 0`), `save_schema_v9_fixture.json` (add/add:
  L2's kept byte for byte), L2's v8 -> v9 test, the `map.layerCount` asserts, `z` in the zone
  schema and validator, every `layers` argument of `save_io.gd`'s validators.
- **Renumbered to v10:** `_v9_to_v10` (same body as before, arm `9:`), `SCHEMA_VERSION := 10`,
  contract title/`const`/description, `save-system.md` (version line, migration list,
  "Stockpile zones"), ADR 064, the `F5a-write-save.gd` header. New fixture
  `save_schema_v10_fixture.json` written by `F5a-write-save.gd` on the rebased build: equal to
  L2's v9 fixture but for `schemaVersion` (and `integrity`, the hash of the state; checked key
  by key). `test_save_migration.gd`: `V10_FIXTURE`, the v9 -> v10 step check, the filter round
  trip on the v10 fixture, the "current fixture re-encodes unchanged" check moved from v9 to v10
  (`V10_RESAVE_PATH`), the older fixtures now load at v10.
- **`Vector3i` sweep in F5a code:** `ZoneTable.accepts_item_at(tile: Vector3i, kind)`,
  `stockpiles_for_item(kind, from: Vector3i)`, `_contains(zone, tile)` checks the zone's `z`;
  `HaulGiver` passes `TileGrid.tile_of(item)` and keeps L2's `Vector3i(x, y, zone.z)` cells;
  `world_state.gd` keeps L2's `_cell_free` / `_passability.passability` / `_tool_store.*`
  wiring with the F5a callables substituted (still 767 lines). **One new reading (ADR 064):**
  `TileGrid.manhattan()` asserts one layer, so a stockpile on another layer than the item gets
  `ZoneTable.OTHER_LAYER_DISTANCE` (it ranks after every stockpile of its priority on the item's
  layer, then by id). With `layerCount = 1` this never happens; it keeps a deeper stockpile
  usable without inventing a cross-layer distance before hauling across layers is designed.
- **Tests:** `test_stockpile_filters.gd` uses `Vector3i` tile constants and `mark_dirty(CROP)`;
  its rectangle counts read surface items only; "a new stockpile is the pre-F5a record" now
  expects 6 keys (L2 added `z`).
- **Warnings:** the rebase first raised the gate (2806 > L2's 2803: four on the new handler's
  rejection line, one in `_contains()`); fixed with typed locals, now 2801.

## Branch and commit

- Branch `antonelmejor50-hub/f5a-stockpile-filters-and-priorities`, one commit on
  `origin/main` 3e7ba13 (see above). Not pushed.
- Earlier history: written on 73d0fa6 as v7 -> v8 (`all 132 test(s) PASS [745s]`), rebased onto
  F3 (32bfb81) as v8 -> v9 (`all 133 test(s) PASS [823s]`), now on L2 as v9 -> v10.
- **Owner coordination note:** ADRs up to 063 are taken (this is **064**); `world_state.gd` must
  not grow (767 -> 767, three statements edited in place); new code uses `TileGrid` helpers.

## Final suite line (branch head, after the rebase onto L2)

```
run_tests: all 134 test(s) PASS  [914s]
```

`origin/main` (3e7ba13) has 133 `test_*.gd`; this branch has 134 (+`test_stockpile_filters.gd`).

## Design, line by line

| Design (BACKLOG F5a, owner 2026-10-30) | Where |
| --- | --- |
| A stockpile accepts a set of item groups (F2's `tool`, `material`, `food`, `seed`; `ore` when F4 lands) | `ZoneTable`: optional `groups` on a stockpile record; `accepts()`; the groups are the items' `kind`s (`ZoneTable.groups_of()`), so F4's `ore` items add the group with no code change. `valuable` (gold coin, ADR 061) is a group too |
| ... and a priority 1-3 | `ZoneTable`: optional `priority`; `MIN/DEFAULT/MAX_PRIORITY` 1/2/3 |
| Haulers take each item to the nearest valid stockpile of the highest priority | `ZoneTable.stockpiles_for_item()` (priority desc, Manhattan distance from the item to the rectangle, zone id) used by `HaulGiver.find_free_haul_cell()`; first free cell row-major inside the chosen stockpile |
| An item in a stockpile that no longer accepts it is moved out to a valid one | `HaulGiver.advance()` skips only items in a stockpile that accepts them (`ZoneTable.accepts_item_at()`) |
| Default for a new stockpile: all groups, priority 2 (today's behaviour) | both keys absent = default; `zone_add` unchanged; setting all groups at priority 2 stores the bare record again |

**Readings to call out (no design reopened):**
1. "Nearest valid stockpile of the highest priority" is read *with room*: a full priority-3
   stockpile falls through to the next one; otherwise an item would wait beside free space.
2. "Nearest" is measured from the item (the hauler is not known when the destination is
   reserved: `JobQueue._tick_haul()` reserves item and cell before assignment).
3. An item already in a *valid* lower-priority stockpile is not moved to a higher one (only
   "no longer accepts it" moves an item; more is "hauling priorities beyond the stockpile one",
   a non-goal).
4. With several *default* stockpiles the nearest now wins, where the lowest zone id won before.
   With one stockpile the chosen cell is exactly the old one.
5. Tool drops (`ToolDropToil`) only use stockpiles accepting `tool`. A tool already stocked in a
   stockpile that stops accepting tools stays (tools have no haul path, ADR 061); see limitations.
6. A haul already carrying an item to a stockpile that stops accepting it delivers it, and
   HaulGiver then hauls it out (ADR 064, "Command").

## Owned paths and the files actually changed

**Owned (BACKLOG F5a):** `core/objects/zone_table.gd`; the haul giver (`core/jobs/givers/haul_giver.gd`);
commands/handlers; persistence (bump + migration + fixture); viewer stockpile panel; tests; an
ADR; this report.

| File | Change |
| --- | --- |
| `game/scripts/core/objects/zone_table.gd` | filter + priority per stockpile, `set_stockpile()`, `accepts_item_at()`, `stockpiles_for_item()`, `get_stockpile_zones_for_group()`, `groups_of()`, `parse_groups()` |
| `game/scripts/core/jobs/givers/haul_giver.gd` | haul-out of rejected items; destination by priority/distance/filter |
| `game/scripts/core/commands/handlers/zone_handler.gd` | `apply_zone_set_stockpile_command()` |
| `game/scripts/core/commands/command_checks.gd` | `check_zone_set_stockpile_command()` + dispatch (shared by `preview()` and `apply()`) |
| `game/scripts/core/world/command_router.gd` | one `match` arm for `zone_set_stockpile` (command dispatch) |
| `game/scripts/core/commands/README.md` | the command and its rejections |
| `game/scripts/core/persistence/state_codec.gd`, `save_io.gd`, `save_migrations.gd`, `validators/object_validator.gd` | v10: encode/decode/validate the optional fields, `_v9_to_v10`, `content_rules()["itemGroups"]` |
| `game/scripts/tests/fixtures/save_schema_v10_fixture.json`, `docs/orca/handoffs/F5a-write-save.gd` | fixture and the script that writes it |
| `docs/architecture/contracts/game-state.schema.json`, `docs/architecture/save-system.md` | contract v10 |
| `game/scripts/viewer/stockpile_panel.gd` (new), `game/scripts/viewer/info_panel.gd` | the panel and its place in the info column |
| `game/data/text/en.json` | 4 rejection texts (ADR 052: every detail code has text) and the panel strings |
| `game/scripts/core/world_state.gd` | composition only, 3 lines edited in place, 0 added: `ZoneTable.new(_item_definitions)`, HaulGiver's new Callables, `ToolDropToil` gets `get_stockpile_zones_for_group.bind("tool")` |
| `docs/architecture/orders-and-movement.md` | the zone-command section and the haul-destination paragraph, which described the old rule |
| `docs/decisions/064-stockpile-filters-and-priorities.md` (new), `docs/decisions/README.md` | ADR |
| `game/scripts/tests/test_stockpile_filters.gd` (new), `test_save_migration.gd`, `test_text_pseudo_locale.gd` | tests (the last one adds the `stockpile` text prefix to its key census: more coverage) |
| `docs/orca/BACKLOG.md` | F5a status row |
| `*.gd.uid` | generated by Godot for the two new scripts |

Not touched: `tool_drop_toil.gd`, `job_queue.gd`, `content_registry.gd`, content JSON.

## Contract impact

- ADR 064 (new). Save schema **v10**: a stockpile in `zones[]` may carry `groups` (ascending,
  distinct, the session's item kinds) and `priority` (1-3), each only away from its default;
  never on a farm zone. Migration `_v9_to_v10` (zones unchanged, version bumped; refuses a v9
  zone already carrying either key). Fixture `save_schema_v10_fixture.json`: L2's v9 fixture
  session, identical to it but for `schemaVersion` (and the `integrity` hash).
- Command `zone_set_stockpile` (`commands/README.md`, `orders-and-movement.md`).
- `state_hash()`: zones were already hashed (`ZoneTable.hash_into()`); a configured stockpile
  hashes its new keys, an unconfigured one hashes as before.
- `HaulGiver` constructor: `accepts_item_at`, `stockpiles_for_item`, `item_lookup` replace
  `is_in_any_zone`, `get_zones`.

## Validation (Windows, Godot 4.7.2 from `$env:GODOT`, branch head)

```powershell
godot --headless --path game --import
tools\run_tests.ps1                                  # run_tests: all 134 test(s) PASS  [914s]
tools\run_tests.ps1 -Filter stockpile_filters        # test_stockpile_filters: PASS
tools\run_tests.ps1 -Filter save_migration           # test_save_migration: PASS
tools\check_core_warnings.ps1                        # OK, 2801 warning(s), none above baseline (2803)
python tools/check_core_budgets.py                   # OK (files <= 800 lines, functions <= 80 ...)
tools\measure_core.ps1 -All                          # figures below
git diff --check origin/main HEAD                    # clean
python -m json.tool <each changed .json>             # all valid
godot --headless --path game --script ../docs/orca/handoffs/F5a-write-save.gd -- <abs path>   # regenerates the v10 fixture
```

What `test_stockpile_filters.gd` proves, through `zone_add`/`zone_set_stockpile` commands, a ripe
crop's real harvest and ticks (no direct internal calls):
- **acceptance:** A (2x2, far: food only, priority 3) and B (3x3, next to the drops: every
  group, priority 1); the harvest's food and a wood stack on the ground -> within a day all food
  is in A (priority beats distance), wood and the harvest's seed in B. Switching A to
  `material` moves all food to B within a day (344 ticks on this seed; a day is 2,200 ticks),
  and B's wood is not pulled into the higher-priority A afterwards;
- **determinism:** two worlds from the same seed and commands (switch included) hash equal every
  100 ticks for two days;
- **save/load:** `from_save_state(to_save_state())` and a real `SaveIO` file round trip
  mid-move keep `state_hash()` and stay in lockstep for a day (with real need decay, which the
  save keeps);
- **replay:** a session recorded through the viewer's `CommandRecorder` (A11) with three
  accepted `zone_set_stockpile` commands replays every checkpoint;
- **equal priority:** the nearer stockpile wins over the lower zone id;
- **accepts nothing:** a stockpile with `groups ""` receives nothing (hauls wait
  `blocked_destination_full`); an item left in it is hauled out once another stockpile exists; a
  new stockpile is the 5-key pre-F5a record;
- **commands:** 9 rejections, the same through `preview()` and `apply()`, none changing the
  hash; groups stored sorted; all groups at priority 2 restores the bare record;
- **panel:** the viewer's stockpile panel lists stockpiles only (not the farm zone), shows
  `Priority 2` and `[x] Food`; its buttons drop Food, raise the priority to 3 (label follows)
  and restore every group, all through commands.

Checked that the acceptance discriminates: with the priority comparison disabled the food goes
to B ("within a day the food must lie in A ..." fails); with `accepts_item_at()` ignoring the
filter the food is never moved out of A (4 checks fail). Both mutations were reverted.

`test_save_migration.gd` (F3's and L2's checks kept): the v9 fixture loads through
`SaveIO.read()` as exactly the v10 fixture; the v9 -> v10 step alone turns the v9 fixture into
the v10 fixture, keeps the zones and refuses a v9 zone with `groups` or `priority`; a stockpile
with `groups` + `priority` loads through `SaveIO.read()`, decodes (with its `z`) and re-encodes
unchanged; unknown, unsorted or repeated groups, non-list groups, priority 0 or 4, and a farm
zone with a priority are `schema_error`; the v10 fixture re-encodes unchanged (L2's v9 check,
moved to v10 as F2, F3 and L2 did); the v1-v8 fixtures now load at v10.

Assert sites (`_expect(`/`_fail(`, `origin/main` 3e7ba13 -> branch): `test_save_migration` 149 -> 164,
`test_text_pseudo_locale` 21 -> 21, `test_stockpile_filters` new, 43. No test removed, skipped
or loosened.

## `tools\measure_core.ps1 -All` (branch head; `origin/main` 3e7ba13 in brackets)

Core total: **22,407 lines** [21,818 lines]. The script counted 109 files in this worktree and
108 in a `git archive` copy of `origin/main`; the branch adds no core file (both track 108).

| File | Total | Code |
| --- | --- | --- |
| `world_state.gd` | 767 [767] | 593 [593] |
| `persistence/state_codec.gd` | 587 [574] | 432 [421] |
| `persistence/save_io.gd` | 400 [397] | 310 [308] |
| `commands/command_checks.gd` | 282 [257] | 230 [208] |
| `persistence/validators/object_validator.gd` | 241 [209] | 214 [186] |
| `persistence/save_migrations.gd` | 225 [209] | 150 [139] |
| `objects/zone_table.gd` | 212 [96] | 149 [63] |
| `world/command_router.gd` | 158 [155] | 139 [136] |
| `commands/handlers/zone_handler.gd` | 85 [67] | 66 [52] |
| `jobs/givers/haul_giver.gd` | 78 [66] | 62 [53] |

`check_core_budgets.py`: OK; no core file above 800 lines, no function above 80; no cap raised.

Warnings gate (branch head): OK, 2801 against the committed baseline 2803 (L2's). The gate
suggests lowering the baseline with `-Update`; I did not (outside the owned paths; F0, F2 and
the earlier F5a rounds left it to the owner). The new handler's rejection line uses typed
locals, so it adds none of the four argument warnings the older `zone_add`/`zone_remove` lines
have.

## Known limitations

- A tool stocked in a stockpile that stops accepting tools stays there (tools have no haul
  path, ADR 061); new tool drops respect the filter.
- The panel is minimal (list of stockpiles, no map selection), like F2's workbench panel.
- Owner confirmation pending: the panel has had no playtest (`REVIEW.md` item 7: after the
  merge, through the desktop shortcut).
- Other `is_in_any_zone()` readers (construction and crafting "stockpiled" counts, rooms) still
  treat any stockpile tile as stocked, filter or not (ADR 064, Consequences).

## Next action

Owner: review the rebase, force-push the branch (its history was rewritten onto L2), then
`tools\orca\review.ps1`. The panel's playtest is still pending (`REVIEW.md` item 7).
