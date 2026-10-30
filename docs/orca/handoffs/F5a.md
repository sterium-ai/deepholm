# F5a handoff: stockpile filters and priorities

> **In short:** A stockpile now accepts a set of item groups and has a priority from 1 to 3.
> Haulers take each item to the highest-priority stockpile that accepts it and has room, the
> nearest one first; an item in a stockpile that stops accepting it is hauled out. A new
> stockpile accepts everything at priority 2 (the old behaviour, byte for byte in the save and
> the hash). New command `zone_set_stockpile`, a stockpile panel in the viewer, a save schema bump
> (v8 on this base, **v10** once rebased onto F3 and L2, per the owner), ADR 064. `world_state.gd` did not grow (767 lines, as on `main`). Suite green; line below.

## Branch and commit

- Branch `antonelmejor50-hub/f5a-stockpile-filters-and-priorities`, one commit on top of
  **73d0fa6**. Not pushed (the owner ships with `tools\orca\ship.ps1`).
- **Not rebased, by owner instruction (terminal, 2026-10-30):** "F3 ya esta en origin/main
  (1476aa1, esquema v8). L2 entrara despues con v9, asi que tu bump de F5a sera v10. No hace
  falta rebasar ahora". The fetch before handoff shows `origin/main` one commit ahead (1476aa1,
  F3, #48). `tools\orca\review.ps1` refuses a branch behind `origin/main`, so **the rebase onto
  F3 + L2 and the renumbering to v10 come before review** (see "Next action"). Every figure in
  this report is from the 73d0fa6 base.
- **Owner coordination note (read before starting):** F3 (PR #48, schema v8) and L2 (schema
  v9) are in flight; ADRs up to 063 are taken; `world_state.gd` must not grow; new code uses
  `TileGrid` helpers. Accordingly: the ADR is **064**. The final schema number is **v10**
  (owner: F3 is v8, L2 will be v9). On this 73d0fa6 base the step is numbered **v7 -> v8**, because a
  v10 step needs F3's and L2's steps in the chain. At the rebase: `_v7_to_v8` becomes
  `_v9_to_v10` (same body, it only bumps the version and refuses a zone that already has
  `groups`/`priority`); `SCHEMA_VERSION := 10`; regenerate the fixture as
  `save_schema_v10_fixture.json` with `docs/orca/handoffs/F5a-write-save.gd`; and update the
  contract `const` and title, the `save-system.md` lines, ADR 064's "schema v8" and
  `test_save_migration.gd` (the v1-v9 fixtures migrate to v10; the v9 -> v10 step check). The F2
  report describes the same renumbering. `world_state.gd`: 767 -> 767 (three lines edited in place). Distance:
  `TileGrid.manhattan()`; the only planar step is the clamp to a zone rectangle
  (`ZoneTable._distance_to()`), noted in ADR 064 for L2.

## Final suite line (branch head)

```
run_tests: all 132 test(s) PASS  [745s]
```

`main` (73d0fa6) has 131 `test_*.gd` (baseline run on a clean `git archive` copy of 73d0fa6:
`run_tests: all 131 test(s) PASS  [747s]`); this branch has 132 (+`test_stockpile_filters.gd`).

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
| `game/scripts/core/persistence/state_codec.gd`, `save_io.gd`, `save_migrations.gd`, `validators/object_validator.gd` | v8: encode/decode/validate the optional fields, `_v7_to_v8`, `content_rules()["itemGroups"]` |
| `game/scripts/tests/fixtures/save_schema_v8_fixture.json`, `docs/orca/handoffs/F5a-write-save.gd` | fixture and the script that writes it |
| `docs/architecture/contracts/game-state.schema.json`, `docs/architecture/save-system.md` | contract v8 |
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

