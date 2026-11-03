# F5a-b handoff: haul rejected tools out of a stockpile

## Branch and commit

- Branch: `antonelmejor50-hub/f5a-b-haul-rejected-tools-out`, one commit on top of `200f9c4`
  (`origin/main` after `git fetch origin` on 2026-11-03: `git log HEAD..origin/main` is empty, so
  no rebase was needed). The commit is the one that adds this file (`git log -1`). Not pushed.

## Final suite line (branch head)

```
run_tests: all 135 test(s) PASS  [919s]
```

This run covers the code at HEAD: the commit after it only adds this line and the note below
to this file.

Note for review: `tools/orca/review.ps1` takes the task id as the first `-` token of the
branch name (line 24), so for `f5a-b-haul-…` it reads `F5A`, i.e. `docs/orca/handoffs/F5a.md`.
That is the parent task's report, which quotes 134 tests. Its preflight then fails with "quotes
134 tests but the branch has 135", and the reviewer prompt would point at F5a's handoff. This
report, `F5a-b.md`, quotes 135. The script is not an owned path, so it is not changed here (see
Next action).

Baseline before the change, same machine: `run_tests: all 135 test(s) PASS  [879s]`. That run
started before the edits were saved and finished after, so some later files may have run
against the edited code. The branch run above is the one that counts. N stays 135: the new
checks are in the existing `test_stockpile_filters.gd`. No test file was added or removed.

## What changed

- `HaulGiver.advance()` first runs `_move_rejected_tools()`. For each stocked tool in id order
  (`ToolItemStore` location type `stockpile`), it skips tools that are reserved or whose tile
  still accepts the tool's group (`ZoneTable.accepts_item_at`). Every other one moves, keeping
  its id:
  1. to the first free cell of the tool-accepting stockpiles in `stockpiles_for_item()` order:
     highest priority, then nearest, then zone id, row-major inside each, the same order
     `find_free_haul_cell()` uses. A free cell is free, passable, unoccupied and holds no
     stocked or ground tool (`ToolItemStore.lies_at`). The tool becomes a stocked tool there
     (`set_stockpile`).
  2. if there is none, onto the ground (`set_ground`) at the nearest free tile that shares an
     edge with its stockpile and lies outside every zone. Ties go by y, then x.
  3. if neither exists, it stays where it is and is tried again on the next tick.

  A stocked tool whose tile lies in no stockpile (its zone was removed) is not touched. F2 says
  such a tool is not stock and stays put, and `test_crafting`'s
  `_check_target_ignores_a_tool_whose_stockpile_was_removed` pins that. The first full run
  failed there (`exactly two axes' inputs must be spent`), because the move had carried the old
  axe into the new zone. The tool is now moved only out of a stockpile that rejects it.
- `find_free_haul_cell()`'s cell test was moved into `_cell_takes_item()` and is reused. The
  behaviour is the same.
- `ToolItemStore.lies_at(cell)` is new: it tells whether a ground or stocked tool is on that cell.
- The `HaulGiver` constructor gained two optional trailing parameters: `tool_store` and
  `get_zones` (`ZoneTable.get_zones`). Without them the move is off, so other constructor
  callers are unaffected.
- `WorldState` passes the two new arguments. One existing line was edited, with no line added
  (767 lines before and after).
- Tests (`test_stockpile_filters.gd`, extended):
  - `_check_rejected_stocked_tool_moves_to_b_with_its_id`: a pick is stocked in A and stays
    while A accepts tools. Then `zone_set_stockpile {zone_1, "material", 2}` is issued. Within
    a day the pick is stocked in B, with the same single id, and A holds no tool.
  - `_check_rejected_stocked_tool_without_b_is_dropped_beside_a`: with no B, the pick is on the
    ground at (30,1), a tile that shares an edge with A and is outside every zone. It is still
    there 50 ticks later.
  - `_check_rejected_stocked_tool_is_deterministic_and_replays`: for both of the cases above,
    two worlds built from the same seed have equal `state_hash()` on every tick, and the
    recorder replay returns ok.
- ADR 064's Consequences now says that F5a-b closes the stocked-tool limitation.

## Deviations from the design and the owner note (pending owner approval)

