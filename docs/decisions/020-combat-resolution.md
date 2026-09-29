# ADR 020: Generic combat resolution and targeting

- **Status:** accepted (round-9 revision); every review round's findings closed, none remain
  `## Blocked`
- **Date:** 2026-09-22
- **Scope:** a new core module (`game/scripts/core/combat/`), `game/scripts/core/world_state.gd`
  (orchestration only, per ADR 011), `game/content/actors.json`, `game/content/objects.json`,
  `game/content/jobs.json` and their schemas, `game/scripts/viewer/colonist_sprites.gd`,
  `game/scripts/core/persistence/save_io.gd`, `docs/architecture/core-budgets.json`,
  `game/scripts/tests/test_actor_table.gd`, `docs/architecture/orders-and-movement.md`
  (re-scoped round-2), `game/scripts/core/persistence/state_codec.gd`,
  `docs/architecture/save-system.md` (re-scoped round-4),
  `game/scripts/core/scheduling/global_assignment.gd` (re-scoped round-6).
- **Implements:** F5 combat in `docs/architecture/foundation-for-breadth.md`; issue #302 (a task of
  #278).

## Decision

`game/scripts/core/combat/` is the one new core system this objective introduces: a generic
combat resolution + targeting module, wired into `WorldState.tick()` as plain orchestration
(ADR 011 — `WorldState` calls it, does not implement it). Nothing in it, or in the content this
task adds, names a species.

- `combat_targeting.gd` (`CombatTargeting`, static, stateless): the nearest adjacent
  (Chebyshev-1) hostile target with a health component for the attack rule, and the nearest
  hostile actor anywhere on the map for the flee giver's own away-direction pick. Hostility is
  read via `Relations.relation(a_faction, b_faction)` with each side's own runtime `factionId`
  field threaded explicitly — **not** `Relations.is_hostile(actor_a, actor_b)`, which reads
  content's `faction_id` key (docs/decisions/015-factions-and-relations.md); every live actor and
  placed object carries the runtime, camelCase `factionId` field instead, so calling
  `is_hostile()` here would silently resolve every pair to the `"neutral"` fallback.
- `combat_resolver.gd` (`CombatResolver`, static): runs once per tick. Every actor with a `combat`
  component decrements its own `cooldown_remaining` by one on every applicable tick — independent
  of whether it currently has an adjacent target, so the rule is elapsed ticks, not ticks spent
  engaged (round-1 revision: the first version only decremented while a target was adjacent, so
  disengaging for longer than `cooldown` then re-engaging made the actor wait out a stale
  remaining value instead of attacking immediately). An actor strictly below its own
  `flee_hp_fraction` (round-1 revision: strictly below, not "at or below") withholds its own
  attack, but its cooldown still elapses. Once ready and adjacent to a hostile target, it attacks,
  dealing its `damage` to the target's `health.hp` (rule 1). Reports every actor that reached 0 hp
  (rule 2) for `WorldState` to apply; an object's damage/destruction (rule 3) is applied
  immediately through an injected `damage_object` callable, since an object has no dict of its own
  to hand back. Records one `attacked_by` event per landed hit and returns the set of actors
  currently engaged, which `WorldState.get_actor_combat_reason()` exposes as `"fighting"` — the
  typed event/reason vocabulary this module extends per the objective's own instruction, now also
  recorded in `docs/architecture/orders-and-movement.md`'s own "Combat" section (round-2 revision;
  see "Round-2 revision" below).
- `combat_targeting.gd` (`CombatTargeting`, static): round-1 revision — `nearest_adjacent_hostile()`
  now keeps every actor occupying a tile (an `Array` per position key), not just the last one
  inserted, and picks the hostile occupant with the lexicographically smallest id when more than
  one shares a tile. Movement does not enforce exclusive actor occupancy, so a friendly actor
  appended after an adjacent hostile one must never hide that hostile actor from targeting.
- `combat_giver.gd` (`CombatGiver`): a job-giver, alongside `HaulGiver`/`NeedGiver`, deciding when
  a `flee` job should exist (rule 4's "paths away" half). Submits through
  `WorldState._scheduler.submit_autonomous()` (ADR 015 Amendment) — the same entry point an
  incident actor's own job uses — so a non-colony actor (a hostile wolf) can flee its own job
  without the ordinary `may_be_ordered` gate refusing it. While a flee job is queued/active for an actor,
  the giver leaves it alone (never resubmitting a fresh leg mid-walk and leaking the previous
  one's target reservation); a "keep moving away" reaction is built from repeated single steps
  instead: `flee`'s own `content/jobs.json` entry completes itself one tick after arrival (a
  token `work_ticks: 1`, the same walk-then-finish shape `incident` already uses), so an actor
  still below its own threshold once it arrives gets a fresh leg the very next tick, with no
  bespoke continuous-chase loop of its own.
  Round-1 revision — three gaps closed:
  1. **Interruption.** Before submitting a fresh flee job, the giver now calls
     `WorldState._interrupt_current_job()` (the same critical-interrupt boundary `NeedGiver`
     already uses, ADR 009), pausing/suspending whatever the actor was doing instead of letting
     it run to completion; a no-longer-fleeing actor calls `_resume_interrupted_job()` symmetrically.
  2. **Save/load continuation.** The giver's own `_fleeing` association is never serialized. On
     each `advance()`, before submitting, it now checks for an existing non-terminal `flee` job
     already restricted to the actor (`GlobalAssignment.get_jobs()`/`.restrict_to_for()`) and
     adopts it instead of submitting a duplicate — the case right after a fresh load, where the
     scheduler's own persisted queue still carries the job this giver submitted before the save.
  3. **Target selection.** `_pick_flee_target()` no longer tries a single diagonal ray: it ranks
     all 8 directions by how directly they point away from the threat (deterministic, tie-broken
     by a fixed index) and, for each, checks passability under the fleeing actor's OWN faction,
     region reachability (`WorldState._region_reachable()`, not just single-tile passability), the
     same reservation-eligibility gate `submit_autonomous()`'s own reserve step consults
     (`WorldState._actor_may_reserve_target()`), and exclusion of any tile currently occupied by a
     hostile actor.
  A flee route that becomes unreachable mid-walk is handled at `WorldState._toil_on_unreachable()`:
  a `flee` job is now cancelled-only there (never resubmitted through the ordinary,
  `may_be_ordered`-gated `submit()`, exactly like `incident` already is), letting this giver's own
  `advance()` — which already treats any non-active/queued tracked job as free — pick a fresh
  candidate through the one `submit_autonomous()` path the very next tick.

### `flee_hp_fraction` lives in content, not the `combat` component's runtime state

`ActorCombat.build()`/`.validate()` (`game/scripts/core/actors/components/combat.gd`, owned by
a different task) carry only `attack`/`damage`/`cooldown`/`cooldown_remaining` into a spawned
actor's runtime state. Rather than editing that file (outside this task's owned paths), this
module reads `flee_hp_fraction` directly off the actor's own **definition** tunables
(`ContentRegistry.get_entry("actors", kind).tunables.combat.flee_hp_fraction`) every time it is
needed, defaulting to `0.0` (never flee) for any actor kind that does not declare one.
`actors.schema.json`'s `combat` tunables gain it as an optional `number` in `(0, 1]`; only
`colonist`'s tunables declare a value (`0.3`, generic unarmed tunables) — `wolf`/`trader` are
untouched, per the objective's Non-goals (no wolf/trader/migrant-specific data here).