- ADR 064 (new). Save schema **v8**: a stockpile in `zones[]` may carry `groups` (ascending,
  distinct, the session's item kinds) and `priority` (1-3), each only away from its default;
  never on a farm zone. Migration `_v7_to_v8` (zones unchanged, version bumped; refuses a v7
  zone already carrying either key). Fixture `save_schema_v8_fixture.json`: the same session as
  v1-v7, identical to the v7 fixture but for `schemaVersion` (checked: only that key differs).
- Command `zone_set_stockpile` (`commands/README.md`, `orders-and-movement.md`).
- `state_hash()`: zones were already hashed (`ZoneTable.hash_into()`); a configured stockpile
  hashes its new keys, an unconfigured one hashes as before.
- `HaulGiver` constructor: `accepts_item_at`, `stockpiles_for_item`, `item_lookup` replace
  `is_in_any_zone`, `get_zones`.

## Validation (Windows, Godot 4.7.2 from `$env:GODOT`, branch head)

```powershell
godot --headless --path game --import
tools\run_tests.ps1                                  # run_tests: all 132 test(s) PASS  [745s]
tools\run_tests.ps1 -Filter stockpile_filters        # test_stockpile_filters: PASS
tools\run_tests.ps1 -Filter save_migration           # test_save_migration: PASS
tools\check_core_warnings.ps1                        # OK, 2929 warning(s), none above baseline
python tools/check_core_budgets.py                   # OK (files <= 800 lines, functions <= 80 ...)
tools\measure_core.ps1 -All                          # figures below
git diff --check origin/main HEAD                    # clean
python -m json.tool <each changed .json>             # all valid
godot --headless --path game --script ../docs/orca/handoffs/F5a-write-save.gd -- <abs path>   # regenerates the v8 fixture
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

`test_save_migration.gd`: v1-v7 fixtures migrate to exactly the v8 fixture; the v7 -> v8 step
alone turns the v7 fixture into the v8 fixture and refuses a v7 zone with `groups` or
`priority`; a stockpile with `groups` + `priority` loads through `SaveIO.read()`, decodes and
re-encodes unchanged; unknown, unsorted or repeated groups, non-list groups, priority 0 or 4,
and a farm zone with a priority are `schema_error`; the v8 fixture re-encodes unchanged (the
former v7 check, moved to v8 as F2 did).

Assert sites (`_expect(`/`_fail(`, main -> branch): `test_save_migration` 122 -> 134,
`test_text_pseudo_locale` 21 -> 21, `test_stockpile_filters` new, 43. No test removed, skipped
or loosened.

## `tools\measure_core.ps1 -All` (branch head; main 73d0fa6 in brackets)

Core total: **21,891 lines in 108 files** [21,663 lines, 108 files].

| File | Total | Code |
| --- | --- | --- |
| `world_state.gd` | 767 [767] | 593 [593] |
| `persistence/state_codec.gd` | 583 [570] | 430 [419] |
| `persistence/save_io.gd` | 396 [393] | 307 [305] |
| `commands/command_checks.gd` | 261 [236] | 214 [192] |
| `persistence/validators/object_validator.gd` | 241 [209] | 214 [186] |
| `objects/zone_table.gd` | 200 [92] | 140 [59] |
| `persistence/save_migrations.gd` | 168 [152] | 108 [97] |
| `world/command_router.gd` | 155 [152] | 136 [133] |
| `jobs/givers/haul_giver.gd` | 80 [66] | 64 [53] |
| `commands/handlers/zone_handler.gd` | 77 [63] | 58 [48] |

`check_core_budgets.py`: OK; no core file above 800 lines, no function above 80; no cap raised.

Warnings gate: 2929 against the committed baseline 2937; `main` itself measures 2927
(untyped 512, unsafe_call 2163). The branch is untyped 511, unsafe_call 2166. On the lines this
branch adds or edits, the only new warnings are the four argument warnings of the new handler's
`_event_log.rejection(command["command_id"], ...)` line (`zone_handler.gd:46`), the same line
`zone_add`/`zone_remove` already have; every other warning on an edited line was there on `main`.
No kind is above its baseline. I did not lower the baseline (outside the owned paths; F0 and F2
left it to the owner too).

## Known limitations

- A tool stocked in a stockpile that stops accepting tools stays there (tools have no haul
  path, ADR 061); new tool drops respect the filter.
- The panel is minimal (list of stockpiles, no map selection), like F2's workbench panel.
- Owner confirmation pending: the panel has had no playtest (`REVIEW.md` item 7: after the
  merge, through the desktop shortcut).
- Other `is_in_any_zone()` readers (construction and crafting "stockpiled" counts, rooms) still
  treat any stockpile tile as stocked, filter or not (ADR 064, Consequences).

## Next action

Once L2 is on `main` (or as the owner decides): rebase onto `origin/main`, renumber the bump to
**v10** as described under "Branch and commit", regenerate the fixture, rerun the gates and the
full suite (quoting the new test count), update this report, then `tools\orca\review.ps1`. Expected
conflicts: F3's `_v7_to_v8` and fixture next to this branch's in `save_migrations.gd`, the
contract, `save-system.md` and `test_save_migration.gd`; keep both, as F2 did with F1. L2's
`Vector3i` sweep will touch `ZoneTable._distance_to()`/`_contains()` and HaulGiver's
`Vector2i(item_x, item_y)`.
