# Colonist AI: decision, movement and priorities (design, 2026-09-18)

> **In short:** How colonists decide what to do next, reserve what they need, walk around furniture, fetch and share tools, eat and sleep, and rescue each other, so they behave predictably instead of getting stuck.

The colonists' ability to solve tasks, gather resources, do activities and find the nearest
food or drink is the heart of a colony simulation, and the area where colony sims most often
feel broken: colonists collide with objects they should pass (chairs, doors), never drop a
tool another colonist needs, stop working, or do something else during the critical months
instead of planting.

This page maps each of those failure modes to a structural cause and specifies the design the
game adopts: layered decisions, explicit reservations, item-centric jobs executed as small
re-validating steps, and no single-manager coupling. It builds on what is already implemented
(`orders-and-movement.md`, ADR 003/004): the fair global scheduler with aging, bounded route
search, typed block reasons, movement and work stepping.

## 1. Design principles

### The single-manager anti-pattern

A common shape for small colony simulations is: one task manager hands tasks to colonists,
one action manager funnels orders, one shared path calculator computes routes for every mobile
actor, professions are hard-coded classes, and a per-actor-type arrival handler decides what
happens on arrival. There is no transactional hand-off between the managers and no
data-driven table for passability, tools or labours. The failure modes above map onto that
shape (section 2). The design below avoids it.

### Layered decisions

Each colonist evaluates an ordered list of decision layers each time it needs a job:
incapacitation, critical needs, forced player orders, urgent needs, work walked by the
colonist's *labour priority table*, and idle (section 3.1). The fixed order is what makes
behaviour predictable: a starving colonist eats before hauling, and a forced order beats
routine work.

### Jobs as re-validating toils

A chosen job is a list of **toils** (go to X, pick up Y, work N ticks, drop Z, release), each
re-checking its preconditions. Any failure ends the job with a typed reason and returns the
colonist to the decision layers; the job itself is re-queued with a backoff instead of being
cancelled and re-created in a tight loop, which would leave work undone while the colonist
looks busy.

### Explicit reservations

Every target a job touches — a tile, an item, a tool, a stockpile cell — is **reserved** in
one reservation table, owned by the job, and released when the job ends for any reason.
Interruption is explicit: a job declares whether needs may interrupt it.

### One passability source

Doors are passable cells with an open cost; furniture is passable-with-cost or impassable
per its content definition; route search, movement stepping and order validation all read
the same cost table, so nothing "collides" unexpectedly.

### What to adopt and what to avoid

| Concern | Adopt | Avoid |
| --- | --- | --- |
| Deciding order | Layered decisions (needs → emergencies → work by priority table → idle) | "First allowed job in the list"; a single global manager |
| Fairness under load | Our ADR 004 aging scheduler (already built) | Pure nearest-first (starves distant work) |
| Job execution | Toils: small steps that re-validate | Cancel-and-recreate loops |
| Items and tools | Item claims made explicit as reservations with owners | Implicit "held tool" state with no reservation |
| Passability | One data table of costs used by pathing *and* movement | Per-object special cases |
| Seasonal urgency | A calendar-driven priority boost the player can see and edit | Silent competition between labours |
| Explaining | Our typed reasons/remedies on every state (ADR 003) | Cancel spam; silent failures |

## 2. Failure modes, their causes, and the rule that prevents each

| Failure mode | Structural cause | Game rule |
| --- | --- | --- |
| Colonists collide with chairs, doors, things they should pass | Pathfinder and movement used different notions of "blocked"; object passability hard-coded per class | **One `passability(tile, object) -> cost|blocked` function** in core, data-driven from content, used by route search, movement stepping and order validation. Objects declare `passable`, `passable_cost`, `opens` (door). A route is re-validated one tile ahead each step; a newly blocked tile triggers re-route, not a stall. |
| A tool stays in a colonist's hand/back while another colonist needs it | Tools lived on the colonist with no reservation and no release step | **Implemented: tools.** Tools are colony items with a reservation like any target. A job that needs a tool reserves the nearest free one as a toil ("fetch tool"); the last toil of every job is "release": the tool stays *held but unreserved*, so the scheduler may assign it to another job — the holder's next job either reuses it (same kind) or begins with "drop tool at stockpile/here". No job ever ends holding a reservation. |
| Colonists stop working / go idle with work pending | Unfair or blocked-prefix selection, stale reservations, races between managers | Already addressed by ADR 004 (aging, cursor past blocked jobs, bounded routes) and the invariant test "no idle colonist while a reachable unreserved eligible job exists". Extended here to items: a job blocked on a missing item says so (`blocked_missing_input`) and does not consume the colonist. |
| In fertile months they did other things instead of planting | No notion of urgency over time; planting competed equally with hauling | **Calendar urgency**: content declares windows (e.g. `sow` in spring days 1–20) that add a priority boost to a labour kind while the window is open, visible on the work table ("Planting ↑ sowing window, 12 days left"). Higher than normal orders, lower than critical needs. The scheduler's aging still guarantees other work is not starved forever. |
| Not storing resources | Hauling was a labour with no reservation of the destination slot; two haulers targeted one slot or none | Hauling jobs reserve **both** the item and the destination stockpile cell; a full/forbidden destination is a typed block, not a dropped item. |
| Colonists stuck at a decision | One manager with 40 methods and no step re-validation | Jobs as **toil lists** (go to, pick up, work, drop, release); each toil re-checks preconditions and fails with a reason; failure releases every reservation and re-queues the job with a **backoff** (retry after N ticks, doubling to a cap) so a permanently broken job neither spams nor blocks. |

