# F5a-b handoff: haul rejected tools out of a stockpile

## Branch and commits

- Branch: `antonelmejor50-hub/f5a-b-haul-rejected-tools-out`. Not pushed.
- Commits on this branch, oldest first:
  (Hashes after the round 5 rebase onto `origin/main` `f55e9b0`, which includes L3 `bb3ff32`.)
  1. `a80f538`: first delivery (an instant move with no job). It was rejected in review round 1.
  2. `6c9d4fb`: a handoff note about `review.ps1`. That note is now dropped, because the
     script was fixed on main (`5be734f`, `76d139b`).
  3. `f34f3af`: the round 1 fix (a carried `haul_tool` job, no teleport).
  4. `1079d00`: the round 2 fix. It answers review round 2 (`.orca-review.md`,
     REQUEST_CHANGES):
     - (b) the destination is rechecked on every tick while the tool is fetched or carried.
       An invalid one fails the job through the shared job engine (`invalid_target`), and the
       delivery revalidates too. A 4th check runs through commands and ticks (seed 64019);
     - (c) `haul_tool` is now a schema bump, with a migration and a fixture. It was v12 in
       round 2 and is v13 since round 3 (see item 5);
     - (a) scope: the owner approved `jobs.json`, `toil_executor.gd`, `toil_bindings.gd`, the
       schema enum and `en.json` in `docs/orca/BACKLOG.md` on main, commit `afeeade`. The rest
       is listed under "Pending owner approval".
  5. `b35d9dc`: round 3. Owner note: F5b (`5399153`) is on main and
     took schema v12. The branch was rebased onto `origin/main` and the bump renumbered to
     **v13**:
     - v13 was free: `origin/main` was at v12, and L3 (merged later, see item 8) has no bump. So
       v13 was used, not v14;
     - the bump is `_v12_to_v13`, and F5b's `_v11_to_v12` (heal labour) is kept unchanged;
     - F5b's `save_schema_v12_fixture.json` is untouched. The new
       `save_schema_v13_fixture.json` (hash 237246710, issued 6, tick 150) is the same session,
       and the v12 fixture migrates to it exactly;
     - rebase conflicts: F5b's `cook_work` and this branch's `haul_tool` are both kept in the
       schema enum, `test_architecture_rules.gd` and `test_toils_dig_chop_regression.gd`
       (22 to 23 kinds).
     The v13 edits were folded into `1079d00`, and this commit updates only this file.
  6. `cca1601`: round 4. It answers review round 4 (`.orca-review.md`,
     REQUEST_CHANGES):
     - (blocking) the round 3 diff edited **three** existing `world_state.gd` lines, not two as
       this file said: the `ToilExecutor` line and both lines of the `HaulGiver` call. The
       first `HaulGiver` line is now restored to `origin/main`'s text
       (`view_jobs_of_kinds.bind(["haul"])`). `HaulGiver` gets its `haul_tool` jobs from a new
       optional trailing argument `get_tool_jobs` (`view_jobs_of_kinds.bind(["haul_tool"])`),
       appended to the second line with `tool_store` and `get_zones`. Against `origin/main`,
       exactly two existing lines change, no line is added, and the file stays at 767 lines;
     - (non-blocking) `docs/orca/BACKLOG.md`'s F5a-b heading said "no schema bump". It now
       says "schema v13";
     - (non-blocking) the full suite was rerun on the round 4 tree.
  7. `dd1b2d6`: round 5. It answers review round 5 (`.orca-review.md`,
     REQUEST_CHANGES):
     - (blocking) a need or rescue interrupt released the reservation of the tool in the
       carrier's hand. On resuming, `_carry_done()` saw no reserved tool and reported the carry
       done; `place_hauled_tool()` then refused the delivery (the tool was no longer this job's),
       and the job completed with the pick still held. Now:
       - `HaulGiver` names the tool on the job (`job.item_id`, through its existing
         `attach_item` callable, as `haul` jobs do), so the cargo identity survives the release;
       - `ToolFetchToil` (`_carry_done()`, `needs()` and `advance()`) re-reserves that tool for
         the job when it is unreserved, whether it is in the hand or still to be fetched. The
         carry is done only when the tool is in the hand under this job's reservation;
       - `ToolDropToil.haul_target_lost()` also fails the job (`invalid_target`, through the
         shared engine) when that tool is gone or reserved by another job;
       - `HaulGiver` skips a tool that a queued or active `haul_tool` job names, so an interrupt
         does not lead to a second job for the same tool;
       - new tick-driven test `_check_need_interrupt_mid_carry_still_stocks_the_tool_in_b`
         (seed 64020, `Scenarios.isolate_need(world, "food")`): with the pick in the hand the
         carrier gets `needs.food = 5`, the job goes back to `queued` with the pick still held,
         then completes with the pick stocked in B (same single id), never loose in A. Without
         the fix it fails with "after the resumed job completes the pick must be stocked in B,
         not held: {type: held, colonist_id: colonist_0}";
     - (non-blocking) the full suite is still author-reported; it was rerun on the round 5 tree
       (see below).
  8. Round 5 rebase, the commit that changes this file to the present text
     (`git log -1 -- docs/orca/handoffs/F5a-b.md`). Owner note: L3 (`bb3ff32`, ADR 068, no schema
     bump) is on main. The branch was rebased onto `origin/main` `f55e9b0` with no conflict:
     - v13 is still free (`origin/main` is at v12), so the bump stays `_v12_to_v13`;
     - L3 changes map and routing code (`regions.gd`, `vertical_links.gd`, `route_search.gd`,
       `passability.gd`, `tile_grid.gd`) and adds `test_vertical_links.gd`, so the full suite
       was rerun on the rebased HEAD and N is now 137;
     - `world_state.gd` is still 767 lines, and still exactly two existing lines differ from
       `origin/main`; this commit updates only this file.
- Owner decision followed (round 5): rebase onto `origin/main` after L3, keep v13, and rerun the
  full suite since the rebase brings code changes.
- Owner decision followed (round 3): rebase onto `origin/main` and renumber the bump to v13,
  keeping F5b's v12 step (v14 only if v13 were taken; it was not).
- Owner decision followed (round 2): `afeeade` on main approves that scope and asks for the
  en-route destination recheck through the shared job engine, with a test through commands and
  ticks.
- Owner decision followed: review round 1, written in `docs/orca/BACKLOG.md` on main, commit
  `07cd384`. The move must be a real haul job through the shared queue and the existing tool
  fetch/drop toils, done by a colonist with the haul labour, and covered by tests through
  commands and ticks. In `world_state.gd`, only a wiring hook of 2 lines or fewer is allowed,
  with no growth.

## Final suite line (author-reported, round 5, after the L3 rebase)

```
run_tests: all 137 test(s) PASS  [985s]
```

The author ran this on HEAD after the round 5 rebase (this branch on `origin/main` `f55e9b0`, with schema
v13, the two-line `world_state.gd` wiring and the round 5 re-reservation), on Windows with Godot
4.7.2 headless. It is still author-reported: the reviewer has
not reproduced it yet (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1`).
N is 137 because main now has 137 test files (L3 added `test_vertical_links.gd`). This branch adds
or removes none: its checks are in existing test files. The round 5 tree before the L3 rebase
gave 136 PASS [880s]. The first full run after the rebase gave `2 of 137 test(s) failed: test_reroute,
test_tool_items_save`, each with `SaveIO must read back ...: could not open save`. Other
worktrees' Godot processes were running and share `user://`. Both tests passed alone (`-Filter`),
and the rerun above, on the same HEAD, passed with no such error. The round 4 tree gave 136 PASS
[999s], round 3 136 PASS [991s]. Earlier runs, before the round 3 rebase, were 135 PASS [924s]
(round 2) and 135 PASS [889s] (round 1).

## What changed (carried design, replaces the teleport)

- New job kind **`haul_tool`** in `content/jobs.json`: labour `haul`, toils `fetch_tool`,
  `reserve`, `go_to`, `work`, `release_all`, priority 1, `work_ticks` 1. It has no
  `needs_tool`.
- `HaulGiver._haul_rejected_tools()` runs at the start of `advance()`. It looks at each stocked
  tool in id order (`ToolItemStore` location type `stockpile`) and skips one when:
  - it is reserved, or
  - its tile still accepts its group, or
  - its tile lies in no stockpile (its zone was removed, so F2 says it is not stock).

  For every other tool, it picks a target:
  1. the first free cell of the tool-accepting stockpiles, in `stockpiles_for_item()` order
     (the same order `find_free_haul_cell()` uses). A free cell is free, passable and
     unoccupied, has no tool lying on it (`ToolItemStore.lies_at`), and is not the target of a
     queued or active `haul_tool` job;
  2. else the nearest such tile that shares an edge with its stockpile and lies outside every
     zone (ties by y, then x);
  3. else no target, and the tool is tried again next tick.

  It then submits a `haul_tool` job at the target through the shared queue (`submit_job`),
  names the tool on it (`item_id`, round 5) and reserves the tool for that job
  (`ToolItemStore.reserve`). A tool that a queued or active `haul_tool` job already names is
  skipped too (round 5).
- A colonist with the haul labour takes the job from the scheduler like any other job.
  - **`fetch_tool`** (`ToolFetchToil`): for a kind with no `needs_tool` that lists
    `fetch_tool`, the toil carries the tool its giver named (`item_id`) and reserved. It walks
    to the tool and picks it up, with no search. It is done once that tool is in the hand under
    this job's reservation, or when the job names no tool (`_carry_done()`). If an interrupt
    (need, rescue) released the reservation, the toil reserves the tool again on resume (round
    5), so the delivery is not refused.
  - `reserve`, `go_to` and `work` (1 tick): the colonist walks to the target.
  - **en-route recheck** (round 2): `ToolExecutor.advance()` calls
    `ToolDropToil.haul_target_lost()` on every tick for a kind with `fetch_tool` and no
    `needs_tool`. The target is lost when it is no longer free for a tool (see below), or when
    it lies in a stockpile that rejects tools now. All stockpiles come from
    `ZoneTable.get_stockpile_zones()`, wired as one argument appended to an existing
    `world_state.gd` line. The job is also lost when its `item_id` tool is gone or reserved by
    another job (round 5). A lost target goes to `fail_for_invalid_target()`:
    - the held tool, if it is this job's, is set down at the colonist's tile
      (`_set_down_held()`). It is stocked when that tile is in any stockpile, so `HaulGiver`
      hauls it out again if that stockpile rejects tools, and it goes on the ground otherwise.
      A tool is never left loose inside a stockpile;
    - every tool reservation of the job is released, and route, work and work progress are
      cleared;
    - `on_toil_fail` fails the job with `invalid_target` (remedy `resubmit_order`), as other
      toil failures do. The giver offers the tool again with a fresh target on a later tick.
  - **work completion** (`ToolDropToil.place_hauled_tool()`): the held tool is set down and
    its reservation is released. The target is checked again at this moment (round 2), since
    zones and filters can change while the tool is carried:
    - the target is "free for a tool" when it is passable and no other ground or stocked tool
      lies there. The cell's reservation is not checked (it is this job's own), and neither is
      a stack (one hauled there since may share it, as before);
    - free and in a stockpile that accepts tools now: stocked there;
    - free and in no stockpile at all: on the ground there;
    - otherwise (taken, or in a stockpile that rejects tools): `_set_down_held()` at the
      colonist's tile, as above. The en-route recheck normally fails the job first; this case
      covers a change on the completing tick.

    If the held tool is not this job's, nothing happens.
  - `release_all` then completes the job.
- `toil_bindings.gd` adds a `haul_tool` arm to the work-completion match. `toil_executor.gd`
  adds a one-line forwarder `place_hauled_tool()`, the 2-line en-route recheck and an optional
  `get_all_stockpiles` constructor parameter (round 2).
- **`world_state.gd` hook (declared):** exactly two existing lines are edited against
  `origin/main` (`git diff origin/main -- game/scripts/core/world_state.gd`), and none is added:
  767 lines before and after.
  - The `ToilExecutor` constructor's last line gains `_zone_table.get_stockpile_zones`
    (round 2).
  - The `HaulGiver` constructor's second line gains three optional trailing arguments:
    `_tool_store`, `_zone_table.get_zones` and
    `_scheduler.queue.view_jobs_of_kinds.bind(["haul_tool"])` (`get_tool_jobs`, round 4). The
    first line keeps `view_jobs_of_kinds.bind(["haul"])`. `HaulGiver` reads its own queued and
    active `haul_tool` jobs through `get_tool_jobs`, so it does not offer a target twice.
- Kept from `18bc3bd`:
  - `ToolItemStore.lies_at(cell)`.
  - `HaulGiver._cell_takes_item()`, shared with `find_free_haul_cell()` (same behaviour).
  - The skip for a tool whose zone was removed. The first full run of `18bc3bd` failed in
    `test_crafting`'s `_check_target_ignores_a_tool_whose_stockpile_was_removed` without it.
- Tests:
  - `test_stockpile_filters.gd`: the three F5a-b checks (seeds 64016, 64017, 64018) go through
    commands and ticks only (`zone_set_stockpile {zone_1, "material", 2}`). Every tick they
    also watch the pick and the `haul_tool` jobs, and assert two things: a `colonist_*`
    held the pick at some tick, and a `haul_tool` job reached `completed`. So a move with no
    carrying colonist fails them.
    - The B case: within a day the pick is stocked in B with the same single id, and A holds
      no tool.
    - The no-B case: the pick lies on the ground at (30,1), beside A and outside every zone,
      and it is still there 50 ticks later.
    - Round 2, seed 64019: B stops accepting tools (`zone_set_stockpile {zone_2, "material",
      1}`) while the pick is in the hand. A `haul_tool` job ends `failed` with reason
      `invalid_target`. On no tick after the switch does the pick lie loose inside A or B, or
      sit stocked in B. It ends on the ground outside every stockpile, and a colonist carried
      it.
    - Round 5, seed 64020: a food need interrupts the carrier with the pick in the hand. The
      job returns to `queued` with the pick still held, resumes, and completes with the pick
      stocked in B (same single id), never loose in A.
    - All cases: two worlds built from the same seed have equal `state_hash()` on every tick,
      and the replay returns ok.
  - `test_architecture_rules.gd`: `haul_tool` is added to the expected job kinds, and a
    `_run_and_verify("haul_tool", 207301, …)` scenario runs it end to end, like the other
    kinds.
  - `test_toils_dig_chop_regression.gd`: its pinned job kind list gains `haul_tool` (22 to 23
    kinds).
- ADR 064's Consequences bullet now describes the carried haul.
- `en.json`: `status.job.haul_tool` is "Hauling a tool" (every job kind has a status text).
- Schema v13 (round 2, renumbered in round 3): `StateCodec.SCHEMA_VERSION` is 13, and
  `SaveMigrations._v12_to_v13` changes only `schemaVersion` (a v12 world queued no `haul_tool`
  job; a v12 state that lists one is refused). `game-state.schema.json` gets const 13 and the
  `"haul_tool"` job kind. `save-system.md` documents v13. The new
  `save_schema_v13_fixture.json` was written by `docs/orca/handoffs/F5a-b-write-save.gd`, and
  `test_save_migration.gd` checks that F5b's v12 fixture migrates exactly to it, that v13 loads
  and re-encodes unchanged, and that a v12 state with a `haul_tool` job is refused.

## Pending owner approval (outside the owned paths)

Approved by the owner in round 2 (`docs/orca/BACKLOG.md` on main, commit `afeeade`):
- `game/content/jobs.json`: the `haul_tool` kind;
- `game/scripts/core/jobs/toil_executor.gd`: the forwarder, the 2-line en-route recheck and the
  constructor parameter (649/800);
- `game/scripts/core/jobs/toil_bindings.gd`: the work-completion arm (501/800);
- the `"haul_tool"` value of the schema's job kind enum;
- `game/data/text/en.json`: one status text.

The owned paths are `haul_giver.gd`, `tool_item_store.gd`, `tool_*_toil.gd`,
`test_stockpile_filters.gd` and this file. These changes are outside them and that approval,
and are still pending:

1. Schema v13 (round 2, needed by review finding (c); v13 since round 3):
   - `docs/architecture/contracts/game-state.schema.json`: const 13 (the enum value is
     approved);
   - `game/scripts/core/persistence/state_codec.gd`: `SCHEMA_VERSION` 13 (597/800);
   - `game/scripts/core/persistence/save_migrations.gd`: the `12:` arm and `_v12_to_v13`;
   - `docs/architecture/save-system.md`: the v13 notes;
   - `game/scripts/tests/test_save_migration.gd`: the v13 checks;
   - new `game/scripts/tests/fixtures/save_schema_v13_fixture.json` and its writer
     `docs/orca/handoffs/F5a-b-write-save.gd`.
2. `game/scripts/tests/test_architecture_rules.gd`: the expected kinds and one scenario; and
   `game/scripts/tests/test_toils_dig_chop_regression.gd`: `haul_tool` added to its pinned kind
   list (22 to 23, after F5b's `cook_work`).
3. `game/scripts/core/world_state.gd`: the edits to two existing lines described above (the
   `ToilExecutor` constructor's last line and the `HaulGiver` constructor's second line). It
   stays at 767 lines, within the round 1 decision (`07cd384`). Round 3 wrongly reported two
   lines while three were edited; round 4 brings it to two.
4. `docs/decisions/064-…md` and `docs/orca/BACKLOG.md` (status `review`, unchanged in this
   round).

## Contract impact

- Save format: schema v13. The job `kind` enum gains `haul_tool`. `_v12_to_v13` changes only
  `schemaVersion`. A saved `haul_tool` job is an ordinary job record, and a tool's reservation
  is already saved in `ToolItemStore.reservations`.
- Ids: none are created. The tool keeps its id (ADR 061). The job takes a normal job id from
  the queue.
- Jobs and content: one new job kind, `haul_tool`. No new toil, command or labour.
- `state_hash()`: its inputs did not change. A world with a stocked tool in a stockpile that
  rejects tools now evolves differently: a job is queued and a colonist carries the tool.
- API:
  - `ToolDropToil.place_hauled_tool()` and `ToolExecutor.place_hauled_tool()` are new. The
    first one revalidates its target at delivery.
  - `ToolDropToil.haul_target_lost()` and `fail_for_invalid_target()` are new (round 2).
    `ToolDropToil._init` and `ToolExecutor._init` each gain an optional trailing
    `get_all_stockpiles` parameter.
  - A failed `haul_tool` job can carry reason `invalid_target`. That reason already exists,
    with its own text.
  - `ToolItemStore.lies_at()` is new.
  - `HaulGiver._init` has three optional trailing parameters: `tool_store` and `get_zones`
    (from `18bc3bd`), and `get_tool_jobs` (round 4). Its `get_jobs` view lists `haul` jobs only,
    as on `origin/main`.

## Validation (Windows, Godot 4.7.2 headless)

Run these from the repo root:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_stockpile_filters
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_architecture_rules
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_save_migration
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1
python tools/check_core_budgets.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/measure_core.ps1
```

- Filtered runs (round 5), all PASS: `test_stockpile_filters` [18s], `test_haul_need_interrupt`
  [2s], `test_architecture_rules` [3s], `test_build_tool_footprint` [1s],
  `test_toils_dig_chop_regression` [2s], `test_tool_handover_scenarios` [18s], `test_tool_items`
  [4s], `test_tool_items_fetch` [6s], `test_tool_items_handover` [2s] and
  `test_tool_items_reservations` [5s].
- Filtered runs (round 4), both PASS: `test_stockpile_filters` [22s] and
  `test_architecture_rules` [3s].
- Filtered runs (round 3): `test_save_migration` [7s] PASS after the v13 renumbering.
- Filtered runs (round 2), all PASS: `test_stockpile_filters` [23s], `test_save_migration`
  [6s], `test_architecture_rules` [3s], `test_crafting` [9s] and
  `test_toils_dig_chop_regression` [1s]. `test_crafting` prints push_error stack lines from its
  expected-failure checks, and still passes.
- Gate: `check_core_budgets: OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file cap(s), 1 file and 3 function exception(s))`.
  No budget or exception was raised.
- `tools/measure_core.ps1`: `core total: 23423 lines in 113 files` (round 5 after the L3 rebase;
  23144 in 112 files before it, 23108 in round 4, 23105 in round 3; the growth is L3's).

  | File | Lines | Longest function |
  |---|---|---|
  | `world_state.gd` | 767 (593 code, 114 comment) | `state_hash`, 30 |
  | `toil_executor.gd` | 649 (478 code, 124 comment) | `_start_current_toil`, 50 |
  | `toil_bindings.gd` | 501 | `_init`, 49 |
  | `tool_drop_toil.gd` | 358 | `_init`, 30 |
  | `tool_fetch_toil.gd` | 278 | `advance`, 41 |
  | `haul_giver.gd` | 169 | — |
  | `state_codec.gd` | 597 (436 code, 106 comment) | `decode`, 70 |

## Known limitations

- If the tool cannot be reached, `fetch_tool` cannot pick it up. The job then fails or
  completes with nothing placed (`place_hauled_tool` is a no-op without the tool in hand). The
  reservation is released, and the giver submits a new job on a later tick.
- A reserved tool (one a colonist is fetching for other work) is skipped until it is free.
- With no free destination and no free adjacent tile, the tool stays put, and the giver searches
  again every tick. That costs a few cell checks per rejected tool per tick.
- The ground fallback must share an edge with the tool's own stockpile, on the same layer. The
  tool is not taken further away.
- The job has no hauling priority of its own (non-goal). It uses `haul`'s priority, 1.
- When the job fails en route, the tool is set down at the colonist's tile with no check that
  the cell is free. If a stocked tool already lies there, the two share the cell until the giver
  hauls one out.
- After a need interrupt the carrier keeps the tool in the hand while the job is queued again
  (`JobQueue.suspend()`). The test covers the same carrier resuming it. A different haul colonist
  claiming the queued job meanwhile is not covered by a test: it cannot pick up a tool held by
  another colonist, so the job would not deliver it until the tool is set down.
- A stack hauled onto the target while the tool is carried may share the cell with the stocked
  tool, as it could before F5a-b.

## Next action

- The owner approves or rejects the files still listed under "Pending owner approval": the
  schema v13 files beyond the enum, the test pins and the `world_state.gd` line edits.
- The reviewer reproduces the full suite line.
- Then review with `tools/orca/review.ps1`, which now resolves `F5a-b` to this file.
