# F5a-b handoff: haul rejected tools out of a stockpile

## Branch and commits

- Branch: `antonelmejor50-hub/f5a-b-haul-rejected-tools-out`. Not pushed.
- Commits on this branch, oldest first:
  1. `18bc3bd`: first delivery (an instant move with no job). It was rejected in review round 1.
  2. `f36dde9`: a handoff note about `review.ps1`. That note is now dropped, because the
     script was fixed on main (`5be734f`, `76d139b`).
  3. `479a473`: the round 1 fix (a carried `haul_tool` job, no teleport).
  4. The round 2 fix, which is the commit that changes this file to the present text
     (`git log -1 -- docs/orca/handoffs/F5a-b.md`). It answers review round 2
     (`.orca-review.md`, REQUEST_CHANGES):
     - (b) the destination is rechecked on every tick while the tool is fetched or carried.
       An invalid one fails the job through the shared job engine (`invalid_target`), and the
       delivery revalidates too. A 4th check runs through commands and ticks (seed 64019);
     - (c) `haul_tool` is now schema v12, with a migration and a fixture;
     - (a) scope: the owner approved `jobs.json`, `toil_executor.gd`, `toil_bindings.gd`, the
       schema enum and `en.json` in `docs/orca/BACKLOG.md` on main, commit `afeeade`. The rest
       is listed under "Pending owner approval".
- Owner decision followed (round 2): `afeeade` on main approves that scope and asks for the
  en-route destination recheck through the shared job engine, with a test through commands and
  ticks.
- Owner decision followed: review round 1, written in `docs/orca/BACKLOG.md` on main, commit
  `07cd384`. The move must be a real haul job through the shared queue and the existing tool
  fetch/drop toils, done by a colonist with the haul labour, and covered by tests through
  commands and ticks. In `world_state.gd`, only a wiring hook of 2 lines or fewer is allowed,
  with no growth.

## Final suite line (author-reported, round 2 fix)

```
run_tests: all 135 test(s) PASS  [924s]
```

