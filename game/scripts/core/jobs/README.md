# Dig job queue contract

> **In short:** The job queue holds the work the player has ordered, decides which job may start, and explains in plain terms why a job is waiting.

`JobQueue` is a plain `RefCounted` module implementing ADR 003 principles 1
and 2 and the explainability section of `simulation-boundaries.md`.
`WorldState` reaches it through the scheduler (`GlobalAssignment.queue`),
which dispatches validated commands to it and drives it once per simulation
tick.

## Inputs and transitions

Construct with an injected, seeded `RandomNumberGenerator` and a deterministic
`Callable(target: Vector2i) -> bool`. The callable must not mutate this queue;
it reads caller-owned reachability state, which may change between ticks.
No random draws are needed: IDs and arbitration use submission order.

- `submit_dig(target, priority = Priority.NORMAL)` returns `{ok: true, job_id}`.
  IDs are monotonic `job_1`, `job_2`, etc., never reused. Targets have nonnegative
  integer coordinates; map bounds/diggability are the caller's responsibility.
- Exactly three priorities exist: `LOW = 0`, `NORMAL = 1`, `HIGH = 2`.
  Other integer values are rejected without consuming an ID.
- `tick()` increments the local tick once, then evaluates all queued jobs in
  descending priority and submission order. There is no worker allocation,
  fairness policy, completion work, or work budget in this module.
- An eligible job becomes `active` and atomically reserves its target through
  the shared `ReservationTable` (colonist-ai.md 3.4; see `reservation_table.gd`
  and the reusable `reservation_invariants.gd` helper), namespaced with a
  `tile:` key. `get_reservations()` still returns the read model as a
  `Dictionary[Vector2i -> String job_id]`, one entry per active job.
  `get_reservation_table()` returns the actual shared `ReservationTable`
  instance (not a copy), so a future item/cell reservation acquired through
  it belongs to this same ledger and this queue's own terminal transitions.
- `cancel(id)`, `fail(id)`, and `invalidate(id)` terminate queued or active
  jobs. `complete(id)` requires an active job. Each calls `release_all(id)` on
  the shared table, releasing every key the job owns (today always exactly
  its own `tile:` key) before returning. Invalidation maps to `failed` with
  `target_invalidated`. A blocked job cannot release another job's reservation.
- Unknown IDs, terminal jobs, and completion of queued jobs are rejected with
  typed reasons/remedies. Terminal jobs remain queryable and never restart.

## Read model and explainability

All getters return detached deep copies. `get_job(unknown_id)` returns `{}`.
A job contains `id`, `kind: dig`, `status`, `priority`, `target: Vector2i`,
`reason`, `remedy`, and `blocking_job_id` (empty when inapplicable).
Statuses are exactly `queued/active/completed/failed/cancelled`, matching the
minimum vocabulary in `game-state.schema.json`. Blocking is queued state with
a nonempty reason, not a new status.

| Cause | Reason | Remedy |
| --- | --- | --- |
| Another job owns target | `blocked_target_reserved` | `wait_for_target_release` |
| Callable returns false | `blocked_target_unreachable` | `restore_target_access` |
| Missing callable or non-boolean result | `blocked_reachability_unavailable` | `provide_reachability_check` |
| Cancel command | `cancelled_by_command` | `resubmit_order` |
| Failure command | `job_execution_failed` | `inspect_target_and_resubmit` |
| Invalidation command | `target_invalidated` | `choose_valid_target` |

Reservation conflicts take precedence over reachability. Every queued job is
retried each tick, including blocked jobs: a released tile or changed callable
result needs no resubmission or notification API. Unchanged blocks emit no
duplicate events; changed causes/owners emit updated `job_blocked` events.
Activation clears all blocking fields and emits `job_unblocked` when applicable.
Active jobs are not polled for reachability; the owning simulation explicitly
invalidates obsolete work. Reasons reflect the last evaluation, refreshed on the next tick.

