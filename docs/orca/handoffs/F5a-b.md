# F5a-b handoff: haul rejected tools out of a stockpile

## Branch and commits

- Branch: `antonelmejor50-hub/f5a-b-haul-rejected-tools-out`. Not pushed.
- Commits on this branch, oldest first:
  (The hashes below are from before the round 11 rebases. After rebasing onto `origin/main`
  `a5cb853`, which includes F5c `47a3e58` and L4, the same 13 commits are, oldest first:
  `d6fa3a8`, `3b3a812`, `1bb6f81`, `e9ddcb8`, `2df8be3`, `b2d7a58`, `a39afe8`, `6d7c6ee`,
  `d782c52`, `033a8a1`, `a83e35d`, `bbdf945`, `a3f2030`. See item 14.)
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
       round 2, v13 in rounds 3 to 10 (see item 5), and is **v14** since round 11 (see item 14);
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
     The v13 edits were folded into `1079d00`, and this commit updates only this file. All of
     this item was superseded in round 11: F5c took v13, and the bump is now `_v13_to_v14`
     (item 14).
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
  8. Round 5 rebase, `6d7c6ee`. Owner note: L3 (`bb3ff32`, ADR 068, no schema
     bump) is on main. The branch was rebased onto `origin/main` `f55e9b0` with no conflict:
     - v13 is still free (`origin/main` is at v12), so the bump stays `_v12_to_v13`;
     - L3 changes map and routing code (`regions.gd`, `vertical_links.gd`, `route_search.gd`,
       `passability.gd`, `tile_grid.gd`) and adds `test_vertical_links.gd`, so the full suite
       was rerun on the rebased HEAD and N is now 137;
     - `world_state.gd` is still 767 lines, and still exactly two existing lines differ from
       `origin/main`; this commit updates only this file.
  9. Round 6, `9796270`. It answers review round 6
     (`.orca-review.md`, REQUEST_CHANGES):
     - (blocking) a `haul_tool` cargo that cannot be reached was re-reserved forever
       (`tool_fetch_toil.gd`, the round 5 re-reservation). Each failed route released it,
       added it to the colonist's exclusion list and reserved it again, so the job neither
       failed nor completed, and the exclusion list kept growing. Now:
       - `ToolFetchToil._exclude_candidate()` knows whether the job carries a named cargo
         (a kind with no `needs_tool`). For such a job it releases the tool, clears the
         exclusions and the route, and fails the job once through the shared engine
         (`on_toil_fail`, existing reason `blocked_target_unreachable`). A job that searches
         for a tool (`needs_tool`) still excludes the candidate and searches again, as before;
       - `HaulGiver` skips a stocked tool whose tile lies in no region reachable from the
         target cell (new optional trailing constructor parameter `region_reachable`, wired as
         `_passability.region_reachable`, appended to the same `world_state.gd` line as round
         4). So the failed tool is not offered again while it is walled off, and no retry loop
         follows. It is offered again once it is reachable;
       - `world_state.gd` is still 767 lines, and still exactly two existing lines differ from
         `origin/main` (`git diff --numstat origin/main -- game/scripts/core/world_state.gd`
         gives `2 2`);
       - new tick-driven test `_check_walled_off_rejected_tool_fails_once_without_a_retry_loop`
         (seed 64021, see "Tests" below). With the round 5 `tool_fetch_toil.gd` swapped in it
         fails at `test_stockpile_filters.gd:761` (the job never fails); with the fix it
         passes;
       - "Known limitations" no longer says this case "fails or completes": it fails, once;
     - (non-blocking) the full suite is still author-reported. The final line and the log path
       of the round 6 run are quoted below;
     - cleanup: broken continuation lines in `haul_giver.gd` (`_cell_takes_item`, `_zone_has`),
       `tool_fetch_toil.gd` and `test_stockpile_filters.gd` are joined or indented again.
  10. Round 7, `3fc7f18`. It answers review round 7
     (`.orca-review.md`, REQUEST_CHANGES):
     - (blocking) `haul_giver.gd` checked reachability only after choosing the first
       destination, so an unreachable preferred stockpile blocked the haul forever even when
       another accepting stockpile was reachable. The region check now runs inside the
       destination search (new helper `_reaches(from, cell)`, used by
       `_free_tool_stockpile_cell()` and `_free_ground_cell_beside()`): an unreachable cell is
       skipped and the search goes on to the next cell, the next stockpile, then the ground
       fallback. The post-selection check is gone;
     - new tick-driven test `_check_walled_off_preferred_stockpile_yields_to_a_reachable_one`
       (seed 64022, see "Tests" below). With the round 6 `haul_giver.gd` swapped in it fails
       at `test_stockpile_filters.gd:791` (the pick stays in A); with the fix it passes. The
       test helper `_wall_a` became `_wall_around(world, rect, rock)`;
     - (non-blocking) the "All cases" determinism and replay claim under "Tests" is narrowed to
       the cases that check it (seeds 64018 and 64019);
     - (non-blocking) the full suite is still author-reported. The final line and the log path
       of the round 7 run are quoted below;
     - `world_state.gd` is still 767 lines, with `git diff --numstat origin/main --
       game/scripts/core/world_state.gd` giving `2 2`; `tool_fetch_toil.gd` is unchanged.
  11. Round 8, `707d681`. It answers review round 8
     (`.orca-review.md`, REQUEST_CHANGES):
     - (blocking) when the destination became unreachable while the tool was in the hand (for
       example B walled off mid-carry), `toil_on_unreachable` in `toil_bindings.gd` took the
       generic non-first-toil path: cancel the job and resubmit it. The resubmitted `haul_tool`
       job had no `item_id` and no tool reservation, while the pick stayed in the carrier's
       hand. Now a `haul_tool` job whose colonist is known goes to a new arm before that path:
       `ToolExecutor.fail_hauled_tool()` (a one-line forwarder) calls
       `ToolDropToil.fail_for_invalid_target()`, the same shared engine as the en-route
       recheck. The held tool is set down at the colonist's tile, the job's tool reservations
       are released, and the job fails with `invalid_target`. No job is resubmitted without its
       cargo. The round 7 per-candidate check then keeps `HaulGiver` from offering the walled-off
       B again, so no re-offer loop follows;
     - new tick-driven test `_check_destination_walled_off_mid_carry_sets_the_tool_down`
       (seed 64023, see "Tests" below). With the new arm disabled it fails: the job ends
       `cancelled` (`cancelled_by_command`) and the pick stays held. With the fix it passes;
     - (non-blocking) the "ToolFetchToil `advance`" row of the table said 41 code lines; it is
       44 (unchanged in this round, the count was wrong);
     - (non-blocking) the full suite is still author-reported (the reviewer reproduced
       `test_architecture_rules` independently). The final line and the log path of the round 8
       run are quoted below;
     - `world_state.gd` is still 767 lines, with `git diff --numstat origin/main --
       game/scripts/core/world_state.gd` giving `2 2`; `haul_giver.gd` and `tool_fetch_toil.gd`
       are unchanged.
  12. Round 9, `dbfe7fd`. It answers review round 9
     (`.orca-review.md`, REQUEST_CHANGES):
     - (blocking) a need interrupt suspends the job and releases its tool reservation, while
       the carrier keeps the pick in the hand and the job keeps `item_id` (ToolFetchToil
       re-reserves it on resume). If B stopped accepting tools before the job resumed, the
       en-route recheck failed the job, but `fail_for_invalid_target()` only set the held tool
       down when that job reserved it, so the pick stayed in the hand. Now it also sets the
       held tool down when it is unreserved and is the job's own `item_id`. A tool reserved by
       another job is still left alone. The round 8 unreachable arm goes through the same
       function, so it gets the same fix;
     - new tick-driven test
       `_check_destination_rejects_tools_during_an_interrupt_sets_the_tool_down` (seed 64024,
       see "Tests" below). With the fix disabled it fails with "the failed job must set the pick
       down: held colonist_0". With the fix, the filtered run passes;
     - (non-blocking) the full suite is still author-reported (the reviewer's sandbox is
       read-only). The final line and the log path of the round 9 run are quoted below;
     - `world_state.gd` is still 767 lines, with `git diff --numstat origin/main --
       game/scripts/core/world_state.gd` giving `2 2`; only `tool_drop_toil.gd` changes in
       core.
  13. Round 10, `a3f2030`. It follows the owner's rule in
     `docs/orca/BACKLOG.md` on main, commit **`c769a48`**: whenever a `haul_tool` job cannot
     continue, the carrier sets the tool down on its current tile, the job fails through the
     shared engine, and the giver re-plans from the ground. The case-by-case fixes of rounds 5
     to 9 are replaced by one failure branch:
     - `ToolDropToil.fail_haul_tool(colonist, job_id, job, hooks, reason)` is the only exit for
       a `haul_tool` job that cannot continue. It sets the held tool down on the carrier's tile
       (when the carrier holds the job's tool, reserved or not), releases every tool reservation
       of the job, clears the toil state and calls `hooks.on_toil_fail` (the shared
       `finish_job("fail_job")`). The callers only pick an existing reason:
       - destination no longer free for a tool or inside a stockpile that rejects tools, or
         cargo gone or reserved by another job: `invalid_target` (`toil_executor.gd`, the
         en-route recheck `ToolDropToil.haul_cannot_continue()`, every tick);
       - destination unreachable mid-carry: `blocked_target_unreachable` (`toil_bindings.gd`
         `toil_on_unreachable`, through `ToolExecutor.fail_hauled_tool()`; round 8 used
         `invalid_target` here);
       - cargo unreachable while fetching: `blocked_target_unreachable`
         (`ToolFetchToil.fail_carry`, wired to `fail_haul_tool`);
       - need or rescue interrupt: `need_interrupt` (`needs_system.gd` and
         `toil_bindings.gd` `abandon_haul_tool`). A `haul_tool` job is no longer suspended and
         re-queued with the tool in the hand; it fails, and the tool is on the ground before
         the carrier walks off to eat;
     - the round 5 re-reservation of an unreserved cargo on resume and the round 9 "unreserved
       but own `item_id`" set-down are gone: no job resumes with a tool in the hand any more;
     - re-plan semantics: a tool set down on a stockpile tile is stocked there (as any tool
       dropped on a stockpile), and if that stockpile rejects tools `HaulGiver` hauls it out
       again; a tool set down outside every zone stays where it is unless a stockpile takes it.
       So the round 5 test now accepts the pick stocked in A for a moment, as long as no idle
       colonist ever holds it and it ends stocked in B;
     - `haul_giver.gd`: only its doc comment changes (it cites `c769a48`);
     - new tick-driven table test `_check_haul_tool_failure_matrix` (seeds 64025 to 64048,
       24 cases): moment (job under way, pick still in A / pick carried) x interrupt (critical
       food need on the carrier / none) x fault (B rejects tools / B walled off / the target
       cell turned to rock) x reservation (kept / released by hand). Every tick it checks that
       no colonist holds the pick without an open job for it; each case checks one failure
       with an existing reason, then, once the fault is undone, that the pick ends stocked in
       B (only while B takes tools) or on the ground outside every stockpile, with the same
       id, no open `haul_tool` job and no stale reservation;
     - the round 9 test is rewritten for the new rule:
       `_check_destination_rejects_tools_after_an_interrupt_leaves_the_tool_outside` (seed
       64024); the round 8 test accepts either existing reason;
     - mutation check: with the set-down in `fail_haul_tool()` removed, the matrix fails (an
       idle colonist holds the pick); restored, `test_stockpile_filters` passes;
     - `world_state.gd` is still 767 lines, with `git diff --numstat origin/main --
       game/scripts/core/world_state.gd` giving `2 2`.
  14. Round 11, `2598977`
     (`git log -1 -- docs/orca/handoffs/F5a-b.md`). Owner notes: F5c (`47a3e58`) is on main and
     took schema v13; then L4 (`a5cb853`, no schema bump) landed too. The branch was rebased
     onto `origin/main` twice, first onto F5c and then onto `a5cb853`. The second rebase had no
     conflict. The bump is renumbered to **v14**:
     - the step is `SaveMigrations._v13_to_v14` (the `13:` arm). It changes only
       `schemaVersion` and refuses a v13 state that already lists a `haul_tool` job. F5c's
       `_v12_to_v13` (colonist `thoughts`) and F5b's `_v11_to_v12` are kept unchanged;
     - `StateCodec.SCHEMA_VERSION` is 14, the schema json const is 14, and `save-system.md` and
       ADR 064 describe v14;
     - F5c's `save_schema_v13_fixture.json` is untouched. The old F5a-b v13 fixture is replaced
       by the new `save_schema_v14_fixture.json` (hash 961387046, issued 6, tick 2063,
       thoughts 3). It is the same session as F5c's fixture, and F5c's v13 fixture migrates
       exactly to it. `test_save_migration.gd` checks that migration, that v14 re-encodes
       unchanged, and that a v13 state with a `haul_tool` job is refused;
     - the writer `docs/orca/handoffs/F5a-b-write-save.gd` now mirrors F5c's writer: it ticks
       until colonists have thoughts. Its loop is bounded by a tick count, never by
       `world.get_tick()`. Its first background run hung for more than an hour, for this
       reason: the class cache was stale after the rebase, so `needs_system.gd` failed to parse
       ("Identifier ActorThoughts not declared"), WorldState did not build, and the old
       `while world.get_tick() < …` never advanced. The Godot process had already exited by
       the time it was checked. The fix: refresh the cache (`--headless --path game --import`),
       bound the loop, and rerun in the foreground. The rerun took seconds and printed
       `F5a-b-write-save: issued=6 tick=2063 thoughts=3 hash=961387046 result=ok`;
     - the rebase conflicts with F5c were in the save and schema files. In each, F5c's v13
       work is kept and this branch's step is moved to v14. Against `origin/main`, the only
       fixture this branch adds is the v14 one;
     - the message of the rebased `e9ddcb8` (originally `1079d00`) and of later commits still says
       "schema v13", but their trees now carry v14. Messages were not rewritten;
     - `docs/orca/BACKLOG.md`: the F5a-b status line now says schema v14;
     - gates on the rebased HEAD: `world_state.gd` is 767 lines and numstat `2 2`;
       `check_core_budgets` OK; `measure_core` 23783 lines in 114 files (the growth is F5c's
       and L4's).
  15. Round 12, `0aaa792`. It answers review
     round 12 (`.orca-review.md`):
     - (blocking 1) a tool set down on the ground was never re-planned: `_haul_rejected_tools`
       only looked at stocked tools, so "the giver re-plans from the ground" (rounds 9 and 10)
       was not true for a tool on the ground outside every zone. Now a ground tool that lies in
       no tool-accepting stockpile is re-planned too, but only while some stockpile rejects its
       kind (an eviction is under way), and only into a free cell of a reachable tool-accepting
       stockpile, never onto more ground. A stocked tool whose tile lies in no zone is still
       skipped (F2). The check is memoised per `_haul_rejected_tools` pass (`_rejecting`, never
       persisted) and uses only the giver's existing `_get_zones` and `_accepts_item_at`
       callables: no new wiring, ids, reasons or saved fields. `haul_giver.gd` now 203 lines;
     - why the narrowing: a first version re-planned every ground tool, and the full suite then
       failed in four tests (`test_farming_content`, `test_haul_need_interrupt`,
       `test_movement_scheduling_load`, `test_tool_items_handover`). They start with ordinary
       tools on the ground, which were then hauled away from the colonists who needed them.
       There is no persisted marker for "set down by a failed `haul_tool` job" (job history is
       not saved), so the rule is bounded by the zone filters instead. With no stockpile
       rejecting a kind, ground tools of that kind are left alone, as before F5a-b;
     - new tick-driven check `_check_interrupt_outside_a_is_replanned_from_the_ground_into_b`
       (seed 64060): the carrier has left A and stands on a tile in neither A nor B; B is
       walled off, the job fails through the engine (`invalid_target` or
       `blocked_target_unreachable`) and the pick is set down on the ground there; B is
       reopened, and a second, new `haul_tool` job carries the same pick id from the ground
       into B. The interruption after leaving A is a destination fault, not a need: NeedGiver
       only interrupts at a toil boundary (`need_giver.gd`, `_evaluate` returns while the
       colonist has a route), and the carry from A to B is one walk, so a need can interrupt
       only at the pickup in A (covered by the matrix's "before" rows and seed 64024);
     - `_tool_rests_validly(world, true)` is tightened: while B takes tools the pick must end
       stocked in B (before, the ground outside A and B also passed). The failure matrix's
       "unreachable" and "walled" rows therefore now prove the re-plan from the ground into B;
     - (blocking 2) `needs_system.gd`: **approved by the owner** in `docs/orca/BACKLOG.md` on
       main, commit `a7cbb0e` ("Review round 10 (owner's interface, 2026-11-03): scope"). The
       same entry asks for the blocking 1 fix above ("a dropped tool outside a stockpile is a
       haul candidate again"). `a7cbb0e` touches only `BACKLOG.md` and is the only commit on
       `origin/main` past this branch's base `a5cb853`, so the branch was not rebased for it;
     - (non-blocking) `docs/architecture/save-system.md` now says `schemaVersion: 14`, as
       `state_codec.gd` does;
     - (non-blocking) the suite line is still author-reported (see below); the log path is
       given so it can be checked;
     - gates on the round 12 tree: `world_state.gd` is 767 lines and numstat `2 2` against
       `origin/main`; `check_core_budgets` OK; `measure_core` 23803 lines in 114 files.
  16. Round 13, `7bd0c42`. It answers review
     round 13 (`.orca-review.md`):
     - (blocking) `haul_giver.gd:131`: the round 12 ground re-plan ran only while some
       stockpile rejected the tool's kind. If A accepted tools again after the pick-up and the
       job then failed outside every stockpile, the set-down tool was never looked at again.
       Recovery is now kept on the tool itself, independent of the current filters: a ground
       tool carries a sparse `set_down` mark (`ToolItemStore`; saved as the optional
       `setDown: true` on its `toolItems` entry, inside the v14 bump). The round 12
       `_stockpile_rejects`/`_rejecting` narrowing is removed;
     - the mark is set by `ToolDropToil._set_down_held()` (every `haul_tool` failure, per
       `c769a48`) and by the ground branch of `place_hauled_tool()` (a tool hauled out onto the
       ground beside a rejecting stockpile, so it is stocked once some stockpile takes tools).
       `set_stockpile()` and `set_held()` clear it. Other ground drops (`drop_tool` and the
       fetch fallbacks) are unmarked, so ordinary ground tools are still left alone, as before
       F5a-b (the four tests that failed in round 12's first attempt stay green);
     - `HaulGiver` considers a ground tool only if it is marked, and plans it only into a free
       cell of a reachable tool-accepting stockpile, never onto more ground;
     - `tool_validator.gd`: a `toolItems` entry allows `setDown` (bool, only `true`) besides the
       required `id`, `kind` and `location`; `_require_fields` was replaced there because it
       treats the required list as the allowed list. `state_codec.gd` writes the key only when
       set and reads it back; the schema has `toolItem.setDown` (const true) and
       `save-system.md` its v14 note. A v13 save has no such key, so `_v13_to_v14` is unchanged
       and the v13 and v14 fixtures still match;
     - new tick-driven check `_check_set_down_tool_is_replanned_after_the_filters_change`
       (seed 64061): A rejects tools, a colonist carries the pick at least 6 tiles out of A, then
       A accepts tools again; B is walled off and the job fails through the engine
       (`invalid_target` or `blocked_target_unreachable`); the pick lies on the ground outside A
       and B, marked. The world goes through a save round trip in memory and then through the
       SaveIO file, and is ticked on until the same pick id is stocked in A, with no open
       `haul_tool` job, no mark and no reservation. Under the round 12 rule no stockpile rejects
       tools at that point, so the pick would be skipped; this was reasoned, not run;
     - (non-blocking) the suite line is still author-reported (see below), with the log path;
     - gates on the round 13 tree: `world_state.gd` is 767 lines and numstat `2 2` against
       `origin/main`; `check_core_budgets` OK; `measure_core` 23822 lines in 114 files;
       `haul_giver.gd` 195 lines, `tool_drop_toil.gd` 358, `tool_item_store.gd` 129,
       `state_codec.gd` 608, `tool_validator.gd` 124.
  17. Round 14, `f2fd02f`. It answers review
     round 14 (`.orca-review.md`):
     - (blocking) `order_handler.gd:73`: `cancel_job`, `fail_job` and `invalidate_job` on an
       active `haul_tool` ended the job and released its reservation but left the pick in the
       carrier's hand, and HaulGiver skips held tools. These commands now go through the shared
       set-down cleanup. `ToolDropToil.set_down_for_ended_job()` is the set-down half of
       `fail_haul_tool()`, which now calls it: the job's tool is set down where the carrier
       stands (marked `set_down`), the job's reservations are released and the execution state
       is cleared. `ToilExecutor.set_down_hauled_tool()` forwards to it.
       `ToilBindings.drop_carried_haul_item()` calls it for a `haul_tool` job before the usual
       cargo drop. `order_handler.gd` and `trench_system.gd` (a trapped carrier) each add
       `"haul_tool"` to the list of kinds whose cargo is dropped at that boundary. All of this
       runs before `_finish_job()`, while the reservation still exists. There is no new id,
       reason or field;
     - new check `_check_job_commands_set_an_active_haul_tool_down`. It uses seeds 64062,
       64063 and 64064, one per command, and runs through commands and ticks. A carries the
       pick at least 6 tiles out of A for a `haul_tool` job, and then the command runs through
       the real command path. The check asserts that the job is ended, the carrier is no longer
       assigned it, and the pick lies on the ground outside A and B, marked, with no
       reservation. It then ticks on. Every tick, the pick is never held by an idle colonist,
       and the same pick id ends stocked in B, unmarked, with no `haul_tool` job open. With the
       three routing edits reverted, `test_stockpile_filters` fails; with them restored, it
       passes;
     - not covered in round 14: `complete_job` on an active `haul_tool`. Round 15 (item 18)
       covers it;
     - (non-blocking) the suite line is still author-reported (see below), with the log path;
     - gates on the round 14 tree: `world_state.gd` is 767 lines and numstat `2 2` against
       `origin/main`; `check_core_budgets` OK; `measure_core` 23836 lines in 114 files;
       `tool_drop_toil.gd` 365 lines, `toil_bindings.gd` 512, `toil_executor.gd` 657.
  18. Round 15, the commit that changes this file to the present text. It answers review
     round 15 (`.orca-review.md`):
     - (blocking) `order_handler.gd:71`: `complete_job` on an active `haul_tool` that has not
       delivered released the reservation but left the pick in the carrier's hand. It now goes
       through the same shared set-down cleanup as `cancel_job`, `fail_job` and
       `invalidate_job` (`ToilBindings.drop_carried_haul_item()` and then
       `ToolDropToil.set_down_for_ended_job()`), before `_finish_job()`. Only `haul_tool` is
       routed for `complete_job`. `haul`, `site_fetch` and `craft_fetch` keep their earlier
       `complete_job` behaviour, so what `complete_job` means for the other carried kinds does
       not change. It is still one condition in `order_handler.gd` (now 109 lines). There is
       no new id, reason or field;
     - command-driven coverage: `_check_job_commands_set_an_active_haul_tool_down` now also
       runs `complete_job`, with seed 64065, through the real command path, and makes the same
       assertions as for the other three commands (job ended, pick set down marked outside A
       and B with no reservation, then re-planned and stocked in B, never held by an idle
       colonist). With `complete_job` taken out of the condition, `test_stockpile_filters`
       fails on `complete_job: the carrier must set the pick down, marked, outside A and B`
       (the pick is `held`); restored, it passes. The `_set_rock` doc comment, which round 14
       had left above the new check, is back above `_set_rock`;
     - (blocking, scope) `order_handler.gd` and `trench_system.gd` lie outside the owned paths.
       The author cannot grant the scope amendment, so it is recorded below as pending owner
       approval (round 15), and the reviewer's condition is that it is recorded before merge;
     - (non-blocking) stale sizes in "Validation": now `state_codec.gd` 608 and
       `toil_bindings.gd` 512;
     - (non-blocking) the suite line is still author-reported (see below), with the log path;
     - gates on the round 15 tree: `world_state.gd` is 767 lines and numstat `2 2` against
       `origin/main`; `check_core_budgets` OK; `measure_core` 23837 lines in 114 files;
       `git diff --check` clean.
- Pending owner approval (round 15, blocks merge per the reviewer, does not block this handoff):
  the scope amendment for `game/scripts/core/commands/handlers/order_handler.gd` (the job
  command condition at lines 70-75, which since round 15 also routes `complete_job` on a
  `haul_tool` job) and `game/scripts/core/actors/trench_system.gd:227`. Both are outside the
  owned paths. The reviewer asks for the owner's amendment to be obtained and recorded before
  merge.
- Pending owner approval (round 14, does not block): two one-line edits outside the owned
  paths, needed for the reviewer's round 14 fix. In `game/scripts/core/commands/handlers/order_handler.gd:73`
  and `game/scripts/core/actors/trench_system.gd:227`, `"haul_tool"` is added to the list of
  carried kinds whose cargo is dropped when the job ends. The round 14 additions to
  `toil_bindings.gd` (the `haul_tool` branch in `drop_carried_haul_item()`) and
  `toil_executor.gd` (the `set_down_hauled_tool()` forwarder) also go beyond the round 2
  approval.
- Pending owner approval (round 13, does not block): the persisted optional `setDown` field on
  `toolItems` entries (the schema, `state_codec.gd`, `tool_validator.gd`, `save-system.md`). It
  is what the reviewer's round 13 fix needs ("preserve recovery eligibility independently of
  current filters"), and round 12 named it as the alternative. It stays inside the v14 bump: no
  new version, id or reason. It replaces the round 12 question, which is withdrawn.
- Owner decision followed (round 12, `a7cbb0e`): `needs_system.gd` is F5a-b scope; a tool
  dropped outside a stockpile is a haul candidate again, with its test; `save-system.md` says
  schema 14; full suite, commit.
- Owner decision followed (round 11): rebase onto `origin/main` after F5c and renumber the bump
  to v14, keeping F5c's v13 (migration `_v13_to_v14` plus a v14 fixture); then rebase again
  after L4.
- Owner decision followed (round 10, `c769a48`): one uniform failure rule for `haul_tool`, with
  a tick-driven table test.
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

## Final suite line (author-reported, round 15)

```
run_tests: all 139 test(s) PASS  [1.028s]
```

Quoted verbatim. As in earlier rounds, the runner prints seconds with `.` as the thousands
separator in this locale. The tree is round 15 (the code changes in item 18). On Windows, with
Godot 4.7.2 headless, the author ran
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -SkipImport > full15.log 2>&1`.
`-SkipImport` is safe here because round 15 adds no `class_name`. The log is at
`C:\dev\tmp\claude\C--Users-Anto-ito-orca-workspaces-deepholm-f5a-b-haul-rejected-tools-out\a0b97d0f-55b9-400d-95db-2c04893aa622\scratchpad\full15.log`.
It is local to the author's machine and not committed. Its FAIL and push_error lines come from
the suite's expected-failure checks. The reviewer has independently verified the other checks
but has not reproduced the full suite.

### Round 14 (history)

```
run_tests: all 139 test(s) PASS  [1.074s]
```

Quoted verbatim. As in earlier rounds, the runner prints seconds with `.` as the thousands
separator in this locale. The tree is round 14 (the code changes in item 17). On Windows, with
Godot 4.7.2 headless, the author ran
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -SkipImport > full14.log 2>&1`.
`-SkipImport` is safe here because round 14 adds no `class_name`. The log is at
`C:\dev\tmp\claude\C--Users-Anto-ito-orca-workspaces-deepholm-f5a-b-haul-rejected-tools-out\a0b97d0f-55b9-400d-95db-2c04893aa622\scratchpad\full14.log`.
It is local to the author's machine and not committed. Its FAIL and push_error lines come from
the suite's expected-failure checks. The reviewer has not reproduced the full suite.

### Round 13 (history)

```
run_tests: all 139 test(s) PASS  [1.037s]
```

Quoted verbatim. As in earlier rounds, the runner prints seconds with `.` as the thousands
separator in this locale. The tree is round 13 (the code changes in item 16). On Windows, with
Godot 4.7.2 headless, the author ran
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -SkipImport > full13.log 2>&1`.
`-SkipImport` is safe here: round 13 adds no `class_name`, and the class cache was refreshed in
round 12. The log is at
`C:\dev\tmp\claude\C--Users-Anto-ito-orca-workspaces-deepholm-f5a-b-haul-rejected-tools-out\a0b97d0f-55b9-400d-95db-2c04893aa622\scratchpad\full13.log`.
It is local to the author's machine and not committed. Its FAIL and push_error lines come from
the suite's expected-failure checks. The reviewer has not reproduced the full suite.

### Round 12 (history)

```
run_tests: all 139 test(s) PASS  [1.071s]
```

Quoted verbatim. `1.071s` is how the runner prints about 1071 seconds in this locale, where `.`
is the thousands separator. The tree is round 12: the round 11 tree plus the ground re-plan in
`haul_giver.gd`, the new and tightened checks in `test_stockpile_filters.gd`, and the schema line
in `save-system.md`. Before this run the author refreshed the class cache with `--import`. Then
on Windows, with Godot 4.7.2 headless, the author ran
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 -SkipImport > full12b.log 2>&1`.
The log is at
`C:\dev\tmp\claude\C--Users-Anto-ito-orca-workspaces-deepholm-f5a-b-haul-rejected-tools-out\a0b97d0f-55b9-400d-95db-2c04893aa622\scratchpad\full12b.log`.
It is local to the author's machine and not committed. Its FAIL and push_error lines come from
the suite's expected-failure checks. The reviewer has not reproduced the full suite. Earlier
rounds are kept below as history.

### Round 11 (history)

```
run_tests: all 139 test(s) PASS  [1.013s]
```

Quoted verbatim. `1.013s` is how the runner prints about 1013 seconds in this locale, where `.`
is the thousands separator. The tree is round 11: this branch rebased onto `origin/main`
`a5cb853` (F5c v13 and L4), with schema v14, `_v13_to_v14` and the v14 fixture. The suite now
has 139 tests rather than 137 because the two rebases brought in other branches' tests. The
author ran it on Windows with Godot 4.7.2 headless, after `--import` refreshed the class cache,
with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 > suite.log 2>&1`.
The log is at
`C:\dev\tmp\claude\C--Users-Anto-ito-orca-workspaces-deepholm-f5a-b-haul-rejected-tools-out\a0b97d0f-55b9-400d-95db-2c04893aa622\scratchpad\suite.log`.
It is local to the author's machine and not committed. Its FAIL and push_error lines come from
the suite's expected-failure checks. The reviewer has not reproduced the full suite. Earlier
rounds are kept below as history.

### Round 10 (history)

```
run_tests: all 137 test(s) PASS  [998s]
```

Round 10 tree (owner rule `c769a48`). The run started just before a whitespace-only fix in
`tool_drop_toil.gd` (one mangled line continuation joined); no behaviour changed. Round 9 gave
137 PASS [898s].

The line is quoted verbatim. The author ran this on the round 9 tree (this branch on
`origin/main` `f55e9b0`, with schema v13, the two-line `world_state.gd` wiring, the round 8
`toil_on_unreachable` arm and the round 9 `fail_for_invalid_target()` change), on Windows with
Godot 4.7.2 headless, with
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1 > suite_r9.log 2>&1`.
The full log is at
`C:\dev\tmp\claude\C--Users-Anto-ito-orca-workspaces-deepholm-f5a-b-haul-rejected-tools-out\a0b97d0f-55b9-400d-95db-2c04893aa622\scratchpad\suite_r9.log`
(local to the author's machine, not committed). Its push_error stack lines come from the
suite's expected-failure checks. It is still author-reported: the reviewer has reproduced
`test_architecture_rules` alone, not the full suite. The branch is not rebased onto the
current `origin/main` (`15211a7`); its base is still `f55e9b0`.
The round 8 tree gave `run_tests: all 137 test(s) PASS  [993s]`, logged in `suite_r8.log`.
The round 7 tree gave `run_tests: all 137 test(s) PASS  [916s]`, logged in `suite_r7.log`.
The round 6 tree gave `run_tests: all 137 test(s) PASS  [1.022s]` (1022 seconds; the
Windows locale prints a thousands separator), logged in `suite_r6.log`.
The round 5 tree after the L3 rebase gave `run_tests: all 137 test(s) PASS  [985s]`.
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

  Since round 13 it also looks at each tool on the ground (location type `ground`) that is not
  reserved and carries the `set_down` mark: a tool a failed `haul_tool` job set down, or one
  this giver hauled out onto the ground beside its stockpile. The mark is saved (`setDown`)
  and does not depend on the current filters, so a tool set down after A accepts tools again
  is still recovered. Unmarked ground tools are left alone. Such a tool only gets step 1 below (a free cell of a reachable tool-accepting
  stockpile); it is never moved from one ground tile to another.

  For every other tool, it picks a target:
  1. the first free cell of the tool-accepting stockpiles, in `stockpiles_for_item()` order
     (the same order `find_free_haul_cell()` uses). A free cell is free, passable and
     unoccupied, has no tool lying on it (`ToolItemStore.lies_at`), and is not the target of a
     queued or active `haul_tool` job;
  2. else the nearest such tile that shares an edge with its stockpile and lies outside every
     zone (ties by y, then x);
  3. else no target, and the tool is tried again next tick.

  A candidate cell (in steps 1 and 2) whose region the tool's tile does not share
  (`region_reachable`, round 6) is skipped and the search goes on (round 7), so a reachable
  later stockpile or ground tile wins over an unreachable preferred one. With no reachable
  candidate the tool gets no job and is tried again next tick.

  It then submits a `haul_tool` job at the target through the shared queue (`submit_job`),
  names the tool on it (`item_id`, round 5) and reserves the tool for that job
  (`ToolItemStore.reserve`). A tool that a queued or active `haul_tool` job already names is
  skipped too (round 5).
- A colonist with the haul labour takes the job from the scheduler like any other job.
  - **`fetch_tool`** (`ToolFetchToil`): for a kind with no `needs_tool` that lists
    `fetch_tool`, the toil carries the tool its giver named (`item_id`) and reserved. It walks
    to the tool and picks it up, with no search. It is done once that tool is in the hand under
    this job's reservation, or when the job names no tool (`_carry_done()`). A route failure
    while fetching goes to `fail_carry`, wired to `ToolDropToil.fail_haul_tool()` (round 10).
  - `reserve`, `go_to` and `work` (1 tick): the colonist walks to the target.
  - **en-route recheck** (round 2): `ToolExecutor.advance()` calls
    `ToolDropToil.haul_cannot_continue()` on every tick for a kind with `fetch_tool` and no
    `needs_tool`. The target is lost when it is no longer free for a tool (see below), or when
    it lies in a stockpile that rejects tools now. All stockpiles come from
    `ZoneTable.get_stockpile_zones()`, wired as one argument appended to an existing
    `world_state.gd` line. The job is also lost when its `item_id` tool is gone or reserved by
    another job (round 5). A lost target goes to the single failure branch
    `fail_haul_tool(..., "invalid_target")` (round 10, owner rule `c769a48`):
    - the held tool, if it is this job's `item_id` or reserved by this job, is set down at the
      colonist's tile
      (`_set_down_held()`). It is stocked when that tile is in any stockpile, so `HaulGiver`
      hauls it out again if that stockpile rejects tools, and it goes on the ground otherwise.
      A tool is never left loose inside a stockpile;
    - every tool reservation of the job is released, and route, work and work progress are
      cleared;
    - `on_toil_fail` fails the job with the caller's existing reason (remedy from the shared
      engine), as other toil failures do. The giver re-plans from the ground on a later tick.
  - **work completion** (`ToolDropToil.place_hauled_tool()`): the held tool is set down and
    its reservation is released. The target is checked again at this moment (round 2), since
    zones and filters can change while the tool is carried:
    - the target is "free for a tool" when it is passable and no other ground or stocked tool
      lies there. The cell's reservation is not checked (it is this job's own), and neither is
      a stack (one hauled there since may share it, as before);
    - free and in a stockpile that accepts tools now: stocked there;
    - free and in no stockpile at all: on the ground there (marked `set_down`, so it is
      stocked once some stockpile accepts tools);
    - otherwise (taken, or in a stockpile that rejects tools): `_set_down_held()` at the
      colonist's tile, as above. The en-route recheck normally fails the job first; this case
      covers a change on the completing tick.

    If the held tool is not this job's, nothing happens.
  - `release_all` then completes the job.
  - **unreachable destination** (rounds 8 and 10): when the route fails, while fetching or
    carrying, `toil_on_unreachable` (and `fail_carry` in `ToolFetchToil`) sends a `haul_tool`
    job to `fail_haul_tool(..., "blocked_target_unreachable")` instead of cancelling and
    resubmitting it, so the tool is set down and the job fails once.
  - **need interrupt** (round 10, replaces the round 5/9 suspend and resume): `NeedsSystem`
    does not suspend a `haul_tool` job. It calls `abandon_haul_tool`, which goes to
    `fail_haul_tool(..., "need_interrupt")`: the tool is set down where the carrier stands and
    the job fails, so no tool waits in a hand. It never sets down a tool another job reserved.
- `toil_bindings.gd` adds a `haul_tool` arm to the work-completion match and (round 8) a
  `haul_tool` arm to `toil_on_unreachable`. `toil_executor.gd` adds the one-line forwarders
  `place_hauled_tool()` and (round 8) `fail_hauled_tool()`, the 2-line en-route recheck and an
  optional `get_all_stockpiles` constructor parameter (round 2).
- **`world_state.gd` hook (declared):** exactly two existing lines are edited against
  `origin/main` (`git diff origin/main -- game/scripts/core/world_state.gd`), and none is added:
  767 lines before and after.
  - The `ToilExecutor` constructor's last line gains `_zone_table.get_stockpile_zones`
    (round 2).
  - The `HaulGiver` constructor's second line gains four optional trailing arguments:
    `_tool_store`, `_zone_table.get_zones`,
    `_scheduler.queue.view_jobs_of_kinds.bind(["haul_tool"])` (`get_tool_jobs`, round 4) and
    `_passability.region_reachable` (`region_reachable`, round 6). The
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
    - Round 6, seed 64021: A is walled off with rock (the ring around it) while a `haul_tool`
      job is on its way to the pick. The job ends `failed` with reason
      `blocked_target_unreachable` within 200 ticks. For a day after that the pick stays
      stocked in A, unreserved, no new `haul_tool` job is created and none is queued or
      active. Once the wall is removed, a colonist carries the pick to B within a day.
    - Round 7, seed 64022: a third stockpile C (every group, priority 3, beside A) outranks B
      but is walled off. After A switches to materials only, a colonist carries the pick to B
      within a day, a `haul_tool` job completes, no `haul_tool` job ever targets C, and C stays
      empty.
    - Round 8, seed 64023: B is walled off with rock while the pick is held by an active
      `haul_tool` job. Within 200 ticks the job ends `failed` with reason `invalid_target`, and
      on no tick is an open `haul_tool` job left with an empty `item_id`. For a day after that
      the pick never reaches B. It ends on the ground or in a stockpile (not held), with the
      same single id, reserved by no one or by an open job only.
    - Round 9, seed 64024: while an active `haul_tool` job carries the pick, the carrier's food
      drops to 5, so a need interrupt sends the job back to `queued`, with the pick held and
      unreserved. B then switches to materials only. The job ends `failed` with reason
      `invalid_target`, the pick is no longer held, and it ends on the ground outside A and B
      with the same id. If the carrier stands inside B when the job fails, the pick is first
      stocked there and the giver hauls it out (by design).
    - Determinism and replay are checked by the seed 64018 case (with and without B) and the
      seed 64019 case: two worlds built from the same seed have equal `state_hash()` on every
      tick, and the recorded session replays ok. The seed 64016, 64017, 64020, 64021, 64022,
      64023 and 64024 cases run one world and do not check this.
  - `test_architecture_rules.gd`: `haul_tool` is added to the expected job kinds, and a
    `_run_and_verify("haul_tool", 207301, …)` scenario runs it end to end, like the other
    kinds.
  - `test_toils_dig_chop_regression.gd`: its pinned job kind list gains `haul_tool` (22 to 23
    kinds).
- ADR 064's Consequences bullet now describes the carried haul.
- `en.json`: `status.job.haul_tool` is "Hauling a tool" (every job kind has a status text).
- Schema v14 (round 2; renumbered to v13 in round 3 and to v14 in round 11):
  `StateCodec.SCHEMA_VERSION` is 14, and `SaveMigrations._v13_to_v14` changes only
  `schemaVersion` (a v13 world queued no `haul_tool` job; a v13 state that lists one is
  refused). `game-state.schema.json` gets const 14 and the `"haul_tool"` job kind.
  `save-system.md` documents v14. The new `save_schema_v14_fixture.json` was written by
  `docs/orca/handoffs/F5a-b-write-save.gd`. `test_save_migration.gd` checks that F5c's v13
  fixture migrates exactly to it, that v14 loads and re-encodes unchanged, and that a v13 state
  with a `haul_tool` job is refused.

## Pending owner approval (outside the owned paths)

Approved by the owner in round 2 (`docs/orca/BACKLOG.md` on main, commit `afeeade`):
- `game/content/jobs.json`: the `haul_tool` kind;
- `game/scripts/core/jobs/toil_executor.gd`: the forwarder, the 2-line en-route recheck and the
  constructor parameter (654/800; round 8 adds a second one-line forwarder,
  `fail_hauled_tool()`, and round 10 points it, the recheck and `ToolFetchToil.fail_carry` at
  `fail_haul_tool()`; the owner has not seen these yet);
- `game/scripts/core/jobs/toil_bindings.gd`: the work-completion arm (507/800; round 8 adds the
  `toil_on_unreachable` arm and round 10 the `abandon_haul_tool` wiring for need interrupts;
  the owner has not seen these yet);
- the `"haul_tool"` value of the schema's job kind enum;
- `game/data/text/en.json`: one status text.

The owned paths are `haul_giver.gd`, `tool_item_store.gd`, `tool_*_toil.gd`,
`test_stockpile_filters.gd` and this file. These changes are outside them and that approval,
and are still pending:

1. Schema v14 (round 2, needed by review finding (c); v14 since round 11, after F5c took v13):
   - `docs/architecture/contracts/game-state.schema.json`: const 14 (the enum value is
     approved);
   - `game/scripts/core/persistence/state_codec.gd`: `SCHEMA_VERSION` 14 (603/800);
   - `game/scripts/core/persistence/save_migrations.gd`: the `13:` arm and `_v13_to_v14`;
   - `docs/architecture/save-system.md`: the v14 notes;
   - `game/scripts/tests/test_save_migration.gd`: the v13-to-v14 and v14 checks;
   - new `game/scripts/tests/fixtures/save_schema_v14_fixture.json` and its writer
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
5. `game/scripts/core/actors/needs_system.gd` (round 10; 532/800 after F5c's growth): a need or rescue interrupt
   of a `haul_tool` job calls the new optional `abandon_haul_tool` callable (fail and set the
   tool down, per `c769a48`) instead of suspending the job. Other kinds are unchanged.
   **Approved since round 12**: the owner approved it in `docs/orca/BACKLOG.md` on main,
   commit `a7cbb0e`. It is listed here only so the scope stays traceable.
6. `game/scripts/core/commands/handlers/order_handler.gd:73` and
   `game/scripts/core/actors/trench_system.gd:227` (round 14): `"haul_tool"` is added to the
   kinds whose carried cargo is dropped when a command or a trap ends the job. Through
   `ToilBindings.drop_carried_haul_item()`, a `haul_tool` carrier sets its tool down
   (`ToolDropToil.set_down_for_ended_job()`) instead of keeping it in hand. This is one edited
   line in each file. Round 15: in `order_handler.gd`, the same condition (lines 70-75) also
   routes `complete_job` on a `haul_tool` job through that set-down, so the file has one more
   line (109). The reviewer requires the owner's scope amendment for both files before merge.

## Contract impact

- Save format: schema v14. The job `kind` enum gains `haul_tool`. `_v13_to_v14` changes only
  `schemaVersion`. A saved `haul_tool` job is an ordinary job record, and a tool's reservation
  is already saved in `ToolItemStore.reservations`. Since round 13 a `toolItems` entry may also
  carry `setDown: true` (a ground tool HaulGiver must stock; absent otherwise), inside v14.
- Ids: none are created. The tool keeps its id (ADR 061). The job takes a normal job id from
  the queue.
- Jobs and content: one new job kind, `haul_tool`. No new toil, command or labour.
- `state_hash()`: its inputs did not change. A world with a stocked tool in a stockpile that
  rejects tools now evolves differently: a job is queued and a colonist carries the tool.
- API:
  - `ToolDropToil.place_hauled_tool()` and `ToolExecutor.place_hauled_tool()` are new. The
    first one revalidates its target at delivery.
  - `ToolDropToil.haul_target_lost()` (round 2; `haul_cannot_continue()` since round 10) is new.
    `ToolDropToil._init` and `ToolExecutor._init` each gain an optional trailing
    `get_all_stockpiles` parameter.
  - A failed `haul_tool` job can carry reason `invalid_target`. That reason already exists,
    with its own text.
  - `ToolItemStore.lies_at()` is new; `set_ground()` takes an optional `set_down` flag
    (round 13), cleared by `set_stockpile()` and `set_held()`.
  - A failed `haul_tool` job can also carry the existing reason `blocked_target_unreachable`
    (round 6), when its cargo or (round 10) its destination cannot be reached, and the existing
    reason `need_interrupt` (round 10).
  - `ToolDropToil.fail_haul_tool()` (round 10) is the single failure branch; it replaces
    `fail_for_invalid_target()`. `NeedsSystem` gains an optional `abandon_haul_tool` callable
    and `ToolFetchToil` a `fail_carry` callable, both wired in `toil_bindings.gd` /
    `toil_executor.gd`.
  - `HaulGiver._init` has four optional trailing parameters: `tool_store` and `get_zones`
    (from `18bc3bd`), `get_tool_jobs` (round 4) and `region_reachable` (round 6). Its `get_jobs` view lists `haul` jobs only,
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

- Filtered run (round 15): `test_stockpile_filters` PASS [32s], with `complete_job` added to the
  command check. With `complete_job` taken out of the `order_handler.gd` condition, it fails;
  restored, it passes.
- Filtered run (round 14): `test_stockpile_filters` PASS [37s], with the new command check.
  With the round 14 edits to `toil_bindings.gd`, `order_handler.gd` and `trench_system.gd`
  reverted, it fails; restored, it passes.
- Filtered runs (round 13), all PASS: `test_stockpile_filters` [32s], `test_save_migration`
  [7s], `test_tool_items_save` [5s], `test_tool_items_handover` [7s], `test_haul_need_interrupt`
  [2s], `test_farming_content` [3s] and `test_movement_scheduling_load` [4s].
- Filtered run (round 10): `test_stockpile_filters` PASS [27s], with the 24-case matrix. With
  the set-down call in `ToolDropToil.fail_haul_tool()` removed, the matrix fails (an idle
  colonist holds the pick); restored, it passes. Also PASS on the round 10 tree:
  `test_haul_need_interrupt`, `test_haul_stockpile`, `test_need_jobs`, `test_needs`, the five
  `test_tool_items*` files and `test_tool_handover_scenarios`.
- Filtered run (round 9): `test_stockpile_filters` PASS [21s]. With the round 9 change to
  `fail_for_invalid_target()` reverted, the seed 64024 check fails ("the failed job must set
  the pick down: held colonist_0").
- Filtered run (round 8): `test_stockpile_filters` PASS [23s]. With the new
  `toil_on_unreachable` arm disabled, the seed 64023 check fails (the job ends `cancelled`,
  the pick stays held).
- Filtered run (round 7): `test_stockpile_filters` PASS [24s]. With the round 6
  `haul_giver.gd` swapped in, it fails at `test_stockpile_filters.gd:791`.
- Filtered run (round 6): `test_stockpile_filters` PASS [21s]. With the round 5
  `tool_fetch_toil.gd` swapped in, it fails at `test_stockpile_filters.gd:761`.
- Filtered runs (round 5), all PASS: `test_stockpile_filters` [18s], `test_haul_need_interrupt`
  [2s], `test_architecture_rules` [3s], `test_build_tool_footprint` [1s],
  `test_toils_dig_chop_regression` [2s], `test_tool_handover_scenarios` [18s], `test_tool_items`
  [4s], `test_tool_items_fetch` [6s], `test_tool_items_handover` [2s] and
  `test_tool_items_reservations` [5s].
- Filtered runs (round 4), both PASS: `test_stockpile_filters` [22s] and
  `test_architecture_rules` [3s].
- Filtered runs (round 11): `test_save_migration` PASS after the v14 renumbering, on the F5c
  rebase (before the L4 rebase; the full suite below covers the final HEAD).
- Filtered runs (round 3): `test_save_migration` [7s] PASS after the v13 renumbering.
- Filtered runs (round 2), all PASS: `test_stockpile_filters` [23s], `test_save_migration`
  [6s], `test_architecture_rules` [3s], `test_crafting` [9s] and
  `test_toils_dig_chop_regression` [1s]. `test_crafting` prints push_error stack lines from its
  expected-failure checks, and still passes.
- Gate: `check_core_budgets: OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file cap(s), 1 file and 3 function exception(s))`.
  No budget or exception was raised.
- `tools/measure_core.ps1`: `core total: 23837 lines in 114 files` (round 15; 23836 in round 14;
  23822 in round 13;
  23803 in round 12;
  23783 in round 11, after the F5c
  and L4 rebases; the table below is round 10's, except that `needs_system.gd` is now 532,
  `toil_bindings.gd` 512 and `state_codec.gd` 608). Earlier: 23456 lines in 113 files (round 10; 23459 in round 9; 23456 in round 8; 23448 in round 7; 23443 in round 6; 23423 in round 5 after the L3 rebase;
  23144 in 112 files before it, 23108 in round 4, 23105 in round 3; the growth is L3's).

  | File | Lines | Longest function |
  |---|---|---|
  | `world_state.gd` | 767 (593 code, 114 comment) | `state_hash`, 30 |
  | `toil_executor.gd` | 654 (480 code, 126 comment) | `_start_current_toil`, 50 |
  | `toil_bindings.gd` | 507 (381 code, 89 comment) | `_init`, 51 |
  | `needs_system.gd` | 460 (360 code, 69 comment) | `ensure_needs`, 45 |
  | `tool_drop_toil.gd` | 356 (258 code, 72 comment) | `_init`, 30 |
  | `tool_fetch_toil.gd` | 279 | — |
  | `haul_giver.gd` | 183 | — |
  | `state_codec.gd` | 597 (436 code, 106 comment) | `decode`, 70 |

## Known limitations

- If the tool cannot be reached, the job fails once with `blocked_target_unreachable` (round
  6) and the reservation is released. The giver does not offer that tool again until its tile
  shares a region with some free candidate cell (round 7: each candidate is checked, not just
  the first); reachability is judged by region, so a tool reachable by region but not by route
  would fail once per offer.
- A reserved tool (one a colonist is fetching for other work) is skipped until it is free.
- With no free destination and no free adjacent tile, the tool stays put, and the giver searches
  again every tick. That costs a few cell checks per rejected tool per tick.
- The ground fallback must share an edge with the tool's own stockpile, on the same layer. The
  tool is not taken further away.
- The job has no hauling priority of its own (non-goal). It uses `haul`'s priority, 1.
- Whenever the job cannot continue (round 10, `c769a48`: target lost or unreachable, cargo
  unreachable or lost, need or rescue interrupt), the tool is set down at the carrier's tile
  with no check that the cell is free. If a stocked tool already lies there, the two share the
  cell until the giver hauls one out.
- A tool set down inside a stockpile that rejects tools (for example A, when the interrupt
  comes right after the pick-up) is stocked there for a moment and hauled out again by a new
  job. That costs one more job, not a loop: each new job fails only on a new fault.
- Only a marked ground tool (`set_down`) is re-planned. A tool dropped on the ground by other
  work (`drop_tool`, the fetch fallbacks) stays where it is, as before F5a-b.
- An interrupted `haul_tool` job is failed, not resumed (round 10), so its progress is lost and
  a new job is queued from where the tool lies.
- A stack hauled onto the target while the tool is carried may share the cell with the stocked
  tool, as it could before F5a-b.

## Next action

- The owner approves or rejects the files still listed under "Pending owner approval": the
  schema v14 files beyond the enum, the test pins, the `world_state.gd` line edits, the
  `needs_system.gd` wiring, the round 8 and round 10 additions to `toil_executor.gd` and
  `toil_bindings.gd`, the round 13 `setDown` field (schema, codec, validator, save-system), and
  the round 14 one-line edits to `order_handler.gd` and `trench_system.gd` plus the round 14
  additions to `toil_bindings.gd` and `toil_executor.gd`.
- Before merge, the owner records the scope amendment for `order_handler.gd` (including the
  round 15 `complete_job` routing) and `trench_system.gd`, as the reviewer requires (item 18).
- The reviewer reproduces the full suite line.
- Then review with `tools/orca/review.ps1`, which now resolves `F5a-b` to this file.
