# ADR 021: Generic combat resolution and targeting

> **In short:** Characters who are hostile to each other now fight when they stand next to each
> other, can be hurt or killed, and can break walls and doors. A badly hurt character stops
> fighting and runs away, then goes back to what it was doing once it is safe.

- **Status:** accepted
- **Date:** 2026-09-22
- **Scope:** a new core module (`game/scripts/core/combat/`), `game/scripts/core/world_state.gd`
  (orchestration only, per ADR 011), `game/content/actors.json`, `game/content/objects.json`,
  `game/content/jobs.json` and their schemas, `game/scripts/viewer/colonist_sprites.gd`,
  `game/scripts/core/persistence/save_io.gd`, `game/scripts/core/persistence/state_codec.gd`,
  `game/scripts/core/scheduling/global_assignment.gd`, `docs/architecture/core-budgets.json`,
  `docs/architecture/orders-and-movement.md`, `docs/architecture/save-system.md`,
  `game/scripts/tests/test_actor_table.gd`.
- **Implements:** F5 combat in `docs/architecture/foundation-for-breadth.md`.

## Decision

`game/scripts/core/combat/` is a generic combat resolution and targeting module, wired into
`WorldState.tick()` as plain orchestration (ADR 011: `WorldState` calls it, does not implement
it). Nothing in the module, or in the content it adds, names a species.

### Targeting (`combat_targeting.gd`)

`CombatTargeting` is static and stateless. It answers two questions: the nearest adjacent
(Chebyshev-1) hostile target with a health component, for the attack rule; and the nearest
hostile actor anywhere on the map, for the flee giver's away-direction pick.

- Hostility is read via `Relations.relation(a_faction, b_faction)` with each side's runtime
  `factionId` field passed explicitly, *not* `Relations.is_hostile(actor_a, actor_b)`. The latter
  reads content's `faction_id` key ([ADR 014](014-factions-and-relations.md)), but live actors and
  placed objects carry the runtime camelCase `factionId` instead, so `is_hostile()` would silently
  resolve every pair to the `"neutral"` fallback.
- Movement does not enforce exclusive tile occupancy, so `nearest_adjacent_hostile()` keeps every
  actor on a tile (an `Array` per position key) and picks the hostile occupant with the
  lexicographically smallest id. A friendly actor on the same tile never hides a hostile one.

### Resolution (`combat_resolver.gd`)

`CombatResolver` is static and runs once per tick.

- Every actor with a `combat` component decrements its `cooldown_remaining` by one every tick,
  whether or not it has an adjacent target. The rule is elapsed ticks, not ticks spent engaged, so
  an actor that disengages for longer than `cooldown` attacks immediately on re-engaging.
- An actor strictly below its `flee_hp_fraction` withholds its attack; its cooldown still elapses.
- Once ready and adjacent to a hostile target, an actor deals its `damage` to the target's
  `health.hp` (rule 1).
- Actors that reach 0 hp are reported back for `WorldState` to remove (rule 2). Damage to an object
  (rule 3) is applied immediately through an injected `damage_object` callable, since an object has
  no dictionary of its own to hand back.
- Each landed hit records one `attacked_by` event. The resolver returns the set of engaged actors,
  which `WorldState.get_actor_combat_reason()` exposes as the `"fighting"` reason. Both are
  documented in the "Combat" section of `docs/architecture/orders-and-movement.md`.

### `flee_hp_fraction` lives in content, not in the component's runtime state

`ActorCombat.build()`/`.validate()` (`game/scripts/core/actors/components/combat.gd`) carry only
`attack`/`damage`/`cooldown`/`cooldown_remaining` into a spawned actor's runtime state. The combat
module reads `flee_hp_fraction` directly from the actor definition's tunables
(`ContentRegistry.get_entry("actors", kind).tunables.combat.flee_hp_fraction`) whenever it needs
it, defaulting to `0.0` (never flee). `actors.schema.json`'s `combat` tunables accept it as an
optional `number` in `(0, 1]`. Only `colonist` declares a value (`0.3`, generic unarmed tunables);
`wolf` and `trader` are untouched.

