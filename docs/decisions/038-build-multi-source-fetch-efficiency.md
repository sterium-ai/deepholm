# ADR 038: `build` gains a per-job multi-source fetch plan; `build_cost` becomes a list

> **In short:** A building can now need several kinds of material, such as wood and stone. The builder collects them from the nearest piles one trip at a time, and two builders never grab the same pile.

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** `content/objects.json`'s `build_cost` field (`object` -> `array` of `{item, quantity}`,
  `game/content/schemas/objects.schema.json`), `game/scripts/core/content/content_registry.gd`'s
  dangling-reference check for it, one new test-only buildable object kind, a per-job on-demand
  multi-source fetch for the `build` job kind (`game/scripts/core/jobs/job_queue.gd`,
  `game/scripts/core/jobs/toil_executor.gd`, `game/scripts/core/world_state.gd`), and
  `docs/architecture/core-budgets.json`'s caps for those three core files.
- **Depends on:** [ADR 028](028-build-job-core-budget-increase.md) (the `build` job kind, its
  toils, and its two-reservation activation shape) and [ADR 037](037-hands-multi-unit-carrying.md)
  (the `hands` list, which lets `pick_up`/`place` move partial counts rather than always a whole
  stack).

## Decision

**`build_cost` is a list, one entry per required kind:** `[{item, quantity}, ...]`, `minItems: 1`.
`wall`, `door`, and `bed` keep their single-entry `[{item: "wood", quantity: 1}]` cost, so their
behaviour is unchanged; every pre-existing `test_build.gd` scenario passes unmodified (only the
Dictionary-vs-Array *type* of a few test helper reads changed, never an assertion).
`content_registry.gd`'s `_check_references()` walks every list position instead of a single
`.item` field, and `test_content_registry.gd`'s dangling-reference fixture declares a two-entry
`build_cost` whose *second* entry is the dangling one, proving the check is not position-blind.
A new object kind, `test_multi_source_crate` (deliberately named as a test fixture, not a real
future object such as a workbench), declares `build_cost: [{item: wood, quantity: 3}, {item: stone,
quantity: 2}]`. That is 5 units in total, one more than `ActorInventory.HANDS_CAPACITY` (4,
ADR 037), so a solo colonist can never carry the whole order in one load (see "Consequences"), and
the multi-source, nearest-first machinery is exercised through real content rather than a
hand-built fixture.

**No new toil, no new job field, no persistence change.** The design lives entirely inside the two
haul-shaped toils `build` already declares (`go_to`, `pick_up`), two already-persisted job fields
(`item_id`/`target`, ADR 028's "leg one" pair), and one repurposed field (`cell`, otherwise unused
by `build` because it never drives a `place` toil). Every job field it reads or writes already
round-trips through `state_codec.gd`'s existing `_encode_jobs()`/`_decode_jobs()` whitelist
(`itemId`, `target`, `cell`, `site`, `buildKind`), so neither `state_codec.gd` nor `save_io.gd`
changes.

**The fetch plan is resolved one hop at a time from the colonist's live position, not stored as a
persisted list.** Submission-time seed selection in `JobQueue._tick_build()` is unchanged
(`WorldState._apply_build_submission()` is generalized only to read the kind of `build_cost[0]`).
No colonist has been chosen at submission, so "nearest to the builder" cannot yet be evaluated for
the first source; it is picked the same position-agnostic way a build order's item always was
(lowest available id of the first declared kind), purely as a placeholder tile.
`GlobalAssignment`'s scoring and routing need *some* concrete tile to route candidates against
before any of them is chosen.

**The placeholder is replaced by the true nearest source the moment the job (re)activates, before
the colonist moves.** `WorldState.tick()` snapshots the ids of all active build jobs
(`_active_build_job_ids()`) immediately before `_scheduler.tick()` runs. Right after,
`_resolve_freshly_activated_build_sources()` diffs that snapshot against the current set, which
yields exactly the build jobs that (re)activated this tick. Both a job's first activation and a
reactivation after a need-interrupt suspend are legitimate "a leg just started" boundaries; an
already-active job mid-route toward its source is untouched (`JobQueue.tick()` never revisits an
already-`"active"` job, so the diff is exact and no separate marker is needed). For each such job,
it runs the same `_next_build_source()` search every later hop uses, from the assigned colonist's
real current tile. If a nearer source exists than the placeholder (or than whatever a reactivation
reacquired), it releases the old reservation and reserves the replacement
(`ReservationTable.release()`/`acquire()`) via the `retarget_build_source()` mutator, so the first
trip the colonist walks is always to the nearest source, not merely the lowest id. This applies
only while `job.get("cell") == null` (still fetching); once delivering, `item_id` no longer drives
movement.

