# F5a handoff: stockpile filters and priorities

> **In short:** A stockpile now accepts a set of item groups and has a priority from 1 to 3.
> Haulers take each item to the highest-priority stockpile that accepts it and has room, the
> nearest one first; an item in a stockpile that stops accepting it is hauled out. A new
> stockpile accepts everything at priority 2 (the old behaviour, byte for byte in the save and
> the hash). New command `zone_set_stockpile`, a stockpile panel in the viewer, a save schema bump
> (**v8 -> v9 for now**, provisional: v10 once L2 lands, per the owner), ADR 064.
> `world_state.gd` did not grow (767 lines, as on `main`). Suite green; line below.

## Pendiente al reanudar (pipeline paused for the owner's playtest, 2026-10-30)

The branch is pushed (`git push -u origin HEAD`) and paused by the owner's instruction: "PAUSA
del pipeline para playtest ... No hagas nada mas hasta nueva nota". When work resumes:

1. **Wait for the owner's note that L2 is merged** (L2 takes v9 and changes `Vector2i` ->
   `Vector3i` across the core).
2. **Rebase again onto `origin/main`.** Expected conflicts: `save_migrations.gd` (L2's
   `_v8_to_v9` next to this branch's), `state_codec.gd` (`SCHEMA_VERSION`, header),
   `save_io.gd` `content_rules()`, the contract (description, title, `const`),
   `save-system.md`, `docs/decisions/README.md`, `test_save_migration.gd`, and the
   `save_schema_v9_fixture.json` add/add (keep L2's). From the `Vector3i` sweep:
   `ZoneTable._distance_to()`/`_contains()`/`stockpiles_for_item(kind, from: Vector2i)`,
   `HaulGiver.find_free_haul_cell()` (`Vector2i(item_x, item_y)`, the returned cell),
   `test_stockpile_filters.gd` (`Rect2i`/`Vector2i` constants) and the zone-rectangle checks.
   Keep both sides, as F2 did with F1.
3. **Renumber the bump to v10:** `_v8_to_v9` -> `_v9_to_v10` (same body: the zones keep their
   shape, a zone already carrying `groups`/`priority` is refused) with arm `9:`;
   `SCHEMA_VERSION := 10`; regenerate `save_schema_v10_fixture.json` with
   `docs/orca/handoffs/F5a-write-save.gd` (it must equal L2's v9 fixture but for
   `schemaVersion`, as v9 equals F3's v8 today); update the contract `const`/title/description,
   `save-system.md`, ADR 064 ("schema v9", `_v8_to_v9`), the header of `F5a-write-save.gd` and
   `test_save_migration.gd` (`V10_FIXTURE`, the v9 -> v10 step check, the resave check, the
   older-fixtures schemaVersion asserts).
4. Rerun the warnings and budgets gates, `measure_core`, the full suite (quote the new N), update
   this report, then `tools\orca\review.ps1`.

## Branch and commit

- Branch `antonelmejor50-hub/f5a-stockpile-filters-and-priorities`, two commits (the feature, then this rebase and renumbering), **rebased onto
  `origin/main` 32bfb81** (F3 1476aa1 + two backlog/baseline doc commits), at the owner's
  request: "rebasa sobre origin/main actual ... tu bump pasa provisionalmente a esquema v9
  (v8->v9, fixture v9)". Pushed at the owner's request (pause note above).
- **Rebase onto F3, what changed:** F3 owns v7 -> v8 (colonist skills) and
  `save_schema_v8_fixture.json`; this branch's step is now `_v8_to_v9` (arm `8:`),
  `SCHEMA_VERSION := 9`, fixture `save_schema_v9_fixture.json` written by
  `F5a-write-save.gd` on the rebased build (the same session as F3's v8 fixture; checked: only
  `schemaVersion` differs). F3's v8 fixture and checks are kept byte for byte. In
  `test_save_migration.gd` F3's structure is kept (the v1-v6 fixtures migrate to the migrated v7
  fixture, now at v9); this branch adds the v8 -> v9 check (the v8 fixture loads as exactly the
  v9 fixture, the step alone turns one into the other, a v8 zone with `groups`/`priority` is
  refused), the stockpile filter round trip and rejections on the v9 fixture, and moves the
  "current fixture re-encodes unchanged" check from v8 to v9, as F2 and F3 did. Conflicts
  resolved keeping both sides: `save_io.gd` `content_rules()` (F3's `skills` + this branch's
  `itemGroups`), `state_codec.gd` header, the contract description, `save-system.md`,
  `docs/decisions/README.md` (062 and 064 rows).
- **Owner coordination note (read before starting):** ADRs up to 063 are taken (this is
  **064**); `world_state.gd` must not grow (767 -> 767, three lines edited in place); new code
  uses `TileGrid` helpers (distance: `TileGrid.manhattan()`; the only planar step is the clamp to
  a zone rectangle, `ZoneTable._distance_to()`, noted in ADR 064 for L2).
- Before the rebase the branch was one commit on 73d0fa6 with the step numbered v7 -> v8 and
  `run_tests: all 132 test(s) PASS  [745s]` (main 73d0fa6: 131 tests, `all 131 test(s) PASS
  [747s]` on a clean `git archive` copy).

## Final suite line (branch head, after the rebase)

```
run_tests: all 133 test(s) PASS  [823s]
```

`origin/main` (32bfb81) has 132 `test_*.gd`; this branch has 133 (+`test_stockpile_filters.gd`).

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
| `game/scripts/core/persistence/state_codec.gd`, `save_io.gd`, `save_migrations.gd`, `validators/object_validator.gd` | v9: encode/decode/validate the optional fields, `_v8_to_v9`, `content_rules()["itemGroups"]` |
| `game/scripts/tests/fixtures/save_schema_v9_fixture.json`, `docs/orca/handoffs/F5a-write-save.gd` | fixture and the script that writes it |
| `docs/architecture/contracts/game-state.schema.json`, `docs/architecture/save-system.md` | contract v9 |
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

- ADR 064 (new). Save schema **v9** (provisional; v10 after L2): a stockpile in `zones[]` may
  carry `groups` (ascending, distinct, the session's item kinds) and `priority` (1-3), each only
  away from its default; never on a farm zone. Migration `_v8_to_v9` (zones unchanged, version
  bumped; refuses a v8 zone already carrying either key). Fixture `save_schema_v9_fixture.json`:
  F3's v8 fixture session, identical to it but for `schemaVersion` (checked: only that key
  differs).
- Command `zone_set_stockpile` (`commands/README.md`, `orders-and-movement.md`).
- `state_hash()`: zones were already hashed (`ZoneTable.hash_into()`); a configured stockpile
  hashes its new keys, an unconfigured one hashes as before.
- `HaulGiver` constructor: `accepts_item_at`, `stockpiles_for_item`, `item_lookup` replace
  `is_in_any_zone`, `get_zones`.

## Validation (Windows, Godot 4.7.2 from `$env:GODOT`, branch head)

```powershell
godot --headless --path game --import
tools\run_tests.ps1                                  # run_tests: all 133 test(s) PASS  [823s]
tools\run_tests.ps1 -Filter stockpile_filters        # test_stockpile_filters: PASS
tools\run_tests.ps1 -Filter save_migration           # test_save_migration: PASS
tools\check_core_warnings.ps1                        # OK, 2929 warning(s), none above baseline
python tools/check_core_budgets.py                   # OK (files <= 800 lines, functions <= 80 ...)
tools\measure_core.ps1 -All                          # figures below
git diff --check origin/main HEAD                    # clean
python -m json.tool <each changed .json>             # all valid
godot --headless --path game --script ../docs/orca/handoffs/F5a-write-save.gd -- <abs path>   # regenerates the v9 fixture
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

`test_save_migration.gd` (F3's checks kept): the v8 fixture loads through `SaveIO.read()` as
exactly the v9 fixture; the v8 -> v9 step alone turns the v8 fixture into the v9 fixture,
keeps the zones and refuses a v8 zone with `groups` or `priority`; a stockpile with `groups` +
`priority` loads through `SaveIO.read()`, decodes and re-encodes unchanged; unknown, unsorted
or repeated groups, non-list groups, priority 0 or 4, and a farm zone with a priority are
`schema_error`; the v9 fixture re-encodes unchanged (the former v8 check, moved to v9 as F2 and
F3 did); the v1-v7 fixtures now load at v9.

Assert sites (`_expect(`/`_fail(`, `origin/main` 32bfb81 -> branch): `test_save_migration` 134 -> 149,
`test_text_pseudo_locale` 21 -> 21, `test_stockpile_filters` new, 43. No test removed, skipped
or loosened.

## `tools\measure_core.ps1 -All` (rebased branch head; `origin/main` 32bfb81 in brackets)

Core total: **22,258 lines in 109 files** [22,030 lines, 109 files].

| File | Total | Code |
| --- | --- | --- |
| `world_state.gd` | 767 [767] | 593 [593] |
| `persistence/state_codec.gd` | 584 [571] | 430 [419] |
| `persistence/save_io.gd` | 399 [396] | 309 [307] |
| `commands/command_checks.gd` | 261 [236] | 214 [192] |
| `persistence/validators/object_validator.gd` | 241 [209] | 214 [186] |
| `objects/zone_table.gd` | 200 [92] | 140 [59] |
| `persistence/save_migrations.gd` | 192 [176] | 127 [116] |
| `world/command_router.gd` | 155 [152] | 136 [133] |
| `jobs/givers/haul_giver.gd` | 80 [66] | 64 [53] |
| `commands/handlers/zone_handler.gd` | 77 [63] | 58 [48] |

`check_core_budgets.py`: OK; no core file above 800 lines, no function above 80; no cap raised.

Warnings gate (rebased head): OK, 2929 against the committed baseline 2937. Before the rebase,
`main` 73d0fa6 measured 2927 (untyped 512, unsafe_call 2163) and the branch untyped 511,
unsafe_call 2166; `origin/main` 32bfb81 was not measured separately. On the lines this
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

Paused by the owner for a playtest: see "Pendiente al reanudar" at the top (L2 merge -> rebase
-> renumber to v10 -> gates and suite -> `tools\orca\review.ps1`).