### Colonists get a `combat` component without changing `actor_table.gd`

`content/actors.json`'s `colonist` entry declares `combat` among its components.
`ActorTable._spawn_colonist()` keeps the colonist's legacy field set and never adds a `combat` key
itself, so `WorldState._ensure_combat()` backfills it, the same way `_ensure_needs()` and
`_ensure_health()` already do. It runs once after `_spawn_colonists()` in `_init()`, and every tick
from `_decay_needs()` for colonists loaded from saves that predate the component. It is always a
plain append, never a rebuild, so the key lands in the same position on every colonist and
`state_hash()`'s `JSON.stringify(_colonists)` stays deterministic across runs of the same seed.

### `flee` is an ordinary job kind

`content/jobs.json` gains `{"kind": "flee", "labour": "", "toils": ["reserve", "go_to", "work",
"release_all"], "work_ticks": 1}`: the same walk, wait one tick, finish shape `incident` uses. The
job reaches `"completed"` on arrival through `_toil_on_work_complete()`'s existing generic path, so
`toil_executor.gd` is unchanged. `docs/architecture/contracts/game-state.schema.json`'s `jobs.kind`
enum and `SaveIO._validate_state()`'s separate job-kind whitelist both include `"flee"`, so a save
containing a queued, active or terminal `flee` job validates. A job's `kind` was always a plain
string, so no schema-version bump is needed.

### The flee job giver (`combat_giver.gd`)

`CombatGiver` is a job giver alongside `HaulGiver` and `NeedGiver`, deciding when a `flee` job
should exist (rule 4, "paths away"). There is no bespoke per-actor chase loop.

**Submission.** Jobs go through `WorldState._scheduler.submit_autonomous()` (ADR 014 amendment),
the entry point incident actors use, so a non-colony actor (such as a hostile wolf) can flee
without the `may_be_ordered` gate refusing it. While an actor has a queued or active flee job the
giver leaves it alone, so it never leaks a previous leg's reservation. Continuous retreat is built
from single legs: because `flee` completes one tick after arrival, an actor still below its
threshold gets a fresh leg on the next tick.

**Episodes.** The giver owns a per-actor *episode* (`_episodes`). It is opened at the interrupt
boundary of the first leg, holds the destinations excluded so far, and, by its presence, records
that the giver still owes the actor a recovery. An episode survives a cancelled leg, destination
exhaustion (nothing is erased when `_pick_flee_target()` returns null) and save/load: it is
persisted as the optional top-level `combatBlockedTargets` field (an array of `{actorId, tiles}`,
mirroring `needJobAssignments`), included in `state_hash()` via the same `StateCodec` helper
(a raw `Vector2i` dictionary key cannot be passed to `JSON.stringify()`), and documented with its
restore order in `docs/architecture/save-system.md`. `CombatGiver.owns(actor_id)` reports whether an
episode is open.

**Interrupt and recovery.** Before submitting the first leg, the giver calls
`WorldState._interrupt_current_job()` (the critical-interrupt boundary `NeedGiver` uses, ADR 009),
suspending whatever the actor was doing. Recovery is keyed on the episode, not on a current job:
the giver cancels any tracked flee job through the shared `_finish_job()` boundary (a no-op if the
job is already terminal), erases the episode, and then calls `_resume_interrupted_job()`.

**Target selection.** `_pick_flee_target()` ranks all 8 directions by how directly they point away
from the threat (ties broken by a fixed index). Direction is the outer loop and distance, farthest
first, the inner loop, so a short escape in a good direction beats any candidate in a worse one.
Every candidate must:

- strictly increase the actor's distance from the threat compared with its current tile;
- be passable under the fleeing actor's own faction and region-reachable
  (`WorldState._region_reachable()`);
