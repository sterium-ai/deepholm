# Orders and movement

> **In short:** How the player's orders (dig, chop, build, haul and so on)
> become jobs, how colonists are chosen for them, and how a colonist walks to
> a job and carries it out one tick at a time.

This page documents the implemented contract for dig/chop/forage/haul
orders, the job queue that arbitrates them, the generic toil vocabulary and
reservation ledger that drive all four, the needs decision layer's own
eat_food/drink_water/sleep jobs (same toil vocabulary and reservation ledger,
driven outside the fair scheduler), the tick-driven route/work stepping that
carries a colonist from an order to a completed tile change, a hauled item,
or a restored need, and the persistent construction-site model (ADR 040) --
see "Construction: `build`" below.

## Commands: `dig`, `chop`, `forage`, `mine`, `cancel_job`

`WorldState.apply(command)` accepts these job command types alongside the
base envelope described in `game/scripts/core/commands/README.md`. Their
`payload` shapes:

- `dig` / `chop` / `forage` / `mine` — `{x: int, y: int, priority: int,
  assignee: String}` (`priority` optional, defaults to `1`/`NORMAL`;
  `assignee` optional, an actor id). `x`/`y` must be in-bounds
  integers, and the target must already be `soil` (for `dig`), `tree` (for
  `chop`), `rock` (for `mine`), or a `berry_bush` object (for `forage` — a
  content object, not a tile kind, since the bush sits on top of ordinary
  floor); otherwise the command is rejected `invalid_target`. Rock, like a
  tree, is impassable, so `mine` has no passability check (`chop`'s shape,
  not `dig`'s). A non-integer `x`, `y`, or `priority`, or a non-string
  `assignee`, is rejected `invalid_payload`. A non-empty `assignee` naming no
  existing actor is rejected `invalid_target`; naming an actor whose
  faction's `rules.may_be_ordered`
  (`ContentRegistry.get_entry("factions", faction_id)`) is not `true` is
  rejected `not_ordered_by_player` instead of submitting the job. `assignee`
  is carried through as `GlobalAssignment.submit()`'s existing `restrict_to`
  parameter (already used internally by `need_giver.gd`'s own committed
  jobs), so the job may only ever be activated for that one actor.
- `cancel_job` (also `complete_job`, `fail_job`, `invalidate_job`) —
  `{job_id: string}`. A missing or empty `job_id` is rejected
  `invalid_payload`.

A valid `dig`/`chop`/`forage`/`mine` submits a job to the queue via the scheduler; a
valid `cancel_job` forwards to the queue's `cancel()`. Both paths return the
queue's own rejection `reason`/`message` (mapped from `reason`/`remedy`) when
the queue itself refuses the request, e.g. `unknown_job` or
`job_already_terminal` for a `cancel_job` naming a job that no longer exists
or has already finished. See `game/scripts/core/world_state.gd`
(`_apply_job_command`).

### Faction-gated assignment and reservations

An assignee's `may_be_ordered` check at submission (above) only ever guards
the `dig`/`chop`/`forage` command path. Two further gates live inside
`GlobalAssignment` itself (`game/scripts/core/scheduling/global_assignment.gd`),
wired from `WorldState._init()` via `set_order_eligibility()`/
`set_reservation_gate()` (never a hardcoded `"colony"` string — both read
through `ContentRegistry.get_entry("factions", faction_id)`), independently
of how a job reached the scheduler (an order's `assignee`, a committed need
job, an ambient `haul` job with no assignee at all, or a test submitting
directly through `GlobalAssignment.submit()`'s `restrict_to`):

- **Order eligibility** (`rules.may_be_ordered`): consulted twice. First, an
  early-exit optimization only, for every worker in `tick()`'s per-worker
  proposal scan, before an *unrestricted* entry (`haul`, which has no actor
  pool of its own to filter, or any order with no `assignee`) may be
  proposed to it at all (`need_giver.gd`'s `advance()` additionally filters
  the colonist pool it scans by the same rule, so an ineligible actor's need
  is never even evaluated). Second, authoritatively, alongside reservation
  eligibility below, immediately before *any* proposal's reserve step —
  covering a `restrict_to`'d order or committed need whose actor's faction
  changed after that early filter ran but before a multi-tick route search
  finished, which the early filter alone cannot catch.
- **Reservation eligibility** (`rules.may_reserve_colony_items`, every target
  in this slice being colony-owned): consulted immediately before a chosen
  job's reserve step would acquire its `tile:`/`item:`/`cell:`
  `ReservationTable` key — `tick()`'s pre-`advance_selection()` "ready"
  selection loop for a fresh activation, and `resume_assignment()`'s
  pre-`reactivate()` check for a job resuming after a critical-need
  interrupt — **never after**, so a refused actor's reservation is never
  even transiently held (covering a faction change made while the job was
  suspended, which must not let it reacquire on resume). Both gates share
  one refusal path: a refused `{job_id, worker}` pair is recorded via
  `GlobalAssignment.take_refused_reservations()`; `WorldState` calls
  `_resolve_refused_reservations()` at the end of `tick()` (after
  `_advance_colonists()`, since a need resolving there can itself trigger
  and refuse a resumption) and at the end of `_apply_job_command()` (a
  `cancel`/`fail`/`invalidate_job` command can resolve a need the same way
  outside `tick()` entirely) — always before the enclosing mutator returns,
  since `GlobalAssignment`'s refusal bookkeeping is transient and never
  saved. Resolution terminally fails the job `not_ordered_by_player` through
  the same terminal path `zone_remove`'s `blocked_destination_gone` already
  uses (`JobQueue.set_pending_fail_reason()` + the job's own `fail()`),
  returns a refused `haul` resumption's carried item to the ground (the
  worker id travels with the refusal since the job's scheduler assignment is
  already gone by then), plus `need_giver.gd` bookkeeping for a need job.

`WorldState._resubmit_unreachable_job()` (the unreachable-first-leg
cancel-and-resubmit) preserves a player-ordered job's `assignee` restriction
across the resubmission via `GlobalAssignment.restrict_to_for()`, read before
the original job's activated-entry snapshot is erased.

## Queue blocking reasons

Once accepted, a job can still sit `queued` and blocked before becoming
`active`. `JobQueue.tick()` (`game/scripts/core/jobs/job_queue.gd`)
retries every queued job each tick and reports exactly one of:

| Reason | Cause | Remedy |
| --- | --- | --- |
| `blocked_target_reserved` | another job already owns the target tile | `wait_for_target_release` |
| `blocked_target_unreachable` | the reachability callable returned `false` | `restore_target_access` |
| `blocked_reachability_unavailable` | the reachability callable is missing or returned a non-boolean | `provide_reachability_check` |

Blocking is queued state with a nonempty `reason`/`remedy`, not a separate
status. A blocked job needs no resubmission: it is retried automatically and
activates as soon as its target frees up or becomes reachable again.

## Tick-cost constants

Movement and work durations are content, not inline magic numbers or
`WorldState` constants: every `content/tiles.json` entry carries its own
`move_ticks_per_tile`, and a `content/jobs.json` entry carries `work_ticks`
when its kind has a `work` phase:

```json
{"id": "soil", "passable": true, "move_cost": 1, "diggable": true, "display": {"label": "Soil"}, "move_ticks_per_tile": 4}
{"kind": "dig", "labour": "mine", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 30}
{"kind": "mine", "labour": "mine", "needs_tool": "pick", "toils": ["fetch_tool", "reserve", "go_to", "work", "release_all"], "work_ticks": 30, "retry_base_ticks": 20, "retry_cap_ticks": 80}
```

`WorldState._init()` reads `move_ticks_per_tile` off the first tile entry and
every job's `work_ticks` into a `kind -> ticks` map (`_load_work_ticks()`),
then injects both into `ToilExecutor`'s existing constructor parameters — the
same values, now content instead of code. A job kind with no `work_ticks`
field (`haul`, `eat_food`, `drink_water`) has no `work` phase at all — see
"Need jobs" below for what they drive instead. `site_work` (below) is the one
exception: it declares a placeholder `work_ticks` purely to enable its `work`
phase, since its real duration is read from the construction site it targets,
never this content constant.

## Route step semantics

Once the scheduler assigns a colonist to a job with a resolved path,
`WorldState._advance_colonists()` drives that colonist by exactly one tick at
a time. A colonist's `route` field (`null` when not moving) holds:

```gdscript
{"job_id": String, "path": Array[Vector2i], "step": int, "move_ticks_remaining": int}
```

- `path` is the resolved tile sequence the colonist walks; `step` is the
  index of the tile the colonist currently occupies within it.
- Each tick decrements `move_ticks_remaining`. When it reaches `0`, the
  colonist advances one tile: `step` increments, `x`/`y` move to
  `path[step]`, and `move_ticks_remaining` resets to `move_ticks_per_tile`
  (content, see "Tick-cost constants" above) for the next tile — one tile
  advance per `move_ticks_per_tile` ticks.
- Arrival (`step == path.size() - 1`) clears `route` to `null` and
  transitions the colonist to `work` instead of resetting the movement
  timer.

**Travel is continuous across tile boundaries.** The one-tile
advance above is an authoritative, instantaneous state change; the *visual*
glide a colonist draws between tiles is a presentation-only concern of
`colonist_sprites.gd` and lags one step behind it by design. `colonist_sprites.gd`
interpolates between its own `previous_tile`/`current_tile` cache (set by
`_update_motion()` whenever `refresh()` observes a one-tile position change),
over a glide duration of `move_ticks_per_tile * seconds_per_tick()` -- the real
duration of one full tile-crossing, read via `WorldState.get_move_ticks_per_tile()`
-- never a single `seconds_per_tick()` (one simulation tick, one quarter of a
tile-crossing at today's `move_ticks_per_tile`). Using one tick's duration alone
made the sprite finish its glide after 1/4 of the real crossing time and then
hold at the destination pixel for the remaining 3/4, which read as a per-tile
pause.

`dig` targets are passable soil, so the router resolves `path` all the way
to the target tile and a one-tile (or empty) path means the colonist already
stands on it. `chop` and `forage` targets are impassable (a tree tile; a
`berry_bush` object, per `content/objects.json`): the router is allowed to
terminate a search on that tile only to detect reachability, but
`GlobalAssignmentScheduler.tick()` (`game/scripts/core/scheduling/global_assignment.gd`)
then trims that final tile from the assigned `path` before handing it to
the colonist, since a colonist may never occupy a tile `passable()` itself
rejects. So for `chop`/`forage`, a one-tile (or empty) `path` means the
colonist already stands on the tile *adjacent* to the tree/bush, not on it,
and `work` begins from that adjacent tile. A resolved path of one tile or
fewer skips `route` entirely and starts `work` immediately in every case;
only what "the target" means (on it, for `dig`, versus next to it, for
`chop`/`forage`) differs. `content/jobs.json` gives `forage` the same
`reserve, go_to, work, release_all` toil sequence as `dig`/`chop`.

`work` (`null` when not working) holds:

```gdscript
{"job_id": String, "ticks_remaining": int}
```

Each tick decrements `ticks_remaining`, seeded from `content/jobs.json`'s
`work_ticks` for that job's kind. When it reaches `0`, the job completes: the
tile transform below is applied, the job is finished through the scheduler,
and `work` is cleared to `null`.

## Passability

`WorldState.passability(x, y, faction_id: String = "colony")`
(`game/scripts/core/world_state.gd`) is the one authoritative movement rule
for a tile: it combines the tile's own kind with any object occupying it and
returns `{"passable": bool, "cost": int, "is_door": bool}`. Route search
(`_is_passable`, the `RouteSearch` cost callable), movement stepping
(`_advance_route`), order validation (`dig`/`chop` target checks) and
reachability checks all call this one function — there is no second notion
of "blocked" anywhere else, which is the fix for the classic colony-sim
per-object collision bugs (see `docs/architecture/colonist-ai.md` section
3.5 and section 2's bug table). Those call sites pass no `faction_id` and
so are implicitly colony-only; non-colony actors reach this function through
the faction-aware paths described under "Incident jobs" below.

`faction_id` is consulted only when the target tile's object declares
`is_door: true` (ADR 014): `ContentRegistry.get_entry("factions",
faction_id).rules.may_pass_doors` of `false` makes the door impassable for
that faction regardless of the object's own `passable`/`move_cost`
(`{"passable": false, "cost": 0, "is_door": true}`); `true` — `colony` and
`allies`, per `content/factions.json` — leaves the door's own
`passable`/`move_cost` in effect. A faction id absent from the registry (or the
default `"colony"`, always declared) fails open (`true`). A non-door object
or a bare tile is unaffected by `faction_id`.

An object on a tile is authoritative over the tile's own kind: an impassable
object blocks the tile outright (`cost: 0`), and a passable object supplies
its own movement cost in place of the tile's. With no object, floor and soil
cost `1` and everything else (rock, hazard, tree) is impassable. Object
costs are content, not code — `game/content/objects.json` declares each
object kind's `passable`, `move_cost`, and `is_door`:

| Kind | Passable | Cost | Door |
| --- | --- | --- | --- |
| `chair` | yes | 3 | no |
| `door` | yes | 2 | yes |
| `wall` | no | — | no |
| `table` | no | — | no |

`WorldState.get_object(x, y)` returns the occupying kind (`""` for none);
`place_object`/`remove_object` commands are the only way to set it (rejected
`invalid_target` for an out-of-bounds tile, a colonist's own tile, a tree
tile, or a tile that already holds an object; rejected `invalid_payload` for
a kind absent from `content/objects.json`). Both apply immediately, with no
job queue involved, mirroring the debug/build precursor framing in
`colonist-ai.md` 3.5.

### Rerouting

A colonist's `route` re-validates its next path tile via `passability()`
every tick (`_advance_route`), before consuming any movement time. A route
built when the path was clear can still be interrupted by a `place_object`
command landing on it mid-walk; the next tile becoming impassable starts a
re-route instead of letting the colonist walk into it or stall silently.

`route.rerouting` (`null` when not rerouting) holds the in-flight bounded
search's own snapshot, persisted the same way as any other route search in
this codebase (see `game/scripts/core/routing/README.md`) so a save/load
mid-reroute resumes rather than restarts:

- `_begin_reroute()` starts a `MeasuredRoute` search from the colonist's
  current tile to the job's target and stores it (keyed by colonist id) in
  `WorldState._reroutes`; the colonist holds position with reason
  `rerouting` (`colonist-ai.md` 3.8) while `route.rerouting` is non-null.
- `_resume_reroute()` advances that search by exactly one bounded `resume()`
  call per tick — the same step budget as every other route search, never an
  unbounded recompute.
- `STATUS_FOUND` replaces `route` with the newly found path (or starts
  `work` immediately when the colonist already stands on or adjacent to the
  target, mirroring `_start_assignment()`'s own shortcut) and clears
  `route.rerouting`.
- `STATUS_UNREACHABLE` cancels the job through the existing queue mechanism
  and resubmits the same target as a fresh job, so the global scheduler's
  own reachability check reports `blocked_target_unreachable` on it exactly
  as for any other unreachable job — rerouting invents no separate release
  path.

## Tile transforms on work completion

`WorldState._advance_work()` applies exactly these transforms when a job's
work timer completes:

- `dig` — the target tile changes `soil -> trench` (ADR 026,
  `docs/decisions/026-trench-trapped-actor-and-rescue.md`; not `floor`).
  `trench` is passable with the same `move_cost`/`move_ticks_per_tile` as
  `soil`/`floor`, but not `diggable`. Dig always spawns one `sand` item
  (`_spawn_item("sand", ...)`, `world_state.gd`'s generalized
  `_spawn_wood_item()` shape), and separately draws exactly one roll from
  `content/jobs.json`'s dig `find_table` (`gold_coin`/`flint`/`coal`/`seed`/no
  find, weights 5/20/10/10/55) against a dedicated `RandomNumberGenerator`
  salted off the world seed (`WorldState._dig_find_random`, mirroring
  `IncidentScheduler._random`'s own salted-stream pattern) — spawning that
  item too when the roll finds one. Both the guaranteed sand and any find are
  placed on the nearest adjacent passable, non-`trench` tile to the dug tile
  (row-major tie-break: lowest `y`, then lowest `x`; falls back to the trench
  tile itself only when no adjacent tile qualifies), never inside the trench.
  When more than one dig job completes on the same tick, `WorldState`
  defers every completion's find roll to `_resolve_dig_finds()` (run once,
  right after that tick's colonist-advance pass) and consumes them in
  ascending job-id order, so the find sequence never depends on
  `_advance_colonists()`'s own colonist-id iteration order.
- `chop` — the target tile changes `tree -> floor`, and one ground-wood item
  is added at that tile (`get_ground_wood(x, y)` increments by one, tracked
  in `WorldState`'s internal ground-items map).
- `mine` — the target tile changes `rock -> floor`, and one ground-stone item
  is added at that tile (`_spawn_stone_item()`, mirroring `_spawn_wood_item()`'s
  shape).
- `forage` — the target tile's kind changes to `floor` (unconditionally, not
  only from `soil`), the `berry_bush` object occupying it is removed, and
  one ground-berries unit is added at that tile (`get_ground_berries(x, y)`
  increments by one, a direct per-tile counter, not a first-class item —
  see `_spawn_berries_item()`).

No other tile kinds or item types are produced by order completion.

## Trenches and trapped actors

The trench contract is defined by [ADR 026](../decisions/026-trench-trapped-actor-and-rescue.md)
and implemented by the trap/climb-out and rescue slices. A trench is
passable for ordinary movement, but a colonist or hostile actor that enters it is trapped on
entry. The trap check runs at the movement/job boundary before the arriving job's completion
effect; the actor's current job is released through the ordinary cancellation/cleanup path, and
a trapped colonist cannot act or auto-escape. Non-hostile colonists remain trapped until a
rescue completes.

Hostile actors receive an autonomous `escape_trench` job. It uses the existing
`reserve, go_to, work, release_all` toil sequence and works for the duration declared by that
actor's `actors.json` entry (`wild.trench_climb_ticks`, currently 40 ticks). The escape job is
restricted to the trapped hostile actor and targets its recorded entry tile; on completion the
actor leaves the trench. A colonist never receives this climb-out job.

`rescue_giver.gd` creates `rescue` jobs for trapped colonists through the scheduler's committed
assignment path. Rescue is one priority layer above ordinary labour and below both need layers:
a pending rescue pre-empts ordinary work, but a colonist with a need search or committed need is
not selected as its rescuer, and a need that arises during rescue wins over the rescue. The
rescuer must reach a passable, non-trench neighbour of the victim by a trench-free real route;
the `rescue` job reuses `reserve, go_to, work, release_all` and works for 20 ticks. Completion
moves the victim to the rescuer's tile and clears `trapped`; cancellation, interruption,
failure, invalidation, death, or an unsafe route releases the job normally and allows a later
search to choose another rescuer.

The rescue job also claims `trapped:<victim_id>` in the shared reservation table, alongside its
ordinary target `tile:` key. `JobQueue` acquires and releases this extra key at the same
activation, suspension, reactivation, restore, and terminal boundaries as the job's other
reservations, so two rescue jobs cannot claim one victim and queued or suspended jobs do not
hold a live `trapped:` reservation.

## Jobs, toils and reservations

Every job kind shares a small, fixed toil vocabulary (a generalization of
dig/chop's original go_to/work stepping), backed by one reservation ledger
and a content-declared per-kind toil sequence. This section documents that
vocabulary, `content/jobs.json`'s shape, the `ReservationTable`'s key
domains, the `zone_add`/`zone_remove` commands stockpile zones are drawn
with, and the haul job kind's backoff constants, all built on top of the
dig/chop contract documented above. "Need jobs" below documents
eat_food/drink_water/sleep, which reuse this same vocabulary and ledger but
are driven by the needs decision layer (colonist-ai.md 3.1), not the fair
scheduler this section otherwise describes.

### The toil vocabulary

`ToilExecutor` (`game/scripts/core/jobs/toil_executor.gd`) implements
exactly eight toils, `ToilExecutor.VOCABULARY`:

| Toil | Meaning |
| --- | --- |
| `reserve` | Acquire every key this job needs on the shared `ReservationTable` (today: satisfied by the scheduler activating the job, which reserves its `tile:` key; haul's activation additionally reserves an `item:` and a `cell:` key — see below; a need job's own commit step reserves its source's `tile:` key the same way — see "Need jobs"). A `site_fetch`/`site_work` job's construction site is a different case entirely — see "Construction" below. |
| `go_to` | Walk the resolved path toward a target, one tile per `move_ticks_per_tile` ticks (content, see "Tick-cost constants" above). Haul and `site_fetch` drive this twice: once toward the loose item, once toward the reserved stockpile cell or construction site. |
| `pick_up` | Remove a ground item and set the colonist's `hands`. Requires the colonist on or adjacent to the item's tile and the item still on the ground; fails typed (`item_out_of_reach`, `item_not_found`) otherwise. |
| `work` | Hold position for a duration (`content/jobs.json`'s `work_ticks` for that job's kind, or -- `site_work` only, see "Construction" -- the site's own remaining need); a kind with no `work_ticks` field (haul, `site_fetch`, eat_food, drink_water) has no work phase at all. |
| `place` | Return the carried item to the ground at a destination cell and clear `hands`. Requires the cell still free of any colonist or ground item; fails typed (`destination_blocked`) otherwise. |
| `deposit` | Transfer carried hands into a construction site's own `held_materials`, clamped to what it still needs, instead of minting a ground item — see "Construction" below. |
| `consume` | Instantly restore a need and remove its source unit (food only); requires the source still valid (`_consume_source_valid()`), fails typed (`source_gone`) otherwise. Used only by `eat_food`/`drink_water` — see "Need jobs". |
| `release_all` | Release every `ReservationTable` key this job owns; runs on every terminal job transition (`complete`/`cancel`/`fail`/`invalidate`), not only success. |

`dig`/`chop`/`forage`/`sleep`/`site_work` only ever drive `go_to` and `work`
(their `route`/`work` fields are exactly the ones documented above); `haul`
drives `go_to` (twice), `pick_up`, and `place`, with no `work` phase;
`site_fetch` drives the same two-leg `go_to`/`pick_up` shape but ends in
`deposit` instead of `place`, also with no `work` phase; `eat_food`/
`drink_water` drive `go_to` then the instant `consume` toil, also with no
`work` phase. `reserve` and `release_all` are never a colonist's *current*
toil — they are instantaneous bookkeeping around activation and completion,
driven by the scheduler (or, for a need job, `WorldState._commit_need_job()`/
`_finish_need_job()`) rather than a per-tick step.
`game/scripts/viewer/colonist_panel.gd` infers a colonist's current toil
name for display from exactly this same route/work/hands state, per job
kind — it is presentation-only and adds no new persisted field. Because
`eat_food`/`drink_water` have no `work` phase, there is a single tick between
arrival (`route` clears) and the instant `consume` toil where neither `route`
nor `work` names the job; for that tick the panel falls back to
`WorldState.get_active_need_job_id(colonist_id)`, a getter over
`_need_job_by_colonist` (see colonist-ai.md's "Implemented: increment D"
note), so the job stays identifiable, labelled "Consuming", for its entire
lifetime.

### `content/jobs.json`

Each job kind declares its `labour` (the colonist-ai.md "who can do this"
category — need jobs declare `""`, since they are not part of the labour
table any colonist can be assigned/disabled for), its fixed toil sequence,
and — for a kind with a `work` phase — its `work_ticks`. The `haul` entry
additionally carries its job-giver `priority` and doubling-backoff
`retry_base_ticks`/`retry_cap_ticks` (see "Haul backoff" below):

```json
{
  "jobs": [
    {"kind": "dig", "labour": "mine", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 30},
    {"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 40},
    {"kind": "forage", "labour": "forage", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 25},
    {"kind": "haul", "labour": "haul", "toils": ["reserve", "go_to", "pick_up", "go_to", "place", "release_all"], "priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
    {"kind": "site_fetch", "labour": "build", "toils": ["reserve", "go_to", "pick_up", "go_to", "deposit", "release_all"]},
    {"kind": "site_work", "labour": "build", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 1},
    {"kind": "eat_food", "labour": "", "toils": ["reserve", "go_to", "consume", "release_all"]},
    {"kind": "drink_water", "labour": "", "toils": ["reserve", "go_to", "consume", "release_all"]},
    {"kind": "sleep", "labour": "", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 60}
  ]
}
```

`ToilExecutor` loads its toil sequence/labour off this content file once at
construction (`has_kind()`, `get_toils()`, `get_labour()`); `WorldState`
reads `work_ticks`/the haul fields itself and injects them into
`ToilExecutor`/`HaulGiver`'s constructors (see "Tick-cost constants" and
"Haul backoff"). A job kind is data, not a branch in `WorldState`. Adding a
new kind that reuses this same toil vocabulary needs no simulation code
change, only a new `content/jobs.json` entry with a `work_ticks` field if it
has a `work` phase.

### `ReservationTable` key domains

One `ReservationTable` (`game/scripts/core/jobs/reservation_table.gd`),
shared by the scheduler's `JobQueue` and `WorldState`, is a generic
String-keyed ledger (`key -> job_id`) that knows nothing about tiles, items,
or cells itself — only the namespace prefix a caller chooses does:

| Key prefix | Meaning | Acquired by |
| --- | --- | --- |
| `tile:x,y` | A dig/chop/forage job's target tile, a need job's source tile (a ground-berries tile, a water tile, or a bed object's tile), or a construction site's own footprint tile. | The scheduler, on activation, for dig/chop/forage (unchanged); `WorldState._commit_need_job()`, for a need job, the instant its search finds a still-unreserved candidate; `WorldState._apply_construction_submission()`, for every footprint tile of a newly-created site, the instant its `build` command is accepted (owner `"site:<id>"`, not a job id — see "Construction" below). |
| `item:<item_id>` | A haul or `site_fetch` job's source ground item. | `JobQueue._tick_haul()`/`_tick_site_fetch()`, before the job ever goes active. |
| `cell:x,y` | A haul job's reserved stockpile destination cell. | Same as above; namespaced separately from `tile:` so a stockpile cell and a dig/chop/forage/need-job target never collide even at the same coordinates. |
| `trapped:<victim_id>` | A rescue job's own claim on the trapped colonist it is freeing; guarantees a second rescue job can never be proposed for the same victim. | `JobQueue`'s own activation (`tick()`) and reactivation (`reactivate()`), via the generic `set_extra_reservation_keys()`/`_extra_keys_for_job` callback described below — never acquired directly by `rescue_giver.gd`. |

`WorldState.is_cell_free(x, y)` and `WorldState._cell_key(x, y)` read/build
`cell:` keys against this same shared table (see `test_zone_commands.gd`'s
`_check_free_cell_query`). Every key a job owns is released together by
`release_all` on every terminal transition — cancelling mid-carry (a haul
job's `cancel_job`) drops the carried item on the colonist's current tile
and releases both its `item:` and `cell:` keys in the same step, per
colonist-ai.md 3.3/3.4's "failure/cancellation releases every reservation".
A construction site's own `tile:` reservation is the one exception to
"every reservation belongs to a job": it is owned by the site itself
(`"site:<id>"`), acquired at command-acceptance time and released only when
the site completes or is cancelled — see "Construction" below and
`ReservationInvariants.find_orphaned_reservations()`'s own
`extra_active_owners` parameter.

**Generic extra reservation keys.** A job kind
can need a reservation key beyond its own ordinary `tile:` target — haul
already special-cases this for its own `item:`/`cell:` pair
(`JobQueue._reactivate_haul()`), but that path is haul-specific. Rescue
generalizes it: `JobQueue.set_extra_reservation_keys(extra_keys_for_job)`
injects a `Callable(job_id: String) -> Array[String]` (mirroring
`set_tool_requirement()`/`set_haul_destination_finder()`'s own injection
style); `tick()`'s activation branch, `reactivate()`, and `restore()`'s own
active-job rebuild all call it and acquire every key it names *alongside*
the target key, refusing activation/reactivation (`BLOCKED_TARGET_RESERVED`)
if any of them is already owned by a different job. This keeps a rescue
job's `trapped:` key moving in lockstep with the job's own activation state
— acquired only while the job is actually active, released for free by the
existing generic `release_all(job_id)` on any terminal transition, and
correctly re-acquired on `reactivate()` after a need/combat interrupt
suspends and later resumes the job. `rescue_giver.gd` is wired via
`WorldState._build_dimension_services()`
(`_scheduler.queue.set_extra_reservation_keys(_rescue_giver.extra_keys_for_job)`);
`RescueGiver.extra_keys_for_job(job_id)` returns `["trapped:<victim_id>"]` for
a job it has committed a victim to, `[]` otherwise. Deduplicating a victim
across searches (never proposing a second rescue for one already claimed)
reads `RescueGiver`'s own `_job_victim` record directly, not this
`ReservationTable`, since a queued or suspended rescue job holds no
`trapped:` key at all under this scheme — only an active one does.

### Zone commands: `zone_add`, `zone_remove`

Stockpile zones are player-drawn axis-aligned rectangles, applied
immediately with no job queue involved (mirroring `place_object`/
`remove_object`'s "no job queue" framing above):

- `zone_add` — `{x: int, y: int, width: int, height: int}`. Rejected
  `invalid_payload` for a non-integer field; rejected `invalid_target` for a
  degenerate (zero width/height) rectangle, one extending past the map
  edge, or one overlapping an existing zone (touching an edge with no
  shared cell is allowed). On success returns `{ok: true, zone_id}`
  (`zone_1`, `zone_2`, ... — monotonic, never reused, like job ids).
- `zone_remove` — `{id: string}`. Rejected `invalid_payload` for a missing
  or empty id; rejected `invalid_target` for an unknown id. Removing a zone
  that a haul job is mid-walk toward fails that job
  `blocked_destination_gone` (`resubmit remedy: choose_reachable_destination`)
  with no leaked `cell:` reservation, rather than leaving the colonist
  walking toward a cell that no longer belongs to any zone.

`WorldState.get_zones()`/`get_zone(id)` return detached, id-sorted copies;
`WorldState._find_free_haul_cell()` scans every zone's cells in zone-id then
row-major order for haul destination selection, so cell assignment is
deterministic for a given zone/reservation state.

### Haul backoff

A haul job with no free destination cell blocks `blocked_destination_full`
and retries on a doubling backoff instead of every tick like dig/chop's
blocks, so a permanently-blocked haul job cannot monopolize the global
scheduler's per-tick route-search budget. The backoff bounds and the
job-giver `priority` `HaulGiver` submits at live on `content/jobs.json`'s
`haul` entry (`retry_base_ticks: 10`, `retry_cap_ticks: 40`, `priority: 1`
today — see the `content/jobs.json` example above), not as `WorldState`
constants.

The first retry waits at least `retry_base_ticks` ticks; each subsequent
retry's gap doubles, capped at `retry_cap_ticks`. `WorldState._init()` reads
these off the haul entry (failing startup if either field, or `priority`, is
missing — content must declare them explicitly, never default to `0`) and
injects them into `JobQueue` via `set_haul_backoff()` and into `HaulGiver`'s
constructor, the same content-to-constructor-parameter pattern
`move_ticks_per_tile`/`work_ticks` already use rather than hard-coding them a
second time. While backed off, `get_reservations()` reports the job's own
target as reserved for as long as `tick < retry_at`, routing it through
`global_assignment.gd`'s existing pre-scoring exclusion (the same one a
target-reserved dig/chop job already gets) instead of competing for a route
search slot every tick. See `game/scripts/core/jobs/README.md`'s "Haul"
section and `test_haul_stockpile.gd` for the full backoff/rehaul acceptance
coverage.

## Construction: `build` (ADR 040)

A construction site is persistent state (`ConstructionSiteTable`,
`game/scripts/core/objects/construction_site.gd`), not a job: `build`
creates a site record and reserves its footprint immediately, before any
material is on hand, and a job-giver decides over time when the site's next
fetch or work job should exist. This supersedes
[ADR 028](../decisions/028-build-job-core-budget-increase.md)'s single-worker
`build` job and [ADR 038](../decisions/038-build-multi-source-fetch-efficiency.md)'s
per-job multi-source fetch plan; wall/door/bed migrate onto this exact flow
with no change to their own cost or duration.

### Command: `build`

`{kind: string, x: int, y: int, orientation: string}` — `orientation`
optional (the same `"horizontal"`/`"vertical"` values `place_object` takes, meaningful
only when `kind` declares `rotatable: true`). Rejected `invalid_payload` for
a non-integer `x`/`y`, an unknown payload field, a malformed `orientation`,
or a `kind` absent from `content/objects.json` or missing its own
`build_cost`. Rejected `invalid_target` for any footprint tile that is
out-of-bounds, impassable (rock, water, trench), a colonist's own tile, a
tree tile, already holding an object, or already claimed by another site's
own footprint reservation. Rejected `blocked_target_unreachable` (the
existing typed reason, not a new one) when the declared kind is itself
impassable (`wall`, `workbench`; `door`/`bed` are declared passable and never
trigger this) and placing it there would strand a currently-reachable tile
(`WorldState._would_enclose_tiles()`, the footprint-aware generalization of
the superseded single-tile `_would_enclose()`). Unlike the superseded job
model, there is **no stock check**: a site is created immediately,
regardless of what materials are currently on hand.

A valid command creates the site record (`ConstructionSiteTable.create()`)
and reserves every footprint tile directly on the shared `ReservationTable`,
owner `"site:<id>"` — never a job id, since no job exists yet.
`WorldState.preview()` runs the identical rule, so a toolbar hover and the
click always agree.

### `ConstructionGiver`: fetch, then work

`game/scripts/core/jobs/givers/construction_giver.gd` runs once per tick
(`WorldState.tick()`, alongside `HaulGiver`'s own `advance()`):

- For each site still short of at least one required material, it tops the
  site's own fetch+work job count up to `max_builders` with fresh
  `site_fetch` jobs (a `max_builders`-2 site may hold two concurrent
  `site_fetch` jobs, letting two build-labour colonists fetch at once) —
  each sized to what the site still needs of one missing kind (up to hands
  capacity, via `pick_up(colonist, item_id, count)`), chosen from
  the nearest available (lowest-id, position-agnostic — no colonist is
  chosen yet at submission, the same precedent ADR 038's own seed selection
  set) stockpiled, unreserved, not-already-committed item of that kind.
  `site_fetch`'s toils are `[reserve, go_to, pick_up, go_to, deposit,
  release_all]` — haul's own shape with a new `deposit` toil (below) in
  place of `place`. Unlike the superseded `build` job's own per-job
  multi-source hopping, a `site_fetch` job always carries exactly one kind;
  `ConstructionGiver` submits a fresh one whenever a slot frees up and
  material is still short, rather than one job visiting several sources
  itself. Once a second concurrent `site_fetch` job actually activates with
  its own colonist, `_next_site_fetch_source()`'s committed-source exclusion (below)
  routes it to the nearest source the *other* active fetch job has not
  already committed to, never the same one twice.
- Once every required material is fully held (`ConstructionSiteTable.
  materials_met()`), it tops the site's own active/queued `site_work` job
  count up to the same `max_builders` cap. `site_work`'s toils are `[reserve,
  go_to, work, release_all]` — the same single-leg shape `dig`/`chop`/`mine`
  use, targeting the site's own origin tile directly. A third colonist is
  never offered a slot while two already hold both of a `max_builders`-2
  site's own, whichever mix of fetching and working they are in.

Neither job kind reserves the site's own footprint tile itself (it is
already reserved to the site): `JobQueue._tick_site_fetch()` only ever
acquires its source item's `item:` key; `JobQueue._tick_site_work()`
acquires no reservation at all, since the number of concurrent builders is
capped by the site record's own `builder_ids`/`max_builders`, not the
`ReservationTable`.

### The `deposit` toil

A separate toil verb (not an extension of `place`): transfers every hands entry a
`site_fetch` job's colonist carries into the named site's own
`held_materials` (`ConstructionSiteTable.deposit()`), clamped to what the
site still needs of each kind, instead of minting a fresh ground item.

On success, `WorldState._toil_on_deposit_success()` checks
whether the colonist's hands still hold units of the job's own kind --
possible only when the just-delivered site's own remaining need was smaller
than what was held, so that site is now fully served for this kind. `kind` is
read straight off `InventoryType.hands_snapshot(colonist)` -- the colonist's
own persisted "hands" field -- never `_site_fetch_picked_kind`, the runtime
cache `_toil_on_pick_up_success()` keeps for its own same-tick use: that cache
is never saved, so resolving it right after a load, or after
its own source item was exhausted and deleted by the pick_up that filled
hands, would silently read `""` and end the chain early with material still
in hand. When leftover exists, `_next_site_fetch_site()` searches every *other*
active construction site still short of the same kind and not already at its
own `max_builders` fetch-plus-work capacity (`_site_fetch_work_busy()`, the
identical queued-or-active count `ConstructionGiver.advance()` sums per site
before topping it up -- a retarget never goes through that submission path,
so without this explicit check here it could push an already-fully-staffed
site over its own cap) by the identical deterministic route-cost search
`_next_site_fetch_source()` uses for ground sources (`_route_cost()`, not
open-field Chebyshev), ties broken by lowest site id. When a reachable,
eligible one exists, `JobQueue.retarget_site_fetch_site()` (a mutator
alongside `retarget_site_fetch_source()`) stamps `job["site"]` and
`job["cell"]` with its origin -- keeping them in lockstep exactly as
`mark_site_fetch_delivering()` first set them equal -- and the job continues:
the ordinary per-tick `advance()` dispatch drives a fresh `go_to`/`deposit`
pair there with no special handling in `toil_executor.gd`, since
`_toil_is_first_leg()` still reads `job["cell"] != null` unchanged by
retargeting. When leftover exists but no eligible sibling does (every
remaining site cancelled, or already satisfied by a competing delivery, while
the colonist still carried material toward it), the leftover is dropped
through the same live-assignment terminal-drop path `cancel_job`/`cancel_site`
already use (`_drop_carried_item_from()`) before the job completes -- nothing
else ever drains "hands" once a job is terminal, so without this the material
would stay sealed in hands forever. Only once hands hold nothing of the job's
own kind does the job complete outright, exactly like `place`'s own
`on_place_success` hook. `job["site"]` always names whichever site the job is
currently delivering to either way -- no new persisted field, so a mid-chain
save/load round-trips exactly like a single-site delivery already did, and a
mid-chain critical-need interrupt or `cancel_job`/`cancel_site` reads/drops
against whatever site those fields currently name, with nothing chain-specific
to restore. This sibling search has no separate item-level exclusion for a
site already named by another pending `site_fetch` job (unlike
`_next_site_fetch_source()`'s own item-level source exclusion), because
eligibility here is already gated by capacity
(`_site_fetch_work_busy() >= max_builders`, above), not by physical item
conflict, and the capacity gate is the one that actually matters in
practice. A single sufficient stockpile stack backing a `build_line` row of
one-quantity blocks does *not* routinely leave every sibling holding a queued
job of its own: `ConstructionGiver._choose_source()` commits that stack's
item id to whichever site's submission claims it first (`committed_items`,
tracked across the whole `advance()` pass), so every other still-short
sibling fed from that same stack gets no fetch job at all until that job's
own reservation is actually freed -- its normal terminal completion (no
further eligible sibling to chain onto) or a `cancel_job`/`cancel_site`
mid-chain, either of which runs `release_all()` -- or until a second source
appears in the meantime. An intermediate chained deposit does *not* free it:
`retarget_site_fetch_site()` leaves `item_id`/`target` untouched, so the job
keeps the same source committed through every hop of the chain. These
job-less siblings are exactly the chain targets this design serves: a
colonist already holding leftover hands-material from an earlier hop reaches
them, not a freed source. A sibling that *does* already hold a job of its own is a
different case: for a `max_builders` 1 site (every wall block), that single
queued-or-active job already saturates `_site_fetch_work_busy()` above, so
the capacity check excludes it from retargeting with no separate rule
needed; for a `max_builders` > 1 site, an existing queued/active job leaves
real spare capacity, so a retarget there is legitimate --
`ConstructionSiteTable.deposit()`'s own clamp to `remaining()` makes two jobs
reaching the same site safe regardless (a site accepts nothing further once
fully served, and whichever job arrives second then chains onward in turn,
or completes) (see ADR 043).

`WorldState._toil_pick_up_count_for()`'s own clamp is widened to match
(ADR 043): a pick_up now sizes to the current target site's own
remaining need plus every other reachable, still-short, not-already-at-
capacity sibling site's own remaining need of the same kind
(`_reachable_short_sibling_sites()`, the query `_next_site_fetch_site()`
also uses -- a sibling already holding its own `max_builders` worth of
queued-or-active fetch-plus-work jobs never inflates this sum, since it
could never actually accept a chained delivery), minus whatever of that kind
the colonist's hands already hold from an earlier hop -- so a hands-load
actually carries enough to chain across several one-quantity blocks in a
row, never past what some real, reachable, capacity-eligible site could use.
This sizing hook lives in `world_state.gd`, injected as
`pick_up_count_for` for `ToilExecutor`, not in `construction_giver.gd`:
`advance()` still tops each still-short site's own
fetch-plus-work count up to `max_builders` with fresh `site_fetch` jobs
every tick -- never capped at one submission per site -- but each fresh
submission still requires its own distinct, still-uncommitted source; a
single stack backing a whole row commits to only the first such submission,
leaving the row's other blocks job-less until that job's own reservation is
freed by its terminal completion or cancellation (never by an intermediate
chained deposit, which leaves the source committed).

### `site_work`'s duration comes from the site, not `content/jobs.json`

A site's own `build_ticks` varies per object kind (a `workbench`'s 120
against a wall's 40), and its *remaining* duration varies with how much
progress other builders have already contributed — neither fits
`content/jobs.json`'s single per-kind `work_ticks` constant.
`WorldState._resume_work_progress()` — the same job-id-scoped "resume stored
progress" hook that already lets an interrupted `dig`/`chop`/`mine` resume
rather than restart — answers `build_ticks - progress`, read fresh from the
site record, for a `site_work` job on every call, whether this is a
genuinely fresh activation or a resumption after a critical-need interrupt.
`_set_work_progress()` adds one tick to the site's own `progress`
(`ConstructionSiteTable.add_progress()`, summed across every active
builder's own job, not a private per-job counter) on every non-final work
tick, checking there too whether accumulated progress has already met
`build_ticks` (with two builders, their combined contributions
routinely cross `build_ticks` before either one's own locally-seeded
countdown reaches zero, so waiting for the final tick alone would not give
genuine N-builder speedup); the final tick's contribution and the same check
are also done directly in `_toil_on_work_complete()`'s own `"site_work"`
case, for the ordinary single/final-builder path. Neither hook touches the
generic tile-keyed `_work_progress`/`_work_progress_owner`/
`_suspended_work_progress` caches for this kind at all: the site's own
`progress` field is the one persisted, authoritative counter, so there is
nothing to cache.

### Completion

The instant accumulated `progress` meets `build_ticks` — checked on every
tick any active builder's `site_work` job contributes, not only when a
job's own local countdown happens to reach zero (see above) —
`WorldState._finalize_construction_site()` places the declared object via
`_set_object()` (the ordinary footprint/orientation-aware placement),
releases the site's own footprint reservation, completes every other
still-active builder job on the site (an empty `completing_job_id` completes
all of them, including the one whose own contribution just crossed the
threshold, when finalizing from the non-final-tick path above), and removes
the site record — discarding `held_materials`, already fully spent by
definition.

### `cancel_site`

`{x: int, y: int}` — any tile in the site's footprint. Rejected
`invalid_payload` for a non-integer `x`/`y` or an unknown payload field;
rejected `invalid_target` when no site occupies the named tile. On success,
every in-flight `site_fetch`/`site_work` job on the site is terminated
through the existing `_finish_job()` path (a mid-fetch builder's own carried
hands drop through the existing `_drop_carried_haul_item()` terminal
path); every held material is placed on the nearest free
tile adjacent to the site's footprint (one distinct tile per kind where
possible, the same north/west/east/south adjacency order
`_dig_item_placement()` already uses for a single tile); the site's own
footprint reservation is released; and the record is removed. There is no
separate "ghost" to erase — a presentation layer draws one from
`get_construction_sites()`, which this call already empties.

### Command: `build_line` (ADR 042)

`{kind: string, tiles: [{x: int, y: int}, ...], orientation: string}` —
`orientation` optional, identical meaning to `build`'s. Submits a whole drag
(a wall line, a rectangle of floor tiles) as one command instead of one
`build` per tile, so the enclosure check below can see the whole shape at
once. `WorldState._classify_build_line_command()` is the single read-only
rule shared by `apply()` and `preview()`:

1. Rejected `invalid_payload` for a non-string kind, a `kind` absent from
   `content/objects.json` or missing its own `build_cost`, a malformed
   `orientation`, a non-array or empty `tiles`, or any tile entry missing
   integer `x`/`y`.
2. `tiles` is de-duplicated and canonicalized into row-major order (lowest
   `y`, then lowest `x`) — the command never trusts caller order, so the same
   tile set always produces the same site ids/positions regardless of drag
   direction.
3. Each canonical tile runs the exact single-tile footprint/occupancy rule
   `build` runs (`_construction_footprint_check()`, shared by both) —
   *excluding* the enclosure check. A tile that fails is moved to a `skipped`
   list (`{x, y, reason}`, the same reason the single-tile command would have
   returned) instead of rejecting the command. A tile that passes is then
   checked against every earlier surviving tile's own footprint in this same
   batch: a `kind` wider than one tile (e.g. a 2x1 workbench) can otherwise
   offer two candidate origins whose footprints overlap, and since neither
   origin's reservation exists in the table yet during classification, both
   would individually pass `_construction_footprint_check()`. A later
   candidate whose footprint touches an earlier survivor's already-claimed
   footprint is skipped `invalid_target` instead — the same reason a real
   reservation conflict would give — rather than surviving to create a second
   site that can never acquire the shared tile.
4. Once every tile is classified, if any survived, `_would_enclose_tiles()`
   runs once across the whole surviving set, treated as one hypothetical
   placement (only meaningful when `kind` is impassable). If it would strand
   any currently-reachable tile, the **entire command** is rejected
   `blocked_target_unreachable` — zero sites are created, zero reservations
   are taken, and the `skipped` list from step 3 is discarded. This is the
   command's own atomicity rule: a line's enclosure effect is a property of
   the whole shape, judged once every tile's occupancy is already known, not
   per tile.
5. Otherwise, one construction site is created per surviving tile, in
   row-major order, exactly as `build` creates one (footprint reservation,
   `ConstructionSiteTable.create()`). Returns `{ok: true, sites: [{id, x, y},
   ...], skipped: [...]}`.

Every site `build_line` creates is mechanically identical to one `build`
created — same record shape, same `ConstructionGiver` scheduling, same
`cancel_site` teardown. A colonist's hands-load is not bound to one site of
the row for its whole trip, either: the chained `deposit` (see "The
`deposit` toil" above, ADR 043) lets a single `site_fetch` job
retarget onto a reachable, still-short sibling site after each successful
deposit, so a hands-load sized for several one-quantity blocks serves them
all before the colonist ever returns to a stockpile.

### Reads: `get_construction_sites()`/`get_construction_site(x, y)`

Mirror `get_objects()`/`get_object()` exactly: `get_construction_site(x, y)`
resolves any of a site's footprint tiles to its whole record (`{}` for none);
`get_construction_sites()` lists every active site. Both translate the
site's internal `builder_ids` (which key sites on the contributing
`site_work` job's own id, resolvable at every terminal transition even after
a colonist's own assignment is gone) to the live colonist id currently
driving each job.

### Persistence

One optional top-level `constructionSites` field (`state_codec.gd`'s
`_encode_construction_sites()`/`_decode_construction_sites()`), absent for
any save written before construction sites existed — `WorldState` then loads with no active
sites, exactly a fresh world's own starting state. A `site_fetch`/`site_work`
job's own `site` field round-trips like `itemId`/`cell` and is part of
`state_hash()`'s existing `"jobs"` entry; `state_hash()` also hashes
`_sites.list()` directly, so two states differing only in held materials,
progress, or builder assignment never hash equal. No `schemaVersion` bump:
every change is additive/optional.

## Need jobs: `eat_food`, `drink_water`, `sleep`

The needs decision layer (colonist-ai.md 3.1) works as follows: three
need kinds (`food`, `water`, `rest`, `content/needs.json`) decay every tick
and, once a colonist crosses a kind's `urgent`/`critical` threshold, drive it
through a need job — submitted through the exact same scheduler entry point
(`GlobalAssignment.submit()`, `restrict_to` pinned to the colonist) any
order-driven dig/chop/haul job uses (`content/jobs.json`'s `labour: ""`
opts it out of the fair labour pool, not a separate submission path), then
driven every tick by the same `WorldState._advance_colonists()` ->
`ToilExecutor.advance()` dispatch every other job uses. `WorldState.tick()`
passes each committed need's `colonist_id -> job_id` into
`GlobalAssignment.tick()`'s own `committed_needs` parameter
(`NeedGiver.get_pending_assignments()`) so only that colonist's own scan ever
proposes it (`GlobalAssignment._propose_committed_need()`), instead of the
ordinary priority/travel-scored competition every other waiting job goes
through — that is what "pre-empts, not competes" means here, not a second
engine outside `GlobalAssignment`/`JobQueue`. A colonist pursuing or
searching for a need job is excluded from the pool the fair scheduler
considers each tick (`_colonists_not_searching_need()`), so a need job never
competes with work for the scheduler's own aging/fairness accounting.

### Source selection

Each need kind has exactly one notion of "a source", read from live world
state, never a stored list (`WorldState._need_source_candidates()`):

| Need | Source | Passable? |
| --- | --- | --- |
| `food` | Any tile with a positive ground-berries count (`get_ground_berries(x, y) > 0`). | Yes (ordinary floor) — the colonist stands on it. |
| `water` | Any `water` tile. | No — the colonist stands adjacent, like a `chop`/`forage` target. |
| `rest` | Any tile holding a `bed` object. | Yes (`content/objects.json`: `bed` is passable, cost 3) — the colonist stands on it. |

`_start_need_search()` candidate-sorts every source of the needed kind by
Manhattan distance (`abs(dx) + abs(dy)`) from the colonist, nearest first,
drops any already-`tile:`-reserved candidate up front, then advances
one bounded route-search `resume()` per tick per candidate
(`_advance_need_search()`) — the same per-tick step budget every other route
search in this codebase uses (`game/scripts/core/routing/README.md`), so a
need search never spends an unbounded amount of a single tick. Losing a
last-instant race for a candidate's `tile:` reservation (another colonist
committed to it between this search's route being found and the commit)
records `blocked_source_reserved` and moves to the next candidate rather
than failing outright. Exhausting every candidate — or finding none at all —
exposes `need_unmet:<kind>` (`WorldState.get_colonist_need_reason()`,
colonist-ai.md 3.8) and starts a doubling backoff before that (colonist,
kind) pair searches again, bounded by `retry_base_ticks`/`retry_cap_ticks`
(10/40 today) read off `content/needs.json` — every entry repeats the same
`full`/`job_priority`/`retry_base_ticks`/`retry_cap_ticks` values, since
`content_registry.gd` has no root-field accessor for a collection kind (see
`WorldState._load_need_config()`), the same shape as the haul entry's
`retry_base_ticks`/`retry_cap_ticks` above, injected into `NeedGiver`'s
constructor rather than hard-coded as `WorldState` constants.
The `need_unmet` alert (an event, `type: "need_unmet"`) fires exactly once
per onset, not once per backed-off retry; a fresh search that later commits
to a source clears the "already alerted" flag, so a later relapse alerts
again. Failing to find any source at all does not stop the colonist from
working — it is simply never added to `_need_job_by_colonist`, so the fair
scheduler's own pool still includes it (colonist-ai.md 3.1: "the colonist
keeps working").

### Toils and target semantics

Once a search commits, `NeedGiver._commit()` reserves the source's `tile:`
key via `GlobalAssignment.submit()` exactly like an assigned work job — see
`content/jobs.json`'s three need-kind entries above. `sleep` reuses the
generic `work(ticks)` toil (its `content/jobs.json` entry's
`work_ticks: 60`) precisely because a bed's rest is mechanically a timed
wait like `dig`/`chop`/`forage`; `eat_food`/`drink_water` use the one-tick
`consume` toil instead, since there is nothing to "work" — the source is
either there or it is not. A resolved path of one tile or fewer skips
`route` and starts `work`/attempts `consume` immediately, the same shortcut
`ToilExecutor.start_assignment()` takes for work jobs; for `water` (an
impassable target, like `chop`/`forage`), `GlobalAssignment`'s own route
search trims the final tile from the path the same way it does for a
`chop`/`forage` target, so the colonist ends up adjacent, not on, the water
tile.

On completion (`_apply_need_effect()`), the kind's `restore` value
(`content/needs.json`) is written to `colonist.needs[kind]`, capped at
`content/needs.json`'s `full` (100 today, read once via
`WorldState._load_need_config()` since every need entry repeats the same
value); `eat_food` additionally decrements the source tile's
ground-berries count (removing the tile's entry once it reaches zero).
`sleep` is the one exception to "the kind's `restore` value is written
unmodified": when the completed job's bed tile falls inside a recognised
bedroom room (`WorldState.get_room_at(target.x, target.y).has_bed`, see
"Rooms" below), the written value is `restore * bedroom_rest_multiplier`
(`content/needs.json`'s `rest` entry) instead of the plain `restore`,
still capped at `full`. An ordinary bed with no enclosing room restores the
unmodified `restore` value, as does any need kind whose content entry
omits `bedroom_rest_multiplier` altogether (`need_def.get(...)` defaults to
`1.0`, a no-op multiplier) — a need kind with no meaningful "bedroom"
concept never has to declare the field at all.
`_finish_need_job()` releases the source's `tile:` reservation on every
terminal transition (`completed`/`failed`), mirroring `release_all`'s
"failure releases every reservation" contract for work jobs. A route that
proves unreachable mid-walk (`_advance_need_route()`'s own re-route, mirror
of "Rerouting" above) fails the job `blocked_source_unreachable` rather than
resubmitting to a fair queue, since a need job has no queue entry to
resubmit to — the colonist simply searches again on its next need-decision
pass.

### Interrupt behaviour

Colonist-ai.md 3.6's interrupt contract is implemented exactly as designed:
a **critical** need (crossed the `critical` threshold) pauses an
in-progress, interruptible `work` toil immediately
(`WorldState._pause_work_job()`), keeping the toil's elapsed tick count on
`WorldState._work_progress` — keyed by the *tile*, not the colonist, so a
different colonist resuming the same job later (or the same colonist,
later) reads the same partial progress back rather than restarting the
job's `content/jobs.json` `work_ticks` from zero. A `rescue` job's key is
further scoped by that job's own id (`_work_progress_key_for_job()`):
two rescue jobs can legitimately share one target tile (two trapped victims
with overlapping adjacency), and a bare tile key would let one job read or
clear the other's progress across a suspend/resume. Every other job kind
keeps the plain tile key, since an ordinary job's own target changes kind (or
is otherwise no longer valid) the moment it completes. Mid-work, the toil
executor's tile-addressed get/set hooks resolve the job through the tile's
current reservation owner (the job being worked always holds it); every
terminal boundary instead clears by the terminating job's explicit identity
(`_clear_terminated_job_progress()`), since `_finish_job()` has already
released that reservation by then — a rescue's own key on every terminal
transition, active or suspended; an ordinary job's plain key only when it was
the active owner, so a paused job's progress on the same tile is never erased
by another job's cancellation. An **urgent** (but not yet critical) need
never interrupts mid-toil; it is only picked up once the current toil ends
naturally, at the next toil boundary. Once the need job that preempted a
paused work job finishes — success, failure, or an onset that found no
source at all — `_resume_paused_job()` hands the colonist back to exactly
the job `_pause_work_job()` set aside, never a fresh assignment; the paused
job's own scheduler entry (`GlobalAssignment._assignments`) is untouched the
entire time, since the colonist is simply absent from
`_colonists_not_searching_need()`'s pool while the need job runs.

## Incident jobs: `incident`

A spawned incident actor (`content/incidents.json`, `IncidentScheduler`) walks
to a random reachable tile and waits a content-declared tick count before
despawning — expressed as an ordinary `content/jobs.json` job
(`{"kind": "incident", "labour": "", "toils": ["reserve", "go_to", "work",
"release_all"]}`), driven through the exact same `WorldState._advance_colonists()`
-> `ToilExecutor.advance()` dispatch every other job uses, never a bespoke
per-actor walk/wait state machine.

### Activation-gated spawning

`IncidentScheduler` never puts an actor into the world by itself. A draw (or
the `spawn_incident` debug command) *proposes* each actor: it builds the actor
dict at a bare, passable edge tile, picks one uniformly random bare tile in
the same region (`same_region()`, backed by the region map, filters
candidates before any route search; the spawn tile itself is excluded), and submits the actor's own
job through `WorldState._submit_incident_job()` ->
`GlobalAssignment.submit_autonomous()` (ADR 014, "Amendment") —
the same `submit()` pipeline any order/need job uses, `restrict_to` pinned to
the actor and flagged `autonomous`. The actor is then **staged**
(`IncidentScheduler.propose()`): offered to `GlobalAssignment.tick()` as a
worker (`WorldState._scheduler_workers()` = the roster not mid-need-search
plus the staged actors) so the shared scheduler can propose, route and
activate its job, but not yet in `_colonists`. The `incident_started` event
lists the *proposed* actor ids.

Once per `WorldState` tick, right after `_scheduler.tick()` and before
`_advance_colonists()`, `IncidentScheduler.activate_pending()` reads each
staged job's status through the ordinary queue record:

| staged job status | consequence |
| --- | --- |
| `active` | the actor is appended to the world, its content-declared `spawn.wait_ticks` is stamped onto the target tile's work-progress key (the same override `ToilExecutor.start_work()` consults to resume an interrupted `work`; `content/jobs.json`'s `"incident"` `work_ticks` is only a placeholder), and it starts its first toil this same tick |
| `queued`, `blocked_target_unreachable` | the actor's own faction-aware bounded search (below) found no route: the job is retired through `WorldState._finish_job(job_id, "cancel_job")`; the actor never spawns |
| `queued`, any other reason (e.g. `blocked_target_reserved`) | stays staged, exactly like a colonist's queued job, until the target frees up |
| terminal / unknown | the proposal is dropped (a gate refusal already failed it; a command cancelled it) |

No `advance_selection()`/`set_assignment()` call lives in `WorldState`: an
incident job activates only through `WorldState`'s own single regular
`_scheduler.tick()` pass, so proposing several actors inside one tick never
ticks `JobQueue`'s or `GlobalAssignment`'s clock more than once, and a target
already held by another job (a race between two incident actors, or an
incident actor and a colonist's job) leaves the later job queued
`blocked_target_reserved` and its actor staged — never spawned, never
stamped. From activation on, `_advance_colonists()` drives the actor exactly
like any other assignment, with no special-casing.

### Reservation eligibility and faction-aware routing

The autonomous entry skips only `_may_be_ordered`. Its reservation gate is the
target-aware `WorldState._actor_may_reserve_target()` (ADR 014 Amendment): a
faction that may not reserve colony items may still reserve a **bare** tile —
no object, ground item, berries, tool item or stockpile cell
(`WorldState._is_bare_tile()`, the same predicate the scheduler's spawn-tile
and target selection apply). A refusal follows the ordinary
`take_refused_reservations()`/`_resolve_refused_reservations()` path (the job
fails; the staged proposal is dropped).

An incident actor's own faction, not the colony's, gates its spawn-tile
eligibility, target selection, initial routing, rerouting, and movement
revalidation. `GlobalAssignment`'s autonomous passability
(`WorldState._passable_for_worker()`) runs the initial bounded search under
the actor's faction, so a wildlife actor's first route never crosses a colony
door and takes an alternate route when one exists; `ToilExecutor`'s own
`_passability` callable and its `go_to_passable` hook thread the acting
actor's `factionId` through to `WorldState.passability()` at every call site
(defaulting to `"colony"`, so every pre-existing caller is unchanged).
`same_region()` is a physical, colony-oriented pre-filter only: a target
beyond a door is still "same region", and it is the actor's own bounded
search that then proves it unreachable — before activation, the job is
retired unspawned (table above); mid-travel (a door placed on the way), the
reroute search fails and `_toil_on_unreachable()` cancels the job.

### Lifecycle cleanup at the shared finish boundary

`WorldState._finish_job()` is the only path that finishes a scheduler job, and
an `"incident"` job's cleanup lives there: on every successful terminal
transition — work completion, unreachable travel, a gate refusal, a
`complete_job`/`cancel_job`/`fail_job`/`invalidate_job` command — it calls
`IncidentScheduler.on_job_finished()` (drops a staged proposal, or removes a
spawned actor from the world) and, when the job was active, clears the wait it
stamped on the target's work-progress key (an active incident job holds that
target's reservation, so the key is its own, and a later job at the same
tile starts at its own full duration). There is no incident-only completion
path and no resubmission: an incident actor's target is never resubmitted.

### Persistence

An ordinary save/load round-trips an incident actor's own entity fields
exactly like any other colonist's: `game-state.schema.json`'s `entities`
schema requires, per `kind`, exactly the component fields that kind's
`content/actors.json` definition produces (`colonist`:
`needs`/`labourTable`/`work`/`carrying`; `wolf`: `needs`/`combat`/`wild`;
`trader`: `inventory`/`visitor`), and `SaveIO._validate_state()` /
`StateCodec._encode_entities()`/`_decode_entities()` mirror that — every
component field is validated/emitted only when the live actor dict carries
it, never backfilled as a colonist-shaped default (`_ensure_needs()`/
`_ensure_held_tool()` skip actors without a `worker` component). The
`autonomous` queue-entry flag is on the wire only when true. On load,
`WorldState._reconcile_incident_jobs_after_load()` re-associates each active
incident job with its restored actor (so it still despawns on completion) and
retires a queued one, whose staged actor was never persisted.
`IncidentScheduler`'s own continuation state — per-incident cooldown-remaining
(`incidentScheduler.cooldownUntilDay`), the scheduler's day counter
(`incidentScheduler.lastProcessedDay`), and its RNG stream's own seed/state
(`incidentScheduler.rng`) — is persisted through `state_codec.gd` and covered
by `WorldState.state_hash()` (ADR 004). The staged proposals
themselves are not part of that state: a staged actor was never appended to
the world, so it round-trips through no save field at all, and a queued
proposal is simply retired on load (table above) rather than restored.

## Combat: `attacked_by`/`fighting` and the `flee` job

`game/scripts/core/combat/` (`CombatResolver`, `CombatTargeting`, `CombatGiver`; ADR 021)
extends this document's typed event/reason vocabulary with combat's own two entries, run once
per `WorldState.tick()` before the fair scheduler sees any colonist — the same ordering
`need_giver.gd`/`haul_giver.gd` already use:

| Kind | Name | Meaning |
| --- | --- | --- |
| event | `attacked_by` | recorded once per landed hit, on the victim entity id (an actor id or an object's `"%d_%d"` tile key); `data` carries `attacker_id` and `damage` |
| reason | `fighting` | exposed through `WorldState.get_actor_combat_reason(actor_id)` for any actor currently adjacent to a hostile target with a ready cooldown, mirroring `get_colonist_need_reason()`'s own reason-string pattern; `""` when the actor has no combat component or no such target this tick |

An actor with a `combat` component attacks the nearest adjacent (Chebyshev-1) hostile target —
another actor or a health-bearing object — every `cooldown` ticks once in range, dealing
`damage` to the target's `health.hp`. An actor whose own hp fraction drops strictly below its
definition's `flee_hp_fraction` tunable withholds its attack (still exposed as `fighting: ""`)
and `CombatGiver` submits a `flee` job for it — an ordinary `content/jobs.json` entry
(`{"kind": "flee", "labour": "", "toils": ["reserve", "go_to", "work", "release_all"],
"work_ticks": 1}`, the same walk-then-finish shape `"incident"` already uses), through
`GlobalAssignment.submit_autonomous()` so a non-colony actor can flee without the `may_be_ordered`
gate refusing it. Submission goes through `WorldState._interrupt_current_job()`/
`_resume_interrupted_job()` (ADR 009), the same boundary `NeedGiver` uses, so a fleeing actor's
prior work/haul/travel job is paused rather than left to run to completion. While a `flee` job is
queued or active for an actor, `CombatGiver` leaves it alone; a still-threatened actor gets a
fresh leg the tick after the previous one completes rather than a bespoke continuous-chase loop.
A `flee` job whose route becomes unreachable mid-walk is cancelled only at
`WorldState._toil_on_unreachable()`, exactly like `"incident"`, never resubmitted through the
ordinary gated `submit()` path.

### `approach`: closing the distance on a hostile target (ADR 033)

`ApproachGiver` (`game/scripts/core/combat/approach_giver.gd`) runs once per tick, after
`CombatResolver.resolve_tick()`/`CombatGiver.advance()` and after `WorldState._advance_colonists()`,
so its "already adjacent" check sees this tick's post-movement positions (and a `trapped` actor
already reads that way before this giver's search runs -- see ADR 033). For every actor with a
`combat` component whose faction's relation to `colony` is `hostile`, it applies these steps in
order:

1. **Flee check.** If `CombatGiver.owns(actor_id)` (an open flee episode), the actor's approach
   tracking is released. This runs before the adjacency check, so a fleeing actor never keeps a
   stale approach association, even on a tick it also becomes adjacent to a hostile target.
2. **Stale-job cleanup.** A tracked job's target-loss/blocked-unreachable cleanup (see
   "Retargeting" below) runs next, also before the adjacency check: the actor can stand adjacent
   to a different hostile on the very tick its tracked job's target dies, and that cleanup must
   not be skipped because the actor happens to be adjacent to something else.
3. **Adjacency.** If the actor is already adjacent to a hostile target, the giver does nothing;
   the attack rule above covers that case.
4. **Approach.** Otherwise it picks the single nearest reachable hostile target -- any living
   actor or health-bearing object this actor's faction relation makes it hostile to -- and
   submits one `approach` job restricted to it, unless one is already queued or active.

`content/jobs.json`'s `"approach"` entry (`{"kind": "approach", "labour": "", "toils":
["reserve", "go_to", "work", "release_all"], "work_ticks": 1}`, the same walk-then-finish shape
`"flee"`/`"incident"` use) is submitted through `GlobalAssignment.submit_autonomous()`, the same
entry point `CombatGiver`/`IncidentScheduler` use. Target ranking is by real route length to the
target's single nearest Chebyshev-adjacent tile, one bounded route-search step per tick through
the shared `_route_budget` ledger (ADR 004), pruned early against each candidate's Chebyshev
distance (Manhattan distance can exceed the true route cost once diagonal movement is allowed, so
it is not a safe lower bound for early-stop pruning), and tie-broken deterministically (an actor
candidate before an object candidate, then ascending target id or tile key). If no target is
reachable, the actor does nothing that tick; the search is re-evaluated every tick, never latched.

**Retargeting.** A tracked job's recorded target is checked before its scheduler status every
tick this giver looks at it. An actor target that has died (no longer in the roster, or present
but `health.dead`), or an object target whose health entry and placed-object record have both
cleared (destroyed, or cleared by any other system), cancels the job through the shared finish
boundary (`WorldState._cancel_autonomous_job`, mirroring `combat_giver.gd`'s `_cancel_job` and
`rescue_giver.gd`'s `_retire_job`) regardless of the job's current status. A job still
`"queued"` with JobQueue's `BLOCKED_TARGET_UNREACHABLE` reason -- the same reason
`combat_giver.gd` watches for its flee legs, since JobQueue retries an unreachable queued target
indefinitely -- is cancelled the same way. Either trigger drops the association and falls through
to a fresh nearest-target search **in the same tick**. An `approach` job whose route becomes
unreachable mid-walk after activation is cancelled only at `WorldState._toil_on_unreachable()`,
exactly like `"flee"`/`"incident"`; that cancellation is detected the same way (status no longer
`"active"`/`"queued"`) and also falls through to a fresh search. If the fresh search finds no
reachable target, the actor is left with no approach job that tick, free for
`IncidentScheduler`'s walk-then-wait to drive it; `ApproachGiver` never cancels or interferes
with an unrelated incident job because its own retargeting failed. (An earlier design instead
retired the actor permanently, via a `_retired` set cleared only by `forget()`; that latch was
replaced by the per-tick retry above.)

`test_combat.gd` covers the cleanup ordering (a stale target is still cancelled while the actor
stands adjacent to a different hostile) and isolates the two fallback mechanisms from each other:
one check seals a tracked job's route (never its destination tile) and proves cancellation
happens without the job ever reaching `"active"`, isolating the
queued+`BLOCKED_TARGET_UNREACHABLE` branch from `_toil_on_unreachable()`'s separate active-route
cancellation; another proposes a genuine `IncidentScheduler` actor/job and proves its
walk-then-wait lifecycle runs to natural completion, untouched by a sealed-off `approach` job
alongside it.

## Rooms: `get_room_at()`

`WorldState.get_room_at(x, y) -> Dictionary` (backed by
`game/scripts/core/map/rooms.gd`'s `RoomMap`, built lazily over the
`RegionMap`) returns `{}` for a tile with no recognised room; otherwise
`{id, size, door_count, has_bed, has_stockpile, tiles}` — `size` the tile
count, `door_count` the number of distinct boundary door tiles, `has_bed`
whether a `bed` object (`content/objects.json`) sits on any member tile,
`has_stockpile` whether an active `zone_add` stockpile zone ("Zone
commands" above) overlaps any member tile, `tiles` the member tile list.

A room is a maximal connected component of tiles reachable through
passable, non-door tiles — both an impassable tile/object (a wall) and a
door stop the flood, unlike `RegionMap`'s own connectivity (where a door is
just another passable tile). A component only resolves to a room when
**both**: it is fully enclosed (the flood never reaches the map boundary —
an unwalled component open to the edge of the map is never a room, however
many doors happen to sit on its frontier) **and** its boundary includes at
least one door (`door_count >= 1`; a sealed box with no door is not a
room). `RoomMap.on_passability_changed(x, y)` is called from the same
mutation sites `RegionMap` already hooks (`_set_object()` — wall/door/bed
add and remove — and the dig/chop/forage/till/sow/sleep tile transforms),
and reruns the bounded flood for every room touching `(x, y)`'s
neighbourhood.

`bedroom_rest_multiplier` (`content/needs.json`, `game/content/schemas/needs.schema.json`
— `type: number`, `exclusiveMinimum: 0`) applies only when `sleep`'s bed
tile resolves to a room with `has_bed: true` (see "Toils and target semantics" above);
the written value is `int(restore * bedroom_rest_multiplier)` — truncated
toward zero, the same conversion every other need-restore write already
uses — capped at `full`. A room with both `has_bed` and `has_stockpile` set
reports both; picking one name to display (`boot.gd`) prefers "Bedroom"
over "Storeroom" over plain "Room".