### Colonist gets a `combat` component without touching `actor_table.gd`

`content/actors.json`'s `colonist` entry now declares `combat` among its components. `ActorTable._spawn_colonist()`
(not owned by this task) keeps colonist's exact legacy field set and would never add a `combat`
key itself. `WorldState._ensure_combat()` backfills it the same way `_ensure_needs()`/
`_ensure_health()` already backfill a component `_spawn_colonist()`'s special case does not
build — called once right after `_spawn_colonists()` in `_init()`, and every tick from
`_decay_needs()` for a colonist loaded from a save that predates this task. Always a plain
append, never a rebuild: every colonist is uniformly missing `combat` before this task, so the
key lands in the same position every time, keeping `state_hash()`'s `JSON.stringify(_colonists)`
deterministic across two runs of the same seed.

### Object health is a new per-instance parallel map, persisted as an optional field

`content/objects.json`'s `wall`/`door` kinds gain optional `health`/`max_health` fields (a kind
template, like `passable`/`move_cost`); `objects.schema.json` gains the matching optional
properties. Per-instance current hp needs a runtime store `WorldState` did not have: `_object_health`,
a parallel map keyed exactly like `_object_factions` (`"%d_%d" -> {"hp","maxHp"}`), initialized/
cleared by `_set_object()` alongside `_objects`/`_object_factions`. Round-4: it is now included in
`state_hash()`'s own snapshot (unlike `_object_factions`, which stays out by its own documented
precedent — a wall's remaining hp changes future combat outcomes, so it must not be excluded) and
persisted through `state_codec.gd` as each `objects` entry's *optional* `health: {hp, maxHp}` field
— present only for an object whose kind declares `max_health`, so a pre-round-4 save (no entry ever
had one) and a bare object both simply omit it, needing no schema-version bump or migration step
(see round-4 revision below, and `docs/architecture/save-system.md`).

Round-1 revision: `_object_factions` turned out to already be persisted (`StateCodec._encode_objects`/
`_decode_objects`), which the first version of this ADR wrongly cited as an un-persisted precedent —
and, worse, `StateCodec.decode()` restores `_objects`/`_object_factions` **directly**, bypassing
`_set_object()` entirely, so a wall/door loaded from a save carried no `_object_health` entry at
all and read as permanently untargetable/undamageable. Without touching the persistence layer,
`WorldState._ensure_object_health()` now backfills a missing entry for any placed object whose kind
declares `max_health`, the same idiom `_ensure_health()`/`_ensure_combat()` already use for a
component a restore path does not build — run every tick from `_decay_needs()`. This still applies
after round-4 for any object whose save genuinely predates this field (or a hand-built fixture that
bypasses `_set_object()`); a save written by this build now instead round-trips the object's exact
accumulated damage.

### `flee` is an ordinary job kind, not a bespoke walk state machine