- pass the reservation-eligibility gate `submit_autonomous()` uses
  (`WorldState._actor_may_reserve_target()`) and not already be another job's live reservation
  (`WorldState._flee_target_reserved()`);
- not be occupied by a hostile actor;
- not be excluded by the current episode.

**Blocked and unreachable legs.** `RegionMap.reachable()` is deliberately faction-agnostic, so a
tile behind a door the actor's faction cannot pass can look reachable while the real,
faction-aware route search never finds a path. A tracked leg stuck `queued` with
`blocked_target_reserved` or `blocked_target_unreachable` is therefore cancelled through
`WorldState._cancel_autonomous_job()` and its destination added to the episode's exclusions. The
exclusions accumulate for the whole episode, because a run of same-direction candidates can all
sit behind one door and a single-slot memory would cycle through them forever. A leg that becomes
unreachable mid-walk is cancelled only (never resubmitted through the ordinary `may_be_ordered`
gated `submit()`) in `_toil_on_unreachable()`, exactly like `incident`; the giver picks a fresh
target on the next tick.

**Winning the scheduler.** Interrupted work returns to the ordinary candidate pool, where it could
out-score an unrestricted flee job indefinitely; a `NeedGiver` commitment would likewise make
`GlobalAssignment.tick()` propose only the need job. `CombatGiver.get_committed_jobs()` therefore
supplies its own commitment map, layered over `NeedGiver`'s in `WorldState._committed_jobs()`, so a
fleeing actor's commitment always wins (rule 4 pre-empts a critical need as it pre-empts ordinary
work). `_colonists_not_searching_need()` keeps a fleeing colonist in the scheduler's worker list
even while it is mid need-search.

**Sharing the interrupt slot with `NeedGiver`.** Both givers pause and resume work through the same
`WorldState._paused_jobs` slot, which records no owner. While an episode is open:

- `WorldState._colonists_not_combat_owned()` removes the actor from the list passed to
  `NeedGiver.advance()`, freezing both new need onsets and in-flight need searches for it without
  clearing `NeedGiver`'s own `_searching`/`_pending` state, which resumes where it left off.
- `WorldState._resume_interrupted_job()` returns without touching `_paused_jobs` when
  `CombatGiver.owns()` is true. This covers `NeedGiver.resolve_job()` callbacks fired by
  cancel/fail/invalidate commands on a still-queued need job. The giver's own recovery erases the
  episode first, so its resume call proceeds normally.

**Save and load.** The giver's `_fleeing` map (actor to current flee job) is not persisted; it is
rebuilt from the queue.

- `StateCodec.decode()` calls `restore_blocked_targets()` after the scheduler queue and scheduling
  state are restored. It re-adopts every non-terminal `flee` job for its restricted actor (opening
  an episode if the save predates episode persistence). The restriction lookup is
  `WorldState._job_restricted_to()`, which falls back to `GlobalAssignment.get_waiting()` for a job
  that has never activated; `restrict_to_for()` alone returns `""` for such a job.
- `advance()` also re-adopts for any open episode lacking a tracked job, and an adopted job goes
  through the same status handling as a tracked one on the same tick. The first tick after a load
  therefore behaves exactly like the uninterrupted run.
- Route reconstruction after load is faction-aware: `GlobalAssignment.restore_scheduling()` uses
  `_passable_for(worker, entry, is_passable)` per candidate (an ordinary entry gets
  `is_passable` back unchanged), and `StateCodec._restore_reroutes()` and
  `WorldState._advance_go_to_or_resubmit()` pass the actor's own `factionId` (defaulting to
  `"colony"`).
- `_reconcile_incident_jobs_after_load()` distinguishes a never-activated queued incident job
  from one that was active and then suspended by a flee interrupt, using `restrict_to_for()`
  (non-empty only once a job has activated). The latter is re-associated via `_incidents.adopt()`
  and resumes through the restored `_paused_jobs` entry.

