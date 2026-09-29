# ADR 009: Critical-need interrupt suspend/resume releases the paused job's reservation

- Status: accepted task contract for #241 (review round 1)
- Date: 2026-09-19
- Extends [ADR 004](004-global-assignment-fairness-policy.md) (aging/fairness formula, unchanged
  here) and colonist-ai.md §3.6 (interrupt semantics).

## Context

colonist-ai.md §3.6 requires a critical need to interrupt a colonist's in-progress `work` toil
immediately: the interrupted job "goes back to the queue with its aging preserved (it does not
lose its place)" and resumes rather than restarts once the colonist is free again. Issue #241
moved this decision (and eat_food/drink_water/sleep submission) out of `WorldState` and into
`NeedGiver`, a job-giver module, submitting through the same `GlobalAssignment.submit()` entry
point any order-driven job uses (AGENTS.md "one work engine").

The first implementation of the interrupt added `GlobalAssignment.suspend_assignment()`/
`resume_assignment()`: `suspend_assignment()` cleared the interrupted worker's own
`_assignments` entry and reinserted the job's original waiting-queue entry (captured at
activation) back into `_waiting` at its exact aging/ordinal position, but left the job's own
`JobQueue` record "active" and its target reservation held. `resume_assignment()` later
restored the worker/job pairing directly.

Review round 1 flagged this: colonist-ai.md §3.4 treats a reservation as belonging to a job that
is actually in progress ("reservations are released when the job ends for any reason"); leaving
it held for the entire duration of an unrelated need job means the target tile is unavailable to
any other legitimate job for as long as the colonist is away eating/drinking/sleeping, with no
bound on how long that takes (a distant source, a long search, a backoff cycle).

## Decision

`JobQueue` gains two small, generic primitives, symmetric with its existing `cancel`/`fail`/
`complete` terminal transitions but not terminal themselves:

- `suspend(job_id)`: transitions an "active" job back to "queued" and releases its reservation
  (`ReservationTable.release_all`), exactly as if the job had just been blocked. The job's
  target, kind, priority and id are untouched.
- `reactivate(job_id)`: transitions a "queued" job back to "active" by ownership check alone
  (not a full reachability re-check -- reachability was already proven when the job first
  activated, and re-running a bounded route search is outside `JobQueue`'s own remit). Returns
  `true` and reacquires the reservation when the target is still free; returns `false` and
  leaves the job queued when something else has since claimed it.

`GlobalAssignment.suspend_assignment(worker, job_id)` now calls `queue.suspend(job_id)` in
addition to its existing `clear_assignment()` + waiting-queue reinsertion. The reinserted entry
sets `restrict_to = worker` (the same per-entry field `submit()` already supports for need jobs,
reused here rather than invented fresh): the released reservation lets a genuinely different job
claim the same target while the colonist is away, but `restrict_to` prevents a different
*worker* from being competitively offered this exact job out from under the colonist that will
resume it.

`GlobalAssignment.resume_assignment(worker, job_id)` now calls `queue.reactivate(job_id)` first;
only on success does it remove the waiting entry and call `set_assignment()`. On failure (the
target was claimed by something else in the interim), it is a no-op: the job stays queued and
restricted to `worker`, and the ordinary fair-queue path decides its fate from there -- the
"colonist is reassigned" language in colonist-ai.md's own increment-D notes already allows this.

`WorldState._resume_paused_job()` accepts the paused job in either "active" or "queued" status
(previously "active" only): it may run before `resume_assignment()` has reactivated the job for
this same tick, since it derives the job's `target` for routing/work purposes only, not its
scheduling state.

`NeedGiver._resubmit_unreachable_job()`'s pre-existing "cancel and resubmit a fresh id" path for
an unreachable go_to target is extended the same way: the replacement job is submitted with
`restrict_to` set to the originating colonist (`NeedGiver.colonist_for_job()`), and the
ownership association is carried over to the new id (`NeedGiver.reassign_job()`) instead of
being dropped via `resolve_job()`, which would let the fair scheduler hand the replacement to a
different colonist while telling the original one its need was already satisfied.

## Consequences

- The rare race (a different job claims the interrupted job's target while its colonist is away)
  is now possible and handled explicitly: `reactivate()` fails, the job stays in the fair queue
  under its original aging, and `_resume_interrupted_job()`'s one-tick-visible cosmetic gap
  (colonist.route/work briefly names a job with no live scheduler assignment, cleared by the next
  `_advance_colonists()` pass) is accepted as a bounded, self-correcting artifact rather than
  engineered away with additional cross-layer state.
- No schema version bump: `suspend`/`reactivate` only toggle the existing `status` enum value
  between two values ("active"/"queued") already present in the schema, and `restrict_to` on a
  waiting entry was already a persisted field (schemaVersion 14, #241 t1/t2).
- `game/scripts/tests/test_movement_and_work.gd` (issue #205, predates this ADR, owned by
  #241) asserted the interrupted job's `JobQueue` record status stays `"active"` throughout the
  interrupt. That assertion encoded the now-superseded design; it has been updated to expect
  `"queued"` during the interrupt window.

## Alternatives considered

- **Keep the reservation held, as round 1 shipped** (rejected by this review): matches "does not
  lose its place" for the waiting-queue position, but conflates queue position with resource
  ownership and can starve an unrelated job on the same tile for an unbounded time.
- **Release the `ReservationTable` entry directly while leaving `JobQueue.status` "active"**
  (considered, rejected): would satisfy `NeedGiver`'s own direct `ReservationTable.is_reserved()`
  checks but not `GlobalAssignment.tick()`'s `get_reservations()`-driven exclusion (which reads
  `status`, not the table), so a different job targeting the same tile would still be blocked --
  only half the reviewer's concern addressed, for no simpler an implementation.
- **Let the interrupted job re-enter fully competitive proposal (no `restrict_to`) on suspend**
  (considered, rejected): matches "one work engine" most purely, but risks a different worker's
  own idle-tick scan winning the job away from the colonist that is about to resume it, before
  `resume_assignment()`'s own forced pairing runs this same tick -- a strictly larger behavior
  change than this review asked for, and not necessary to fix the reservation-holding defect.