The author ran this on the round 2 working tree, which is the content of the round 2 commit, on
Windows with Godot 4.7.2 headless. It is still author-reported: the reviewer has not reproduced
it yet (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1`). N stays
135: the new checks are in existing test files, and no test file was added or removed. Round 1's
run was `run_tests: all 135 test(s) PASS  [889s]`.

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

  It then submits a `haul_tool` job at the target through the shared queue (`submit_job`) and
  reserves the tool for that job (`ToolItemStore.reserve`).
- A colonist with the haul labour takes the job from the scheduler like any other job.
  - **`fetch_tool`** (`ToolFetchToil`): for a kind with no `needs_tool` that lists
    `fetch_tool`, the toil carries the tool its giver reserved. It walks to the tool and picks
    it up, with no search. It is done once that tool is in the hand, or once the job has no
    reserved tool left (`_carry_done()`).
  - `reserve`, `go_to` and `work` (1 tick): the colonist walks to the target.
  - **en-route recheck** (round 2): `ToolExecutor.advance()` calls
    `ToolDropToil.haul_target_lost()` on every tick for a kind with `fetch_tool` and no
    `needs_tool`. The target is lost when it is no longer free for a tool (see below), or when
    it lies in a stockpile that rejects tools now. All stockpiles come from
    `ZoneTable.get_stockpile_zones()`, wired as one argument appended to an existing
    `world_state.gd` line. A lost target goes to `fail_for_invalid_target()`:
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
- **`world_state.gd` hook (declared):** one existing line is edited. `HaulGiver` reads
  `view_jobs_of_kinds.bind(["haul", "haul_tool"])` instead of `["haul"]`, so it sees its own
  `haul_tool` jobs. In round 2, `_zone_table.get_stockpile_zones` is appended to the existing
  `ToilExecutor` constructor line. No line was added: 767 lines before and after. The two optional
  `HaulGiver` arguments (`tool_store`, `get_zones`) were already wired by `18bc3bd` on the same
  line.
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
    - All cases: two worlds built from the same seed have equal `state_hash()` on every tick,
      and the replay returns ok.
  - `test_architecture_rules.gd`: `haul_tool` is added to the expected job kinds, and a
    `_run_and_verify("haul_tool", 207301, …)` scenario runs it end to end, like the other
    kinds.
  - `test_toils_dig_chop_regression.gd`: its pinned job kind list gains `haul_tool` (21 to 22
    kinds).
- ADR 064's Consequences bullet now describes the carried haul.
- `en.json`: `status.job.haul_tool` is "Hauling a tool" (every job kind has a status text).
- Schema v12 (round 2): `StateCodec.SCHEMA_VERSION` is 12, and
  `SaveMigrations._v11_to_v12` changes only `schemaVersion` (a v11 world queued no `haul_tool`
  job; a v11 state that lists one is refused). `game-state.schema.json` gets const 12 and the
  `"haul_tool"` job kind. `save-system.md` documents v12. The new
  `save_schema_v12_fixture.json` was written by `docs/orca/handoffs/F5a-b-write-save.gd`, and
  `test_save_migration.gd` checks that the v11 fixture migrates exactly to it, that v12 loads,
  and that a v11 state with a `haul_tool` job is refused.

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

1. Schema v12 (round 2, needed by review finding (c)):
   - `docs/architecture/contracts/game-state.schema.json`: const 12 (the enum value is
     approved);
   - `game/scripts/core/persistence/state_codec.gd`: `SCHEMA_VERSION` 12 (596/800);
   - `game/scripts/core/persistence/save_migrations.gd`: the `11:` arm and `_v11_to_v12`;
   - `docs/architecture/save-system.md`: the v12 notes;
   - `game/scripts/tests/test_save_migration.gd`: the v12 checks;
   - new `game/scripts/tests/fixtures/save_schema_v12_fixture.json` and its writer
     `docs/orca/handoffs/F5a-b-write-save.gd`.
2. `game/scripts/tests/test_architecture_rules.gd`: the expected kinds and one scenario; and
   `game/scripts/tests/test_toils_dig_chop_regression.gd`: `haul_tool` added to its pinned kind
   list (21 to 22).
3. `game/scripts/core/world_state.gd`: the edits to two existing lines described above (the
   `HaulGiver` hook, and in round 2 the argument appended to the `ToilExecutor` line). It stays
   at 767 lines, within the round 1 decision (`07cd384`).
4. `docs/decisions/064-…md` and `docs/orca/BACKLOG.md` (status `review`, unchanged in this
   round).

## Contract impact

- Save format: schema v12. The job `kind` enum gains `haul_tool`. `_v11_to_v12` changes only
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
  - `HaulGiver._init` has two optional trailing parameters (from `18bc3bd`).

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

- Filtered runs (round 2), all PASS: `test_stockpile_filters` [23s], `test_save_migration`
  [6s], `test_architecture_rules` [3s], `test_crafting` [9s] and
  `test_toils_dig_chop_regression` [1s]. `test_crafting` prints push_error stack lines from its
  expected-failure checks, and still passes.
- Gate: `check_core_budgets: OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file cap(s), 1 file and 3 function exception(s))`.
  No budget or exception was raised.
- `tools/measure_core.ps1`: `core total: 22961 lines in 112 files`.

  | File | Lines | Longest function |
  |---|---|---|
  | `world_state.gd` | 767 (593 code, 114 comment) | `state_hash`, 30 |
  | `toil_executor.gd` | 649 (478 code, 124 comment) | `_start_current_toil`, 50 |
  | `toil_bindings.gd` | 501 | `_init`, 49 |
  | `tool_drop_toil.gd` | 351 (255 code, 70 comment) | `_init`, 30 |
  | `tool_fetch_toil.gd` | 254 | — |
  | `haul_giver.gd` | 161 | — |
  | `state_codec.gd` | 596 | `decode`, 70 |

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
- A stack hauled onto the target while the tool is carried may share the cell with the stocked
  tool, as it could before F5a-b.

## Next action

- The owner approves or rejects the files still listed under "Pending owner approval": the
  schema v12 files beyond the enum, the test pins and the `world_state.gd` line edits.
- The reviewer reproduces the full suite line.
- Then review with `tools/orca/review.ps1`, which now resolves `F5a-b` to this file.