**Resuming interrupted work.** `GlobalAssignment.resume_assignment()` applies the same gates as the
scheduler's ready loop, read from the job's `_activated_entries` snapshot: an autonomous entry is
exempt from the player-order gate and reserves through the target-aware `_pair_may_reserve()`.
Without this, an incident actor's interrupted incident job failed as `not_ordered_by_player` on
resume. If recovery's fresh route (`_advance_go_to_or_resubmit()`) is immediately unreachable, it
goes through `_toil_on_unreachable(job_id, job, true)`, the kind-aware boundary that cancels
`incident`/`flee` jobs and resubmits every other kind.

### Object health

`content/objects.json`'s `wall` and `door` kinds gain optional `health`/`max_health` fields (a kind
template, like `passable`/`move_cost`), with matching optional properties in
`objects.schema.json`. Per-instance hp lives in `_object_health`, a map keyed like
`_object_factions` (`"%d_%d" -> {"hp", "maxHp"}`) and maintained by `_set_object()`.

- `_object_health` is included in `state_hash()`: a wall's remaining hp changes future combat
  outcomes.
- `StateCodec._encode_objects()`/`_decode_objects()` persist it as each `objects` entry's optional
  `health: {hp, maxHp}` field, present only for kinds that declare `max_health`. This follows the
  optional `route.rerouting` precedent, so no `SCHEMA_VERSION` bump or migration is needed.
  `game-state.schema.json` adds the optional property.
- `SaveIO` accepts an absent `health` key, but a present one (including an explicit `null`) must be
  a valid dictionary with `hp >= 0` and `maxHp >= 1`, mirroring `_valid_entity_health()`. An
  explicit `null` would otherwise pass validation and then fail when decoded into a typed
  `Dictionary`.
- `StateCodec.decode()` restores `_objects`/`_object_factions` directly, bypassing `_set_object()`.
  `WorldState._ensure_object_health()` runs every tick from `_decay_needs()` and backfills full
  health for any placed object whose kind declares `max_health` but has no entry: a save from
  before this field existed, or a hand-built fixture.

### Removing an actor

`WorldState._remove_colonist_by_id()` calls `_cleanup_actor_scheduling(colonist_id)`, so every
removal path shares it: death via `_apply_actor_death()`, and an incident despawn via
`IncidentScheduler.on_job_finished()`. The cleanup:

1. calls `GlobalAssignment.retire_worker(worker_id)`, which erases exactly that worker's in-flight
   candidate-routing batch (`_pending[worker_id]`). A removed worker never appears in the list
   passed to `_scheduler.tick()` again, so without this its pending candidates would stay in
   `claimed_jobs` forever and no other worker could be offered those unrestricted jobs;
2. captures and detaches the actor's `_paused_jobs` entry *before* cancelling its active
   assignment. Cancelling an active need job calls `NeedGiver.resolve_job()`, which would
   otherwise resume the paused (often unrestricted) work for the actor being removed and leave it
   assigned;
3. cancels, through `_finish_job()`, the active assignment, the captured paused job, and every
   other `queued`/`active` job restricted to the actor (`_job_restricted_to()`), pairing cancelled
   need jobs with `NeedGiver.resolve_job()`;
4. calls `CombatGiver.forget()`.

The incident job whose termination triggered a despawn is already terminal when this runs, and
`_scheduler.finish()` treats a terminal job as a no-op, so it is not re-entered.

Only death drops inventory: `_apply_actor_death()` calls `_drop_inventory_contents()` before
delegating to `_remove_colonist_by_id()`, since an ordinary incident despawn must not drop
anything. A colonist's held `ToolItemStore` tool (`WorkerType.get_held_tool()`) goes to the ground
via `set_ground()`, releasing any reservation it carried. A generic actor's `inventory.tool` and
tool-kind entries in `inventory.items` go through `_drop_inventory_item()`, which sends a declared
tool kind to `spawn_ground_tool_item()` (one identity-bearing ground tool per unit), where
tool-match searches look, and everything else to `_place_ground_item()`.