## 3. The intermediate design

### 3.1 Decision layers (per colonist, evaluated when idle or when an interrupt fires)

```
1. incapacitated (downed, asleep) ..................... no decision
2. critical needs  (starving, dehydrated, exhausted)... need job, may interrupt any interruptible toil
3. player-forced order for this colonist .............. direct job
4. urgent needs    (hungry, thirsty, tired) ........... need job, only at toil boundaries
5. work            (global fair scheduler, filtered by this colonist's labour table
                    and boosted by calendar urgency)
6. idle            (typed reason: no_eligible_work | all_blocked | labours_disabled …)
```

Needs have three thresholds in data (`warn`, `urgent`, `critical`). A need job is "find the
nearest reachable, unreserved source of kind X (food item, water tile/barrel, bed), reserve
it, go, consume, release". "Nearest" uses the same bounded route search as work, so it obeys
the tick budget. If no source exists the colonist keeps working and the reason is exposed
(`need_unmet: no_food_reachable`) — the player sees it in the panel and the alert list.

### 3.2 Labour table and priorities

**Implementation file map (F2):**
`game/scripts/core/actors/actor_table.gd` exposes the worker component;
`game/scripts/core/actors/components/worker.gd` owns this section's labour
table and the held-tool accessors used by the tool flow. Callers use these
accessors instead of directly managing fields on `WorldState`'s colonist
dictionary. The underlying `labourTable` and `held_tool` fields remain in that
dictionary; there is no nested `worker` key (see
[ADR 012](../decisions/012-actors-and-components.md)).

Each colonist has a table `labour kind → 0 (off) | 1 | 2 | 3 | 4`, editable
by the player (default all 3). Labour kinds for the slice: `mine`, `chop`, `farm`, `haul`,
`build`, `craft`, `cook`. The `mine` job kind (rock outcrops mined for stone) joins
`dig` under the existing `mine` labour kind rather than adding a new one, so the labour-table UI
needs no change (ADR 025). The global scheduler (ADR 004) keeps its aging queue, but a
colonist only examines jobs whose kind is enabled for it, and the job's effective priority is
`16 * (order priority + calendar boost + 4 - colonist labour level) + ticks waiting`, capped
so that aging still dominates after a bounded wait. This keeps one scheduler (no per-labour
queues) and one fairness proof.