1. **No ToolFetchToil/ToolDropToil.** The backlog and the owner note ask to reuse the tool
   fetch and drop toils. Here the move is an instant `ToolItemStore` write and no colonist
   carries the tool. A move carried by a colonist would need a new job kind or a toil chain.
   That means `content/jobs.json`, `toil_executor`, `toil_bindings` and `JobQueue`, which are
   outside the owned paths, and very likely a schema bump for the saved job. ADR 061 is still
   honoured: no id is created and the tool keeps its record. If the owner wants the carried
   version, it is a follow-up task (see Next action).
2. **`game/scripts/core/world_state.gd` is touched, and it is not an owned path.** The edit is
   the one line where `HaulGiver` is constructed, and the file did not grow (767/800). The
   owner note's "sin crecer" (no growth) is met. Wiring a giver dependency can't be done
   without this line.

## Owned paths and the files actually changed

Owned: `core/jobs/givers/haul_giver.gd`, `core/items/tool_item_store.gd`,
`core/jobs/tool_*_toil.gd`, `tests/test_stockpile_filters.gd`, `docs/orca/handoffs/F5a-b.md`.

Changed:
- `game/scripts/core/jobs/givers/haul_giver.gd` (155 lines)
- `game/scripts/core/items/tool_item_store.gd` (115 lines)
- `game/scripts/core/world_state.gd` (one line, not owned, see Deviations)
- `game/scripts/tests/test_stockpile_filters.gd`
- `docs/decisions/064-stockpile-filters-and-priorities.md` (Consequences bullet)
- `docs/orca/BACKLOG.md` (F5a-b status changed to `review`)
- `docs/orca/handoffs/F5a-b.md`

The `tool_*_toil.gd` files were not changed.

## Contract impact

- Save format: none. No schema bump. A moved tool is an ordinary `ToolItemStore` record whose
  location type is `stockpile` or `ground`, both already valid.
- Ids: none are created. The moved tool keeps its id (ADR 061).
- Commands, jobs, toils, content and texts: none added or changed.
- `state_hash()`: the hash's inputs did not change. A world with a stocked tool in a stockpile
  that rejects tools now evolves differently. That situation could only arise once F5a added
  filters, and F5a left the tool where it was.
- API: `HaulGiver._init` has two new optional trailing parameters, and `ToolItemStore.lies_at()`
  is new.

## Validation (Windows, Godot 4.7.2 headless)

Run these from the repo root:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Filter test_stockpile_filters
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1
python tools/check_core_budgets.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/measure_core.ps1
```

- Gate: `check_core_budgets: OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file cap(s), 1 file and 3 function exception(s))`.
  No budget or exception was raised.
- `tools/measure_core.ps1`: `core total: 22851 lines in 112 files`. `world_state.gd`: 767 total,
  593 code, 114 comment lines; its longest function is `state_hash` at 30 lines.
  `haul_giver.gd` is 155 lines and its longest function, `_free_ground_cell_beside`, is under 30
  lines. `tool_item_store.gd` is 115 lines.
- Each run prints "N resources still in use at exit". It already appeared 74 times in the
  baseline, so it is not new.

## Known limitations

- The move is instant, with no colonist, no walking and no labour. The tool simply appears at
  its destination on the tick after the filter changes.
- A tool that is reserved (a colonist is fetching it) is left alone. If the fetch is dropped
  later, the tool is moved on a later tick.
- With no free destination and no free adjacent tile, the tool stays in the rejecting
  stockpile and the search repeats every tick. That costs a few cell checks per rejected tool
  per tick, and nothing else.
- The fallback ground tile must share an edge with the tool's own stockpile and lie on the
  same layer. The tool is not taken further away.

## Next action

The owner should approve or reject the two deviations. If the tool must be carried by a
colonist through ToolFetchToil and ToolDropToil, open a follow-up that owns `jobs.json`, the
toil executor and bindings, and `JobQueue`. Its first step is to decide whether that job is
saved, because a saved job means a schema bump. Otherwise this is ready for review.

To launch the review, `review.ps1` must resolve the id `F5A-B`. That needs a small fix in that
script, owned by the owner: for example, take the token before the first `-` that is followed
by a word of three or more letters, or accept a `-TaskId` parameter. Until then, use
`-SkipPreflight`, and tell the reviewer that the report is `docs/orca/handoffs/F5a-b.md`.