### Health bars

`colonist_sprites.gd` gains pure static `health_bar_fill(health) -> float` and
`health_bar_color(fraction) -> Color`, callable on the script's preload without a `Node2D`, so tests
can assert bar values headlessly. `WorldState.get_actors_with_health()` is an unfiltered read-only
accessor, and `_refresh_health_bars()` draws from it in its own loop with its own stale tracking,
independent of the worker-only sprite roster. A wolf or trader gets a health bar even without
dedicated sprite frames.

## Non-goals

- No player-controlled attack command, ranged combat or armour.
- No per-colonist update loop, re-route path or job-state machine outside the toil executor; the
  flee decision is a job giver, like haul and need.
- No wolf-, trader- or migrant-specific data (`flee_hp_fraction` is colonist-only; `factions.json`
  and `incidents.json` are untouched).
- No save-schema version bump or migration step: the `jobs.kind` enum widening, object health and
  `combatBlockedTargets` are all additive and optional, so older saves still validate.

## Consequences

- `docs/architecture/core-budgets.json`'s cap for `world_state.gd` rose from 2026 to 2440 over the
  course of this work, and `global_assignment.gd`'s from 673 to 688 (`retire_worker()` and the
  `resume_assignment()` gates).
- `test_combat.gd` proves, among other things: damage lands every `cooldown` ticks, including
  across a disengage/re-engage cycle; death drops inventory (including every unit of a held or
  carried tool, usable by surviving workers), cancels every nonterminal job restricted to the
  actor and frees its pending route search for other workers; a wall reduced to 0 hp is removed; a
  damaged wall's and door's exact hp survive save/load and combat continues from them; an actor
  strictly below `flee_hp_fraction` stops attacking, is interrupted and flees; a blocked direct
  escape finds an alternative that never moves toward the threat; flee jobs survive save/load
  (queued, searching, active or blocked) without duplication and with the same subsequent
  destinations, positions and faction-aware routes as an uninterrupted run; recovery after
  destination exhaustion resumes the interrupted work; need searches, need onsets and need-job
  terminations during a flee episode never disturb it; an incident actor removed mid-flee leaves
  no jobs, reservations, assignments, searches or giver associations behind; queued, active and
  terminal `flee` jobs pass `SaveIO.write_atomic()`; and two runs of the same seed produce
  identical `state_hash()` values.

## Alternatives considered

- **A bespoke per-actor walk state machine instead of a job giver.** Rejected: ADR 011 forbids a
  job-state machine outside the toil executor; `combat_giver.gd` reuses the existing `go_to` toil
  and the shared job queue, like `haul_giver.gd`.
- **Persist `_object_health` with a `SCHEMA_VERSION` bump and a `save_migrations.gd` step,
  following `factionId`'s required-field precedent.** Rejected: `route.rerouting` already
  establishes that an optional per-entry field needs neither a version bump nor a migration,
  since older saves simply omit it and the decoder tolerates its absence.

## Revision notes

The design above was reached through several revisions. The main changes from the first version:

- The cooldown originally decremented only while a target was adjacent, and the flee threshold was
  "at or below" rather than strictly below.
- Object health was first unpersisted and excluded from `state_hash()`, relying only on
  `_ensure_object_health()`; a damaged wall silently returned to full health after loading.
- Flee tracking was originally transient (`_fleeing` and an unpersisted `_blocked_targets` map),
  so recovery after a load or after destination exhaustion never retired the flee job or resumed
  the interrupted work. The persisted episode replaced it.
- Flee target selection first tried a single diagonal ray, then used distance as the outer loop,
  which could pick the one open tile directly toward the threat.
- Actor cleanup first lived only in `_apply_actor_death()`, so an incident despawn during a flee
  left the flee job, reservation and giver episode behind; it now runs on every removal.