**Implemented**: `global_assignment.gd`'s per-(worker, job) scoring extends this
formula exactly, in both the proposal loop and the ready-list rescoring, via
`GlobalAssignment._priority_bracket()`. A candidate whose job's labour is 0 for a worker
(`ToilExecutor.get_labour(job.kind)` read against that worker's `labourTable`) is never
proposed to that worker at all — checked by `GlobalAssignment._is_labour_enabled()`, a hard
eligibility filter kept entirely separate from the score itself (see below), not a low score.
`calendar boost` is `CalendarService.active_boost(job_labour, tick)` (ADR 008), queried at the
current tick, not the job's submission tick; `WorldState._calendar` is constructed once in
`_init()` from `_content.document("calendar")` — the same `ContentRegistry`-validated bundle
every other service reads (ADR 010/`extension-points.md`), not a second independent
`calendar.json` read — and both `ToilExecutor.get_labour` and `CalendarService.active_boost` are
passed into `GlobalAssignment.tick()` as callables (`world_state.gd`'s own `tick()`), keeping the
scheduler itself free of a direct `WorldState`/`ToilExecutor` dependency. `WorldState.
get_active_calendar_boost(labour: String) -> int` exposes the same query read-only for the
presentation layer. The bracketed term `(order priority + calendar boost + 4 - labour level)` is
capped at `GlobalAssignment.MAX_PRIORITY_BRACKET` (20) the same way `MAX_TRAVEL_PENALTY` already
caps travel, but never floored: `calendar.schema.json` permits a negative boost, and a resulting
negative bracket is a real, valid score (summed with `ticks_waiting` as usual), not a sentinel —
eligibility (`_is_labour_enabled()`) and score (`_priority_bracket()`) are two separate functions
precisely so a negative boost on an enabled labour can never be mistaken for "labour disabled".
Without the upper cap, calendar content could stack arbitrarily large boosts (`active_boost`
sums every matching window) and defeat ADR 004's aging-dominance argument by making the bracket
win forever regardless of `ticks_waiting`. Both callables default to an invalid `Callable` for a
caller that does not supply them (the lower-level scheduler tests), which reproduces ADR 004's
original priority-only formula bit for bit.

Section 3.1's needs-before-work layering does not rely on scoring at all. `GlobalAssignment.submit()`
has a `restrict_to` parameter that both `NeedGiver._commit()` (a committed need job) and
`suspend_assignment()` (a critical-need-interrupted work job, put back so only the same worker may
resume it later) use to mark an entry as proposable to one worker only — but the two are not
equivalent, and `GlobalAssignment.tick()` never equates them: a `restrict_to` entry is still just an
entry, and if both a need and its own interrupted work happened to carry it for the same worker, a
labour/calendar bonus on the interrupted work could outscore the need on `restrict_to` alone. Instead,
`tick()` takes a `committed_needs: Dictionary` parameter (worker id → job id), `WorldState`'s own
`_need_giver.get_pending_assignments()` — the ground truth of which job, if any, a worker is actually
committed to. For a worker with an entry in `committed_needs`, `tick()` skips its ordinary
`JOB_EVALUATION_BUDGET` scan entirely: `_propose_committed_need()` finds that one job by direct id
lookup in `_waiting` (never missed by sitting past the scan window, and still exclusive even while
blocked by a reservation) and proposes it alone, so no other job — restricted or open — is ever
proposed to that worker the same tick. Any of that worker's own in-progress ordinary-work route
search still `_pending` from before the need committed is discarded outright (not merely outscored)
at the top of the same `tick()` call, before it could otherwise complete and activate on its own. This
makes layer 4/2 strictly precede layer 5 structurally, not "usually win on score".

When every colonist that could ever perform a queued job's labour has it set to 0, the job is
marked with the non-terminal reason `labour_disabled` while it stays queued (not failed) —
`GlobalAssignment` recomputes this once per tick from the **full colony roster** (a separate
`all_colonists` parameter on `tick()`, defaulting to the scheduling pool for a caller that
omits it), not the pool `tick()` itself schedules against: `world_state.gd`'s `tick()` already
filters that pool down to colonists not mid-search for a need (section 3.1), and a colonist
mid-search still has a real labour table that must count toward "every colonist" regardless of
whether it can take work this exact tick. `GlobalAssignment` calls the
`JobQueue.set_labour_disabled(job_id, disabled)` setter, which mirrors the existing
`_block()`/`job_unblocked` pattern `blocked_destination_full`/`blocked_target_reserved` already
use (`job_queue.gd`'s private `_block()`/`job['reason']`/`job_blocked` event) rather than
repurposing `set_pending_fail_reason` (fail()/invalidate()-only, terminal). The reason clears
(`job_unblocked`) the moment any colonist re-enables that labour, on the next scheduler scan;
`GlobalAssignment.tick()` runs this refresh before its own reservation-recheck branch (and checks
labour eligibility before that branch too, so a disabled job's target reservation is never re-added
to the per-tick `selected` set while disabled), so a labour re-enable's `job_unblocked` always fires
— even when the job immediately re-blocks for a different reason (its target still reserved) the
same tick — instead of the two reasons silently alternating forever. A stale multi-tick route search
that fails after its job went labour-disabled mid-search is guarded the same way: `tick()` only
selects a failed candidate (letting `advance_selection()` assign it a routing reason) when
`_is_labour_enabled()` still holds, so a disabled job's reason is never overwritten by a search that
was already in flight when it was disabled. A haul job's `blocked_destination_full` backoff
(`retry_at`) is tracked independently of the reason string `JobQueue.set_labour_disabled()` and
`_tick_haul()`/`get_reservations()` display or gate on: `set_labour_disabled()` may show
`labour_disabled` immediately, even mid-backoff, while `_tick_haul()`'s own `tick < retry_at` check
(not a reason match) still blocks a fresh destination attempt, and `get_reservations()` still reports
the target reserved on that same check, so a labour toggle can never shorten an in-progress retry
delay even though the displayed reason updates right away.

### 3.3 Jobs as toils — implemented

A job kind is data: `{kind, labour, needs_tool?, toils: [...]}`. Toils are a small fixed
vocabulary implemented once in core: `reserve(target|item|tool|cell)`, `go_to(target,
adjacent?)`, `pick_up(item)`, `work(ticks)`, `place(item, cell)`, `consume(item)`,
`fetch_tool`, `drop_tool`, `release_all`. Each tick advances exactly one toil of each active job; each toil validates its
precondition first (target still valid, item still there, cell still free, tool still held)
and fails with a typed reason otherwise. The existing `route`/`work` fields on the colonist
become the state of the current `go_to`/`work` toil.

Cargo uses the `hands` list defined by [ADR 037](../decisions/037-hands-multi-unit-carrying.md):
each entry is `{kind, count}`, and all entries together are capped at 4 units. A colonist
picks up an item only for its job's purpose and deposits everything through the ordinary drop
path when that job ends for any reason. For the multi-source build behavior in
[ADR 038](../decisions/038-build-multi-source-fetch-efficiency.md), each next source is the
nearest reachable unreserved source by deterministic route cost. After pickup, delivery starts
when the build cost is covered, hands are full, or no source remains; otherwise the "very close"
rule delivers early when the destination is strictly cheaper to reach than the next source.
This decision is made once at the pickup boundary and is not re-evaluated mid-route.

**Implemented: tools.** `fetch_tool` and
`drop_tool` are toils inside the existing executor, not a new job-giver or a
second job queue. Content declares `needs_tool` (pick for dig, axe for chop).
Fetching reserves the nearest available matching item, including an unreserved
held tool; unreachable candidates are excluded for that attempt. A completed
job releases its tool reservation while the item can remain held. A holder's
next dispatched job drops a foreign-reserved or unsuitable tool to a stockpile
cell, falling back to the ground, before its ordinary work proceeds.

The existing generic job fields carry the bookkeeping: `retry_at` and
`backoff_ticks` retain blocked-tool retry timing; `blocking_job_id` persists the
active drop-leg marker without overwriting haul cargo's `item_id`. The detached
`get_jobs()` handover overlay reuses `reason`, `remedy`, `item_id`, and
`blocking_job_id` to describe the requester and holder; that display overlay
is not persisted or consulted by simulation decisions. See
[ADR 013: tool toils](../decisions/013-tool-toils.md) for cancellation,
interruption, destruction, reservation-release and load semantics.

The viewer reads `held_tool` and `get_tool_item()` to display the held kind.
A separate left badge reuses the carried-item atlas cell (zero-based column 23,
row 4, 16 px cell with 1 px separation), tinted brown for axe and blue-gray for
pick; the right cargo badge remains independently visible. Empty hands draw no
tool badge or label. Both `blocked_no_tool` and `waiting_for_tool_handover` use
the text table's reason/remedy labels, including waits on active jobs.
`test_colonist_panel_toil.gd` covers those displays and a real two-job handover;
`test_tool_handover_scenarios.gd` covers the core transitions and save continuation.

The panel also reads `hands` and shows each `{kind, count}` entry as cargo text; empty hands
produce no cargo line. The viewer's haul-toil inference uses hands emptiness, not the retired
`carrying` field.

### 3.4 Reservations — implemented

One `ReservationTable` in core: `key (tile | item id | tool id | stockpile cell) → job id`.
Acquired only by the `reserve` toil (or the scheduler for the job target, as today), released
by `release_all`, by any toil failure, and by every terminal job transition. A save contains
the table; load rebuilds nothing from guesses. An invariant test asserts that no reservation
outlives its job on any path (complete, cancel, fail, invalidate, need interrupt, load).

### 3.5 Passability and movement — implemented

`content/objects.json` declares per object kind: `passable: bool`, `move_cost: int` (1 = floor),
`is_door: bool`. `WorldState.passability(x, y)` combines tile kind and the object on it and is
the only function route search, movement stepping, order validation and reachability checks
call. Doors are passable with cost 2 for colonists (later: locked for enemies). A colonist
re-validates the next path tile on every step; if it became blocked, the `go_to` toil requests
a re-route through the same bounded search (no instant recompute) and the colonist waits in
place with reason `rerouting`.

### 3.6 Interrupts — implemented

A toil declares `interruptible: bool` (`work` yes, `pick_up` no). Critical needs interrupt an
interruptible toil immediately, urgent needs only between toils. Interrupting a `work` toil
keeps partial progress on the tile (`work_progress` on the tile, not the colonist), so
returning resumes rather than restarts — this is what makes eating mid-dig cheap. The
interrupted job goes back to the queue with its aging preserved (it does not lose its place).

The implemented file map for this slice is `game/scripts/core/jobs/givers/need_giver.gd`
and `haul_giver.gd` for job creation, `game/scripts/core/jobs/job_queue.gd` and
`scheduling/global_assignment.gd` for shared assignment, and the consolidated
`game/scripts/core/jobs/toil_executor.gd` for toil execution and release.

**Implemented: rescue ([ADR 026](../decisions/026-trench-trapped-actor-and-rescue.md)).** A
trapped colonist (`colonist.trapped`) cannot act. Colonists never escape a trench on their own
(only a hostile actor does, via `escape_trench`), so a trapped colonist stays trapped until
another colonist rescues it.

*Priority.* `rescue_giver.gd` decides when a `rescue` job exists. Rescue is a priority layer of
its own, **above ordinary work (layer 5) and below both need layers (2 and 4)**. It reuses the
committed-proposal pathway a need job uses (`get_pending_assignments()` feeding
`GlobalAssignment.tick()`'s `committed_needs`, `world_state.gd`'s `_committed_jobs()`), so a
pending rescue pre-empts ordinary labour exactly as a need job does. It never pre-empts a need:
the candidate pool that `world_state.gd`'s `_rescue_candidates()` supplies each tick excludes any
colonist mid need-search or committed to a need job (mirroring `_colonists_not_searching_need()`),
any trapped colonist, any colonist `CombatGiver` owns, and any actor whose faction may not be
ordered, so a hostile actor built on the colonist definition (a raider) is never offered a victim
to rescue. `_committed_jobs()` always lets a need commitment overwrite a rescue one for the same
actor, never the reverse, so a rescuer who develops a critical need mid-rescue stays below both
need layers for as long as that need is pending.

*Choosing a safe route.* The job's target is never the trench tile itself, only one of the
victim's passable, non-trench neighbours. Every search uses the same unrestricted routable-to
callable the real `go_to` leg uses, and a (candidate, target) pair is accepted only when the
resulting path crosses no trench tile at all, not merely the victim's own: a candidate's only
route can cross an unrelated trench elsewhere on the map. (An earlier scheme searched with only
the victim's trench tile made impassable. That proved some detour existed, but not that the real
`go_to` leg, which does not avoid trenches, would walk it.) A pair whose only route crosses a
trench is rejected outright; if every pair is rejected, the giver reports `no_rescuer_available`
exactly as if no candidate existed, rather than send a rescuer in to fall in itself.

A candidate is a moving colonist that may keep walking its ordinary job while this multi-tick
search runs, so the search re-validates the candidate's live position after each full sweep
across every target and redoes a sweep whose start position has gone stale. This is bounded to
`MAX_STALE_RETRIES` consecutive discards per candidate, so one continuously moving worker cannot
starve out a later, idle candidate.

*Shared route budget.* Every search the giver runs shares ADR 004's per-colonist, per-tick route
budget with the scheduler and the toil executor. `RescueGiver.advance()` runs right after
`GlobalAssignment.tick()` (which clears the shared `_route_budget` ledger) and before
`_advance_colonists()`. It spends at most one `resume()` per candidate per tick, skips (and keeps
unfinished) a search whose candidate the scheduler or another victim's search already routed this
tick, and marks the ledger so a later toil re-route in the same tick defers likewise.
`get_route_telemetry()` reports the actual calls.

*Staying safe after commit.* The giver validates the route at commit time only. Afterwards
`world_state.gd` keeps a committed rescue trench-safe at its existing boundaries, never by a
synchronous search run to completion:

- The `go_to` toil's passability hook gives a rescue job `_rescue_routable_to()`, under which
  every trench tile is impassable and the target gets none of `_routable_to()`'s
  impassable-target exception. A mid-travel re-route around a newly blocked corridor therefore
  never crosses a trench, and a target made impassable reads as unreachable instead of being
  trimmed so that rescue work starts one tile off.
- A resume after a need interrupt (`_resume_paused_rescue()`) re-derives its route through the
  toil executor's budgeted, multi-tick re-route under the same passability, and requires the
  colonist to stand exactly on the target (not merely Chebyshev-adjacent) before work may start.
- The first drive of a fresh activation (`_rescue_activation_safe()`) scans the scheduler's
  already-computed path tile by tile (no trench, ends on the target, target still passable),
  since the map may have changed between commit and activation.

Whenever one of these checks finds that the commitment can no longer be completed safely,
including the scheduler's own `blocked_target_unreachable` verdict on a queued commitment (which
the giver retires the same tick), `_retire_rescue_job()` cancels the job through the shared
finish boundary and clears the giver's association. The job is never resubmitted under the same
rescuer, so the victim's next search is free to choose any available rescuer.

*Work progress.* Work progress is keyed by the job's explicit identity
(`_work_progress_key_for_job()`), scoped by job id only for `rescue` jobs: two rescue jobs that
share one target tile (one suspended mid-work, the other activating on the freed tile) can never
read or clear each other's saved progress. Every other job kind keeps the plain tile key, since
an ordinary job's target changes kind (or stops being a valid target) the moment the job
completes, so a same-kind job cannot reuse that tile the way two rescues can. Every terminal
boundary (a cancel/fail/invalidate command on an active or suspended rescue, trapping, death, a
refused reservation, retirement) clears a rescue's key by that explicit identity, never by a
lookup of a reservation owner that has already been released, so a paused ordinary job's
plain-key progress on the same tile is never erased.

*Completion.* The rescuer's `work` toil (`content/jobs.json`'s `rescue` entry, 20 ticks, reusing
the ordinary `reserve, go_to, work, release_all` sequence) moves the trapped colonist onto the
rescuer's tile and clears its `trapped` field. The freed colonist re-enters the scheduler's pool
like any idle colonist; it does not resume the job it had before falling in (that job was
released, as by `cancel_job`, the instant it became trapped). If the assigned victim no longer
exists or is no longer trapped when the work completes (it died, say), the completion effect
treats the rescue as obsolete and does nothing beyond the ordinary cleanup. It never substitutes
a different adjacent trapped colonist, which could free the wrong victim or bypass that victim's
own live rescue claim.

When no rescuer candidate exists at all (every other colonist is trapped or busy with a need),
`get_colonist_rescue_reason()` exposes `no_rescuer_available`, mirroring
`get_colonist_need_reason()`'s `need_unmet:<kind>` pattern, for the panel to render as "trapped
in a trench, no one can help".

*One rescue per victim.* Alongside the job's ordinary `tile:x,y` reservation key, a committed
rescue job holds a key in its own domain, `trapped:<victim_id>` (`orders-and-movement.md`,
"ReservationTable key domains"). The key moves through the same activation/reactivation boundary
as the target key, via `job_queue.gd`'s generic `set_extra_reservation_keys()` callback, so it is
released on suspend and reacquired on resume. This needs no `reservation_table.gd` change and no
per-kind special case beyond the callback (haul uses the same mechanism for its `item:`/`cell:`
pair). An earlier design had `rescue_giver.gd` acquire the key directly at commit time; that
broke the invariant that a reservation exists only while its job is active, and failed across a
need or combat interrupt's suspend/resume cycle. Deduplication reads `rescue_giver.gd`'s
victim-association record directly rather than the reservation table, since a queued or
suspended rescue job holds no `trapped:` key.

*Persistence.* A rescue job's victim is deliberately not a per-job field, and target tile plus
adjacency cannot stand in for it: two victims can share a target tile or have overlapping
candidate adjacency, so guessing could match a restored job to the wrong victim or to none.
`RescueGiver` instead exposes its `job_id -> victim_id` map as save data (`get_job_victims()`),
persisted verbatim with the giver's other continuation state and restored on load
(`restore_victim_assignments()`/`restore_pending_assignments()`, called from `state_codec.gd`'s
`decode()`).

The implemented file map is `game/scripts/core/jobs/givers/rescue_giver.gd` for job creation,
`job_queue.gd` for the generic extra-reservation-keys mechanism, `state_codec.gd` for load-time
continuation, and `world_state.gd`'s `_toil_on_work_complete()` `"rescue"` case for the
completion effect.

### 3.7 Calendar urgency

`content/calendar.json`: `{day_length_ticks: int, windows: [{id, labour, from, to, boost,
label}]}` (ADR 008). `day_length_ticks` is the tick count of one in-game day; `from`/`to` are
1-indexed, inclusive day-of-year numbers (day 1 is spring day 1; no other season-length
content exists yet, so later seasons are added by offsetting their windows' day numbers, not
by changing the schema). `day_length_ticks` is **2200** (ADR 024: at x1, 2 ticks per second,
a day takes about 18.3 real minutes, slow enough for needs decay — see below — to be
survivable). The seeded window is `{id: "sow", labour: "farm", from: 1, to: 20, boost: 1,
label: "sowing window"}`; `from`/`to` are day numbers, not ticks, so lengthening `day_length_ticks` changes how long a day takes without changing which day numbers
the sowing season spans.

`CalendarService` (`game/scripts/core/calendar/calendar_service.gd`) is a plain, scene-
independent core class that loads this content once and exposes pure queries: `day_of_tick(tick)`
derives the day from `day_length_ticks` and the tick alone; `active_boost(labour, tick)` sums
every window whose `labour` matches and whose `[from, to]` contains that day, returning 0 when
none match — this is the "calendar boost" term in 3.2's effective-priority formula. The work
table shows these active boosts.

`alert_state(tick, has_labour_enabled, has_plowed_plot, has_seed_stock, already_fired)` warns
`ALERT_LEAD_DAYS` (3) days before the soonest upcoming window opens, and only when nobody has
that window's labour enabled and the colony already has both a plowed plot and seed stock —
the colonist/farm-order facts this needs are passed in as plain booleans rather than read from
`WorldState`, so the service has no dependency on `WorldState`. Once `already_fired` is true for a window it reports `due: false` even at the
exact lead-day tick, so the alert fires at most once per window. This is a data change to add
new windows (harvest, winter firewood).

### 3.8 Explainability (unchanged policy, extended vocabulary)

Every colonist exposes `activity`, `job_id`, `toil`, `reason`, `remedy`. New reasons:
`blocked_missing_input`, `blocked_no_tool`, `waiting_for_tool_handover`, `blocked_destination_full`, `need_unmet:<kind>`,
`trapped`, `no_rescuer_available`, `rerouting`, `retry_in:<ticks>`, `labour_disabled`. `trapped`
identifies a colonist unable to act after trench entry; `no_rescuer_available` is exposed for a
trapped colonist when the rescue giver finds no reachable eligible rescuer. The panel shows them;
headless tests assert them.

## 4. Testing the AI without a full game

The slice already has tiles, trees, wood items and three colonists. Each increment below adds
the minimum content its tests need; every test is headless, seeded and hash-checked:

- **Passability**: a map with a chair (passable cost 3), a door and a wall; routes go through
  the door and around the wall; movement never enters the wall; building a wall across a route
  mid-walk triggers `rerouting`, not a stall.
- **Tools**: two colonists, one axe, two chop orders; both orders complete; the axe is never
  reserved by a finished job; total idle ticks below a bound.
- **Needs**: one food item, a hungry colonist mid-dig; it eats at the next toil boundary and
  resumes with the tile's progress kept; with no food the reason `need_unmet:food` is exposed
  and work continues.
- **Labour table**: colonist A farm=1 haul=4, colonist B the reverse; mixed orders → A plants
  first, B hauls first; with `farm` off for both, planting jobs report `labour_disabled`.
- **Calendar**: same orders inside and outside the sowing window → inside, planting precedes
  hauling for every colonist with farm enabled; outside, aging order holds.
- **Storage**: two haulers, one free stockpile cell → one hauls, the other reports
  `blocked_destination_full` and takes other work; no item is dropped in the field.
- **Invariant**: after every scenario, `ReservationTable` contains only keys owned by active
  jobs; no colonist is idle while an eligible reachable unreserved job exists.

## Implemented: increment D, the needs layer

Increment D (the table row above) shipped in five steps: needs decay and
thresholds (schema v6), berry/water/bed content and their tile representation
(schema v7), the needs decision layer itself (need jobs, nearest-reachable-
unreserved-source search), critical-need interrupts that keep a paused
`work` toil's progress on the tile, and the colonist panel/alert-list
presentation this page's own section 3.8 and section 4's "Needs" test bullet
describe. What shipped matches section 3.1's decision-layer shape and
section 3.6's interrupt semantics closely, with these concrete choices where
the design left room:

- **Need kinds**: exactly three ship — `food`, `water`, `rest` (section 3.1
  calls them "hunger, thirst, rest" in prose; the data and code use the noun
  form throughout). Each has `warn`/`urgent`/`critical` thresholds and a
  `restore` value, declared in `content/needs.json`, matching the three-
  threshold design in 3.1. Decay is declared in **points per day**
  (`rate_per_day`, ADR 024: food 67, water 100, rest 80) rather
  than points per tick, applied through a deterministic per-colonist,
  per-need integer accumulator (`ActorNeeds.apply_tick()`) so the exact tick
  a need loses its next point is reproducible and float-free regardless of
  `day_length_ticks`.
- **Sources**: a ground-berries tile for `food`, any `water` tile for
  `water`, a placed `bed` object for `rest` — exactly the three examples 3.1
  names. A need job is `eat_food`, `drink_water`, or `sleep`; `sleep` reuses
  the generic `work(ticks)` toil like `dig`/`chop`, while `eat_food`/
  `drink_water` use a new one-tick `consume` toil instead of `work`
  (`content/jobs.json`).
- **Reason vocabulary actually exposed**: `need_unmet:<kind>`,
  `blocked_source_reserved`, `blocked_source_unreachable`
  (`WorldState.get_colonist_need_reason()`). Section 3.8's larger new-reason
  list (`blocked_missing_input`, `blocked_no_tool`, `blocked_destination_full`,
  `retry_in:<ticks>`, `labour_disabled`) belonged to later increments (tools,
  labour table) and was still design-only at the time this section shipped;
  `labour_disabled` shipped with the labour table/calendar work
  and `blocked_missing_input` with till/sow (see "Implemented: farming"
  below). An earlier draft of this design named the no-source-available case `need_source_missing:<kind>`; the shipped
  reason string is `need_unmet:<kind>` for both "still searching, found
  nothing" and "searched, nothing reachable" — there is no separate
  `need_source_missing` reason in the code. The presentation layer (below)
  renders and alerts `need_source_missing:<kind>` wherever it handles
  `need_unmet:<kind>`, generically, off whatever string
  `get_colonist_need_reason()` returns — so the day WorldState is changed to
  emit the distinct reason, no further presentation change is needed — but
  nothing in the shipped core produces it today, and this page normalizes to
  the name that actually ships.
- **Interrupts**: critical needs pause an interruptible `work` toil
  immediately, keeping its tick count on `WorldState._work_progress` (keyed
  by tile, not colonist) exactly as 3.6 specifies; urgent needs wait for the
  current toil to end. The paused job resumes rather than restarts.
- **Presentation**: `colonist_panel.gd` reads three need
  bars straight off `get_colonists()`'s `needs` field, and shows a committed
  need job's activity ("Eating"/"Drinking"/"Sleeping") and toil by resolving
  the job id carried on the colonist's own `route`/`work` field through
  `get_jobs()` — the same pattern the existing dig/chop/haul display uses,
  never a position comparison. `eat_food`/`drink_water` have no `work` phase,
  so for the single tick between route arrival and the instant `consume` toil
  neither `route` nor `work` names the job any more; `WorldState.
  get_active_need_job_id(colonist_id)` (a thin getter over
  `_need_job_by_colonist`) is the fallback the panel reads for exactly that
  tick, so "Eating"/"Drinking" and the "Consuming" toil stay visible for the
  whole job, not just its travel phase. `boot.gd`'s status area lists every
  colonist currently `need_unmet:<kind>` or `need_source_missing:<kind>`,
  recomputed (not appended) on every refresh so it never grows and clears the
  instant the reason does.

## Implemented: farming — till/sow job kinds

Two new job kinds, content-only (`content/jobs.json`), both `labour: "farm"` and composed of
the same toils as `dig`/`chop`/`forage` (`reserve`, `go_to`, `work`, `release_all`) — no new
toil, matching this page's own "jobs as toils" design (3.3) exactly:

- **`till`**: target must be a `soil` tile (same check as `dig`'s own target validation); its
  `on_work_complete` effect turns the target tile to a new tile kind, `plowed_soil` (passable,
  `move_cost: 1`, matching `floor`'s shape).
- **`sow`**: target must be a `plowed_soil` tile *and* at least one `seed` item (a new
  `content/items.json` entry, `{"id": "seed", "kind": "seed"}`) must exist anywhere in the
  world — on the ground/stockpile *or* mid-haul in a colonist's hands (ADR 037),
  since hauling moves an item out of the ground-item map into `colonist["hands"]`
  (`toil_executor.gd`'s `pick_up`) and a seed in transit still counts — else the order is
  rejected at submission — the
  same mechanism as `dig`/`chop`'s own `invalid_target` rejection, but with reason
  `blocked_missing_input` (3.8's already-documented vocabulary for a job blocked on a missing
  item). Its `on_work_complete` effect removes one existing seed item — ground/stockpile first
  (first found by id order), falling back to the lowest-id colonist currently carrying one — and
  turns the target tile to a second new tile kind, `planted` (same passable/`move_cost: 1`
  shape). `planted` is a terminal tile state for this slice — growth/harvest is out of scope.
  Because the "a seed exists" precondition is only checked at submission, two `sow` orders can
  both be accepted while exactly one seed exists (each submission still sees it); the first to
  reach `on_work_complete` consumes it and plants, and the second finds nothing left to consume
  and fails `blocked_missing_input` instead of planting for free — the same terminal-failure
  path (`JobQueue`'s pending-fail-reason override) a haul job takes when its destination goes
  away mid-carry. If the seed consumed this way was mid-haul (a colonist's hands, not
  the ground), the haul job that was carrying it is likewise failed `blocked_missing_input`
  rather than later placing an emptied stack.

Both job kinds use the existing `farm` labour kind (already in `LABOUR_KINDS`) and the existing
`work(ticks)` toil, so the labour-priority formula, `labour_disabled` reason and calendar
boost (3.2/3.7, the seeded `sow` window already names `labour: "farm"`) apply unchanged: a
colonist with `farm` preferred over `haul` activates a queued till/sow job before its own haul
jobs, and `farm` disabled for every colonist leaves till/sow jobs queued with reason
`labour_disabled` while other labour kinds proceed. Starting seed stock, a toolbar order for
till/sow, and wiring the calendar alert into live state were not part of this increment; they
belong to the viewer (`game/scripts/viewer/`, `boot.gd`) and the world state.

The `"tile:"` reservation only guarantees no other order-driven job was *active* on till/sow's
target at the same time, not that the tile still matches by completion time: a critical-need
interrupt releases a paused till/sow job's own reservation (3.6/ADR 009), so a second order
queued for the same tile can activate and complete first. `_toil_on_work_complete()` therefore
re-checks its own target — till against `soil`, sow against `plowed_soil` — immediately before
applying its effect, and fails a stale job `invalid_target` (mirroring `dig`/`chop`'s own
submission-time rejection) rather than overwriting a tile another job already changed or
re-consuming a seed on an already-planted tile.

`HaulGiver` attaches a loose seed to a haul job the instant it appears on the ground, whether or
not any stockpile has room for it; with none, that haul job sits queued forever under
`blocked_destination_full`, never having picked the item up. When `sow`'s completion effect
consumes that same ground seed, the dangling haul job is failed `blocked_missing_input` and its
reservations released the same way a mid-carry consumption already fails the hauler (see above),
rather than left retrying forever for an item that no longer exists.

## 5. Sequencing

| Increment | Adds |
| --- | --- |
| A. Passability table + objects + re-route | chair, door, wall objects; `passability()`; re-route |
| B. Toils + ReservationTable + backoff | generic job execution; hauling to a stockpile zone with item + cell reservations; wood on the ground gets hauled |
| C. Labour table + calendar urgency | per-colonist priorities UI in the panel; sowing window; tilling + planting orders |
| D. Needs layer | hunger/thirst/rest with thresholds; food items, water tile, bed; interrupts with kept progress |
| E. Tools | axe/pick as items; fetch/release toils; two-colonist handover test |

A is small and unblocks B; B is the core of this design and the one to review most carefully;
C–E can be reordered by priority. Each increment is a milestone of several smaller changes.

## 6. What this design does not do (yet)

No utility-AI scoring (layered decisions plus a priority table are enough); no per-colonist
skills or speed differences (content later); no animals, combat or mental states; no
multi-map pathing. The layering in 3.1 leaves room for each (skills weight job choice in
layer 5; combat becomes a layer between 1 and 2).
