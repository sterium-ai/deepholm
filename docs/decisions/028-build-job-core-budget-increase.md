# ADR 028: The `build` job kind raises core budgets

> **In short:** Colonists can now build walls, doors and beds: they fetch wood from a stockpile,
> carry it to the building spot, work for a while, and the object appears. Orders are checked so
> they never trap anyone inside walls, and interrupted or saved builds pick up where they left off.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** a new `build` job kind (`content/jobs.json`), a `build_cost` field on buildable
  `content/objects.json` entries (`content/schemas/objects.schema.json`), a `build {kind, x, y}`
  command in `game/scripts/core/world_state.gd`, a Build toolbar tool
  (`game/scripts/boot.gd`, `game/scripts/viewer/map_view.gd`), a correction to
  `game/scripts/core/jobs/toil_executor.gd`'s per-leg arrival dispatch, `build`'s activation and
  reactivation reservation lifecycle in `game/scripts/core/jobs/job_queue.gd`, persistence of its
  site/kind fields in `game/scripts/core/persistence/state_codec.gd` (validated by
  `game/scripts/core/persistence/save_io.gd`), `build_cost.item` reference validation in
  `game/scripts/core/content/content_registry.gd`, and `docs/architecture/core-budgets.json`'s
  caps for the three touched core files.

## Context

Together with combat ([ADR 021](021-combat-resolution.md)), `build` is one of the two new core
additions allowed by the F5 regions/rooms/incidents foundation work
(`docs/architecture/foundation-for-breadth.md`). It must reuse the existing fixed toil vocabulary.

## Decision

