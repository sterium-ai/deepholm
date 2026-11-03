# F5a-b handoff: haul rejected tools out of a stockpile

## Branch and commits

- Branch: `antonelmejor50-hub/f5a-b-haul-rejected-tools-out`. Not pushed.
- Commits on this branch, oldest first:
  1. `18bc3bd`: first delivery (an instant move with no job). It was rejected in review round 1.
  2. `f36dde9`: a handoff note about `review.ps1`. That note is now dropped, because the
     script was fixed on main (`5be734f`, `76d139b`).
  3. The round 1 fix, which is the commit that changes this file to the present text
     (`git log -1 -- docs/orca/handoffs/F5a-b.md`).
- Owner decision followed: review round 1, written in `docs/orca/BACKLOG.md` on main, commit
  `07cd384`. The move must be a real haul job through the shared queue and the existing tool
  fetch/drop toils, done by a colonist with the haul labour, and covered by tests through
  commands and ticks. In `world_state.gd`, only a wiring hook of 2 lines or fewer is allowed,
  with no growth.

## Final suite line (author-reported, round 1 fix)

```
run_tests: all 135 test(s) PASS  [889s]
```

The author ran this on the round 1 working tree, which is the content of the fix commit, on
Windows with Godot 4.7.2 headless. The reviewer did not reproduce it. N stays 135: the new
checks are in the existing `test_stockpile_filters.gd` and `test_architecture_rules.gd`, and no
test file was added or removed. The first full run of the fix failed 1 of 135
(`test_toils_dig_chop_regression`, which pins the job kind list at 21). With `haul_tool` added
there (22 kinds), the run above is the second one.

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
  - **work completion** (`ToolDropToil.place_hauled_tool()`): the held tool is set down at the
    target, as a stocked tool inside a zone or on the ground outside, and its reservation is
    released. If the held tool is not this job's, nothing happens.
  - `release_all` then completes the job.
- `toil_bindings.gd` adds a `haul_tool` arm to the work-completion match, and `toil_executor.gd`
  adds a one-line forwarder `place_hauled_tool()`.
- **`world_state.gd` hook (declared):** one existing line is edited. `HaulGiver` reads
  `view_jobs_of_kinds.bind(["haul", "haul_tool"])` instead of `["haul"]`, so it sees its own
  `haul_tool` jobs. No line was added: 767 lines before and after. The two optional
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
    - Both cases: two worlds built from the same seed have equal `state_hash()` on every tick,
      and the replay returns ok.
  - `test_architecture_rules.gd`: `haul_tool` is added to the expected job kinds, and a
    `_run_and_verify("haul_tool", 207301, …)` scenario runs it end to end, like the other
    kinds.
  - `test_toils_dig_chop_regression.gd`: its pinned job kind list gains `haul_tool` (21 to 22
    kinds).
- ADR 064's Consequences bullet now describes the carried haul.
- `en.json`: `status.job.haul_tool` is "Hauling a tool" (every job kind has a status text).
- `game-state.schema.json`: the job `kind` enum gains `"haul_tool"`.

## Pending owner approval (outside the owned paths)

The backlog lists these owned paths: `haul_giver.gd`, `tool_item_store.gd`, `tool_*_toil.gd`,
`test_stockpile_filters.gd` and this file. A carried job also needed the following changes. Each
is the smallest wiring that the shared queue and the toil engine require:

1. `game/content/jobs.json`: one line, the `haul_tool` kind.
2. `game/scripts/core/jobs/toil_executor.gd`: +3 lines, the forwarder (647/800).
3. `game/scripts/core/jobs/toil_bindings.gd`: +2 lines, the work-completion arm (501/800).
4. `docs/architecture/contracts/game-state.schema.json`: `"haul_tool"` added to the job kind
   enum. This is additive. An older save never has that kind, so it still loads.
5. `game/data/text/en.json`: one status text.
6. `game/scripts/tests/test_architecture_rules.gd`: the expected kinds and one scenario; and
   `game/scripts/tests/test_toils_dig_chop_regression.gd`: `haul_tool` added to its pinned kind
   list (21 to 22).
7. `game/scripts/core/world_state.gd`: the one-line hook above. It is within the round 1
   decision (`07cd384`).
8. `docs/decisions/064-…md` and `docs/orca/BACKLOG.md` (status `review`, unchanged in this
   round).

## Contract impact

- Save format: no schema version bump. The job `kind` enum gains `haul_tool`, which is
  additive. A saved `haul_tool` job is an ordinary job record, and a tool's reservation is
  already saved in `ToolItemStore.reservations`.
- Ids: none are created. The tool keeps its id (ADR 061). The job takes a normal job id from
  the queue.
- Jobs and content: one new job kind, `haul_tool`. No new toil, command or labour.
- `state_hash()`: its inputs did not change. A world with a stocked tool in a stockpile that
  rejects tools now evolves differently: a job is queued and a colonist carries the tool.
- API:
  - `ToolDropToil.place_hauled_tool()` and `ToolExecutor.place_hauled_tool()` are new.
  - `ToolItemStore.lies_at()` is new.
  - `HaulGiver._init` has two optional trailing parameters (from `18bc3bd`).

## Validation (Windows, Godot 4.7.2 headless)

Run these from the repo root:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_stockpile_filters
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_architecture_rules
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1
python tools/check_core_budgets.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/measure_core.ps1
```

- Filtered runs, all PASS: `test_stockpile_filters` [21s], `test_architecture_rules` [3s],
  `test_text_pseudo_locale` [2s], `test_crafting` [9s] and `test_toils_dig_chop_regression` [1s]. `test_crafting` prints push_error
  stack lines from its expected-failure checks, and still passes.
- Gate: `check_core_budgets: OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file cap(s), 1 file and 3 function exception(s))`.
  No budget or exception was raised.
- `tools/measure_core.ps1`: `core total: 22885 lines in 112 files`.

  | File | Lines | Longest function |
  |---|---|---|
  | `world_state.gd` | 767 (593 code, 114 comment) | `state_hash`, 30 |
  | `toil_executor.gd` | 647 | `_start_current_toil`, 50 |
  | `toil_bindings.gd` | 501 | `_init`, 49 |
  | `tool_drop_toil.gd` | 293 | `_init`, 29 |
  | `tool_fetch_toil.gd` | 254 | — |
  | `haul_giver.gd` | 161 | — |

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

## Next action

- The owner approves or rejects the out-of-scope wiring listed under "Pending owner approval".
- Then review with `tools/orca/review.ps1`, which now resolves `F5a-b` to this file.