Events contain `type`, `tick`, `system_priority: 50`, `entity_id` (job ID, or
empty for rejected submissions), monotonic `sequence`, and `data`. Events are
returned sorted by `(tick, system_priority, entity_id, sequence)`, as required
by the simulation contract; `sequence` preserves emission chronology.
Types: `job_queued`, `job_blocked`, `job_unblocked`, `job_active`,
`reservation_acquired`, `reservation_released`, `job_cancelled`, `job_failed`,
`job_completed`, `job_rejected`. Block and terminal event data carry reasons
and remedies; reservation data carry the target and the released
`ReservationTable` key (today always the job's own `tile:` key, since dig/chop
reserve nothing else; a terminal transition emits one `reservation_released`
per key `release_all()` actually freed). Rejections return
`{ok: false, rejection: {job_id, reason, remedy, tick}}` and emit that data.
Rejection codes are `invalid_priority`, `invalid_target`, `unknown_job`,
`job_already_terminal`, and `job_not_active`.

## Example and tests

```gdscript
var rng := RandomNumberGenerator.new()
rng.seed = 45
var queue := JobQueue.new(rng, func(_tile: Vector2i) -> bool: return true)
var first: String = queue.submit_dig(Vector2i(3, 2))["job_id"]
var second: String = queue.submit_dig(Vector2i(3, 2))["job_id"]
queue.tick() # first active; second queued / blocked_target_reserved
queue.cancel(first) # reservation released immediately
queue.tick() # second active without resubmission
```

`test_job_queue.gd` covers competing targets, bypassing blocked jobs,
reachability recovery and reason changes, all terminal releases, rejection
integrity, exactly three priorities, detached reads, and seeded replay/events.

This is an in-memory module contract, not a save format: persisting this read
model directly is invalid. Persisted job fields and their migrations are
documented in
[`docs/architecture/save-system.md`](../../../../docs/architecture/save-system.md).

## Haul

`haul` jobs carry four extra job fields, always present with harmless
defaults (`""`, `null`, `0`, `0`) on every kind: `item_id` (the ground item to
carry, attached post-submission via `attach_item()` since
`GlobalAssignment.submit()`'s fixed signature has no room for it), `cell`
(the reserved destination `Vector2i`, chosen by the injected
`set_haul_destination_finder()` callable and set at activation), `backoff_ticks`
and `retry_at` (see below). `job["target"]` stays the item's tile, used only
for the scheduler's own routing/`get_reservations()` bookkeeping exactly like
dig/chop's target -- the real reservations are `"item:<item_id>"` and
`"cell:x,y"` keys on the shared `ReservationTable`, acquired together by
`_tick_haul()` before the job ever goes active (colonist-ai.md 3.4: "reserve
the item and one free destination cell"). WorldState drives the two travel
legs and the two instant toils (`pick_up`, `place`) itself; `job_queue.gd`
only owns activation.

A haul job with no free destination blocks `blocked_destination_full` and
retries on a backoff (base ticks, doubling to a cap; both injected via
`set_haul_backoff()` from `WorldState.HAUL_RETRY_BASE_TICKS`/
`HAUL_RETRY_CAP_TICKS`, mirroring how `MOVE_TICKS_PER_TILE`/`WORK_TICKS` are
injected into `ToilExecutor`) instead of every tick like dig/chop's blocks.
Backing off must not let unbounded ADR 004 aging
([`004-global-assignment-fairness-policy.md`](../../../../docs/decisions/004-global-assignment-fairness-policy.md))
let one permanently blocked job monopolize a worker's scoring competition
forever: `get_reservations()` reports a backed-off haul job's own target as
"reserved" for as long as `_tick < retry_at`, routing it through
`global_assignment.gd`'s existing pre-scoring exclusion (the same one a
target-reserved dig/chop job already gets) instead of competing for a route
search slot or a `chosen` pairing every tick. `_tick_haul()` checks that
backoff before touching reachability at all, since `_can_reach()`'s result is
only meaningful for a job the scheduler actually searched a route for this
tick.