`content/jobs.json`'s `build` entry declares `["reserve", "go_to", "pick_up", "go_to", "work",
"release_all"]`, a strict subset of `{reserve, go_to, pick_up, place, work, release_all}`: haul's
shape with `work` in place of `place`. No new verb is added to `toil_executor.gd`; its existing
dispatch is corrected so a haul-then-work shape composes.

### Per-leg arrival dispatch in the toil executor

`toil_executor.gd`'s generic `advance()` chose its per-tick dispatch branch by whether `"work"`
appears anywhere in a job kind's toils, and every `go_to` arrival in such a kind used the same
default (`on_arrive` unset -> `start_work()`). That was harmless for `dig`/`chop`/`mine`/`till`/
`sow`/`sleep` (one `go_to`, always leading into `work`) and for haul (no `work_ticks`, so the call
was a no-op), but for `[go_to, pick_up, go_to, work]` it would start work the instant the colonist
reached the wood, before `pick_up` ran.

`ToilExecutor._arrival_hook()`/`_next_toil_after_go_to()` now look at the toil that actually
follows the current `go_to` leg in the declared array (mirroring `_next_toil_index()`'s
occurrence reasoning) and pass an explicit no-op `on_arrive` when it is `pick_up`, leaving that
leg's arrival to the ordinary dispatch on the next tick. `ToilExecutor.leads_into_work()` (a
read-only passthrough of the same check) and `WorldState._resume_paused_job()`/
`_advance_go_to_or_resubmit()` use the same rule, since they previously decided whether to call
`start_work()` from "does this kind have a work toil anywhere".

Which leg the colonist is on is decided by the current job's own toils
(`ToilExecutor._is_first_leg(toils, colonist)`): always the first leg for a kind with no `pick_up`
toil, and otherwise by whether the colonist is carrying. Deciding it from the carrying flag alone
was wrong for single-leg kinds (`sleep`, `flee`, `dig`, `chop`, `forage`, `till`, `sow`,
`incident`, `escape_trench`): a colonist interrupted mid-haul or mid-build keeps its cargo through
the interrupting job (ADR 009), so a `sleep` or `flee` job was misread as "second leg", took the
no-op arrival and never started its work timer. `test_haul_need_interrupt.gd`, `test_build.gd` and
`test_combat.gd` cover rest and flee interrupts while carrying.

### Work target and delivery

`work`'s progress key (`WorldState._work_progress`, tile-keyed, ADR 009) is normally a job's
`target` tile, but `build`'s `target` names the wood item's tile, not the site (see "Two
targets"). `ToilExecutor`'s injected `work_target_for` callable (`WorldState._work_target_for()`)
resolves the correct tile everywhere a work-progress key is read or cleared (`start_work()`,
`advance_work_step()`, `_toil_on_work_complete()`, `_trap_actor()`, `_apply_job_command()`'s
terminal cleanup).

`build` never drives a `place` toil. The wood stays carried (`InventoryType`) through the second
leg and the timed work phase, and `_toil_on_work_complete()`'s `"build"` case consumes it and calls
`_set_object()`, the same "work produces an effect" shape `dig`/`chop`/`mine`/`till`/`sow` use.

### Two targets on one job

`build` has two destinations: the wood item's tile (first leg) and the build site (second leg,
exclusively reserved). The job dict carries native `site` and `build_kind` fields, like haul's
`cell` field, rather than a `WorldState` side table. `job["target"]` still names the item's tile
(mirroring haul's `target`/`cell` split, so `JobQueue._can_reach(job["target"])` works unchanged);
`JobQueue.attach_build()`, called once at submission alongside `attach_item()`, records the site and
kind.

### Reservations are acquired on activation

Both reservations are acquired only on the `queued -> active` transition, by
`JobQueue._tick_build()` (haul's two-reservation shape from `_tick_haul()`, without a destination
search since the site is fixed at submission). `JobQueue._reactivate_build()` mirrors
`_reactivate_haul()` for suspend/resume. Both keys release together through `JobQueue._finish()`'s
`release_all(job_id)`. Acquiring them at submission instead would break
`ReservationInvariants.find_orphaned_reservations()`'s active-owner requirement for as long as the
job sat queued, and `JobQueue.suspend()`/`reactivate()` (which act only on active jobs) could not
release and reacquire them. The site reservation uses `JobQueue.TARGET_KEY_PREFIX` (`"tile:"`), so
it contends with any other job kind on the same tile through the one ledger.

### The builder works from an adjacent tile

A build site is still passable while the builder travels, so the ordinary go_to trim rule (drop
the path's last tile only when the target is impassable now) never fires, and the builder would
stand on the tile about to become an object. The `go_to_force_trim_last` hook
(`WorldState._toil_go_to_force_trim_last()`, `ToilExecutor.advance_go_to()`'s `force_trim_last`
parameter) forces the trim for every build kind, landing the builder adjacent like `chop`/
`forage`. A builder already standing on the site has nothing to trim; `advance_go_to()`'s step-off
rule re-aims the same leg at the first passable orthogonal neighbour (north, west, east, south, the
order `_dig_item_placement()` uses), so no builder works while standing on the site.

### Completion re-validates everything submission checked

`_build_completion_failure()` runs at the work-complete boundary before anything is placed: the
site must still be free of objects *and of every actor* (a passer-by on the site fails the build
rather than being walled in), an impassable kind must still not enclose anything, and the builder
must still carry at least the declared quantity of the declared item. A refusal fails the job typed
(`invalid_target`, `blocked_target_unreachable`, `blocked_missing_input`) through the same
cargo-dropping terminal path an unreachable second leg uses, so the wood is conserved on the ground
and both keys release.

`_consume_build_cost()` subtracts exactly `build_cost.quantity` from the carried stack; any
remainder goes back to the ground through the usual deposit path (`place()` onto the builder's
tile), never destroyed with the rest of the stack.

### Pending orders are commitments

A queued build holds no reservation yet, but its item and site are committed:
`_find_available_build_item()` skips every item a queued or active build names, and
`_check_build_command()` refuses a site any pending build already claims (`_pending_build_jobs()`),
so several orders in one tick pick distinct wood and never share a site.

### Enclosure check

`_would_enclose()` runs when the target kind's object definition is impassable (`wall`; `door` and
`bed` never trigger it). For each colony component it compares a 4-connected flood fill of
`passable("colony")` tiles from one actor of that component with and without the candidate tile.
Every pending impassable build site already counts as blocked (the second of two walls ordered into
a room's two openings is refused). Every colony actor's component is examined: actors in an
already-visited component are skipped, and one standing on an impassable tile anchors nothing, so
a trapped or disconnected actor never hides an enclosure elsewhere. The check runs again at
completion, since topology can change while the wood is on its way. Rejection is always
`blocked_target_unreachable`. An impassable site tile (rock, water, trench) is rejected
`invalid_target` at submission.

### Preview

`WorldState.preview()` routes `build` to the same `_check_build_command()` `apply()` uses
(including the stock check), so hover colouring and the click never disagree. `boot.gd`'s
`_command_for_tile()` builds the real command for the three Build tools, and its Cancel tool
resolves a build by its construction site (`_order_tile()`), not the wood tile.
`MapView._current_preview_key()` includes `world.get_tick()`, and a successful `build` command does
not advance the tick, so while paused the cached preview would keep the pre-claim colour;
`MapView._commit_build()` clears `_preview_cache_key` after applying the command.

### Persistence

`site`/`build_kind` round-trip through `state_codec.gd`'s `_encode_jobs()`/`_decode_jobs()` like
`itemId`/`cell`, and are covered by `state_hash()`'s `"jobs"` entry (`get_jobs()` returns the full
job dict), so an in-flight wall order and bed order at the same tick hash differently, and a
save/load at any phase (queued, hauling, carrying, mid-search, working) preserves both.
`_restore_reroutes()` rebuilds a carrying build's second-leg search against `job.site`, with the
same site-tile exception live execution uses. In the canonical schema and `save_io.gd`'s validator
both fields are optional on a job (a same-version save from before `build` existed still loads,
with `StateCodec` defaulting them to `null`/`""`) but mandatory and well-formed on every `build`
job. No schema-version bump.

### Work-progress ownership

`_work_progress_owner` records which job owns each `_work_progress` tile key. It is persisted
directly as the optional top-level `workProgressOwners` field, an array of `{target, jobId}`
(`_encode_work_progress_owners()`/`_decode_work_progress_owners()`, `workProgressOwnerEntry` in
`game-state.schema.json`, `SaveIO._valid_work_progress_owners()`), mirroring `pausedJobs`. Like
`digFindRng` and `combatBlockedTargets` it is optional on the wire and needs no migration.
Deriving the owner after load from "which non-terminal job targets this key" was wrong: two jobs of
different kinds can legitimately target the same tile (a `dig` may be queued on a site a `build` is
working, because reservations are acquired on activation), and a load in that window could hand
the build's progress to the dig.

`WorldState._restore_work_progress_owners()` trusts each persisted job id, cross-checked against the
restored job list (the job must exist, be `queued`/`active`, and be a kind that ticks work). For a
save from before the field existed, `_reconstruct_work_progress_owners()` recovers owners from
execution state the format has always carried (each colonist's `work.job_id`, and `_paused_jobs`
for a job a need interrupt suspended mid-work), never from which job merely targets the key. Any
`_work_progress` key still without an owner is then pruned, except an active incident's
job-id-less wait, so an unowned timer cannot leak into a later job at the same tile.

### Suspended jobs keep their own progress

JobQueue releases a suspended job's reservations, so a different job can activate on the same tile
while the first is suspended. If both shared the tile-keyed cache, the second job would inherit the
first's leftover ticks, overwrite them, and erase them on completion. Therefore:

- `_suspend_work_progress(work)` moves a job's in-progress timer out of the shared cache into the
  job-id-keyed `_suspended_work_progress` whenever its colonist's `work` is cleared for a
  non-terminal reason (a critical-need interrupt, or `_advance_colonists()`'s per-tick
  reconciliation). An incident's job-id-less stamp is excluded.
- `_resume_work_progress(target, job_id)`, the `work_progress_get` hook `ToilExecutor.start_work()`
  calls, reads by job. `_get_work_progress()` stays tile-only, which is what `escape_trench`'s
  "has anything been stamped here" check needs.
- `_suspended_work_progress` is persisted as the optional `suspendedWorkProgress` field, included in
  `state_hash()`, and cleared by the `_release_owned_work_progress()` terminal boundary.

`docs/architecture/orders-and-movement.md` and `docs/architecture/save-system.md` describe the
persisted shape. `test_build.gd` covers both orders (a suspended build then an activating till, and
the reverse) with a second colonist and a save/load mid-overlap.

### Cargo is conserved when a resume is refused

Terminal cargo cleanup for a job suspended by a critical-need interrupt finds the carrier through
`_paused_jobs` (`_drop_carried_haul_item()`), for `haul` and `build` alike, and deposits the cargo
without touching the route or work the need job owns. A resumption refused by the faction gate
(`_resolve_refused_reservations()`) drops a build's cargo the same way it drops a haul's.

A resumption can also be refused because a rival job claimed the build's site while it was
suspended: `JobQueue.reactivate()` returns `false` and `resume_assignment()` leaves the job
`"queued"` with no assignment. `WorldState._resume_interrupted_job()` checks the job's status after
`resume_assignment()`; if it is not `"active"` and the job is a `haul`/`build` whose colonist still
carries its cargo, the `_paused_jobs` association is restored, so a later terminal command can
still find the carrier and drop the wood. A non-carrying job falls to the ordinary fair-queue path.
`test_build.gd`'s `_check_blocked_resume_after_rival_claims_site_conserves_cargo()` reproduces the
race with a real critical-need interrupt and a rival `till` order, and proves the blocked state
survives save/load and can be cancelled with the cargo conserved exactly once.

### `build_cost.item` joins content reference validation

`ContentRegistry._check_references()` walks every `objects.json` entry's optional
`build_cost.item` like a job's `needs_tool`: an id absent from `items.json` fails construction
typed `dangling_reference`, naming `objects.json` and the id, instead of surfacing later as a
runtime `blocked_missing_input`. `test_content_registry.gd` asserts every real `build_cost.item`
resolves and adds a dangling-reference fixture. The check exposed a real gap: `content/items.json`
never declared `"wood"`, the id every buildable object names. It now declares
`{"id": "wood", "kind": "material"}` alongside `stone`/`sand`/`flint`/`coal`.

### Core budgets

The caps for `world_state.gd` (2774 before this change), `toil_executor.gd` and `job_queue.gd` are
each set to the file's exact post-change line count, per the convention of ADRs 015-017, 023, 025
and 027.

## Consequences

- The toil vocabulary grows by zero verbs; `build` is a recombination of
  `reserve`/`go_to`/`pick_up`/`work`/`release_all`.
- `_apply_build_submission()` resolves the wood item once, at submission. Unlike haul's per-tick
  retry in `_tick_haul()`, a `build` command with no available stockpiled item of the declared kind
  and quantity is rejected outright (`blocked_missing_input`); the player re-issues the order once
  the stockpile is restocked. Retry-with-backoff for `build` would need its own job-giver module.
- `build_cost.quantity` is honoured exactly (a stack of three wood loses one for a wall costing
  one), but ground items never merge same-kind stacks at spawn, so every buildable kind declares
  quantity 1 today; a single `pick_up` carries one whole stack.
- A site's reachability from the colony is not checked at submission (only bounds, passability,
  occupancy, pending claims and enclosure are). An unreachable site's job later fails typed
  `blocked_target_unreachable` when its second-leg route search proves it unreachable
  (`_toil_on_unreachable()`'s `"build"` branch), like a haul whose second leg is unreachable.
- A transient occupant on the site at the completion tick fails the build (typed, cargo conserved)
  rather than waiting; the player re-issues the order.

## Known limitations

- `game/scripts/viewer/designation_overlay.gd` draws a pending order at `job.target`, which for a
  build is the wood tile, not the construction site; the toolbar's Cancel tool already resolves the
  site correctly. Cosmetic; the overlay should read the site the way `boot.gd`'s `_order_tile()`
  does.
- The Build tool's toolbar labels are hardcoded English rather than read from
  `game/data/text/en.json`, like the New Game/Debug Scenario buttons before it.

## Revision notes

An earlier version ended `build` with `place` (no timed work phase) and acquired both reservations
at submission, because the toil executor's arrival dispatch could not yet tell a build's two
`go_to` legs apart. Correcting that dispatch allowed the design above.