`content/jobs.json` gains `{"kind": "flee", "labour": "", "toils": ["reserve", "go_to", "work",
"release_all"], "work_ticks": 1}` — the same walk-then-wait-one-tick-then-finish shape
`"incident"` already uses, so the job actually reaches `"completed"` once the actor arrives
(`WorldState._toil_on_work_complete()`'s existing generic fallthrough, no new branch), rather than
sitting `"active"` forever with nothing to drive it further. Uses `ToilExecutor`'s existing
vocabulary with no change to `toil_executor.gd` itself.
`docs/architecture/contracts/game-state.schema.json`'s `jobs.kind` enum gains `"flee"`; no
`schemaVersion` bump, since a job's `kind` was always a plain string with no other encoding
change — an old save with no `flee` job in flight remains valid, and a new one with one now
validates too. **Round-1 finding, closed round-2:** `game/scripts/core/persistence/save_io.gd`
carried its own, separate job-kind whitelist (`_validate_state()`, line ~855) that still ended at
`"incident"`; now re-scoped into this task's owned paths and widened to include `"flee"`, so a
save containing any `flee` job — queued, active or terminal — is accepted by
`SaveIO.write_atomic()`. `test_combat.gd` covers all three statuses directly through
`SaveIO.write_atomic()` (not just the `StateCodec` round trip already covered), since the
whitelist bug lived in `SaveIO`, not `StateCodec`.

### Actor death: every nonterminal job restricted to it, and every held item

`WorldState._apply_actor_death()` cancels, through the shared `_finish_job()` boundary: the dead
actor's active assignment, any job `_pause_work_job()` had paused for it, and — round-1 revision —
every other job still `queued`/`active` and restricted to it (`_job_restricted_to()`, which falls
back to `GlobalAssignment.get_waiting()`'s own raw `restrict_to` for a job that never got as far as
activation, since `restrict_to_for()` itself only reads `_activated_entries` and is documented `""`
for one that hasn't). A cancelled need job is paired with `NeedGiver.resolve_job()` so its own
`_pending` map never points at a removed actor; `CombatGiver.forget()` does the same for this
task's own giver. `_drop_inventory_contents()` now also moves a colonist's held `ToolItemStore`
item (`WorkerType.get_held_tool()`) to the ground via the store's own `set_ground()` — which
releases whatever job reservation it carried too — rather than leaving it pointing at a removed
actor, and drops a generic actor's `inventory.tool` slot the same way it already drops
`inventory.items`.

### Health bars

`colonist_sprites.gd` gains `health_bar_fill(health) -> float` and `health_bar_color(fraction) ->
Color`, pure static functions callable on the script's own preload without instantiating a
`Node2D`, so `test_combat.gd` can assert bar values headlessly. Round-1 revision: the bar no longer
renders only inside the sprite loop's own worker-only roster (`WorldState.get_colonists()`, which
filters to actors with a `worker` component) — `WorldState.get_actors_with_health()` is a new,
unfiltered read-only accessor, and `colonist_sprites.gd._refresh_health_bars()` draws off it in its
own loop with its own stale-tracking, independent of `_sprites`'s worker-only bookkeeping. A wolf
or trader now gets a health bar even though this file still has no dedicated sprite frames for one.

## Non-goals (this task)

- No player-controlled attack command, ranged combat, or armour.
- No per-colonist update loop, re-route path, or job-state machine outside the toil executor —
  the flee decision is a job-giver, exactly like haul/need.
- No wolf-, trader- or migrant-specific data (`flee_hp_fraction` is colonist-only; `factions.json`/
  `incidents.json` untouched).
- No save-schema version bump or migration step: the `jobs.kind` enum widening, the
  object-health field (round-4), and `combatBlockedTargets` (round-6's second pass) are all
  additive/optional, so an older save still validates unchanged.

## Consequences

- `docs/architecture/core-budgets.json`'s cap for `game/scripts/core/world_state.gd` has risen,
  from 2165 to 2378 across all six rounds: the round-1 revision's own additions
  (`_job_restricted_to()`, `_cancel_job_for_death()`, `_ensure_object_health()`,
  `get_actors_with_health()`, `_passable_for_flee()`/`_region_reachable()`) on top of the original
  2026 → 2165 rise, then round-2's rise to 2282, then round-3's `_committed_jobs()` and the
  `_colonists_not_searching_need()` fleeing override, rising to 2314, then round-4's
  `state_hash()`/doc-comment additions for persisted object health, rising to 2316, then round-5's
  death-cleanup ordering fix, `_reconcile_incident_jobs_after_load()`'s activation-shape check,
  and the new `_flee_target_reserved()`/`_cancel_autonomous_job()` wrappers, rising to 2370, then
  round-6's `retire_worker()` call site, rising to 2378, then round-6's second pass (see "Round-6
  revision" below) adding `_drop_inventory_item()` and the `combat_blocked_targets` state_hash()
  entry, rising to 2400. `global_assignment.gd`'s own cap (re-scoped round-6) rose from its
  pre-existing 673 to 685 for `retire_worker()` itself. `core-budgets.json` was re-scoped into this
  task's owned paths round-2 (see "Round-2 revision" below).
- `test_combat.gd` proves: damage lands every `cooldown` ticks, not every tick, including across a
  disengage/re-engage cycle; death at hp 0 drops inventory (including a held tool) as loose/ground
  items, cancels every nonterminal job restricted to the actor (queued or active), and removes it
  from scheduling; a wall reduced to hp 0 clears to no object; a damaged wall's and a damaged
  door's exact accumulated hp (not a reset full/default value) survive a save/load round trip and
  combat continues uninterrupted from that persisted value afterward; an actor strictly below its
  own `flee_hp_fraction` (not at-or-below) stops attacking, has its current work interrupted, and
  starts a `flee` job that survives a save/load without duplicating (whether that job was already
  active or still queued/never-activated at the moment of save); a blocked direct escape route
  still finds an alternate one that strictly increases separation from the threat, never one that
  moves toward it; hostile targeting is stable when a tile holds more than one occupant; a queued,
  active and terminal `flee` job all pass `SaveIO.write_atomic()`'s own validation; and two fresh
  runs of the same seed/tick sequence produce identical `state_hash()`.

## Round-9 revision

Three lifecycle gaps, all inside owned paths:

- **Resolving a queued need job could resume over an owned flee episode.**
  `_colonists_not_combat_owned()` (round-8) guards `NeedGiver.advance()`, but not the
  `_need_giver.resolve_job()` callbacks `_apply_job_command()`'s cancel_job/fail_job/invalidate_job
  path fires directly. A need that had paused ordinary work and submitted a still-queued need job,
  followed by combat interrupting the SAME actor into a flee episode before that need job resolves,
  left `_paused_jobs` still naming the original paused work (`CombatGiver`'s own interrupt found
  nothing new to pause, since the need job never activated an assignment). Resolving the need job
  then called `resolve_job() -> _resume_interrupted_job()`, which resumed and overwrote the actor's
  active flee assignment, orphaning it under `CombatGiver`'s own `_fleeing`/`_episodes`. Fixed at the
  shared `WorldState._resume_interrupted_job()` boundary itself (the same function both
  `NeedGiver.resolve_job()` and `CombatGiver.advance()`'s own recovery branch call): it now checks
  `CombatGiver.owns(colonist_id)` first and defers (returns without touching `_paused_jobs`) while an
  episode is open. `CombatGiver`'s own recovery branch erases its episode BEFORE calling this same
  function, so `owns()` already reads false by the time it runs for that call, and the deferred
  resume proceeds exactly as an uninterrupted run would once the episode actually closes.
- **Recovery's own immediate-unreachable result skipped the kind-aware failure boundary.**
  `_advance_go_to_or_resubmit()` (a fresh route re-derived once `_resume_paused_job()` finds the
  colonist not yet in reach) called `_resubmit_unreachable_job()` unconditionally on "unreachable" --
  the ordinary, `may_be_ordered`-gated `submit()` path `_toil_on_unreachable()` already knows to skip
  for an `incident`/`flee` job. If an incident actor's own original destination became disconnected
  while combat had it fleeing, recovery's own first-step search exhausting immediately cancelled the
  incident (despawning the actor through `_finish_job()`) and then submitted a replacement ordinary
  incident job restricted to the now-removed actor -- a job that can never run. Fixed by routing
  through `_toil_on_unreachable(job_id, job, true)` instead, the same kind-aware boundary every other
  first-leg unreachable case already uses (cancel-only for `incident`/`flee`, resubmit for every
  other kind, unchanged).
- **Despawn skipped the additional jobs/associations combat introduces.** Cancelling, failing or
  invalidating an incident job suspended by fleeing calls `IncidentScheduler.on_job_finished()`,
  which calls `WorldState._remove_colonist_by_id()` directly -- bypassing every scheduling/giver
  cleanup step `_apply_actor_death()` performs, since that cleanup lived only there. The actor's
  queued or active flee job, its scheduler search/assignment, its destination reservation, its
  `_paused_jobs` entry and its `CombatGiver` episode all survived the removal, held indefinitely
  since the removed actor never receives another tick. Fixed by extracting the scheduling/giver
  cleanup (`retire_worker()`, the paused-job/active-assignment/restricted-job cancellation loop,
  `CombatGiver.forget()`) into a new `_cleanup_actor_scheduling(colonist_id)`, called from
  `_remove_colonist_by_id()` itself -- the one path both `_apply_actor_death()` and
  `IncidentScheduler.on_job_finished()` funnel through -- so both callers share it uniformly.
  Inventory-drop stays specific to death (`_apply_actor_death()` calls `_drop_inventory_contents()`
  itself before delegating to `_remove_colonist_by_id()`), since an ordinary (non-death) incident
  despawn must not drop anything. Cancelling the very incident job this cleanup is itself running on
  top of is not a hazard: `_scheduler.finish()` rejects an already-terminal job as a no-op, and by
  the time the cleanup loop scans `_scheduler.queue.get_jobs()` for `queued`/`active` entries, that
  job's own status already reads terminal, so it never re-enters `_incidents.on_job_finished()`.
- **`docs/architecture/core-budgets.json`**: `world_state.gd`'s cap raised from 2410 to 2440 for the
  three fixes above.
- **`test_combat.gd`**: new coverage proves a paused work job, a submitted but unactivated need job
  and an active flee job together leave the flee assignment, recovery association and reservation
  lifecycle intact when the need job is cancelled/failed/invalidated; an incident actor's own
  destination disconnected mid-flee recovers as a cancellation with no replacement job or residual
  scheduling state; and terminating a suspended incident job while its flee job is searching, and
  again while active, leaves no jobs, reservations, assignments, searches or giver associations for
  the removed actor.

## Round-8 revision

Two independent bugs, both closed within this task's already-owned paths (no re-scope needed):

- **Need recovery could resume over an owned flee episode, or overwrite its own recovery
  association.** `NeedGiver._onset_failed()` (a real search timing out) and `NeedGiver._evaluate()`
  (a fresh onset at a toil boundary) both call the same `_interrupt_current_job`/
  `_resume_interrupted_job` callables CombatGiver uses for its own flee interrupt/recovery, through
  the single shared `WorldState._paused_jobs` slot -- with no record of which giver owns a given
  pause. A need search that outlived a flee interrupt could call `_resume_interrupted_job()` and
  silently overwrite the active flee job's own scheduler assignment (orphaning it, its reservation
  still held) without CombatGiver ever finding out; a need onset arriving mid-flee (at a flee
  toil's own go_to/work boundary) could call `_interrupt_current_job()` and overwrite
  `_paused_jobs`'s entry with the flee job's own id, losing the original interrupted work's
  association forever. Fixed at the shared call boundary rather than inside either giver's own
  logic: `CombatGiver.owns(actor_id)` (new, `_episodes.has()`) is CombatGiver's own public answer to
  "do I currently own this actor's interrupt/resume boundary", and
  `WorldState._colonists_not_combat_owned()` (new) excludes every actor it owns from the colonist
  list `tick()` hands to `NeedGiver.advance()` -- freezing both `_evaluate()`'s own new-interrupt
  path and `_advance_search()`'s own search continuation for that actor, deterministically, for as
  long as the episode stays open, without touching `need_giver.gd` at all (NeedGiver's own
  `_searching`/`_pending` state for a frozen actor is left untouched, not cleared, so it resumes
  exactly where it left off the tick ownership is released). `_paused_jobs`/`_resume_interrupted_job`
  themselves are unchanged: CombatGiver's own recovery call (unwrapped) always finds exactly what it
  itself paused, since NeedGiver never gets a chance to touch that actor's entry while owned.
  `test_combat.gd` adds `_check_need_search_survives_flee_activation()` (a real, non-stub multi-tick
  need search still alive when a separate hostile actor triggers flee) and
  `_check_need_onset_during_existing_flee_episode()` (a real need onset firing mid-episode);
  both assert the pre-existing `_paused_jobs` association survives untouched throughout and that
  recovery resumes the original work, never a need job.
- **Save/load routing reconstruction defaulted to colony passability regardless of the acting
  actor's own faction.** `tick()`'s own live scheduler search already picks per-candidate
  passability through `_passable_for(worker, entry, passable)` (autonomous entries route through
  the worker's own faction), but three restore-path call sites always used the colony default:
  `GlobalAssignment.restore_scheduling()` rebuilt both a resumed pending route and every found
  pair's path with the raw `is_passable` argument, ignoring each candidate's own persisted
  `autonomous` flag; `StateCodec._restore_reroutes()` rebuilt an in-flight reroute search (a
  colonist's own `route.rerouting` snapshot) via `world._routable_to(target)`, defaulting
  `faction_id` to `"colony"`; `WorldState._advance_go_to_or_resubmit()` (recovery's own fresh-route
  path once a paused job resumes) did the same. A raider's own saved flee search or active reroute
  could therefore resolve differently after a reload than the live, faction-aware search would have
  -- finding a path through a faction-forbidden door the uninterrupted run never could. Fixed by
  threading the acting worker/actor's own faction through all three: `restore_scheduling()` now
  calls `_passable_for(worker, entry, is_passable)` per candidate (an ordinary, non-autonomous entry
  is unaffected -- it gets back `is_passable` unchanged, so every existing colony-only golden hash
  holds); `_restore_reroutes()` and `_advance_go_to_or_resubmit()` now read the colonist's own
  `factionId` (defaulting `"colony"`, a no-op for an ordinary colonist) instead of `_routable_to()`'s
  own default. `test_combat.gd` adds three regressions:
  `_check_flee_pending_search_survives_save_load_faction_aware()` (saves a raider's own flee search
  while `GlobalAssignment._pending` is still genuinely mid-flight, exercising
  `restore_scheduling()`'s pending-route branch), `_check_flee_active_reroute_survives_save_load_faction_aware()`
  (a new "racetrack + door" fixture forces a live reroute mid-walk that stays genuinely
  `STATUS_SEARCHING` across a save, exercising `_restore_reroutes()`), and
  `_check_flee_recovery_resume_needs_fresh_route_faction_aware()` (exercises
  `_advance_go_to_or_resubmit()` directly: since that bug is identical on a live, never-saved run --
  a run-vs-run comparison could not reveal it, as an unfixed default would be wrong identically in
  both -- this asserts directly that the restored recovery's own fresh route never crosses the
  actor's own faction-forbidden door while still actually resuming the paused job).
- **`docs/architecture/core-budgets.json`**: `game/scripts/core/world_state.gd`'s cap raised from
  2400 to 2410 for `_colonists_not_combat_owned()` and the `_advance_go_to_or_resubmit()` faction
  threading; `global_assignment.gd` stays within its existing 688-line cap.

## Round-7 revision

Two blocking findings, plus one latent defect their regressions exposed:

- **Recovery cleanup depended on transient flee tracking.** `_fleeing` (actor -> current flee
  job) is rebuilt from the queue and starts empty after every load, and was also erased the moment
  a blocked leg was cancelled with no replacement destination left -- so recovery after a load, or
  after destination exhaustion, never retired the flee job, never cleared the exclusions and never
  resumed the interrupted work. The giver now owns a per-actor *episode* (`_episodes`, the map
  formerly named `_blocked_targets`): opened at the interrupt boundary of the first leg, it holds
  the excluded destinations and, by its mere presence, says the giver still owes this actor a
  recovery. It survives a blocked leg's cancellation, destination exhaustion (nothing is erased
  when `_pick_flee_target()` returns null) and a save/load (it is exactly the persisted
  `combatBlockedTargets` map; an episode with no exclusions is an entry with an empty `tiles`
  list, which the existing validator/schema already accept). Recovery is keyed on the episode, not
  on a current job: it cancels any tracked flee job, erases the episode and resumes. Restored flee
  jobs are reconciled *before* any decision: `StateCodec.decode()` now calls
  `restore_blocked_targets()` after the scheduler queue/scheduling restore, and that method
  re-adopts every non-terminal `flee` job for its restricted actor (opening the episode if a save
  predates episode persistence); `advance()` additionally re-adopts for any owned episode lacking a
  tracked job before the `should_flee` branch, so the very first tick after a load handles
  recovery exactly like the uninterrupted run.
- **Autonomous work could not be resumed after a flee (latent, exposed by the new recovery
  regressions).** `GlobalAssignment.resume_assignment()` applied the player-order gate
  (`_worker_may_be_ordered`) and the colony-item reservation gate to every worker, unlike the
  "ready" loop, which exempts an autonomous entry from the order gate and reserves through the
  target-aware `_pair_may_reserve()`. Resuming a raiders incident actor's own interrupted incident
  job therefore refused the reservation and failed the job as `not_ordered_by_player`. It now
  applies the ready loop's exact gates, read from the job's `_activated_entries` snapshot.
  `core-budgets.json` raises `global_assignment.gd`'s cap from 685 to 688 for it.
- **Dropping a multi-unit tool entry lost every unit but one.** `_drop_inventory_item()` spawned a
  single ground tool regardless of `count`; it now spawns one identity-bearing ground tool per
  inventory unit (`world_state.gd` stays within its 2400-line cap).
- **`test_combat.gd`**: `_check_flee_recovery_after_save_load_matches_uninterrupted()` drives a
  mid-search, an active and a blocked flee job on two identical worlds, saves one, recovers both
  and compares flee-job status, resumed till job, assignment, reservation, exclusions, route
  search and forty ticks of positions; `_check_flee_recovery_after_destination_exhaustion()` boxes a
  raiders actor into a three-tile room behind a door its faction cannot pass so every outside
  candidate is submitted, blocked, cancelled and excluded until nothing is left, then proves
  recovery clears the exclusions, consumes the paused-job entry and resumes the interrupted
  (autonomous) work; `_check_death_drops_every_inventory_tool_unit_usable_by_workers()` drops
  `{axe, count: 2}` plus `inventory.tool: pick`, asserts exactly three identity-bearing ground
  tools and none in the item pile, then runs a real chop and a real dig by two surviving workers
  through normal discovery, reservation, pickup and use of only those dropped tools.
- **`docs/architecture/save-system.md`** now documents `combatBlockedTargets` and its restore
  order.

## Round-6 revision

`game/scripts/core/scheduling/global_assignment.gd` was re-scoped into this task's owned paths
so the round-5 `## Blocked` finding could actually be fixed rather than left open:

- **A dead worker's own multi-tick route-search state could starve unrestricted work for every
  other worker, permanently.** `GlobalAssignment` gains `retire_worker(worker_id)`: erases exactly
  `_pending[worker_id]`, the worker's own in-flight candidate-routing batch, and nothing else
  (`_waiting`, `_assignments`, every other worker's own `_pending` entry are untouched). Called from
  `WorldState._apply_actor_death()` unconditionally, before the existing restriction-based job
  cleanup, since the gap was specifically in jobs that restriction-based cleanup correctly never
  touches (unrestricted, never-activated candidates a dead worker was merely evaluating). Without
  this, `tick()`'s own `claimed_jobs` rebuild (`for worker in _pending: for entry in
  _pending[worker]["candidates"]: claimed_jobs[entry["id"]] = true`) kept reporting those job ids
  claimed forever, since the dead worker never reappears in the `colonists` array `WorldState`
  passes to `_scheduler.tick()` to advance or retire its own batch.
- **`docs/architecture/core-budgets.json`**: `global_assignment.gd`'s cap raised from 673 (its
  pre-existing line count) to 685 for `retire_worker()`; `world_state.gd`'s cap raised from 2370 to
  2378 for the call site and its doc comment.
- **`test_combat.gd`**: `_check_dead_worker_pending_search_frees_job_for_other_worker()` places two
  colony-faction workers at a Manhattan distance from a shared unrestricted job's target that both
  exceed `GlobalAssignment.MAX_TRAVEL_PENALTY` (15), so their initial proposals tie on score and the
  worker-id tie-break deterministically picks one (`doomed_worker`) to begin the multi-tick search
  (open-arena BFS at `RouteSearch.STEP_BUDGET` (64) expansions/tick genuinely needs several ticks to
  cover a distance-20 diamond) while the other (`rescue_worker`) is never even proposed it, matching
  the finding's own shape: the job is still `_pending`, not yet assigned, at the moment of death.
  Kills `doomed_worker` mid-search (a real adjacent-attacker kill through `_apply_combat()`, not a
  bypass), then proves `GlobalAssignment._pending` no longer names it, the job stays `queued` (never
  cancelled -- it remains valid work), and `rescue_worker` goes on to actually receive and be
  assigned it (`status == "active"`) within a bounded number of further ticks.

### Round-6 revision, second pass

Three further blocking findings against the same review round, all inside owned paths:

- **Flee recovery left an orphaned active/queued flee job.** `CombatGiver.advance()`'s
  not-`should_flee` branch erased the giver's own `_fleeing`/`_blocked_targets` association and
  resumed interrupted work, but never retired the flee job itself -- an active leg (and its
  destination reservation) stayed live indefinitely once `_resume_interrupted_job()` overwrote the
  worker's assignment out from under it. Fixed by calling the same `_cancel_job` (shared
  `_finish_job()` boundary) the blocked-queued path already used, before erasing/resuming; safe
  whether the job is queued, active, or already completed on its own, since `job_queue.gd`'s
  `_finish()` rejects (no-ops) a job already terminal.
- **`_blocked_targets` was neither persisted nor hashed, and an adopted job skipped a tick of
  status handling.** Unlike `_fleeing`, `_blocked_targets` cannot be rebuilt from the scheduler's
  own queued/active jobs after a load -- a cancelled blocked flee job that produced an exclusion is
  already gone from the queue by the time it is excluded. `CombatGiver` gains
  `get_blocked_targets()`/`restore_blocked_targets()`; `StateCodec` gains
  `_encode_combat_blocked_targets()`/`_decode_combat_blocked_targets()` and a new, optional
  top-level `combatBlockedTargets` save field (an array of `{actorId, tiles}`, mirroring
  `needJobAssignments`'s `{colonistId, jobId}` shape) -- optional exactly like the object-health
  field, so no schema version bump or migration is needed, and `SaveIO._validate_state()`/
  `game-state.schema.json` both accept its absence. `WorldState.state_hash()` now includes it
  (JSON-safe-encoded through the same `StateCodec` helper, since a raw `Vector2i` dictionary key
  cannot be `JSON.stringify()`d). Separately, `advance()`'s adoption branch (`_adopt_existing_flee_job()`
  after a fresh load) no longer `continue`s straight past the blocked-queued check: it now falls
  through into the same status handling a same-tick-tracked job gets, so an adopted job already
  `queued` and blocked is excluded/cancelled the same tick, not one tick later than an uninterrupted
  run.
- **A dead actor's generic `inventory` tool contents were dropped where a tool-match search can
  never find them.** `_drop_inventory_contents()` routed `inventory.tool` and any tool-kind entry
  inside `inventory.items` through `_place_ground_item()` -- the ordinary stackable-pile store --
  but every tool-match precondition (`ToilExecutor`'s fetch-tool toil) only ever searches
  `ToolItemStore`. Fixed with a new `_drop_inventory_item(kind, count, x, y)` that dispatches by
  `is_tool_kind(kind)`: a declared tool kind goes through `spawn_ground_tool_item()`
  (`ToolItemStore`), anything else through `_place_ground_item()` as before.
- **`docs/architecture/contracts/game-state.schema.json`**: new optional `combatBlockedTargets`
  property (`$defs.combatBlockedTargetsEntry`), not added to the top-level `required` array.
  **`docs/architecture/core-budgets.json`**: `world_state.gd`'s cap raised from 2378 to 2400 for
  `_drop_inventory_item()` and the `state_hash()` addition.
- **`test_combat.gd`**: new coverage proves flee recovery during a queued, searching, and active
  flee leg each leaves no orphaned job or reservation; a save after multiple blocked destinations
  reproduces identical subsequent destinations, job transitions and actor positions against an
  uninterrupted run; and a dead actor's `inventory.tool`/`inventory.items` tool drops are reservable
  and usable by a surviving worker.

## Round-5 revision

Four blocking findings closed, all inside owned paths; a fifth confirmed genuinely out-of-scope
and reported `## Blocked` rather than worked around:

- **Death during a need job could reactivate the dead actor's own paused work.**
  `_apply_actor_death()` cancelled the active assignment (a need job the critical-need interrupt
  had switched the colonist onto) before checking `_paused_jobs` — cancelling a need job calls
  `NeedGiver.resolve_job()`, which calls `_resume_interrupted_job()`, which reactivates whatever
  `_pause_work_job()` had paused (the original, often *unrestricted*, work job) for the actor about
  to be removed. `_job_restricted_to()` then found no restriction for that reactivated job (an
  unrestricted job restricts to nobody) and never cancelled it, leaving a dangling assignment and
  reservation. Fixed by capturing and *detaching* `_paused_jobs[colonist_id]` before the active
  assignment is cancelled at all, so `_resume_interrupted_job()`'s own `_paused_jobs.has()` guard
  makes the resume a no-op; the captured job is then cancelled directly afterward, unconditionally,
  exactly like the active assignment already was.
- **A previously activated incident job paused by a flee interrupt was cancelled on load, not
  re-associated.** `_reconcile_incident_jobs_after_load()` treated every "queued" incident job as
  a never-activated proposal, but `CombatGiver`'s own flee interrupt suspends an *active* incident
  job back to "queued" exactly like a critical need would — saving mid-flee therefore destroyed a
  live, paused incident job and its actor association on every load. Fixed by using
  `GlobalAssignment.restrict_to_for()`'s own contract (non-empty only once a job has actually
  activated at least once, since `_activated_entries` is written at first activation and never
  cleared by `suspend()`) to distinguish "queued, never activated" from "queued, previously
  activated, paused by combat" — the latter is now re-associated via `_incidents.adopt()` exactly
  like an active job, so it despawns correctly and resumes through the `_paused_jobs` entry
  `StateCodec` already restores.
- **A blocked queued `flee` job could strand its actor forever, and a candidate's own eligibility
  was never checked against a live reservation.** `_pick_flee_target()` checked
  `_actor_may_reserve_target()` (faction eligibility) but never whether the candidate tile was
  *already* another job's live target reservation, so a flee job could be submitted straight at a
  claimed tile — where it then sat "queued" and `blocked_target_reserved`/`blocked_target_unreachable`
  forever, since nothing but a fresh submission ever changes a job's own target and
  `_toil_on_unreachable()` only ever fires once a job has activated. `RegionMap.reachable()`
  compounds this for the unreachable case: it is deliberately faction-agnostic (`regions.gd`:
  "Physical passability only — no faction awareness"), so it reports a tile behind a
  faction-forbidden door reachable regardless of the fleeing actor's own faction, even though the
  real per-tick route search (faction-aware) can never find a path through it. Fixed on both ends:
  `_pick_flee_target()` now also rejects a candidate `WorldState._flee_target_reserved()` reports
  reserved; and `CombatGiver.advance()` now detects a tracked flee job stuck "queued" with either
  blocked reason, cancels it through the new `WorldState._cancel_autonomous_job()` boundary, and
  excludes that exact destination (accumulated per actor for the whole flee episode, in
  `_blocked_targets` — not just the single most recent failure, since an entire run of
  same-direction candidates can sit past one door and a single-slot memory would keep re-trying
  them in an endless cycle) from every subsequent pick, so the search keeps making progress toward
  a direction that never needed the blocked tile at all.
- **`SaveIO._valid_object_health()` accepted an explicit `"health": null` the same as an omitted
  key.** `_valid_object()` called `_valid_object_health(object_entry.get("health"))`, and `.get()`
  returns `null` for both an absent key and an explicit `"health": null` value — indistinguishable,
  so the latter passed validation even though `StateCodec._decode_objects()` then assigns it
  straight into a typed `Dictionary` variable the instant `item.has("health")` is true, which errors
  on `null` rather than failing gracefully. Fixed by checking `object_entry.has("health")` at the
  caller: the key's *absence* is still accepted (unchanged), but its *presence* now always requires
  a valid Dictionary shape — `_valid_object_health()` no longer has a null-passthrough case at all.
- **`## Blocked` (out-of-scope): a dead worker's own multi-tick route-search state can starve
  unrestricted work for every other worker, permanently.** `GlobalAssignment._pending[worker]`
  holds a worker's own in-flight candidate-routing batch across ticks; `tick()` rebuilds
  `claimed_jobs` from every entry still in `_pending` (`for worker in _pending: for entry in
  _pending[worker]["candidates"]: claimed_jobs[entry["id"]] = true`), which excludes those job ids
  from being proposed to any OTHER worker this tick. When a worker dies mid-search over
  *unrestricted* candidates (never activated, so `_job_restricted_to()`'s restriction-based death
  cleanup does not touch them — correctly, since they remain valid for other workers), its own
  `_pending` entry is never removed: the dead worker no longer appears in the `colonists` array
  `WorldState` passes to `_scheduler.tick()`, so the `for colonist in workers: if not
  _pending.has(worker): continue` loop that would otherwise advance/retire it never runs for that
  worker again. `_pending` has no public eraser and `GlobalAssignment` is not in this task's owned
  paths — required change: a `retire_worker(worker_id)`-shaped method removing exactly that
  worker's own pending selection/search state while leaving the shared candidate jobs available to
  every living worker, called from `_apply_actor_death()`. See the handoff's `## Blocked` section.

## Round-4 revision

Object-health persistence, `## Blocked` since round-3, is now closed: `state_codec.gd` and
`save-system.md` were re-scoped into this task's owned paths, the one seam round-3 correctly
identified as missing.

- **`_encode_objects()`/`_decode_objects()`** (`state_codec.gd`) gain a third parameter/return key:
  each `objects` entry carries an *optional* `"health": {"hp","maxHp"}` field, present exactly when
  `world._object_health` has an entry for that key — mirrors the existing optional
  `route.rerouting` field (present only mid-search), not the required `factionId` field (which
  needed a migration precisely because it was required). Kept optional deliberately, so no
  `SCHEMA_VERSION` bump or `save_migrations.gd` step is needed at all — `save_migrations.gd` was not
  re-scoped into this task's owned paths, and an optional field needs no migration to stay valid
  for an older save.
- **`game-state.schema.json`**'s `object` `$def` gains the matching optional `health` property (not
  added to `required`); `SaveIO._valid_object_health()` validates it when present (hp ≥ 0,
  maxHp ≥ 1), mirroring `_valid_entity_health()`'s checks for actor health.
- **`WorldState.state_hash()`** now includes `_object_health` directly in its snapshot — the
  round-3 finding's own point: a damaged wall silently reverting to full health after a save/load
  changes future combat outcomes the diagnostic hash must be able to detect.
- **`test_combat.gd`**'s `_check_object_health_survives_save_load()` no longer only proves a health
  entry exists after load; it damages a wall and a door to distinct partial hp values, proves both
  *exact* values survive the round trip (not the object's full/default health), and proves combat
  continues correctly from the persisted value afterward (further damage lands relative to it, and
  reaching 0 still clears the object) — closing the round-3 finding that the old check "only checks
  that a health entry exists."
- `WorldState._ensure_object_health()` is unchanged in behavior; its doc comment now describes it as
  the fallback for a save that genuinely predates this field, not the everyday path.

## Round-3 revision

Three findings, all inside owned paths, closed; one (object-health persistence) confirmed
genuinely out-of-scope and now reported as `## Blocked` rather than a "known gap":

- **Flee never actually won scheduler assignment.** `GlobalAssignment.suspend_assignment()`
  (called by `_interrupt_current_job()`) returns the work a fleeing actor was interrupted from to
  the ordinary scored candidate pool, where it could out-score a merely-queued, unrestricted flee
  job forever — `CombatGiver` only re-interrupts when its own tracked job goes terminal, so once
  stuck it stayed stuck. An existing `NeedGiver` commitment (`committed_needs`) had the same
  effect: `GlobalAssignment.tick()` proposes *only* the committed job to a committed worker, so a
  flee job never even got a chance. A colonist mid need-search fared worse still:
  `WorldState._colonists_not_searching_need()` excluded it from `GlobalAssignment.tick()`'s own
  worker list entirely, so its flee job was never proposed at all. Fixed by giving `CombatGiver`
  its own commitment map (`get_committed_jobs()`, mirroring `NeedGiver.get_pending_assignments()`)
  and layering it over `NeedGiver`'s in a new `WorldState._committed_jobs()`, passed to
  `GlobalAssignment.tick()` in place of the raw need map — a fleeing actor's commitment always
  wins a collision, since rule 4 pre-empts a critical need exactly like it pre-empts ordinary
  work. `_colonists_not_searching_need()` now also keeps a colonist `CombatGiver` already tracks
  as fleeing, even while mid need-search. No `GlobalAssignment`/`NeedGiver` API changed — both
  already accepted a generic worker-id-to-job-id map; only `WorldState`'s own wiring changed.
- **A queued or still-searching `flee` job lost its restriction across a save/load.**
  `CombatGiver._adopt_existing_flee_job()` used `GlobalAssignment.restrict_to_for()`, which by its
  own contract only reads `_activated_entries` and returns `""` for a job that has never
  activated — exactly the state a flee job can be in for one or more ticks after submission
  (queued, or mid its own initial route search). A reload during that window found no
  restriction, so `CombatGiver` submitted a second, duplicate leg. Fixed by wiring `CombatGiver`'s
  `restrict_to_for` callable to `WorldState._job_restricted_to()` instead — the same
  `GlobalAssignment.get_waiting()`-falling-back helper `_apply_actor_death()` already relies on —
  rather than the raw scheduler method.
- **`_pick_flee_target()` could move the actor toward its own threat.** The candidate search's
  outer loop was distance (farthest first), inner loop direction: when every distance-6 endpoint
  except the one directly *toward* the threat was blocked, that endpoint won simply for being
  the first one found, regardless of direction. Fixed by requiring every candidate to strictly
  increase the actor's own distance from the threat compared to its current tile (an always-on
  correctness filter, not just a preference), and by making direction the outer loop (ranked
  away-from-threat first, as before) with distance descending inside each direction — so a
  short, available escape in a good direction is chosen over ever trying a bad one.
- **Object-health persistence: re-confirmed out-of-scope, now `## Blocked`.** Round-2 recorded
  this as a "known gap" and moved on; the task's own text says a persistence change like this
  should stop with `## Blocked` rather than be documented as deferred. `StateCodec.encode()`/
  `.decode()` (`game/scripts/core/persistence/state_codec.gd`) are the only read/write path for
  `WorldState.to_save_state()`/`from_save_state()` — there is no seam inside this task's owned
  paths (`save_io.gd` only validates the dictionary `state_codec.gd` already produced) to add
  `_object_health` to the encoded/decoded state or to `state_hash()`. See the handoff's `##
  Blocked` section; "Known gaps" below is retained only for the historical record of why
  `_ensure_object_health()`'s backfill exists.

## Round-2 revision

Four items from round-1's "Known gaps" were re-scoped into this task's owned paths and closed:

- **`game/scripts/core/persistence/save_io.gd`**: `_validate_state()`'s job-kind whitelist now
  includes `"flee"` alongside the existing kinds. `test_combat.gd` proves a queued, an active and a
  terminal (`"completed"`) `flee` job all pass `SaveIO.write_atomic()`.
- **`docs/architecture/core-budgets.json`**: `game/scripts/core/world_state.gd`'s cap raised to
  2282, its current line count.
- **`game/scripts/tests/test_actor_table.gd`**: already carried the correct
  `EXPECTED_COMPONENTS_BY_DEF_ID["colonist"]` (including `"combat"`) from the round it was first
  touched; left as-is, now authorized.
- **`docs/architecture/orders-and-movement.md`**: gained a "Combat" section documenting the
  `attacked_by` event and `fighting` reason, and the `flee` job's shape and lifecycle, alongside
  the document's existing typed event/reason tables.

## Known gaps

None open. The round-5 gap (a dead worker's own `GlobalAssignment._pending` route-search state
never retired) was closed by the round-6 revision's `retire_worker()`. The round-4 entry here
(`_object_health` not persisted through `state_codec.gd`/`state_hash()`) was closed by the round-4
revision.

## Alternatives considered

- **Give the flee job a bespoke per-actor walk state machine instead of a job-giver.** Rejected:
  ADR 011's guardrail forbids a job-state machine outside the toil executor; `combat_giver.gd`
  reuses the existing `go_to` toil and the shared job queue exactly like `haul_giver.gd`.
- **Persist `_object_health` with a `SCHEMA_VERSION` bump and a `save_migrations.gd` step,
  mirroring `factionId`'s required-field precedent.** Rejected (round-4): `save_migrations.gd` was
  not re-scoped into this task's owned paths, and a required field is not the only precedent this
  codebase has — `route.rerouting` already establishes that an optional, per-entry field needs
  neither a version bump nor a migration step, since an older save simply omits it and the decoder
  already tolerates absence. Object health follows that precedent instead.