Every later source is resolved on demand once the job is active and driven by a real colonist.
`WorldState._toil_on_pick_up_success()` (a new `ToilExecutor` hook, fired when a `pick_up` toil
succeeds) asks `WorldState._next_build_source(colonist, job, from)` for the nearest still-needed,
still-unreserved ground item to the colonist's *current* tile. Candidates are ranked by
deterministic route cost (`WorldState._build_route_cost()`, the same bounded `RouteSearch` and
`_routable_to()` target-tile exception the colonist's `go_to` toil travels under), so a candidate
ranked nearest is guaranteed reachable by the same rule that later moves the colonist, not merely
close in open-field distance. Unreachable candidates are skipped and ties are broken by lowest item
id. The chosen item is reserved immediately on the shared `ReservationTable`
(`JobQueue.ITEM_KEY_PREFIX`, the ledger `_tick_haul()`/`_tick_build()` already use), and the job
is retargeted at it via `JobQueue.retarget_build_source(job_id, item_id, target)`, a small new
mutator mirroring `attach_item()`/`attach_build()` but gated on `"active"` instead of `"queued"`,
since it fires mid-execution. A source already reserved by any other active job is invisible to
`_next_build_source()` and is skipped in favour of the next-nearest unreserved candidate, which
keeps two colonists' fetches disjoint without either job knowing the other exists.

An upfront persisted plan array was considered and rejected because surviving a save mid-fetch
would require changing `state_codec.gd`, `save_io.gd`, and the save schema (see "Alternatives
considered"). The on-demand approach is behaviourally equivalent for a stable stockpile (only this
job's own reservations change candidate availability while it fetches), and it is arguably a more
literal "nearest to the builder": always nearest to where the builder *currently* stands, not where
it stood when a plan was drawn up.

**`is_first_leg` becomes a hook for kinds that need more than one answer over a job's lifetime.**
ADR 028 makes this toil-sequencing decision once per job (`ToilExecutor._is_first_leg()`). Every
kind except `build` keeps the original `not InventoryType.is_carrying(colonist)` rule unchanged; a
new `hooks: Dictionary` parameter is threaded through `_is_first_leg()`'s three existing call sites
and consulted only when present. `build`'s hook (`WorldState._toil_is_first_leg()`) answers
`job.get("cell") == null`. Since `build` otherwise never uses `cell` (ADR 028: "`build` no longer
drives a `place` toil at all"), it serves as a boolean-shaped flag: null while fetching, and set to
the job's site when `_toil_on_pick_up_success()` decides to stop fetching
(`JobQueue.mark_build_delivering()`). This needs no new field and is already covered by the
validation and encoding paths a `haul` job's `cell` exercises. `job["item_id"]`/`["target"]` always
name the *last* source visited, whether fetching or delivering, and stay reserved to it for the
rest of the job's lifetime, exactly as a single-source build always did, so
`JobQueue._reactivate_build()` and `restore()` needed no change (both already unconditionally
reacquire `item_id`'s key).

**Each `pick_up` is clamped to what the order still needs of that kind, but only for a multi-entry
`build_cost`.** `ToilExecutor.pick_up()` already accepts a `count` (ADR 037). A new optional
`pick_up_count_for(job, colonist)` hook lets `build` request `declared_quantity_for_this_kind -
already_held` instead of `pick_up()`'s default of taking the whole reachable stack. A single-entry
`build_cost` (wall, door, bed) always passes `-1`, the unchanged default, so the behaviour covered
by `_check_stack_larger_than_cost_keeps_remainder()` (the excess rides along in hands and is
deposited back at the builder's tile) is unchanged. Only a multi-entry cost clamps, because taking
a large single source's whole stack could fill every free hand with one kind and leave no room for
a second kind the order also needs, a failure a single-kind order cannot suffer.

**The "very close" rule is the one behavioural branch point in the plan.** After each successful
`pick_up`, `_toil_on_pick_up_success()` decides whether to keep fetching or start delivering. It
delivers once hands cover the order's full cost, hands are full, or no further eligible source
exists. Otherwise (hands not full, need remains, and a further source exists), it still prefers
delivering when the site's route cost from the colonist's current tile is *strictly* lower than the
next source's, using the same `_build_route_cost()` metric `_next_build_source()` ranks by. This is
evaluated exactly once per `pick_up` and never re-evaluated mid-travel, so a colonist walking toward
a chosen source cannot flip-flop on a stale comparison. This follows the "decide once, act until the
next discrete boundary" discipline of the rest of the toil vocabulary.

## Consequences

- A solo colonist assigned an order whose combined `build_cost` exceeds `HANDS_CAPACITY` (4), such
  as `test_multi_source_crate`'s 5, cannot gather the full order in one load. Its fetch stops at 4
  units (hands full) with one kind still short, it delivers anyway, and `_build_completion_failure()`
  (now list-aware: every entry's declared quantity must be met) fails the job with the typed reason
  `blocked_missing_input`, with cargo conserved on the ground like every other typed build failure.
  This is accepted behaviour, not a bug: `test_build.gd`'s multi-source scenarios (trip sequence,
  mid-fetch cancellation) deliberately never require this kind's build to *complete*, only that the
  visiting order, mid-fetch cancellation cleanup, and cross-job disjointness are correct. Letting a
  single job complete such an order (staging partial deliveries at the site across several loads)
  is out of scope here; [ADR 040](040-construction-sites.md) later addresses it with construction
  sites.
- "Two colonists on the same build order" is realized as two separate build orders of
  `test_multi_source_crate`'s kind, submitted concurrently and drawing from one shared stockpile,
  not as a single `JobQueue` job driven by two colonists in turn. The engine does not support the
  latter: `GlobalAssignment._assignments`/`resume_assignment()` tie an active job to exactly one
  worker for its whole lifecycle. `suspend()`, `reactivate()`, and `resume_assignment()` are the
  only transitions that move a job between "has a worker" and "does not", and each either keeps the
  same worker (resume) or drops to none (suspend, awaiting the same worker's resume). A mid-job
  hand-off would be a scheduler-layer change (`global_assignment.gd`/`assignment_queue.gd`), not a
  toil extension. The two-orders scenario exercises the same shared-reservation disjointness
  machinery a hand-off would need, under the same stockpile contention and with the same
  determinism guarantee. "Fewer total trips" is interpreted, and documented in the scenario's
  comment in `test_build.gd`, as fewer total *ticks* to finish fetching across both orders: two
  colonists fetching concurrently finish in roughly `max(a, b)` ticks, where `a` and `b` are each
  order's fetch duration, while a lone colonist must serialize both orders (`a + b`, plus the full
  work phase and typed failure of the first order before the worker frees up). It is not a claim
  that the raw pick-up count differs; it does not, since each order's hands-capacity bound is the
  same regardless of who fetches it.
- `_find_available_build_item()`'s existing "one item covers the whole quantity" contract is kept
  for the *seed* search only, now called with `quantity = 1` rather than the first entry's full
  amount, since a multi-source fetch may combine partial amounts from several items. Submission
  feasibility (`_check_build_command()`) is generalized to `_build_total_available()`, the summed
  eligible stock across all matching items, checked once per `build_cost` entry.
- Line-count caps move, following the exact-line-count convention of the earlier core-budget ADRs:
  `world_state.gd` 4015 -> 4360 (including the placeholder-replacement step above),
  `toil_executor.gd` 860 -> 920 (including a `go_to_skip_assignment_path` hook), and
  `job_queue.gd` 698 -> 738.

## Alternatives considered

- **A persisted `fetch_plan: Array[String]` job field holding the whole ordered list, resolved once
  at activation.** This is the most literal reading of "a fetch plan", but surviving a save
  mid-fetch would require changing `state_codec.gd` (`_encode_jobs()`/`_decode_jobs()`) and
  `save_io.gd`'s job validator. Rejected in favour of the on-demand design, which needs no new
  persisted field and is behaviourally equivalent for a stable stockpile.
- **Interim ground-drop staging at the site once hands are full but the order is not**, looping the
  job back through another fetch cycle via the existing `place` toil. This would let one colonist
  complete an order costing more than 4 across several loads, but it reopens ADR 028's settled
  "delivery, not a ground drop" invariant and needs new site-side accounting (what has been staged
  there, by which job). Rejected here; a solo colonist failing such an order with a typed reason is
  the accepted outcome (see "Consequences").
- **A literal two-colonists-one-job hand-off**, where a second colonist resumes an interrupted build
  job's partial fetch after the first is reassigned. The engine ties an active job to one worker
  for its whole lifecycle (`GlobalAssignment._assignments`/`resume_assignment()`, always keyed to
  the colonist that suspended it); a genuine mid-job hand-off is a scheduler-layer change well
  beyond a toil extension. Rejected in favour of the two-separate-orders scenario above.
