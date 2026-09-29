# ADR 036: `build` gains a per-job multi-source fetch plan; `build_cost` becomes a list

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** `content/objects.json`'s `build_cost` field (`object` -> `array` of `{item, quantity}`,
  `game/content/schemas/objects.schema.json`), `game/scripts/core/content/content_registry.gd`'s
  dangling-reference check for it, one new test-only buildable object kind, a per-job on-demand
  multi-source fetch for the `build` job kind (`game/scripts/core/jobs/job_queue.gd`,
  `game/scripts/core/jobs/toil_executor.gd`, `game/scripts/core/world_state.gd`),
  `docs/architecture/core-budgets.json`'s caps for the three touched core files.
- **Implements:** issue #403 (t2 of the two-task split started by issue #402/ADR 035; t1 gave a
  colonist a 4-unit multi-kind `hands` list, explicitly leaving `build_cost` and multi-source fetch
  to this task).
- **Depends on:** [ADR 027](027-build-job-core-budget-increase.md) (the `build` job kind itself,
  its toils, its two-reservation activation shape) and [ADR 035](035-hands-multi-unit-carrying.md)
  (the `hands` list `pick_up`/`place` already move counts against, not always a whole stack).

## Decision

**`build_cost` is a list, one entry per required kind.** `[{item, quantity}, ...]`, `minItems: 1`.
`wall`/`door`/`bed` keep their existing single-entry `[{item: "wood", quantity: 1}]` shape --
zero behavioural change for them, proven by every pre-existing `test_build.gd` scenario passing
unmodified (only the Dictionary-vs-Array *type* of a handful of test helper reads needed updating,
never an assertion). `content_registry.gd`'s `_check_references()` walks every list position instead
of a single `.item` field; `test_content_registry.gd`'s own dangling-reference fixture now declares
a two-entry `build_cost` whose *second* entry is the dangling one, proving the check isn't
position-blind. A new object kind, `test_multi_source_crate` (deliberately named as a test fixture,
not a real future object -- Non-goals forbids implementing the workbench this issue's own recipe
would otherwise resemble), declares `build_cost: [{item: wood, quantity: 3}, {item: stone,
quantity: 2}]` -- 5 total, one more than `ActorInventory.HANDS_CAPACITY` (4, ADR 035), so a solo
colonist can never carry the whole order in one hands-load (see "Consequences" below) and the
multi-source/nearest-fetch machinery is exercised through real content, not a hand-built fixture.

