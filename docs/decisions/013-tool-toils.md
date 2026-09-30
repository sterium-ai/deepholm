# ADR 013: Tool toils — fetch_tool and drop_tool

> **In short:** Digging and chopping need a tool. This decision describes how a
> colonist goes and gets the right tool, how it hands a tool over when another
> colonist needs it, and what happens when no tool is available or a tool is
> destroyed mid-job.

- **Status:** accepted
- **Date:** 2026-09-20
- **Scope:** `game/scripts/core/jobs/toil_executor.gd`, `game/scripts/core/jobs/tool_matching.gd`, `game/scripts/core/jobs/tool_fetch_toil.gd`, `game/scripts/core/jobs/tool_drop_toil.gd`, `game/scripts/core/jobs/tool_handover.gd`, `game/scripts/core/jobs/tool_item_store.gd`, `game/scripts/core/jobs/job_queue.gd`, `game/scripts/core/scheduling/global_assignment.gd`, `game/scripts/core/world_state.gd`, `game/scripts/core/persistence/state_codec.gd`, `game/scripts/core/persistence/save_io.gd`, `game/scripts/core/persistence/save_migrations.gd`, `game/content/jobs.json`
- **Implements:** docs/architecture/colonist-ai.md section 2 ("a tool stays in a colonist's hand... no reservation and no release step") and 3.3 ("jobs as toils"); docs/architecture/extension-points.md "Toil"; the tool-item data model and `needs_tool` cross-check; docs/decisions/004-global-assignment-fairness-policy.md (blocked_no_tool's aging/backoff and the shared routing allowance); ADR 009 (`suspend_assignment`/`resume_assignment`, plus the new sibling `requeue_assignment()`).

## Decision

Add two toils to `ToilExecutor.VOCABULARY`:

- `fetch_tool` — declared as the first toil of any job whose content entry has
  `needs_tool: <kind>`. Dig and chop declare
  `["fetch_tool", "reserve", "go_to", "work", "release_all"]`.
- `drop_tool` — never declared in `content/jobs.json`; `ToilExecutor.advance()`
  inserts it dynamically when a colonist holds a tool that another job has
  reserved (see "drop_tool and the tool handover").

A held tool's *reservation*, not its location, is the source of truth for who
may use it. Reservations live in a `ReservationTable` owned by
`tool_item_store.gd`.

### Module layout

The logic is split into small injected collaborators so that
`toil_executor.gd`, `world_state.gd`, `job_queue.gd` and
`global_assignment.gd` stay within their `core-budgets.json` caps without an
increase:

| File | Responsibility |
|---|---|
| `tool_matching.gd` | Pure, dependency-free lookup (`find_nearest_free_tool()`) plus shared scheduler helpers (`gate_backed_off()`, `gate_check()`, `gate_force_backoff()`, `reinsert_activated_entry()`). |
| `tool_fetch_toil.gd` | The fetch_tool state machine: `needs()`/`satisfied()`/`advance()`, candidate exclusion, and the read-only `current_target()`. |
| `tool_drop_toil.gd` | The drop_tool toil, the requester's handover wait, and the destroyed-mid-job failure path. |
| `tool_handover.gd` | A presentation-only `waiting_for_tool_handover` overlay applied by `WorldState.get_jobs()`. |
| `tool_item_store.gd` | Tool item CRUD and the tool `ReservationTable`, injected into `WorldState`. |

All are injected the same way `route_search_factory` is, as plain
collaborators with no behaviour of their own beyond what is described here.

## fetch_tool

Whenever `fetch_tool` is not yet satisfied — the colonist's `held_tool` does
not name a reserved item of the required kind — `advance()` routes to
`ToolFetchToil.advance()` instead of the ordinary go_to/work dispatch:

1. **Already held.** If `colonist.held_tool` names an item of the right kind,
   the toil acquires (or confirms it already owns) that item's reservation for
   the current job (`WorldState.reserve_tool_item()`). On success the toil is
   satisfied with no travel. A held item still reserved by a *different* job
   does not satisfy it: checking the kind without reserving would let two jobs
   use one tool.
2. **Found elsewhere.** `find_nearest_free_tool()` searches every tracked tool
   item — on the ground, in a stockpile, or held by another colonist but
   unreserved — for the nearest one of the required kind not excluded in this
   attempt, breaking ties by item id for determinism. The search first
   excludes tools currently held by a *busy* colonist and falls back to the
   unfiltered search only when that finds nothing (see "Candidate
   preference"). The toil reserves the result and travels to it through the
   ordinary go_to machinery: `advance_go_to()`/`advance_route_step()` take an
   optional `record_as`/`on_arrive` pair, so the same stepping and re-route
   code drives this leg, records it as `fetch_tool` in the execution trace,
   and calls a pickup callback (`WorldState.set_tool_item_held()`) on arrival.
   A colonist already holding a different tool drops it on the ground at
   arrival (`set_tool_item_held()` refuses a second tool).
3. **Unreachable candidate.** If a candidate's location resolves to nothing
   walkable or its route search proves it unreachable, the reservation is
   released, the item id is excluded for this fetch attempt, and the next
   candidate is tried on the following tick. Without this, a closer tool
   enclosed by walls would block the job forever even with a reachable tool
   further away. `_exclude_candidate()` deliberately does not re-enter
   `advance()` in the same tick: each candidate's search already spends the
   colonist's route allowance for the tick (ADR 004).
4. **Nowhere.** No candidate exists, or every candidate has been excluded. See
   "blocked_no_tool and the shared scheduler".

### Candidate preference

A freshly assigned job whose nearest candidate happens to be held by a busy
colonist would otherwise wait for a handover even while a farther, free tool
of the same kind sits unused. `ToolFetchToil.advance()` therefore runs the
nearest-match search once excluding every tool held by a busy colonist, and
only falls back to the unfiltered search (which may select a busy-held tool
and so start a handover wait) when that finds nothing. A handover wait still
happens when it must — no free tool anywhere — but not when a free
alternative exists.

## blocked_no_tool and the shared scheduler

When no tool can be fetched, the job goes back to the ordinary scheduler with
a backoff; there is no second, tool-specific scheduling lifecycle.

- `WorldState._toil_on_no_tool_found()` (the `on_no_tool_found` hook, fired
  once every known candidate proves unreachable or none exist) calls
  `GlobalAssignment.requeue_assignment(colonist_id, job_id)`. This releases
  the job's target reservation, returns it to "queued", and reinserts it into
  `_waiting` at its **original** aging position and with its **original**
  `restrict_to` (empty for an ordinary order, so any eligible colonist may take
  it).
- It then calls `JobQueue.block_no_tool(job_id)`, which applies the job kind's
  content-declared `retry_base_ticks`/`retry_cap_ticks` to the job's existing
  `retry_at`/`backoff_ticks` fields — the same fields `_tick_haul()` uses for
  `BLOCKED_DESTINATION_FULL` (a kind is either `HAUL_KIND` or declares
  `needs_tool`, never both, so they do not collide) — and sets reason
  `blocked_no_tool`, remedy `craft_or_find:<kind>`.
- While `_tick < retry_at`, `JobQueue.get_reservations()` reports the job's
  target as reserved, as it already does for `BLOCKED_DESTINATION_FULL`.
  `GlobalAssignment.tick()`'s pre-scoring "already reserved" check then
  refreshes the job every tick without routing or scoring it, so it cannot win
  a colonist's pick — and cannot starve a tool-free order — while backed off.
- `get_reservations()` runs before `JobQueue.tick()` increments `_tick`, so it
  reads the tick one step behind `tick()`'s per-job loop.
  `ToolMatching.gate_backed_off()` runs first in that loop (before the
  reservation-owner and reachability checks, mirroring `_tick_haul()`'s early
  return) and stays gated through `tick <= retry_at`. Otherwise, on the
  boundary tick, a stale reachability result would overwrite
  `blocked_no_tool` with `blocked_target_unreachable` for the whole backoff
  window.
- Independently, `JobQueue.set_tool_requirement(tool_requirement_of,
  tool_available)` gates ordinary activation on a matching tool existing
  *anywhere* (`WorldState._tool_exists()`, job-id-aware so a job that already
  reserved its own tool is not mistaken for proof that none exists). This is a
  cheap existence check, not a reachability check: an order submitted where no
  matching tool exists is blocked before it consumes a colonist or a
  route-search slot. The same gate re-checks, and on failure re-escalates the
  backoff, once a backoff elapses.

Both paths use the same `reason`/`remedy`/`retry_at`/`backoff_ticks` fields as
every other block reason, so labour eligibility
(`GlobalAssignment._is_labour_enabled()`), committed needs
(`_propose_committed_need()`), pending route batches (`_pending`) and ADR 004's
aging and cursor rotation apply to a blocked_no_tool job exactly as to any
other queued job.

The backoff is required, not optional. The job's own target is usually
reachable — the tool-fetch failure is invisible to `GlobalAssignment`'s
routing and scoring — so without a backoff its growing aging term would win
every scoring pass, reactivate the job, and fail the fetch again every cycle,
starving any tool-free order. The existence gate alone cannot see
reachability, which is why the reachability failure that fetch_tool discovers
drives the backoff directly through `block_no_tool()`.

### Ordinary fetch failure vs. critical-need interrupt

`GlobalAssignment.requeue_assignment(worker, job_id)` is a sibling of
`suspend_assignment()` (ADR 009's critical-need interrupt). Both perform
`clear_assignment()` + `queue.suspend(job_id)` + an aging-preserving `_waiting`
reinsert through the shared `ToolMatching.reinsert_activated_entry()`. They
differ in one respect:

- `suspend_assignment()` pins the reinserted entry's `restrict_to` to the
  interrupted colonist, because the interrupt's whole point is that the same
  colonist resumes the same job via `resume_assignment()`.
- `requeue_assignment()` passes `restrict_to = ""`, keeping the entry's
  original `restrict_to`. A fetch failure is an ordinary order whose current
  colonist failed a reachability search; it must return to the fair pool. If
  it were pinned and that colonist's labour were later disabled
  (colonist-ai.md 3.2), the order could never reactivate.

`_toil_on_no_tool_found()` calls `requeue_assignment()`;
`_interrupt_current_job()` keeps calling `suspend_assignment()`.
`test_tool_items.gd`'s
`_check_blocked_no_tool_failure_frees_job_for_a_different_colonist()` covers
this: colonist_0's fetch fails against a pick enclosed by rock, its "mine"
labour is disabled, and once a reachable pick appears colonist_1 completes the
same order.

## Shared per-colonist routing allowance

ADR 004 limits each colonist to one `RouteSearch.resume()` call per tick across
*all* route work, not just `GlobalAssignment`'s candidate search. Without
coordination, a colonist whose job the scheduler just activated could also
start and resume a fetch_tool search on the same tick, and a fetch-to-return
transition inside one `ToilExecutor.advance()` call (`_start_current_toil()`'s
go_to branch followed by `advance()`'s own `_continue_go_to()`) could resume
the same search twice.

`WorldState._route_budget` (`colonist_id -> bool`) is shared by reference
between `GlobalAssignment` (`set_route_budget()`) and `ToilExecutor`
(constructor parameter). `GlobalAssignment.tick()` clears it at the top of
every call (it always runs first within `WorldState.tick()`), and both its own
route-resume site and `ToilExecutor._resume_go_to_reroute()` check-and-set it
before calling `search.resume()`. The first resume in a tick wins; any later
request that tick leaves the search non-terminal and defers to the next tick.
`test_reroute.gd`'s
`_check_route_budget_shared_across_scheduler_fetch_and_return()` checks that no
search's `resume_calls` rises by more than one per external tick, against a
fixture that forces multi-batch searches in both the fetch and return legs.

## Persistence

**Fetch-leg route restore.** `_restore_reroutes()` (`state_codec.gd`) rebuilds
each in-flight search's cost callable with a target-tile passability
exception. For a fetch_tool leg the target is the tool's location, not the
job's. `ToilExecutor.needs_fetch_tool()` (read-only) tells `_restore_reroutes()`
that a search is a fetch leg; it then uses the persisted `snapshot["target"]`
— the exact tile `ToolFetchToil.advance()` baked into the cost callable when
the search began, already round-tripped by `_encode_route()`/`_decode_route()`.
Recomputing the tool's location from post-restore state would be wrong once a
held tool's holder has moved since the search began. Covered by
`test_reroute.gd`'s `_check_save_load_mid_fetch_tool_matches_uninterrupted_run()`
(stationary tool) and
`_check_save_io_round_trip_mid_fetch_tool_holder_moves_matches_uninterrupted_run()`
(a real `SaveIO` file round trip after the holder has moved).

**Excluded candidates.** `ToolFetchToil._excluded` (job id -> tool ids proven
unreachable in the current attempt) is persisted, since losing it on restore
would change subsequent ticks. `StateCodec.SCHEMA_VERSION` moves from 16 to
17: `get_excluded()`/`restore_excluded()` (plumbed through
`ToilExecutor.get_fetch_tool_excluded()`/`restore_fetch_tool_excluded()`)
round-trip through a new top-level `toolFetchExcluded` array of
`{jobId, toolIds}` entries, one per job with at least one exclusion.
`WorldState.state_hash()` includes it, so a save/load that drops or corrupts
the set diverges on the same tick. `SaveMigrations._migrate_v16_to_v17()`
backfills `toolFetchExcluded: []`, and `SaveIO._valid_tool_fetch_excluded()`
cross-checks every `toolId` against the save's `toolItems`, as
`toolReservations` already is. `test_tool_items.gd`'s
`_check_save_io_round_trip_after_candidate_excluded()` checks the restored set
and that the resumed run reaches the same final `state_hash()` at the same tick
as an uninterrupted run.

Drop-leg persistence is described under "Drop-leg identity marker" and
"Drop-leg route restore" below.

## drop_tool and the tool handover

A tool that fetch_tool finds held by another colonist but unreserved can be
reserved by the requesting job while the holder still physically carries it.
The two sides of that handover are handled as follows.

### Holder side

`ToilExecutor.advance()` inserts `drop_tool` ahead of whatever toil the
colonist's active job would run next whenever `colonist.held_tool` names an
item reserved by a different job (`ToolDropToil.needs_drop()`). Insertion only
happens at a toil boundary (`colonist.route` and `work` both null), so it runs
before the holder's **next dispatched job** and never interrupts an in-flight
leg. Insertion does not depend on job kind; it can precede a haul job's
`pick_up`, for example.

`ToolDropToil.advance()` drops the tool in place when no free stockpile cell
lies within `TOOL_DROP_RADIUS`, otherwise walks there first through the shared
`advance_go_to()` stepping (recorded as `drop_tool` in the trace). The
nearest-free-cell search (`_find_drop_cell()`) mirrors
`HaulGiver.find_free_haul_cell()`'s free/passable/occupied checks through
injected read-only callables (`get_zones`, `is_cell_free`, `get_tool_items`),
but picks the nearest cell within a bounded radius rather than the first free
cell in zone order. Every free, passable, in-radius stockpile cell is
eligible, including the job's own target tile when it is passable and nearest.

Dropping (`WorldState.set_tool_item_ground()`/`set_tool_item_stockpile()`)
releases whatever reservation the tool carries (colonist-ai.md 2), including
the requester's. This is intended: the requester's `fetch_tool` re-scans and
re-reserves the now-unheld item on its next `advance()`.

### Requester side: the handover wait

Before calling `ToolFetchToil.advance()`, `ToilExecutor.advance()` checks
`ToolDropToil.waiting_for_handover(colonist_id, job_id)`. It returns `{}`
unless the job's reserved tool is still `held` by a different colonist that is
currently **busy** (route or work in flight); in that case `advance()` returns
without starting travel that tick. `ToolFetchToil.advance()` also checks
`_held_by_busy_foreign()` itself immediately after acquiring a candidate and
before computing a target, so a tool reserved on this tick cannot be picked up
out of a busy holder's hand through `advance_go_to()`'s same-call pickup for
an already-adjacent target.

No persisted "waiting" state is needed. When the holder's drop completes, the
requester's reservation is released, `ToolFetchToil.satisfied()` becomes
false, and the ordinary find/reserve/travel sequence rediscovers the grounded
or stockpiled item. The wait is simply the ordinary not-yet-satisfied state,
prevented from starting a travel leg toward a tool that has not moved yet.

The busy condition matters. A fully **idle** holder has no assignment, so
`advance()` never runs for it and no `drop_tool` can be inserted; waiting on
it would strand the requester. An idle holder's reserved tool is therefore
picked up directly, as before.

**Stale route to a moved tool.** `advance_go_to()` does not re-target a
resolved route by itself. If a route started toward an idle holder's tool and
that holder later became busy and moved the tool through its own drop leg, the
requester would arrive to find nothing. `ToolFetchToil.advance()` compares a
*freshly (re)acquired* reservation's live target with the route's current
destination (`_route_effective_target()`, shared with `ToolDropToil`) and
discards a stale route so the next call searches toward the tool's actual
location. The check is limited to freshly acquired reservations: an
already-held reservation's target legitimately drifts while an idle holder
walks, and restarting the search every tick would thrash.

**Presentation overlay.** `waiting_for_handover()` also drives
`tool_handover.gd`, applied by `WorldState.get_jobs()` only (never
`_get_job()`, the lookup `ToilExecutor` uses for simulation decisions) to the
job's detached duplicate. While waiting, the job's `reason` reads
`waiting_for_tool_handover` and its existing `item_id`/`blocking_job_id`
fields name the reserved tool and the holder's current job id. No new state is
persisted.

### Destination consistency

`ToolDropToil.advance()` chooses the drop destination once, when the leg starts
(`colonist.route == null`). Later calls reuse the route's own destination
(`_route_effective_target()`: `route["rerouting"]["target"]` while a search is
in flight, `route["path"][-1]` once resolved — both already persisted).
Recomputing it every tick could retarget the arrival callback to a cell the
colonist never walked to.

On arrival, `_cell_still_free()` re-validates that destination: free,
passable, not occupied by a colonist, stackable item or another
ground/stockpiled tool (scanned through `get_tool_items()`, since the shared
`cell_occupied` callable only checks colonists and stackables), and still
inside some stockpile zone. If any check fails, the tool is dropped on the
ground where the colonist actually stands.

### Drop-leg identity marker

Which toil started an in-flight route is a fact about the route's history.
Reservation state cannot always reconstruct it, because other jobs'
reservations change for unrelated reasons (a requester is cancelled mid-drop; a
fetch reservation is briefly released between a holder's drop and the
requester's re-reserve; a held tool becomes foreign-reserved during an
ordinary go_to leg). So the identity is recorded explicitly and persisted:

- `JobQueue.set_active_item_marker(job_id, item_id)` writes directly into an
  *active* job's own record (a no-op on queued or terminal jobs).
  `JobQueue.get_active_item_marker(job_id)` re-reads the live record on every
  call, so a marker written earlier in the same tick is visible immediately —
  `ToilExecutor.advance()` calls `is_dropping()` both before and after
  dispatching `ToolDropToil.advance()` in one call.
- The marker is stored in the job's `blocking_job_id` field. That field is
  unused while a job is active, for every job kind: `JobQueue` writes it only
  from `_block()`/`_set_reason()` on queued jobs, and activation resets it to
  `""`. It must not be `item_id`, because `drop_tool` can run ahead of a haul
  job's `pick_up`, and `item_id` is haul's cargo id, read back by
  `WorldState._toil_item_id_for()`.
- `ToolDropToil.advance()` sets the marker on entry (idempotent while the leg
  is in flight) and clears it on every completion path (grounded, stockpiled,
  unreachable); `fail_for_destroyed_tool()` clears it too.
- `is_dropping()` is `colonist.route != null` and the marker is non-empty and
  equals `colonist.held_tool`. It performs no reservation lookup and no
  position comparison. `needs_drop()` remains reservation-based: it decides
  whether to *start* a drop; `is_dropping()` only asks whether one is in
  progress.

`blockingJobId` is already part of every job's wire encoding
(`state_codec.gd`, `game-state.schema.json`), so the marker needs no schema
change and no restore-time reconstruction: `JobQueue.restore()` brings it back
with the job.

Tests in `test_tool_items.gd`:
`_check_save_io_round_trip_after_requester_cancellation_midflight()`,
`_check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool()`
and `_check_save_io_round_trip_ordinary_route_after_held_tool_foreign_reserved_midflight()`
each compare a real `SaveIO` round trip tick by tick against an uninterrupted
run. The release-gap test names the requester `colonist_0` and the holder
`colonist_1`: `WorldState._advance_colonists()` processes colonists in id
order, so the holder's release lands after the requester's turn and the gap
spans a real tick boundary; the test asserts it is inside that gap before
saving. `_check_drop_tool_during_haul_job_preserves_cargo_identity_in_place()`,
`_check_drop_tool_during_haul_job_preserves_cargo_identity_via_stockpile()` and
`_check_save_io_round_trip_mid_drop_during_haul_job_preserves_cargo_and_completes()`
check that a haul job's cargo `itemId` and its `item:`/`cell:` reservations are
untouched. `test_job_queue.gd`'s `_check_active_item_marker()` covers the
marker API in isolation.

### Drop-leg route restore

The live `ToolDropToil.advance()` always searches with plain passability.
`ToilExecutor.is_dropping_leg()` (a passthrough to `is_dropping()`) lets
`_restore_reroutes()` choose plain passability for a restored drop leg too,
before the fetch_tool and ordinary-target branches. Otherwise a drop leg whose
job does not need a tool would get the ordinary-target exception, and an
impassable job target lying between the holder and its stockpile cell would
become a shortcut that the live search never has.
`_check_save_io_round_trip_mid_drop_tool_search_impassable_target_between_holder_and_stockpile()`
covers this with a full-width wall whose only "opening" is the job's target,
comparing `state_hash()` tick by tick.
`_check_save_io_round_trip_mid_drop_tool_movement_matches_uninterrupted_run()`
and `_check_save_io_round_trip_mid_drop_tool_route_search_matches_uninterrupted_run()`
cover saves taken mid-movement and mid-search.

## Destroyed-mid-job failure path

If a tool item reserved to an active job — already held, or still being
travelled to — is removed from tool tracking, `ToolDropToil.active_tool_missing()`
detects it on the next `advance()` call. It reads every item id the job
currently reserves from the `ReservationTable`'s key set
(`_reserved_item_ids_for()`, through an injected
`get_tool_reservation_table` callable), not from the live item list: a
destroyed item's dangling reservation is still there after the item is gone.
Scanning *every* reserved id matters because a job can hold more than one
reservation (its current tool plus one not yet picked up).

`ToilExecutor.advance()` runs `active_tool_missing()` first, before
`is_dropping()` or any other leg interpretation, so `ToolFetchToil` never gets
a chance to silently reserve a replacement and a destroyed reservation always
fails the job on the next call.

`ToolDropToil.fail_for_destroyed_tool()` then:

- records the toil actually in flight in the execution trace under phase
  `"failed:tool_destroyed"` (distinct from ordinary `blocked_no_tool`
  exhaustion). `_toil_in_flight()` reads execution state: `work` first, then
  `is_dropping()`, then `go_to` if the destroyed id was the one physically
  held, else `fetch_tool`;
- releases **every** tool reservation the job holds
  (`release_all_tool_reservations`, i.e. `ToolItemStore.release_all`);
- clears the job's route, work and tile work progress, and re-queues it
  through the same `on_no_tool_found` -> `requeue_assignment()` ->
  `block_no_tool()` path as an ordinary fetch failure — no new terminal path
  and no new persisted state;
- clears `colonist.held_tool` only if the destroyed item is the one held, so a
  surviving, unrelated held tool stays consistent with its own item record;
- reconciles other holders (`_reconcile_stale_holders()`): the destroyed item
  may still be held by a *different* colonist (the handover holder), whose
  `held_tool` nothing else would clear, because `tool_item_store.gd`'s
  `set_ground()`/`set_held()` cannot touch a holder once the item's location
  is gone. It scans every colonist (through injected `find_colonist` and
  `get_assignments` callables) and clears a matching `held_tool`; if that
  holder was mid-drop for the same item, its route and marker are cleared too,
  so its next `advance()` does not treat the abandoned route as an ordinary
  go_to leg.

Tests in `test_tool_items.gd`:
`_check_destroyed_tool_among_multiple_reservations_not_first_and_unrelated_held_tool_preserved()`,
`_check_destroyed_fetch_target_preserves_unrelated_held_tool()` (the axe sits
far from the job target so no other check can mask the ordering),
`_check_destroyed_foreign_held_tool_while_waiting_reconciles_holder()` and
`_check_destroyed_foreign_held_tool_mid_drop_reconciles_holder_route()`.

## Consequences

- `core-budgets.json` caps are unchanged; the collaborators listed under
  "Module layout" absorb the new logic.
- `test_movement_scheduling_load.gd`'s `_check_no_idle_while_work_available()`
  keeps a single per-colonist idle streak with a strict 3-tick bound and no
  handover exemption. It holds because "Candidate preference" avoids needless
  waits in the load scenario (10 tools, 3 colonists, 20 orders) and a
  `drop_tool` leg's route is never null on the tick it is dispatched.
  `_check_handover_wait_is_bounded_without_other_queued_work()` constructs a
  genuine handover wait in isolation (at most two jobs queued), bounds it by
  `HANDOVER_WAIT_TICK_BOUND` (derived from the scenario's geometry, work
  duration and `TOOL_DROP_RADIUS`), and checks the requester actually starts
  routing once the wait ends.
- Headless fixtures that drive a dig/chop order to completion need a
  reachable matching tool, or an already-held one where tick-exact timing
  leaves no room for travel.
- A critical-need interrupt (`WorldState._interrupt_current_job()`) releases
  the paused job's tool reservation (`_tool_store.release_all(job_id)`) as well
  as its target tile, so the tool is not locked away for the length of the
  interrupt. The colonist keeps holding it; on resume the "already held" path
  re-acquires it if nothing else claimed it, otherwise fetch_tool runs again.
- `WorldState._resume_paused_job()` checks `ToilExecutor.needs_fetch_tool()`
  before restarting a route or work timer, deferring to the ordinary
  fetch_tool -> go_to -> work sequence if the tool was taken while paused.
- `WorldState._finish_job()` releases tool reservations only after the
  scheduler confirms the terminal transition (`result["ok"]`). A rejected
  `complete_job`/`cancel_job`/`fail_job` against a blocked_no_tool order must
  leave its reservations intact.
- `StateCodec.SCHEMA_VERSION` moves from 16 to 17; the wire contract gains one
  field, `toolFetchExcluded`, and
  `docs/architecture/contracts/game-state.schema.json` and
  `docs/architecture/save-system.md` are updated to match.

## Revision notes

The design went through several corrections before acceptance:

- **blocked_no_tool recovery.** Early versions failed the job and resubmitted a
  replacement (breaking `cancel_job` on the original id and resetting its
  aging), then parked it in a separate tracker outside `GlobalAssignment`
  (bypassing labour eligibility, aging and backoff). Both were replaced by the
  requeue-plus-backoff design above. Reusing `suspend_assignment()` directly
  was also rejected because it pins the order to the failing colonist.
- **Drop-leg identification.** An unpersisted route flag was lost on save;
  position-based comparisons against the job and fetch targets misclassified
  legs whose destinations were trimmed or drifting; an in-memory marker
  re-seeded from reservation state on restore was not equivalent to the live
  one; and storing the persisted marker in `item_id` corrupted haul cargo. The
  final design persists the marker in `blocking_job_id`. With identity no
  longer position-based, `_find_drop_cell()`'s special-case exclusions around
  the job's target were removed.
- **Handover wait.** The first version picked the tool out of the busy holder's
  hand on arrival, so no wait happened; the busy-holder gate and stale-route
  discard were added.
- **Load-test invariant.** Intermediate versions exempted handover waits from
  the 3-tick idle bound. The exemption was removed once candidate preference
  fixed the underlying cause, and the handover bound is tested separately.
