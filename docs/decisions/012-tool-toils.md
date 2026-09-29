# ADR 012: Tool toils -- fetch_tool and drop_tool

- **Status:** accepted (fetch_tool implemented in the original change; drop_tool, the foreign-reservation handover, and the destroyed-mid-job failure path are implemented by issue #266 -- see "drop_tool: the handover wait, resolved" and "Destroyed-mid-job failure path" below). Round 5 review found `blocked_no_tool`'s recovery bypassed the shared scheduler (labour eligibility, aging/scoring), its continuation state was unpersisted, `_restore_reroutes()` reconstructed the wrong passability exception for an in-flight fetch_tool leg, and a colonist could spend more than one per-tick routing allowance across scheduler activation and fetch/return travel -- all four are resolved in this change; see "blocked_no_tool integrates with the shared scheduler", "Persistence", and "Shared per-colonist routing allowance" below. Round 6 review found three further gaps, now also resolved: the excluded-candidate set was still unpersisted (save_io.gd was, at that point, genuinely out of this task's owned paths; it has since been added and the gap closed -- see "Persistence"), `JobQueue.tick()`'s reachability check ran before the tool-backoff check and could overwrite `blocked_no_tool`'s reason mid-backoff (see "blocked_no_tool integrates with the shared scheduler"), and `_toil_on_no_tool_found()` reused `suspend_assignment()` verbatim, permanently pinning an ordinary order to the colonist whose fetch happened to fail first (see "Ordinary fetch failure vs. critical-need interrupt"). Issue #266 round 1 (drop_tool/handover) shipped with six gaps a round 2 review found: the requester never actually waited (fetch_tool stole the tool out of the holder's hand at arrival), the leg's "am I dropping" state lived in an unpersisted `route["drop_tool"]` flag `state_codec.gd` silently dropped on restore, the drop destination was recomputed every tick instead of fixed for the leg, tool destruction was only detected once a job already held its tool (not while fetch_tool was still travelling toward it), a destroyed tool's failure released only that one reservation instead of every reservation the job held, and `test_movement_scheduling_load.gd`'s own idle-streak bound was loosened from 3 to 4 to paper over a regression instead of fixing it. All six are resolved in this round -- see "drop_tool: the handover wait, resolved" and "Destroyed-mid-job failure path" below, both now driven by a new extracted collaborator, `tool_drop_toil.gd`, mirroring how `tool_fetch_toil.gd` already keeps `toil_executor.gd` under its line budget. A round 2 review of THAT round found five further gaps, all resolved in this same round: the handover's own busy-holder gate only ever ran before a candidate was reserved, so a candidate reserved from an already-adjacent busy holder could still be picked up the same tick, and a route toward an idle holder's tool was never re-targeted once that holder later moved it via its own drop_tool leg (see "The requester side, actually implemented" and "Destination consistency" below); `is_dropping()`'s exact-equality comparison against the job's own (often impassable, therefore trimmed) ordinary target misclassified an ordinary or fetch_tool leg as a drop the instant a foreign reservation appeared mid-flight, and stopped recognizing a genuine drop leg the instant that reservation disappeared again (a cancelled requester); `active_tool_missing()` checked only the first reservation a Dictionary snapshot happened to yield and `fail_for_destroyed_tool()` cleared `colonist.held_tool` unconditionally, either of which could miss a destroyed non-primary reservation or desync a surviving held tool's own record; `_restore_reroutes()` picked the ordinary-job-target passability branch for a restored drop leg, which this ADR incorrectly called harmless (see "Persistence" below); and neither `_find_drop_cell()` nor arrival accounted for an existing ground/stockpiled tool occupying the chosen cell or the destination zone disappearing mid-travel. See "drop_tool: the handover wait, resolved", "Persistence" and "Destroyed-mid-job failure path" below for each fix. A round 3 review of THAT round found three further gaps, all resolved in this same round: `ToilExecutor.advance()` ran `is_dropping()` before `active_tool_missing()`, so destroying an in-flight fetch_tool target (which makes `ToolFetchToil.current_target()` report null) could be misread as "not the fetch leg, must be a drop" for up to a whole extra leg before the destroyed-tool check, buried inside the old `if TOIL_FETCH_TOOL in toils:` block, ever ran; `is_dropping()`'s exact-position comparison against `current_target()` also broke for a fetch destination trimmed short by an impassable tool tile and for a foreign holder's own drop_tool leg physically relocating the fetched tool mid-flight (both left the route's frozen destination and the freshly recomputed target apart without the tool ever being destroyed); and `_find_drop_cell()`'s blanket exclusion of every cell reachable-adjacent to the job's own ordinary target discarded valid, free stockpile cells next to a *passable* target, when only an *impassable* one still needs that exclusion. See "drop_tool: the handover wait, resolved" and "Destroyed-mid-job failure path" below for each fix. A round 5 review of THAT round found two further gaps, both resolved in this same round: `seed_active_drop()`'s restore-time reconstruction of the leg-identity marker was a heuristic, not an equivalent, with three unbounded-duration misclassification cases (a cancelled requester, a fetch reservation's release/re-reserve gap with an unrelated foreign-reserved held tool, and an ordinary leg whose held tool becomes foreign-reserved mid-flight); and `test_movement_scheduling_load.gd`'s idle-streak invariant exempted a genuine handover wait by matching the requester's own presentation `reason` string, unconditionally and without any bound of its own. Both are resolved by making the leg-identity marker itself part of `JobQueue`'s own persisted job record (`JobQueue.set_active_item_marker()`/`get_active_item_marker()`, at that point reusing the job's already-round-tripped `item_id` field) instead of an in-memory reconstruction, and by replacing the reason-string exemption with a direct simulation-origin check plus its own separately bounded streak -- see "Round 5 review" under "drop_tool: the handover wait, resolved" below for both. A round 6 review of THAT round found three further gaps, all resolved in this same round: reusing `item_id` for the leg-identity marker corrupted a haul job's own cargo identity, since `drop_tool` runs for any active job kind (including haul) and `item_id` is already haul's own carried-item field -- the marker now lives in `blocking_job_id` instead, the only other generic job field genuinely unused while active regardless of kind (see "Round 6 review" under "drop_tool: the handover wait, resolved" below); `test_movement_scheduling_load.gd`'s idle-streak check still exempted a genuine handover wait from its own 3-tick bound, merely swapping a presentation-string match for a call to the same origin predicate -- the check now only evaluates unassigned colonists against that bound, with a separate, unconditional, per-population bound covering every assigned colonist instead, plus a dedicated test proving the handover bound in isolation (see the `_check_no_idle_while_work_available()` bullet under "Consequences" below); and the reservation-release-gap regression test saved before the gap it meant to exercise ever opened, so it could not have caught the bug it was named for -- the test now orders its two colonists' ids so the gap is genuinely observable across a tick() boundary, and asserts it is inside that gap before saving (see "This claim was wrong for the second case" under "drop_tool: the handover wait, resolved" below).
- **Date:** 2026-09-20
- **Scope:** `game/scripts/core/jobs/toil_executor.gd`, `game/scripts/core/jobs/tool_matching.gd`, `game/scripts/core/jobs/tool_fetch_toil.gd`, `game/scripts/core/jobs/tool_drop_toil.gd`, `game/scripts/core/jobs/tool_handover.gd`, `game/scripts/core/jobs/tool_item_store.gd`, `game/scripts/core/jobs/job_queue.gd`, `game/scripts/core/scheduling/global_assignment.gd`, `game/scripts/core/world_state.gd`, `game/scripts/core/persistence/state_codec.gd`, `game/scripts/core/persistence/save_io.gd`, `game/scripts/core/persistence/save_migrations.gd`, `game/content/jobs.json`
- **Implements:** docs/architecture/colonist-ai.md section 2 ("a tool stays in a colonist's hand... no reservation and no release step") and 3.3 ("jobs as toils"); docs/architecture/extension-points.md "Toil"; the tool-item data model and `needs_tool` cross-check from issue #213; docs/decisions/004-global-assignment-fairness-policy.md (blocked_no_tool's aging/backoff and the shared routing allowance); docs/decisions/009 (suspend_assignment/resume_assignment, and the new sibling requeue_assignment(), reused here).

## Decision

Add `fetch_tool` to `ToilExecutor.VOCABULARY`. A job whose content entry
declares `needs_tool: <kind>` lists `fetch_tool` as its first toil (dig and
chop now declare `["fetch_tool", "reserve", "go_to", "work", "release_all"]`).
Whenever `fetch_tool` is not yet satisfied -- the colonist's `held_tool` does
not name an item of the required kind -- `advance()` routes to a dedicated
`ToolFetchToil.advance()` path (injected into `ToilExecutor`, see below)
instead of the ordinary go_to/work dispatch:

1. **Already held**: if `colonist.held_tool` already names an item of the
   right kind, the toil first tries to acquire (or confirm it already owns)
   that item's reservation for the current job id
   (`WorldState.reserve_tool_item()`); when that succeeds the toil is
   satisfied with no travel and the job proceeds straight to
   `reserve`/`go_to`/`work` as if `fetch_tool` were absent. A held item already
   reserved by a *different* job (its previous job has not released it yet) is
   not satisfied -- checking item kind alone, without also reserving it, was a
   round-3 review finding: it let a colonist's next matching job proceed
   unreserved, so a different job could take the tool mid-work.
2. **Found elsewhere**: `tool_matching.gd`'s pure `find_nearest_free_tool()`
   searches every tracked tool item -- on the ground, in a stockpile, or held
   by another colonist but currently unreserved (reservation is the source of
   truth, not location type) -- for the nearest one of the required kind not
   already excluded this attempt, breaking ties by item id for determinism.
   The toil reserves it (`WorldState.reserve_tool_item()`) and travels to it by
   reusing the existing go_to machinery: `advance_go_to()`/`advance_route_step()`
   gained an optional `record_as`/`on_arrive` pair so the exact same stepping
   and re-route code drives this leg, recording it under `fetch_tool` in the
   execution trace and handing arrival to a pickup callback
   (`WorldState.set_tool_item_held()`) instead of the job's own `work` toil.
   A colonist already holding a different tool drops it to the ground at
   arrival first (`set_tool_item_held()` refuses a second tool outright) --
   this is fetch_tool's own minimal handling of that case, not the drop_tool
   toil below. If the chosen candidate's location resolves to nothing walkable
   or its route search proves it unreachable, `ToilExecutor` releases that
   reservation, remembers the item id as excluded for this same fetch attempt,
   and immediately re-evaluates the next-nearest candidate (round 3 review
   finding: without this, a closer candidate enclosed by walls would report
   `blocked_no_tool` forever even with a farther, genuinely reachable match
   available).
3. **Nowhere**: no candidate exists, or every candidate has been tried and
   excluded. See "blocked_no_tool integrates with the shared scheduler" below.

The pure tool-matching/lookup algorithm lives in the dependency-free
`game/scripts/core/jobs/tool_matching.gd` (plain data in, plain data out,
no WorldState/scene reference). The fetch_tool toil's own state machine --
`needs()`/`satisfied()`/`advance()` and their `_reserved_tool_for()`/
`_arrive()`/`_exclude_candidate()` helpers -- lives in
`game/scripts/core/jobs/tool_fetch_toil.gd`, holding every callable it needs
(tool CRUD, `advance_go_to`, the execution-trace recorder) and constructed
once inside `ToilExecutor._init()`. Both are injected the same way
`route_search_factory` already is -- this is what keeps `toil_executor.gd`
under its `core-budgets.json` cap without requesting an increase. Tool item
CRUD plus their `ReservationTable` live in `game/scripts/core/jobs/
tool_item_store.gd`, injected into `WorldState` the same way, for the same
reason on the `world_state.gd` side of the budget.

## blocked_no_tool integrates with the shared scheduler

Round 1/2 of this task failed the job outright and resubmitted a fresh
replacement once a WorldState-owned backoff elapsed. Round 3 review rejected
that: it terminally failed the original order (so `cancel_job` on the
original id reported `job_already_terminal` while a hidden replacement kept
working), reset its ADR 004 aging on every resubmission, and duplicated
`JobQueue`'s own job lifecycle inside `WorldState` -- exactly the "job-state
machine outside the toil executor" AGENTS.md calls a defect regardless of
what the acceptance checks say.

Round 4 parked the job **outside** `GlobalAssignment`'s waiting list entirely
in a new `WorldState`-owned `ToolBlockTracker` (`job_id -> colonist_id`),
reconnecting it once a tool existed via `GlobalAssignment.resume_assignment()`.
Round 5 review rejected that as a second, parallel reconnect lifecycle: it
bypassed labour eligibility, committed needs, pending searches and aging/
scoring entirely, and had no backoff (an unreachable-but-existing tool could
retrigger recovery every tick with no delay).

The corrected design reuses a sibling of `GlobalAssignment.suspend_assignment()`
(the existing critical-need-interrupt mechanism, ADR 009 -- see "Ordinary
fetch failure vs. critical-need interrupt" below for why a sibling, not the
same call) plus a new, generic, kind-agnostic queued-failure backoff in
`JobQueue` itself:

- `WorldState._toil_on_no_tool_found()` (the `on_no_tool_found` hook fired by
  `ToolFetchToil._report_no_tool_found()` once every currently known candidate
  proves unreachable, or none exist) calls
  `GlobalAssignment.requeue_assignment(colonist_id, job_id)` -- releasing the
  job's target reservation, returning it to "queued", and reinserting it into
  `_waiting` at its **original** aging position and its **original**
  restrict_to (empty for an ordinary order, so ANY eligible colonist may pick
  it back up), mirroring `suspend_assignment()`'s own reinsert. This alone was
  tried and rejected as insufficient in an earlier draft of this round (see
  below): without a backoff, the job's unbounded aging term wins every
  scoring pass forever, so it immediately follows with...
- `JobQueue.block_no_tool(job_id)`, a new method that applies this job kind's
  own content-declared `retry_base_ticks`/`retry_cap_ticks` (dig/chop's own
  jobs.json fields, mirroring haul's identical fields) to the job's existing
  `retry_at`/`backoff_ticks` fields -- the *same* fields `_tick_haul()`
  already uses for `BLOCKED_DESTINATION_FULL`, reused rather than duplicated
  (a kind is either `HAUL_KIND` or declares `needs_tool`, never both, so
  there is no collision) -- and sets reason `blocked_no_tool`/remedy
  `craft_or_find:<kind>`.
- `JobQueue.get_reservations()` marks a backed-off queued job's own target as
  "reserved" for as long as `_tick < retry_at`, the same trick
  `BLOCKED_DESTINATION_FULL` already relies on: `GlobalAssignment.tick()`'s
  pre-scoring "already reserved" check (`if reservations.has(entry["target"])`)
  then refreshes the job every tick without ever routing or scoring it, so it
  cannot win a colonist's pick -- and therefore cannot starve a competing
  tool-free order -- while backed off. `get_reservations()` runs *before*
  this same `GlobalAssignment.tick()` call's own `advance_selection()` ->
  `JobQueue.tick()` increments `_tick`, so it is always reading `_tick` one
  step behind `tick()`'s own per-job loop; `ToolMatching.gate_backed_off()`
  (called first in that loop, before the reservation-owner/reachability
  checks, mirroring `_tick_haul()`'s own early return) therefore stays gated
  through `tick <= retry_at`, not `gate_check()`'s own `tick < retry_at`, so
  the one boundary tick where `get_reservations()` still calls the job
  reserved never falls through to a reachability result no real route search
  this cycle produced (round 6 review: without this, the scheduler's own
  reservations-shortcut selection fed that stale `_can_reach() == false`
  result into the SAME job and overwrote `blocked_no_tool`'s reason with
  `blocked_target_unreachable` for the entire backoff window).
- Independently, `JobQueue.set_tool_requirement(tool_requirement_of,
  tool_available)` gates ordinary activation (`tick()`'s per-job loop, after
  the existing reservation/reachability checks) on a matching tool existing
  *anywhere* right now (`WorldState._tool_exists()`, job-id-aware so a job
  that already reserved its own tool ahead of activation is never mistaken
  for proof none exists) -- a cheap existence check, not a reachability
  check, so a dig/chop order submitted where literally no matching tool
  exists is blocked before ever consuming a colonist or a route-search slot.
  This same gate re-checks (and, on failure, re-escalates the backoff via the
  same fields) once a prior backoff elapses.

Both paths funnel through the *same* `reason`/`remedy`/`retry_at`/
`backoff_ticks` fields every other block reason already uses, so labour
eligibility (`GlobalAssignment._is_labour_enabled()`, checked before a
`_waiting` entry may ever be scored), committed needs
(`_propose_committed_need()`), pending route batches (`_pending`), and ADR
004's aging/cursor rotation all apply to a blocked_no_tool job exactly as
they do to any other queued job -- there is no second scheduler.

An earlier draft of this round tried `suspend_assignment()` alone, with no
backoff at all: measurement (a headless regression driving a blocked dig job
with a *permanently* unreachable tool, alongside a tool-free forage order for
the same colonist) showed the dig job's own target is always reachable (the
tool-fetch failure is invisible to `GlobalAssignment`'s routing/scoring), so
it kept winning the aging race and reactivating -- fetch_tool would retry and
fail every single cycle, starving the forage order. This is exactly why
`JobQueue.block_no_tool()` exists as a *separate* call from
`requeue_assignment()`: the job-queue-level existence gate alone cannot see
reachability, so the reachability failure fetch_tool itself discovers must
also drive the backoff directly.

## Ordinary fetch failure vs. critical-need interrupt

Round 5 reused `GlobalAssignment.suspend_assignment()` verbatim for
`_toil_on_no_tool_found()`. Round 6 review found that wrong: `suspend_
assignment()` unconditionally pins the reinserted `_waiting` entry's
`restrict_to` to the failing colonist, because that call's other caller
(`WorldState._interrupt_current_job()`, ADR 009's critical-need interrupt)
*needs* that pin -- the whole point is that the same colonist resumes the
same job once the need resolves, via `resume_assignment()`. A fetch_tool
failure is not that: it is an ordinary order whose only currently-assigned
colonist happened to fail a reachability search, and the order must go back
to the *ordinary* fair pool for any eligible colonist, not stay bound to the
one that failed. The prior behavior made this concrete: if the failing
colonist's own labour is later disabled (colonist-ai.md 3.2), the order could
never reactivate again even after a reachable tool appeared, since the one
colonist still allowed to take it (per `restrict_to`) could never again pass
`_is_labour_enabled()`.

`GlobalAssignment.requeue_assignment(worker, job_id)` is `suspend_assignment()`'s
new sibling: identical `clear_assignment()` + `queue.suspend(job_id)` +
aging-preserved `_waiting` reinsert (both now share `ToolMatching.
reinsert_activated_entry()`, extracted to keep `global_assignment.gd` under
its line budget), but passing `restrict_to = ""` to that shared helper keeps
the reinserted entry's *original* `restrict_to` (empty for an ordinary order)
instead of overwriting it to `worker`. `_toil_on_no_tool_found()` calls this
new method; `_interrupt_current_job()` keeps calling `suspend_assignment()`
unchanged. `test_tool_items.gd`'s
`_check_blocked_no_tool_failure_frees_job_for_a_different_colonist()` proves
the fix directly: colonist_0's own fetch attempt fails against a pick fully
enclosed by rock, its "mine" labour is then disabled, and only once a second,
genuinely reachable pick appears does colonist_1 -- the only colonist still
eligible -- complete the SAME order.

## Shared per-colonist routing allowance

ADR 004: "Each colonist owns at most one unfinished RouteSearch and calls its
unchanged `resume()` at most once per tick... at most 64 frontier expansions
across all route work" -- a budget meant to span *every* route search a
colonist's tick can touch, not just `GlobalAssignment`'s own per-worker
candidate search. Before this round, `GlobalAssignment`'s activation search
and `ToilExecutor`'s go_to/fetch_tool reroute search tracked resume
consumption entirely independently: a colonist whose job the scheduler just
activated (spending its own pending-route search that same tick) could still
have fetch_tool immediately start and resume a *second*, unrelated search the
same tick; and a long fetch-tool-to-return-leg transition inside a single
`ToilExecutor.advance()` call (`_start_current_toil()`'s go_to branch,
followed unconditionally by `advance()`'s own `_continue_go_to()` call) could
resume the *same* search object twice.

`WorldState._route_budget` (`colonist_id -> bool`) is now shared by reference
between `GlobalAssignment` (`set_route_budget()`) and `ToilExecutor`
(injected as a constructor parameter): `GlobalAssignment.tick()` clears it at
the very top of every call (mirroring its own `_metrics` reset, since that
call always runs first within `WorldState.tick()`, before
`_advance_colonists()` can spend any of it), and both its own route-resume
site and `ToilExecutor._resume_go_to_reroute()` check-and-set it before
calling `search.resume()`. A colonist's first resume this tick wins,
whichever module asks first; every later request this same tick sees the
search stay non-terminal and simply defers to the following tick, exactly as
if reaching this point one tick later. `test_reroute.gd`'s
`_check_route_budget_shared_across_scheduler_fetch_and_return()` proves both
halves of this directly (no persisted-search object's `resume_calls` may rise
by more than one within a single external tick; the scheduler's own resumed
search and a brand-new fetch_tool search must not both spend a resume on the
tick a job activates) against a fixture that forces a genuine two-batch
search in both the fetch and the return leg.

## Persistence

`_restore_reroutes()` (`game/scripts/core/persistence/state_codec.gd`)
reconstructs each in-flight search's cost callable with a target-tile
passability exception -- correct for the job's own go_to leg (dig/chop's
target, or a haul leg), but a fetch_tool leg's real target is a *tool's*
location, not the job's. Round 4 review found this wrong for a mid-fetch
save/load; round 5 fixed the *shape* of the bug (using `job["target"]`
instead of the tool's own location) but round 6 review found the fix itself
still wrong: it recomputed the tool's location from the *current*,
post-restore `toolItems`/`toolReservations` state rather than reading the
search's own already-persisted `rerouting.target` -- these differ once a
held tool's holder physically moves after the search began but before the
save, silently applying the passability exception to the wrong tile. The
fix needs no new field either way: `ToilExecutor.needs_fetch_tool()`
(already a read-only check, see `tool_fetch_toil.gd`'s `needs()`) tells
`_restore_reroutes()` whether a colonist's in-flight search is a fetch_tool
leg, and if so it uses `snapshot["target"]` directly -- the exact Vector2i
`ToolFetchToil.advance()` bakes into the cost callable at the moment the
search actually begins (`_begin_go_to_reroute()`'s own `target` argument,
already round-tripped by `_encode_route()`/`_decode_route()` for every other
in-flight search), reused rather than reconstructed. `test_reroute.gd` covers
both fixed defects: `_check_save_load_mid_fetch_tool_matches_uninterrupted_run()`
(round 5's own regression, a stationary tool) and
`_check_save_io_round_trip_mid_fetch_tool_holder_moves_matches_uninterrupted_run()`
(round 6's, a *real* SaveIO file round trip -- not just `StateCodec.encode()`/
`decode()` -- taken after the tool's holder has already relocated mid-search).

`ToolFetchToil._excluded` (job_id -> tool ids already proven unreachable
within the current fetch attempt) is now fully persisted too: round 5 left it
out because `game/scripts/core/persistence/save_io.gd` -- the real
autosave/save-file validator (`write_atomic()`/`read()`, distinct from
`StateCodec.encode()`/`decode()`'s own direct round trip most tests use) --
hardcodes an exact field allow-list at every level and was not, at that
point, an owned path for this task; round 6 review correctly rejected that as
a real gap rather than a defensible boundary (losing this set on restore
genuinely changes subsequent ticks, which is exactly the kind of thing a save
round trip must not do), and the task's owned paths now include `save_io.gd`
and `save_migrations.gd`. `StateCodec.SCHEMA_VERSION` is bumped from 16 to
17 (a genuinely new persisted field, matching every prior schema bump in this
codebase's history): `get_excluded()`/`restore_excluded()`
(`tool_fetch_toil.gd`, plumbed through `ToilExecutor.get_fetch_tool_excluded()`/
`restore_fetch_tool_excluded()`) round-trip through a new top-level
`toolFetchExcluded` array of `{jobId, toolIds}` entries, one per job with at
least one excluded candidate; `WorldState.state_hash()` includes it too, so a
save/load that dropped or corrupted the set is caught the same tick it
diverges rather than several ticks later once its downstream effects show up.
`SaveMigrations._migrate_v16_to_v17()` backfills `toolFetchExcluded: []` for
any older save (no fetch attempt could ever have excluded anything before
this field existed), and `SaveIO._valid_tool_fetch_excluded()` cross-checks
every `toolId` against the save's own `toolItems`, mirroring
`toolReservations`' own cross-check. `test_tool_items.gd`'s
`_check_save_io_round_trip_after_candidate_excluded()` proves the persisted
set matches exactly on restore and that a run resumed from it reaches the
identical final `state_hash()` as an uninterrupted run, at the identical
tick -- if the set were dropped, the restored run would re-try the excluded
candidate and take measurably longer.

## drop_tool: the handover wait, resolved (issue #266)

`drop_tool` is now in `ToilExecutor.VOCABULARY`. It is never declared in any
`content/jobs.json` toils array (that file is out of this task's owned
paths): instead `ToilExecutor.advance()` inserts it dynamically, ahead of
whatever toil a colonist's own active job would otherwise run next, whenever
`colonist.held_tool` names an item currently reserved by a job other than the
colonist's own (`ToolDropToil.needs_drop()`). This is exactly case (b)'s
third location from "Decision" above: a tool `fetch_tool` found held by
another colonist and unreserved at the moment it reserved it, but the holder
still physically has it. The insertion point is gated to a toil boundary
(`colonist.route`/`work` both null) so it lands on the holder's own **next
dispatched job** -- never interrupting an in-flight leg of its own -- matching
the "next dispatched job" framing in the issue. The holder side of this toil,
the requester side of the same handover (below), and the destroyed-mid-job
failure path (further below) all now live in a new injected collaborator,
`game/scripts/core/jobs/tool_drop_toil.gd`, extracted out of
`toil_executor.gd` the same way `tool_fetch_toil.gd` already is, purely to
stay under `core-budgets.json`'s cap.

`ToolDropToil.advance()` drops the tool in place when no free stockpile cell
lies within `TOOL_DROP_RADIUS` of the colonist, otherwise walks there first
via the same `advance_go_to()` stepping every other toil already shares
(recorded under `drop_tool` in the execution trace). The nearest-free-cell
search (`_find_drop_cell()`) mirrors `HaulGiver.find_free_haul_cell()`'s own
free/passable/occupied checks -- reused read-only through injected callables
(`get_zones`, `is_cell_free`, both already-public `WorldState` methods, plus
`get_tool_items` for the tool-occupancy check added this round, see
"Destination consistency" below) -- but nearest-first within a bounded radius
instead of "first free cell in zone order"; `haul_giver.gd` itself is
untouched, per this task's non-goals. Dropping (`WorldState.set_tool_item_ground()`/
`set_tool_item_stockpile()`, both pre-existing) unconditionally releases
whatever reservation the tool currently carries (colonist-ai.md 2), including
the foreign job's own: this is not a bug -- the foreign job's `fetch_tool`
simply re-scans and re-reserves the now-unheld item on its very next
`advance()` call, exactly as it already does for any other newly-freed
candidate.

**The requester side, actually implemented (round 2 review):** round 1's
`ToolFetchToil._arrive()` still called `set_tool_item_held()` unconditionally
at arrival, which transfers the tool out of the holder's hand immediately --
including while the holder is still travelling to drop it -- so the wait
never actually happened. `ToilExecutor.advance()` now checks
`ToolDropToil.waiting_for_handover(colonist_id, job_id)` for every
`fetch_tool`-driven job, every tick, before ever calling `ToolFetchToil.
advance()`'s own travel step: `{}` unless job_id's own currently-reserved tool
item is still physically `held` by a *different*, currently *busy* colonist
(route or work in flight -- see below), in which case `advance()` simply
returns without starting any travel that tick. No new persisted "waiting"
state is needed: dropping a tool unconditionally releases whatever
reservation it carries (see above), so the requester's own reservation on it
is released the instant the holder's `drop_tool` toil completes; the
requester's very next `advance()` call then finds itself unreserved again
(`ToolFetchToil.satisfied()` false) and re-runs its ordinary
`find_nearest_free_tool()`/reserve/travel sequence, which re-discovers the
now-grounded (or now-stockpiled) item as the nearest candidate and fetches it
normally. The wait is not, semantically, a distinct persisted phase at all --
it is the *ordinary* not-yet-satisfied state, merely gated from starting a
doomed travel leg toward a tool that has not physically moved yet.

**A candidate reserved this same tick was still stealable (round 2 review of
round 2):** `ToilExecutor.advance()`'s own `waiting_for_handover()` gate only
ever runs BEFORE `ToolFetchToil.advance()` is called, so on the very tick a
fresh candidate is found and reserved -- inside that same `advance()` call --
the gate has nothing to check yet: reservation and (for an already-adjacent
holder) `advance_go_to()`'s own `path.size() <= 1` same-call pickup shortcut
could both happen before the gate ever runs again, stealing the tool out of a
busy holder's hand the instant it was reserved. `ToolFetchToil.advance()` now
also checks `_held_by_busy_foreign()` itself, immediately after acquiring
`item_id` (freshly reserved or already-owned) and before computing a target or
starting `advance_go_to()` at all, so no travel or pickup ever begins on the
reserving tick either. A second gap in the same round: `advance_go_to()` never
re-targets an already-resolved route on its own (colonist-ai.md 3.5's own
stepping only starts a fresh search when a blocked next tile or reroute
forces one), so a route legitimately started toward an **idle** holder's tool
kept walking toward that holder's OLD position even after the holder later
became busy and its own `drop_tool` leg physically moved the item to a
stockpile cell elsewhere -- the requester would arrive to find nothing there
and back off `blocked_no_tool` instead of completing. `ToolFetchToil.
advance()` now compares a freshly (re)acquired reservation's live target
against its own route's current destination (`_route_effective_target()`,
the same helper `ToolDropToil` uses) and discards a stale route before
`advance_go_to()` runs, so the next call searches fresh toward the tool's
actual current location; this discard is deliberately gated to a *freshly*
(re)acquired reservation only -- an already-held reservation's target
legitimately drifts tick to tick while its still-idle holder simply walks
around, and restarting that search every tick would thrash forever.

The busy check matters: a fully **idle** holder (no scheduler assignment at
all right now, so `advance()` never runs for it and therefore its held tool's
foreign reservation can never trigger a drop insertion) would strand the
requester forever if the wait applied unconditionally -- there is no "next
dispatched job" to hang a `drop_tool` toil off. `waiting_for_handover()`
therefore only reports waiting when the holder is currently busy (`route` or
`work` in flight, read via the same `get_colonists` callable already injected
for `ToolFetchToil`'s own candidate search); an idle holder's unreserved held
tool is instead picked up directly, exactly as it already was before this
task -- there is nothing in flight to interrupt. With genuine waits now
actually enforced (the previous paragraph), a requester can legitimately sit
idle for as long as a busy holder's *current* toil takes to finish before its
own `drop_tool` insertion runs. `test_movement_scheduling_load.gd`'s own "no
idle while work available" invariant accounts for this (round 5 review: see
below for why the first version of this accounting was rejected).

**Round 5 review: reason-string exemption replaced with an origin check plus
its own bounded streak.** The version above matched the requester's own
active job against the *presentation* `reason` string
(`waiting_for_tool_handover`, `tool_handover.gd`'s own overlay) and reset its
idle streak unconditionally on a match, with no bound of its own -- a genuine
stall (the wait never actually resolving, e.g. a latent deadlock) could never
be caught by this test, and matching a derived display string is "a check at
the point of the symptom instead of its origin," the exact anti-pattern this
repository's review rules reject. `_waiting_for_handover()`
(`test_movement_scheduling_load.gd`) now asks the ORIGIN directly --
`ToilExecutor.waiting_for_handover(colonist_id, job_id)`, the same read-only
predicate `ToilExecutor.advance()` itself gates `fetch_tool`'s travel on, not
a derived presentation field -- and a colonist it reports true for is tracked
against its OWN separate `handover_wait_streaks` counter, bounded by
`HANDOVER_WAIT_TICK_BOUND` (200 ticks: a documented, geometry-derived ceiling
covering the busiest holder's own worst-case current toil in this load
scenario -- at most the full load area's own travel distance, the longer of
dig/chop's own work duration, and `TOOL_DROP_RADIUS`'s own travel, all at
`content/tiles.json`'s `move_ticks_per_tile`, with headroom), never widened
by matching a reason string. The ordinary `idle_streaks` counter keeps its
original, unwidened 3-tick bound for every colonist the origin check does
NOT report waiting -- exactly the same population and the same bound as
before this task, undiluted.

**Presentation overlay:** `waiting_for_handover()` also drives a new,
presentation-only overlay, `game/scripts/core/jobs/tool_handover.gd`,
applied by `WorldState.get_jobs()` (only -- never `_get_job()`, the
`_job_lookup` callable `ToilExecutor` itself uses for simulation decisions) to
the job's own already-detached duplicate: while waiting, the job's `reason`
reads `waiting_for_tool_handover` and its *existing*, already-persisted
`item_id`/`blocking_job_id` fields (reused, not new state, per this task's own
non-goal against inventing persisted state) name the reserved tool and the
holder's own currently assigned job id. `get_jobs()`'s own new code is four
lines (a loop calling `ToolHandoverType.apply()`); `world_state.gd` stayed
within its `core-budgets.json` cap by trimming an equal number of comment
lines elsewhere in the same file, not by requesting a budget increase.

**Destination consistency (round 2 review):** round 1 recomputed the nearest
free cell on *every* tick while already travelling, so a cell that stopped
being free (or a closer one that became free) mid-flight could retarget the
`on_arrive` closure's captured cell while the colonist kept walking toward the
path it had already committed to -- arrival would then apply the drop at a
cell the colonist never actually reached. `ToolDropToil.advance()` now
computes the destination exactly once, when the leg starts
(`colonist.route == null`); every later call reuses the route's own
already-chosen destination (`_route_effective_target()`, reading
`route["rerouting"]["target"]` while a search is in flight or
`route["path"][-1]` once resolved -- both already-persisted fields, no new
state). Arrival re-validates that *same* destination -- free, passable,
unoccupied by a colonist, stackable item, *or another ground/stockpiled tool
item* (round 2 review of round 2: the general `cell_occupied` callable never
checked tool items, only colonists and stackables, so a chosen cell could
already hold an axe or pick; `_cell_still_free()` now also scans
`get_tool_items()`, injected the same read-only way `ToolFetchToil` already
receives it, rather than widening the shared callable itself, which stays out
of this task's line-budget-capped `world_state.gd`), and still belonging to
*some* stockpile zone (a zone removed mid-travel must not still record
`location.type` `"stockpile"` for a cell no longer inside one) -- and falls
back to dropping on the ground, right where the colonist is actually
standing, if any of that no longer holds. `_find_drop_cell()` also excludes
the job's own ordinary `go_to` target itself, and (round 3 review: only when
that target is *impassable*) every cell reachable-adjacent to it -- see
"Persistence" below for why, and for why a *passable* target no longer needs
the broader exclusion.

**Persistence (round 2 review):** round 1 tagged the in-flight leg with an
unpersisted `route["drop_tool"] = true` flag `state_codec.gd`'s
`_encode_route_field()`/`_decode_route_field()` fixed allow-list silently
dropped on every real `SaveIO` round trip -- a save taken mid-leg restored
into a colonist whose route `advance()` could then only interpret as its own
tool-free job's *ordinary* travel, starting `work` at the stockpile cell
instead of completing the handover. `ToolDropToil.is_dropping()` replaces the
flag with a check reconstructed entirely from already-persisted state
(`colonist.held_tool`, the route's own path/rerouting target), never a
persisted flag -- but its first version (this same round) compared the
route's destination for *exact equality* against job_id's ordinary `go_to`
target, which a round 2 review of round 2 found still wrong two ways: an
ordinary leg toward an *impassable* target (dig/chop/forage's own tree/bush,
trimmed one tile short by `advance_go_to()`'s own target-tile trim) is never
actually equal to that target, so it was misclassified as dropping the
instant a foreign reservation happened to also turn `needs_drop()` true
mid-flight; and requiring `needs_drop()` to still hold made a *genuine* drop
leg stop being recognized the moment its triggering reservation disappeared
(the requester's own job was cancelled), letting the SAME in-flight route
finish as if it were the holder's own ordinary leg and start `work` at the
stockpile cell. `is_dropping()` now instead checks: the colonist still
physically holds something, AND the route's destination is neither
*reachable-adjacent* to the job's own ordinary target (the same one-tile
trim tolerance `advance_go_to()` itself applies, closing the impassable-target
gap above) nor equal to `ToolFetchToil.current_target()` -- a new read-only
method mirroring `needs()`'s own side-effect-free contract, so an in-flight
`fetch_tool` leg toward a *different* tool is never mistaken for a drop leg
either, closing the same misclassification `is_dropping()`'s own callers
already worried about for the ordinary case. Continuing a leg no longer
depends on `needs_drop()` staying true at all (closing the cancellation gap):
once started, a drop leg is identified purely by "still holding something,
and walking somewhere neither this job's own `go_to` nor its own `fetch_tool`
would ever send it," which survives the triggering reservation disappearing
exactly as it must survive a save/load. For this to stay unambiguous,
`_find_drop_cell()` must never itself choose a cell that coincides with (or
is reachable-adjacent to) the job's own ordinary target -- otherwise a
legitimate drop destination could collide with the very thing `is_dropping()`
uses to recognize an *ordinary* leg, silently skipping the drop callback; it
now excludes any such cell up front. No `state_codec.gd` schema change was
needed for any of this, and none was made (this task's own non-goal against a
schema bump this round): `test_tool_items.gd`'s
`_check_save_io_round_trip_mid_drop_tool_movement_matches_uninterrupted_run()`
and `_check_save_io_round_trip_mid_drop_tool_route_search_matches_uninterrupted_run()`
prove a real `SaveIO` round trip taken both mid-movement (a resolved path,
not yet arrived) and mid-search (`route["rerouting"] != null`, a wide-open
room forcing the RNG-free Dijkstra search well past its own 64-expansion
per-tick budget) reaches the identical final `state_hash()` as an
uninterrupted run; `_check_ordinary_route_not_misclassified_as_drop_when_reservation_appears_midflight()`,
`_check_fetch_route_not_misclassified_as_drop_when_other_reservation_appears()`,
`_check_requester_cancellation_midflight_still_completes_drop_correctly()` and
`_check_drop_cell_coincident_with_impassable_ordinary_target_falls_back_to_ground()` cover
the four round 2 gaps above directly.

**Round 3 review:** the round 2 `is_dropping()` still compared the route's
own (possibly stale) destination against a *freshly recomputed*
`ToolFetchToil.current_target()` for exact position equality, which broke two
further ways: a fetch destination trimmed one tile short by
`advance_go_to()`'s own target-tile trim (an impassable tool tile, e.g. a wall
built on it mid-travel) was never actually equal to the live recomputed
target even though it plainly was still the same fetch leg; and a foreign
holder's own `drop_tool` leg physically walking toward *its* chosen stockpile
cell relocates the tool tick by tick while it is still `held` (its position is
the holder's own current tile), drifting `current_target()` away from the
requester's already-in-flight route -- frozen by design once reserved (see
"A candidate reserved this same tick was still stealable" above) -- until the
holder actually arrives. Both could misclassify a genuine in-flight
`fetch_tool` leg as a drop; `active_tool_missing()` also ran too late to catch
a *destroyed* fetch target before `is_dropping()` saw it (see "Destroyed-mid-
job failure path" below). `is_dropping()` now checks `current_target()` for
*existence* only, never position, plus a second, complementary check --
`ToolFetchToil.needs()` true (job_id's own fetch_tool need is still
unsatisfied) *and* `needs_drop()` false (the held tool is not itself foreign-
reserved, so there is no competing genuine-drop explanation) -- covering the
gap window between a reservation being released (by any means, including a
foreign holder's own drop) and `fetch_tool`'s own next `advance()` call
re-scanning and re-reserving. Both checks are position-independent, so
neither trimming nor drift nor a momentarily-absent reservation can affect
them; only once both rule out "still fetching" does `is_dropping()` fall back
to the position-based ordinary-target comparison, which is exact-match-or-
elsewhere as round 2 left it. `_find_drop_cell()`'s blanket exclusion of every
cell reachable-adjacent to the job's own ordinary target is now scoped to an
*impassable* target only (see "Destination consistency" above): a real
ordinary/fetch leg toward a *passable* target always walks exactly onto it
(the exact-match branch), so a drop cell merely adjacent to one was never
actually ambiguous, and excluding it discarded a valid, free stockpile cell
for no reason; the exact target tile itself stays excluded regardless (a drop
landing exactly there would be indistinguishable from a leg that legitimately
reaches a passable target exactly).
`_check_fetch_route_survives_impassable_fetch_destination_trim()`,
`_check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover()`,
the geometry fix to `_check_destroyed_fetch_target_preserves_unrelated_held_tool()`
(the axe now sits far from the job's own target, instead of adjacent to it,
so the ordinary-target reach check can no longer mask the destroyed-tool
ordering bug by accident) and
`_check_drop_cell_near_passable_ordinary_target_uses_nearest_stockpile_cell()`
cover these round 3 gaps directly.

`_restore_reroutes()` (`state_codec.gd`, in this task's owned paths this
round) previously picked its cost-function branch off `ToilExecutor.
needs_fetch_tool()` alone, which was never taught about drop legs: for a drop
leg whose own job kind happens not to need a tool at all, this landed on the
"ordinary job target" branch (a target-tile passability exception around
job.target) rather than plain passability, the ONLY policy the live
`ToolDropToil.advance()` ever actually uses. This ADR previously called that
harmless, reasoning a drop's chosen destination is already pre-verified
free/passable by `_find_drop_cell()` so the exception is never *needed* --
true, but incomplete: the exception is still *applied*, and if job.target
itself (an impassable dig/chop/forage target) happens to lie on the direct
route between the holder and its chosen stockpile cell, the restored search
gains a one-tile "shortcut" through it that the live, always-plain-passability
search never has, changing what a resumed mid-search restore finds. `ToilExecutor.is_dropping_leg()` (a thin passthrough onto
`ToolDropToil.is_dropping()`, using the corrected check above) now lets
`_restore_reroutes()` pick plain passability for a drop leg exactly like the
live toil does, before falling through to the fetch_tool/ordinary branches.
`test_tool_items.gd`'s
`_check_save_io_round_trip_mid_drop_tool_search_impassable_target_between_holder_and_stockpile()`
proves this against a real round trip: the job's own target sits directly on
a full-width wall between the holder and the only stockpile cell within
reach, with no other opening at all, so the OLD reconstruction would have let
the restored search cross where the direct run (always plain, unaffected by
save/load) never could -- compared tick by tick via `state_hash()` equality,
not merely at completion.

**Round 4 review: leg identification made stable, independent of reservation
state.** Round 3's `is_dropping()` still classified an in-flight route by
comparing its own destination against the job's ordinary/fetch targets, ruled
out `fetch_tool` first via `ToolFetchToil.current_target()`'s existence and,
for the gap between a reservation being released and `fetch_tool`'s own next
re-reserve, a tiebreaker of `ToolFetchToil.needs()` true *and* `needs_drop()`
false. Round 4 review found two concrete counter-examples where reservation
state changes for reasons that have nothing to do with which leg is
physically in flight, and the tiebreaker read the wrong answer both ways:

- A holder's own already-in-flight drop leg (triggered because its held tool
  was reserved by a *foreign* job) keeps walking while that foreign job gets
  cancelled, releasing the reservation that triggered the drop. If the
  holder's own **next dispatched job** (the one the drop is running ahead of)
  itself needs a *different* tool, `needs_drop()` is now false but
  `ToolFetchToil.needs()` is true (the held tool never matched what the next
  job needs anyway) -- the round 3 tiebreaker read that combination as "not
  dropping, must be fetching" and let `ToolFetchToil.advance()` discard the
  in-flight route toward the stockpile cell before the tool was ever actually
  dropped.
- A requester's own in-flight `fetch_tool` route can go through the same
  `current_target()` gap -- its target tool's foreign *holder* drops it,
  releasing the requester's reservation for the one or more ticks until the
  requester's own next `advance()` re-reserves the now-grounded item -- while
  the requester *also* happens to hold a second, unrelated tool that is
  itself foreign-reserved by a third job. `needs_drop()` is then genuinely
  true for an entirely unrelated reason, so the round 3 tiebreaker could not
  rule out "must be dropping," and treated the frozen fetch destination (the
  holder's old position) as a drop cell for the wrong tool.

Both counter-examples share a root cause: which toil is currently driving a
route is a fact about that route's own *history* (which toil started it), not
something any instantaneous snapshot of reservation state can always
reconstruct, since *other* jobs' reservations change for reasons unrelated to
this leg. `ToolDropToil` now keeps that history directly: a small in-memory
`_active_drop: Dictionary` (`job_id -> item_id`), set once when `advance()`
starts driving a job's drop and cleared the instant that drop finishes or
fails. `is_dropping()` is now exactly `colonist.route != null and
_active_drop.has(job_id) and _active_drop[job_id] == colonist.held_tool` --
no reservation lookup, no position comparison, so neither counter-example
above can misclassify it: `_active_drop` only ever answers "did *this* toil
start this leg," a question no other job's reservation churn can affect.
`needs_drop()` itself is unchanged and still reservation-based -- that is the
correct, and only, place a *decision* to start a new drop belongs (colonist-
ai.md 3.3's "a decision about *when* a job exists is a job-giver module" logic
applies the same way to "when a toil starts" here); `is_dropping()` merely
asks whether one already has.

`_active_drop` is deliberately **not** a new `state_codec.gd` field (this
task's own non-goal against a schema bump this round): a fresh
`ToolDropToil` after restore starts with it empty, so
`ToolDropToil.seed_active_drop()` bootstraps it once, immediately after
`decode()` rebuilds `world._colonists`/`world._scheduler` and before
`_restore_reroutes()` needs `is_dropping_leg()` to pick a cost function --
from the same `needs_drop()`/`current_target()`-existence signals a live tick
can read. Every later tick then relies purely on the marker `advance()`
itself maintains, never recomputing this way again. `test_tool_items.gd`'s
`_check_drop_continues_when_holders_own_next_job_needs_a_different_tool()`
and
`_check_fetch_route_not_misclassified_as_drop_when_leftover_tool_also_foreign_reserved()`
(the latter including a `SaveIO` round trip taken *before* the gap, then
compared tick by tick through it against an uninterrupted run) cover the two
round 4 counter-examples directly, but only for a save taken *before* either
gap opens.

**Round 5 review: this restore-time reconstruction is not equivalent to the
live marker, and the divergence is not bounded to one restored tick.** Round
4's claim above was wrong on both counts. `needs_drop()`/
`ToolFetchToil.current_target()` are reservation-state snapshots, and by
design (see "Both counter-examples share a root cause" above) reservation
state at a single instant cannot always answer "which toil started this
route" -- the exact property that made the *live* `_active_drop` marker
necessary in the first place applies just as much to *seeding* it from the
same signals. Three concrete cases, none limited to the save tick:

- A save taken any time after the requester's job that originally triggered
  the drop is cancelled (releasing the reservation `needs_drop()` reads):
  restores with the marker unseeded from that tick onward, not just the save
  tick -- the colonist's still-in-flight drop route is read as its own job's
  ordinary/fetch leg, letting `work` start at the stockpile cell or letting
  `fetch_tool` discard the route.
- A save taken inside the (not narrow) window between a fetch_tool
  reservation being released and `ToolFetchToil`'s own next `advance()`
  re-reserving it, while the colonist also holds a second, unrelated tool
  that is itself foreign-reserved: `needs_drop()` reads true for the
  unrelated tool, so the seed wrongly marks a live fetch leg as a drop,
  permanently -- nothing later re-evaluates a wrongly-seeded marker.
- A save taken during any ordinary `go_to` leg (dig/chop/forage's own
  travel, no fetch or drop involved) after the colonist's held tool happens
  to become foreign-reserved mid-leg: live behaviour never reclassifies an
  in-flight leg this way (insertion only ever happens at a toil boundary,
  `colonist.route == null`), but `seed_active_drop()` has no boundary
  concept and wrongly marks it a drop the instant `needs_drop()` reads true.
  This is the widest case -- no cancellation, no gap timing, just an
  ordinary leg plus an unrelated foreign reservation.

A correct fix needs the route's own toil identity to survive the save
independent of reservation state at the moment of restore -- exactly what
the live `_active_drop` marker already is, just not read from anywhere on
restore because it is deliberately not wire state. The only already-*wire*
values that could carry it without a new field are a job's own already-
persisted, already-permitted `reason`/`itemId`/`blockingJobId` (a genuinely
empty, unused `String` on every *active* job regardless of kind, per
`job_queue.gd`'s own `_set_reason(job, "", "")` call at every activation
site) -- but writing to them requires a live, non-`.duplicate(true)` handle
into `JobQueue`'s own job record, which today only exists inside
`job_queue.gd` itself: `get_job()`/`WorldState._get_job()` hand back a deep
copy on every read by design, so nothing outside `job_queue.gd` can persist
per-tick state into a job without a new method there, and every existing
public `JobQueue` mutator either targets `queued`-only jobs (`attach_item()`)
or writes a side dictionary consulted only at a terminal transition
(`set_pending_fail_reason()`), never a live *active* job's own fields.

**Resolved this same round.** `job_queue.gd`/`test_job_queue.gd` are in this
task's owned paths (round 5 review corrected an earlier draft of this round
that had claimed otherwise), so the missing piece above -- a live, non-
duplicated write handle into an active job's own record -- is now added
directly: `JobQueue.set_active_item_marker(job_id, item_id)` writes straight
into an active job's own record (a no-op on a queued or terminal job,
mirroring `attach_item()`'s own queued-only guard); `JobQueue.get_active_item_marker(job_id)`
re-reads the live record fresh on every call rather than trusting a
caller-held `.duplicate(true)` snapshot, so a marker written earlier in the
*same* tick is visible immediately to a second call within that tick (this
matters: `ToilExecutor.advance()` calls `is_dropping()` once before dispatching
`ToolDropToil.advance()` and once again right after, in the same call, to
decide whether the leg is still in flight). No new field, no schema bump: the
target field is already part of every job's wire encoding regardless of kind,
already round-tripped through a real `SaveIO` file. **This round's own choice
of field -- `item_id` -- was wrong; see "Round 6 review" immediately below for
why and for the corrected field.**

`ToolDropToil` no longer keeps `_active_drop` as an in-memory Dictionary at
all: `_set_active_item`/`_get_active_item` (bound to the two `JobQueue`
methods above, injected into `ToolDropToil` and `ToilExecutor` the same way
every other tool-item callable already is) replace every read/write of the
old field. `is_dropping()` is now `colonist.route != null and
_get_active_item.call(job_id) != "" and _get_active_item.call(job_id) ==
colonist.held_tool` -- structurally identical to round 4's version, just
reading a persisted marker instead of a volatile one. `advance()` sets the
marker at entry (idempotent while the leg is in flight) and clears it on
every completion path (grounded, stockpiled, or proven unreachable); `fail_
for_destroyed_tool()` clears it too. Because the marker is now simply part
of the job's own already-persisted state, **`seed_active_drop()` is deleted
outright, along with its `state_codec.gd` bootstrap call
(`_seed_active_drop()`) and its `ToolFetchToil.current_target()` dependency**:
a freshly restored `JobQueue` already carries whatever the marker's value was
at save time (`JobQueue.restore()` takes the exact persisted job list, `item_id`
included), so `ToilExecutor.is_dropping_leg()` (still used by
`_restore_reroutes()` to pick a cost function) reads the correct answer with
no bootstrap step at all -- there is no restore-time reconstruction left to
be inexact. All three round 5 cases above are closed by construction, not by
narrowing the window: cancellation only ever touches the *reservation*
(`needs_drop()`'s own input), never the marker; the fetch-reservation gap
never touches the marker either (only `ToolDropToil.advance()` writes it, and
a fetching colonist never calls that method for its own job); and an ordinary
`go_to` leg's job never has its marker set in the first place, so an
unrelated foreign reservation appearing mid-leg has nothing to flip.
`test_tool_items.gd`'s `_check_save_io_round_trip_after_requester_cancellation_midflight()`,
`_check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool()`
and `_check_save_io_round_trip_ordinary_route_after_held_tool_foreign_reserved_midflight()`
cover the three cases directly, each with a real `SaveIO` file round trip
compared tick by tick against an uninterrupted run through job completion;
`test_job_queue.gd`'s `_check_active_item_marker()` covers the mutator/getter
contract itself (queued/terminal no-ops, same-tick write visibility, and
survival through `restore()`) in isolation from the toil layer.

**This claim was wrong for the second case (round 6 review).** The version of
`_check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool()`
this round shipped with saved *before* the holder's drop completed at all,
never inside the release/re-reserve gap itself -- a save that early would
restore correctly even under round 4's own rejected in-memory `_active_drop`
marker, so it never actually exercised this case. The gap is real but brief:
`WorldState._advance_colonists()` sorts colonists by id (not array order)
within one external `tick()` call, so whichever colonist's id sorts *first*
runs its own turn before the other's release becomes visible to it, and does
not see that release until its *own* next turn, at the start of the following
external `tick()` call. The test now names the requester `"colonist_0"` (sorts
first) and the holder `"colonist_1"` (sorts second) specifically so the
holder's drop -- and the release it causes -- lands strictly after the
requester's own turn each tick, making the gap observable across a real
tick() boundary; it now asserts, before saving, that the requester's own
fetch route is still present and the axe's reservation is genuinely absent
(not merely reassigned), proving the save lands inside the gap rather than
before it.

**Round 6 review: the marker corrupts a haul job's own cargo identity --
`item_id` is the wrong field.** Round 5's justification above rested on "a
job kind is either `HAUL_KIND` or declares `needs_tool`, never both" -- true,
but irrelevant: `drop_tool`'s own insertion point (`ToilExecutor.advance()`,
see "drop_tool: the handover wait, resolved" above) is unconditional on job
kind. `ToolDropToil.needs_drop()` only asks whether `colonist.held_tool`
names an item reserved by some *other* job -- nothing about that check reads
or requires `needs_tool`. A colonist can arrive at a haul job's own toil
boundary (between its two `go_to` legs, where `route`/`work` are both null
exactly like any other boundary) still physically holding a leftover tool
from an earlier job that has since become foreign-reserved; `drop_tool` then
runs ahead of that haul job's own `pick_up`, and `set_active_item_marker()`
overwrote -- then, on completion, cleared to `""` -- the SAME job's own
`item_id` field, which `_tick_haul()` had already populated with the cargo's
own ground-item id at activation and `WorldState._toil_item_id_for()` reads
right back at `pick_up` time. The result: `pick_up` reads an empty or
wrong id immediately after the drop finishes, failing `item_not_found`
against a haul job that was carrying real, correctly-reserved cargo the
entire time.

The fix moves the marker to `blocking_job_id` instead of `item_id`.
`blocking_job_id` is the only other generic `String` field every job kind
already carries that is genuinely unused while a job is `"active"`:
`JobQueue` only ever writes it from `_block()`/`_set_reason()`, both of which
only ever run against a *queued* job (`tick()`'s per-job loop,
`set_labour_disabled()`), and activation itself resets it to `""`
(`_set_reason(job, "", "")` at every activation site) -- no code path reads or
writes it again until the job's next block/terminal transition, regardless of
kind. `set_active_item_marker()`/`get_active_item_marker()` (`job_queue.gd`)
now read/write `blocking_job_id`; `tool_drop_toil.gd`'s own doc comments are
updated to match. No schema change: `blockingJobId` was already part of every
job's wire encoding (`state_codec.gd`, `"blockingJobId"` in
`game-state.schema.json`, itself just `{"type": "string"}` with no pattern
constraint), already round-tripped through `SaveIO`.
`test_tool_items.gd`'s `_check_drop_tool_during_haul_job_preserves_cargo_identity_in_place()`,
`_check_drop_tool_during_haul_job_preserves_cargo_identity_via_stockpile()` and
`_check_save_io_round_trip_mid_drop_during_haul_job_preserves_cargo_and_completes()`
drive a real haul job through both drop shapes and a mid-drop `SaveIO` round
trip, asserting the cargo's own `itemId` (and, for the round trip, both of the
haul job's own `item:`/`cell:` `ReservationTable` entries) stay untouched on
every tick and the job still completes; `test_job_queue.gd`'s
`_check_active_item_marker()` is updated to assert against `blocking_job_id`
(and that `item_id` is never touched) instead.

**Round 4 review: `_find_drop_cell()`'s target-coincidence exclusions
removed.** With leg identification no longer based on the route's
destination at all, a chosen drop cell coinciding with (or landing adjacent
to) the job's own ordinary/fetch target is no longer ambiguous with any other
leg -- `_find_drop_cell()` no longer excludes the job's own ordinary target or
its neighbourhood at all (the `avoid` parameter round 2/3 added is removed
entirely): every free, passable, in-radius cell in a stockpile zone is now an
eligible destination, including the exact target tile itself when it happens
to be the nearest. `_check_drop_cell_coincident_with_impassable_ordinary_target_falls_back_to_ground()`
is renamed to
`_check_drop_cell_adjacent_to_impassable_ordinary_target_uses_nearest_stockpile_cell()`
and now expects the nearest free stockpile cell (the bush tile itself stays
excluded, but only by `_cell_still_free()`'s own ordinary passability check,
never by a special-cased exclusion); a new
`_check_drop_cell_exactly_on_passable_ordinary_target_is_used()` covers the
exact-coincidence case directly, with a single-cell zone that is itself the
job's own passable target.

## Destroyed-mid-job failure path (issue #266)

If the tool item a job is actively relying on -- reserved to it, whether
already physically held or `fetch_tool` is still travelling toward it -- is
removed from `WorldState`'s tool tracking while the job is active,
`ToolDropToil.active_tool_missing()` detects it the very next `advance()`
call. Round 1 only checked `colonist.held_tool` (`_held_tool_missing()`),
which missed a tool destroyed while `fetch_tool` was still travelling toward
it (reserved but not yet held): `ToolFetchToil.advance()` would find its own
`_reserved_tool_for()` scan come up empty (the destroyed item is gone from
the live tool-item list) and silently re-run `find_nearest_free_tool()`,
reserving a different, still-existing candidate instead of failing -- exactly
the "rescans and reserves a replacement while retaining the old route,
without failing and backing off" round 2 review finding.
`active_tool_missing()` instead reads the job's own currently-reserved item
id(s) straight off the `ReservationTable`'s own key set (`_reserved_item_ids_for()`,
via a newly injected `get_tool_reservation_table` callable -- already a
public `WorldState` method), not off the live item list: a destroyed item's
dangling reservation still shows up there even after the item itself is
erased, so this check runs *before* `ToolFetchToil.satisfied()`/`advance()`
ever gets a chance to rescan, whether the job is mid-fetch-travel, mid-return-
travel (already holding it), or mid-work. `active_tool_missing()` scans
*every* id job_id currently reserves, not just one (round 2 review of round
2: `_reserved_item_id_for()`'s original singular form returned whichever id a
Dictionary snapshot's iteration order happened to yield first, which is not
guaranteed to be the one that was actually destroyed -- a job can hold more
than one reservation at once, e.g. its own primary tool plus a second, not-
yet-picked-up one, and a surviving first match must never mask a destroyed
second one).

**Round 3 review:** `ToilExecutor.advance()` only ran this check *inside* the
`if TOIL_FETCH_TOOL in toils:` block, *after* `is_dropping()`'s own leg check
had already run and (possibly) dispatched `ToolDropToil.advance()` for the
tick. Destroying an in-flight fetch_tool target makes
`ToolFetchToil.current_target()` report null (the destroyed item is gone from
`_get_tool_items.call()`), which `is_dropping()` could misread as "not the
fetch leg, must be a drop" and let a whole extra drop leg play out --
including dropping an unrelated, surviving leftover tool the colonist also
happened to be holding -- before this check ever ran. `advance()` now runs
`active_tool_missing()` unconditionally first, before `is_dropping()` or any
other leg interpretation, so a destroyed active reservation always fails the
job the very next `advance()` call regardless of what the colonist's route
currently looks like.
`_check_destroyed_fetch_target_preserves_unrelated_held_tool()`'s geometry was
also corrected (the axe now sits far from the job's own target rather than
adjacent to it): the round 2 version's adjacency let `is_dropping()`'s
ordinary-target reach check mask this exact bug by accident, so it could not
have caught this regression.

`ToolDropToil.fail_for_destroyed_tool()` records the *actual* current toil in
the execution trace (`work`, `fetch_tool`, or the return-to-target `go_to` --
never hardcoded to `fetch_tool` as round 1 did) under a typed phase
(`"failed:tool_destroyed"`, distinguishing this failure from an ordinary
`blocked_no_tool` search exhaustion in the trace), releases **every**
reservation the job held via a newly injected `release_all_tool_reservations`
callable (`ToolItemStore.release_all`, already public) -- not just the one
destroyed item, fixing round 1's `_release_tool.call(held_id, job_id)`
single-item release that left any other reservation the same job happened to
hold dangling -- clears its route/work/tile work-progress, and re-queues it
through the *exact same* `on_no_tool_found` -> `GlobalAssignment.
requeue_assignment()` -> `JobQueue.block_no_tool()` path t1 already wired for
an ordinary fetch_tool failure -- no new terminal/failure path, no new
persisted state, reusing the generic release-on-terminal-transition discipline
`test_tool_items.gd`'s `_check_reservation_released_on_real_job_commands`
already proved. `colonist.held_tool` is cleared only when the *destroyed* item
is the one actually held (round 2 review of round 2): this round's first
version cleared it unconditionally, which desynced a colonist still
physically holding a *different*, surviving tool (its own item record
correctly still says `"held"` by that colonist) from a destroyed reservation
on some other item the job also held but had not yet picked up.
`test_tool_items.gd`'s
`_check_destroyed_tool_among_multiple_reservations_not_first_and_unrelated_held_tool_preserved()`
and `_check_destroyed_fetch_target_preserves_unrelated_held_tool()` cover the
multiple-reservation scan and the conditional `held_tool` clearing
respectively, the second with the destroyed item specifically *not* the one
held.

**Round 6 review:** two further gaps, both in the destroy path itself, plus one
in `tool_fetch_toil.gd`'s candidate selection surfaced by restoring the load
test's original invariant (below):

1. *Foreign-holder reconciliation.* `fail_for_destroyed_tool()` only ever
   cleared `held_tool` on `job_id`'s own colonist (the requester, `A`). When the
   destroyed item was still physically held by a *different*, busy colonist
   (`B`, case (b)'s handover holder), `A`'s own reservation released correctly,
   but `B`'s `held_tool` kept naming the now-erased id forever:
   `tool_item_store.gd`'s `set_ground()`/`set_held()` both refuse to touch a
   colonist's `held_tool` once the item itself is gone (there is no `location`
   left for their own `_clear_holder()` to read), so nothing else in the system
   was ever going to clear it. `_reconcile_stale_holders()` fixes this directly:
   given the destroyed id(s), it scans every colonist for a matching
   `held_tool` (not just `A`'s) and clears it there, using two newly injected
   callables (`find_colonist` -- a live lookup mirroring `world_state.gd`'s own
   private `_find_colonist()`, and `get_assignments` -- `WorldState.
   get_assignments()`, already public) rather than the item's own `location`
   (gone) or `job_id`'s own colonist (not necessarily `B`). If `B` was also
   mid-`is_dropping()` for that exact item (destruction during an in-flight
   drop leg, not just while idle-holding it), its dangling route and
   `blockingJobId` marker are cleared too (via `B`'s own `get_assignments()`
   entry), so `B`'s next `advance()` cannot misread the abandoned route as its
   ordinary `go_to` leg and arrive at the drop cell instead of its real target.
   `_check_destroyed_foreign_held_tool_while_waiting_reconciles_holder()` and
   `_check_destroyed_foreign_held_tool_mid_drop_reconciles_holder_route()`
   cover both cases, including proving the former holder can pick up a
   genuinely new tool (or complete a later job) afterward.
2. *Current-toil misclassification.* `fail_for_destroyed_tool()` used to derive
   the failed toil from `ToolFetchToil.needs()`, which necessarily reports
   "needs a replacement" the instant the destroyed item is gone -- misreporting
   the return-to-target `go_to` leg (the colonist had already picked the tool
   up before it was destroyed) as `fetch_tool`, and never reporting `drop_tool`
   at all. `_toil_in_flight()` now reads execution state instead: `work` first,
   then `is_dropping()` (the same marker/route/held_tool triple it always
   checks, independent of which reservation was destroyed), then whether the
   destroyed id is the one the colonist physically already held (`go_to`) or
   not (`fetch_tool`, still travelling toward it).
3. *A production cause, not a test exemption.* `test_movement_scheduling_load.
   gd`'s `_check_no_idle_while_work_available()` is restored to its exact
   pre-#266 form (a single continuous per-colonist streak, unconditional on
   assignment status, no handover carve-out) rather than the split assigned/
   unassigned populations rounds 3-5 introduced to tolerate a genuine handover
   wait. Restoring it surfaced a real, small (4-5 tick) violation: a freshly
   *assigned* job whose `fetch_tool` candidate search happened to land on a
   tool already held by a busy foreign colonist could start waiting on its very
   first tick of assignment, even while a farther but immediately *free* tool
   of the same kind sat unused elsewhere -- and the busy holder's own other job
   was exactly the "eligible work" this check exists to police. Fixed in
   `ToolFetchToil.advance()`: the nearest-match search now runs once excluding
   every tool currently held by a busy colonist, falling back to the
   unfiltered search (which can land on a busy-held candidate, as before) only
   when that first pass finds nothing. A genuine handover wait -- no free tool
   anywhere -- still occurs when it must (`_check_handover_wait_is_bounded_
   without_other_queued_work()` constructs one directly and still relies on
   `HANDOVER_WAIT_TICK_BOUND`); it just never arises in the load scenario's own
   geometry (10 tools shared by 3 colonists across 20 orders) once a free
   alternative is preferred, so the restored strict bound holds without any
   carve-out.

## Consequences

- `docs/architecture/core-budgets.json`'s existing caps are unchanged.
  `tool_matching.gd`, `tool_fetch_toil.gd` (the fetch_tool toil's own
  `needs()`/`satisfied()`/`advance()` state machine, including its own
  excluded-candidate bookkeeping), `tool_item_store.gd` (tool item CRUD
  plus their `ReservationTable`), `tool_drop_toil.gd` (issue #266: the
  drop_tool toil, the handover wait, and the destroyed-mid-job failure path)
  and `tool_handover.gd` (issue #266: the presentation-only
  `waiting_for_tool_handover` overlay on `WorldState.get_jobs()`) are the
  extractions that keep `toil_executor.gd`/`world_state.gd` within their
  existing budgets rather than requesting an increase, following the same
  "plain injected collaborator, no behaviour change" pattern throughout.
- `test_movement_scheduling_load.gd`'s `_check_no_idle_while_work_available()`
  keeps its original 3-tick idle-streak bound (round 2 review: round 1
  loosened it to 4 to paper over a regression instead of fixing it). The
  regression is gone once `drop_tool`'s own destination is computed once per
  leg instead of every tick (see "Destination consistency" above): a
  `drop_tool` leg's `colonist.route` is never left `null` on the same tick
  `advance()` dispatches it, so it was never actually observable as an idle
  tick by that test's own `route == null && work == null` definition --
  round 1's regression came from elsewhere in its own per-tick recomputation,
  not from `drop_tool` existing at all.

  **Round 6 review: "no idle while work available" and "a genuine handover
  wait may exceed 3 ticks" are two different invariants, and rounds 2-5 kept
  conflating them by exempting the second from the first's own check.** A
  colonist genuinely waiting for a handover already has an active assignment;
  it was never actually a candidate for the "eligible work nobody is even
  trying to run" complaint this check exists to catch, exempted or not, so it
  should never have been evaluated by that check's population at all. The
  fixed version splits the two populations for real: `idle_streaks` now only
  ever considers colonists with **no current assignment** (the only ones for
  which the complaint is meaningful), keeping the original, undiluted 3-tick
  bound with no handover carve-out whatsoever -- an unassigned colonist can
  never be mid-handover-wait, since that state requires an active assignment,
  so none is ever needed. A second, unconditional check
  (`assigned_stall_streaks`) covers every **assigned** colonist between toils
  (ordinary reassignment/route-evaluation lag, a `drop_tool` dispatch, or a
  genuine handover wait alike), running every tick regardless of whether
  eligible work exists elsewhere, so it can never be starved of coverage once
  other work runs out; it still uses the same origin predicate
  (`ToilExecutor.waiting_for_handover()`) to pick which of two bounds applies
  -- the strict 3 ticks for the ordinary case, or `HANDOVER_WAIT_TICK_BOUND`
  only for a confirmed wait -- but every tick, for every colonist, some bound
  is now actually enforced; nothing is exempted from having a bound at all.
  `_check_handover_wait_is_bounded_without_other_queued_work()` (same file)
  additionally proves the wait's own bound holds in an isolated, minimal
  scenario with at most two jobs ever queued at once, independent of
  `_has_eligible_queued_job()` finding anything else to point at, and drives
  the requester through the full lifecycle to the point where it is observed
  actually routing once the wait ends -- not merely no longer waiting.
  Round 4 review rejected an earlier draft's second exemption (a job whose
  assignment was present immediately before `tick()` and gone immediately
  after, meant to cover a job's own work finishing) as unnecessary and
  removed it: an ordinary completion tick was never actually idle by this
  test's own `route == null && work == null` definition once the regression
  above was fixed, so no second exemption was ever needed, and a blanket one
  would also have hidden a genuine stuck-while-assigned regression -- the
  round 6 fix keeps this property: the assigned-colonist check above still
  enforces the strict 3-tick bound for exactly that case, unconditionally.
- Every existing headless fixture that drives a dig/chop order to completion
  needs a reachable (or, where tick-exact timing leaves no room for travel,
  already-held) matching tool; fixtures updated under this change are listed
  in the handoff.
- A critical-need interrupt (`WorldState._interrupt_current_job()`) also
  releases the paused job's own tool reservation (`_tool_store.
  release_all(job_id)`), not just its target tile: previously a fetched tool
  stayed reserved to a job that was not currently advancing for as long as the
  interrupt lasted, unusable by any other colonist (round 3 review finding).
  The colonist keeps physically holding the tool through the interrupt;
  on resume, the "already held" fast path re-acquires the same tool for free
  if nothing claimed it meanwhile, or the toil falls through to `fetch_tool`
  again if something did -- no special-cased resume path needed.
- `WorldState._finish_job()` releases tool reservations only once the
  scheduler itself confirms the terminal transition actually took
  (`result["ok"]`), not before: a rejected `complete_job`/`cancel_job`/
  `fail_job` against a parked (`blocked_no_tool`) order must leave its
  reservations intact, or the order is left queued with a tool it can never
  re-acquire (round 4 review finding, still correct under round 5's redesign
  since `blocked_no_tool`'s recovery state is now ordinary `JobQueue`/
  `GlobalAssignment` state with the same "only touch it once the transition
  is confirmed" discipline).
- `ToolFetchToil._exclude_candidate()` does not re-enter `advance()` for the
  next candidate within the same tick (each candidate's own go_to search
  already spends a route-search attempt; chaining them would violate ADR
  004's per-tick routing bound independently of the shared-allowance fix
  above) -- the next candidate is picked up on the following tick instead.
- `WorldState._resume_paused_job()` does not start a route toward the job
  target or the work timer before confirming the job's tool is actually still
  satisfied (`ToilExecutor.needs_fetch_tool()`, read-only): a needs_tool job
  resuming from an interrupt whose tool was taken away while paused defers
  entirely to `ToilExecutor`'s own `fetch_tool` -> `go_to` -> `work` sequence
  instead of reusing a stale route/work state as fetch_tool's travel leg or
  resuming the work timer at the wrong location.
- `StateCodec.SCHEMA_VERSION` moves from 16 to 17 (see "Persistence"); the
  wire contract otherwise gains exactly one field (`toolFetchExcluded`) and
  `docs/architecture/contracts/game-state.schema.json`/
  `docs/architecture/save-system.md` are updated to match.
- `job_queue.gd` and `global_assignment.gd` stay within their existing
  `core-budgets.json` caps this round too: the tool-backoff early-exit
  (`ToolMatching.gate_backed_off()`) and the `suspend_assignment()`/
  `requeue_assignment()` shared reinsert (`ToolMatching.
  reinsert_activated_entry()`) both live in the same dependency-free
  `tool_matching.gd` extraction already used for `gate_check()`/
  `gate_force_backoff()`, rather than growing either scheduler file directly.