**No new toil, no new job field, no persistence change.** The whole design lives inside the two
existing haul-shaped toils `build` already declares (`go_to`, `pick_up`) plus two small,
already-persisted job fields (`item_id`/`target`, ADR 027's own "leg one" pair) and one
repurposed one (`cell`, always unused/null for `build` since it never drives a `place` toil).
Every job field this design reads or writes already round-trips through `state_codec.gd`'s
existing `_encode_jobs()`/`_decode_jobs()` whitelist (`itemId`, `target`, `cell`, `site`,
`buildKind`) -- `state_codec.gd`/`save_io.gd` are not owned paths for this task, and this design
needs no change to either, by construction.

**The fetch plan is realized incrementally, one hop at a time, from the colonist's live position
-- not materialized as a persisted list.** `JobQueue._tick_build()`'s own submission-time seed
selection is unchanged (`WorldState._apply_build_submission()`, generalized only to read
`build_cost[0]`'s kind instead of a single field): no colonist is chosen yet at submission, so
"nearest to the builder" cannot be evaluated for the very first source, and it is picked the same
position-agnostic way every build order's item always was (lowest available id of the first
declared kind) -- purely as a placeholder tile for `GlobalAssignment`'s own scoring/routing
(`global_assignment.gd` is not an owned path for this task, so the routing/scoring pass itself
cannot be made position-of-final-colonist-aware; it needs *some* concrete tile to route candidates
against before any of them is chosen).

**Round-2 review: that placeholder is swapped for the true nearest-to-builder source the instant
the job actually (re)activates, before the colonist ever moves.** `WorldState.tick()` snapshots
every currently-active build job's id (`_active_build_job_ids()`) immediately before
`_scheduler.tick()` runs; right after, `_resolve_freshly_activated_build_sources()` diffs that
snapshot against the now-current set, so it sees exactly the build jobs that just (re)activated
THIS tick -- both a job's first-ever activation and a reactivation after a need-interrupt suspend
are legitimate "a leg just started" boundaries; an already-active job mid-route toward its current
source is untouched (`JobQueue.tick()` never revisits an already-`"active"` job, so the diff is
exact, no separate marker needed). For each, it re-runs the exact `_next_build_source()` search
every later hop already uses, from the assigned colonist's real current tile: if a genuinely nearer
source exists than the placeholder (or than whatever a reactivation reacquired), it releases the
placeholder's reservation and reserves the replacement (`ReservationTable.release()`/`acquire()`,
the same ledger every other reservation swap in this design already uses) via the existing
`retarget_build_source()` mutator -- so the very first trip the colonist actually walks is always
nearest-to-builder, never merely lowest-id. Restricted to `job.get("cell") == null` (still
fetching): once delivering, `item_id` no longer drives movement, so re-checking it would be inert.
Every source AFTER that is resolved on demand exactly as before, once the job is genuinely
active and driven by a real colonist: `WorldState._toil_on_pick_up_success()` (a new
`ToilExecutor` hook, fired the instant a `pick_up` toil succeeds) asks
`WorldState._next_build_source(colonist, job, from)` for the nearest still-needed, still-unreserved
ground item to the colonist's CURRENT tile -- ranked by deterministic route cost
(`WorldState._build_route_cost()`, the same bounded `RouteSearch` and `_routable_to()` target-tile
exception the colonist's own `go_to` toil will actually travel under, so a candidate ranked
nearest is guaranteed reachable by the identical rule that later moves the colonist, not merely
close in open-field distance), unreachable candidates skipped outright and ties broken by the
lowest item id for full determinism -- reserves it immediately on the shared `ReservationTable`
(`JobQueue.ITEM_KEY_PREFIX`, the same ledger `_tick_haul()`/`_tick_build()` already use -- issue
#403's "reserve each source item as it is claimed"), and retargets the job at it
(`JobQueue.retarget_build_source(job_id, item_id, target)`, a new small mutator mirroring
`attach_item()`/`attach_build()` but gated on `"active"` instead of `"queued"` since it fires
mid-execution). A source already reserved by a different active job -- of this same order's kind
of content or a wholly different one -- is invisible to `_next_build_source()` and is skipped in
favor of the next-nearest unreserved candidate, satisfying the two-colonist disjointness
requirement without either job ever knowing the other exists.

This is a considered adaptation, not a shortcut: an upfront persisted plan array was designed and
rejected specifically because it would have needed `state_codec.gd`/`save_io.gd`/the save schema
touched to survive a save mid-fetch, and neither file is an owned path for this task (t1's own note
that it is "already an owned path via t1" does not match this task's actual `Owned paths` list;
per this project's own hard-won lesson about required-but-unauthorized supporting files, the
design was reshaped to need no such file instead of touching it anyway). The on-demand shape is
behaviourally equivalent for a stable stockpile (nothing but this same job's own reservations ever
changes candidate availability while it fetches) and is, if anything, a more literal "nearest to
the builder" than a one-time snapshot would have been: it is always nearest to wherever the
builder *currently* stands, not wherever it stood when a plan was first drawn up.

**`is_first_leg`, the toil-sequencing decision ADR 027 already makes once per job (`ToilExecutor.
_is_first_leg()`), is now a hook for the kinds that need more than one answer over a job's
lifetime.** Every kind but `build` keeps the original `not InventoryType.is_carrying(colonist)`
rule byte-for-byte (a new `hooks: Dictionary` parameter threaded through `_is_first_leg()`'s three
existing call sites, consulted only when present). `build`'s own hook
(`WorldState._toil_is_first_leg()`) answers `job.get("cell") == null`: `cell` is unconditionally
unused by `build` otherwise (ADR 027: "`build` no longer drives a `place` toil at all"), so
repurposing it as a plain boolean-shaped flag -- null while still fetching, stamped with the job's
own site the moment `_toil_on_pick_up_success()` decides to stop (`JobQueue.
mark_build_delivering()`) -- needs no new field and is already covered by every existing
`cell`-shaped validation/encoding path a `haul` job's own `cell` already exercises.
`job["item_id"]`/`["target"]` always keep naming the LAST source visited, whether still fetching or
already delivering, and stay reserved to it for the job's entire remaining lifetime exactly like a
single-source build always did -- `JobQueue._reactivate_build()`/`restore()` needed no change at
all for this reason (both already unconditionally reacquire `item_id`'s own key).

**Each `pick_up` is clamped to exactly what the order still needs of that source's own kind, but
only for a genuinely multi-entry `build_cost`.** `ToilExecutor.pick_up()` already accepts a `count`
parameter (ADR 035); a new optional `pick_up_count_for(job, colonist)` hook lets `build` request
`declared_quantity_for_this_kind - already_held`, instead of `pick_up()`'s own "take the whole
reachable stack" default -- a single-entry `build_cost` (wall/door/bed) always passes `-1`, `pick_up
()`'s untouched default, so `_check_stack_larger_than_cost_keeps_remainder()`'s existing behaviour
(the excess rides along in hands and is deposited back at the builder's own tile) is provably
unchanged; only a `build_cost` with more than one entry clamps, since taking a generous single
source's WHOLE stack there could fill every free hand with one kind and leave no room for a second
kind the same order also needs -- a failure mode a single-kind order can never suffer regardless of
stack size.

**The "very close" rule -- the one behavioral branch point in the whole plan.** After each
successful `pick_up`, `_toil_on_pick_up_success()` decides whether to keep fetching or start
delivering: deliver once the order's full cost is covered by hands, or hands are full, or no
further eligible source exists; OTHERWISE (hands not full, real need remains, and a further source
does exist) still prefer delivering when the site's deterministic route cost from the colonist's
current tile is *strictly* lower than that next source's -- the same `_build_route_cost()` metric
`_next_build_source()` itself ranks candidates by, not open-field distance. This is evaluated
exactly once per `pick_up`, never
re-evaluated mid-travel (so a colonist already walking toward a chosen source can never flip-flop
mid-route on a stale comparison) -- the same "decide once, act until the next discrete boundary"
discipline the rest of the toil vocabulary already follows.

## Consequences

- A solo colonist assigned an order whose combined `build_cost` exceeds `HANDS_CAPACITY` (4) --
  `test_multi_source_crate`'s own 5 -- can never gather the full order in one hands-load: its fetch
  plan stops at 4 units (hands full) with one kind still short, delivers anyway, and
  `_build_completion_failure()` (now list-aware: every entry's own declared quantity must be met,
  not a single field) fails it typed `blocked_missing_input`, cargo conserved on the ground exactly
  like every other typed build failure. This is accepted, not a bug: `test_build.gd`'s own
  multi-source scenarios (trip sequence, mid-fetch cancellation) deliberately never require this
  content kind's build to *complete* -- only that the visiting order, the mid-fetch cancellation
  cleanup, and cross-job disjointness are correct. A future task wanting a single job to complete
  such an order (staging partial deliveries at the site across more than one hands-load) is
  explicitly out of this task's scope; Non-goals already forbids inventing that mechanic here.
- "Two colonists on the same build order" (the acceptance's own phrasing) is realized as two
  separate build orders of `test_multi_source_crate`'s kind, submitted concurrently and drawing
  from one shared stockpile -- not a single `JobQueue` job driven by two colonists in sequence,
  which the engine's one-job-one-active-worker shape does not support and this task's Non-goals
  does not ask for. "Fewer total trips" is interpreted, and documented in `test_build.gd`'s own
  scenario comment, as fewer total TICKS to finish fetching across both orders: two colonists
  fetching concurrently finish in roughly `max(a, b)` ticks where `a`/`b` are each order's own
  fetch duration, against a lone colonist forced to serialize both orders (`a + b`, plus the full
  work-phase-then-typed-failure of the first order before the second worker frees up) -- a strictly
  larger number for any non-trivial `a, b > 0`, not a claim that raw pick-up COUNT differs (it does
  not: each order's own hands-capacity bound is identical regardless of who fetches it or in what
  order).
  **Round-2 review requested the literal same-`JobQueue`-job reading instead** (or, failing that,
  the task owner revising the acceptance requirement). Re-examined against the current checkout:
  `GlobalAssignment._assignments`/`resume_assignment()` tie an active job to exactly one worker
  for the job's *entire* lifecycle -- not merely "until reassigned," but structurally: `suspend()`/
  `reactivate()`/`resume_assignment()` are the only transitions that ever move a job between
  "has a worker" and "does not," and every one of them either keeps the same worker (resume) or
  drops to none (suspend, awaiting the SAME worker's own resume call). Nothing in this engine ever
  hands an *active* job to a second worker while the first is still capable of finishing it, and
  building that hand-off would mean editing `global_assignment.gd`/`assignment_queue.gd` -- neither
  is an owned path for this task, and both are explicitly the layer this task's own `Owned paths`
  withholds (t2's remit is the toil vocabulary `build` already declares, not colonist-to-job
  assignment). This is not a preference the author is declining to implement; it is a change this
  task cannot make without editing files outside its authorized scope, which the project's own
  hard rules treat as `## Blocked`, not something to route around with an in-scope approximation
  dressed up as the real thing. The two-separate-orders reading above is kept as the closest
  faithful proof available inside this task's Owned paths: it exercises the identical shared-
  reservation disjointness machinery a literal same-job hand-off would also need, under the
  identical stockpile-contention conditions, with the identical determinism guarantee.
- `_find_available_build_item()`'s existing single-item-covers-the-whole-quantity contract is kept
  for the SEED search only (called with `quantity = 1` now, not the full first entry's declared
  amount, since multi-source fetch may combine partial amounts across several items); submission
  feasibility (`_check_build_command()`) is generalized to `_build_total_available()`, the summed
  eligible stock across every matching item, checked once per `build_cost` entry.
- Line-count caps move (the convention ADR 016/017/018/022/024/026/027 already established):
  `world_state.gd` 4015 -> 4223 -> 4360 (round-2 review's seed-swap fix above), `toil_executor.gd`
  860 -> 890 -> 920 (round-2 review's `go_to_skip_assignment_path` hook), `job_queue.gd` 698 -> 738.

## Alternatives considered

- **A persisted `fetch_plan: Array[String]` job field, the whole ordered list resolved once at
  activation.** Matches the objective's own prose most literally, but needs `state_codec.gd`
  (`_encode_jobs()`/`_decode_jobs()`) and `save_io.gd`'s job validator touched to survive a save
  mid-fetch -- neither is an owned path for this task. Rejected in favor of the on-demand design
  above, which needs no new persisted field and is behaviourally equivalent for a stable stockpile.
- **Interim ground-drop staging at the site once hands are full but the order isn't**, looping the
  job back through another fetch cycle via the existing `place` toil. Would let a single colonist
  complete a >4-cost order across more than one hands-load, but reopens ADR 027's own settled
  "delivery, not a ground drop" invariant and needs new site-side accounting (what has already been
  staged there, by which job) this task's Non-goals does not authorize inventing. Rejected; a solo
  colonist failing a >4-cost order typed is an accepted, typed outcome instead (see Consequences).
- **A literal two-colonists-one-job hand-off**, where a second colonist resumes an interrupted
  build job's still-partial fetch after the first colonist is reassigned elsewhere. The engine
  ties an active job to exactly one worker for its entire lifecycle
  (`GlobalAssignment._assignments`/`resume_assignment()`, always keyed to the SAME colonist that
  suspended it); building genuine mid-job hand-off is a scheduler-layer change well beyond a toil
  extension and not authorized by this task's Owned paths (`global_assignment.gd`/
  `assignment_queue.gd` are not listed). Rejected in favor of the two-separate-orders reading above.
