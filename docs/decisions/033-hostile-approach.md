# ADR 033: Hostile approach job-giver

> **In short:** Hostile creatures such as wolves can now walk toward the colony on their own and attack, instead of only fighting whatever happens to be next to them. If their target dies or becomes unreachable, they pick a new one.

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** a new module (`game/scripts/core/combat/approach_giver.gd`),
  `game/scripts/core/world_state.gd` (orchestration only, per ADR 011), `game/content/jobs.json`,
  `docs/architecture/contracts/game-state.schema.json`, `game/scripts/core/persistence/state_codec.gd`,
  `game/scripts/core/persistence/save_io.gd`, `docs/architecture/core-budgets.json`,
  `docs/architecture/orders-and-movement.md`, `docs/architecture/save-system.md`,
  `game/scripts/tests/test_combat.gd`, and the `state_hash()` literal baselines in
  `game/scripts/tests/test_world_state_determinism.gd` and `test_toils_dig_chop_regression.gd`.
- **Extends:** ADR 021 (combat resolution), ADR 026 (route-budget and multi-tick search precedent).

## Decision

ADR 021 gave a hostile actor two behaviours: fight when adjacent, and flee below its
`flee_hp_fraction`. Neither ever *walks toward* a hostile target it has not yet reached, so a
wolf spawned across the map from the colony had no way to close the distance. This ADR adds the
third behaviour, alongside `combat_resolver.gd`/`combat_targeting.gd`/`combat_giver.gd` in
`game/scripts/core/combat/`: `approach_giver.gd` (`ApproachGiver`), a job-giver that decides *when*
an `approach` job should exist, exactly as `CombatGiver` decides `flee` (never a per-colonist loop
or job-state machine in `world_state.gd`, per ADR 011).

`WorldState.tick()` calls `ApproachGiver.advance()` once per tick, after `_apply_combat()` (which
runs `CombatResolver.resolve_tick()` then `CombatGiver.advance()`), keeping ADR 021's ordering in
which the attack and flee decisions get first say every tick. Unlike `CombatGiver`, this giver
runs *after* `_advance_colonists()`, not alongside `_apply_combat()`, for two reasons:

- Its "already adjacent" check (rule 1 below) must see this tick's post-movement positions, the
  same ones `CombatResolver.resolve_tick()` checks first thing next tick, since nothing moves in
  between. Checking pre-movement positions (as `_apply_combat()` would) submits a redundant
  approach job for an actor that walked into range this tick.
- An actor trapped this tick (`WorldState._trap_actor()`, ADR 026) already carries `trapped` by
  the time this giver looks at it, so an approach job can never win a same-tick race for that
  actor's scheduler slot against a freshly submitted `escape_trench` job. Both submit at the same
  priority and the scheduler tries only one candidate per worker per tick, so an approach job
  submitted on the tick an actor falls into a trench would delay `escape_trench`'s first
  activation by a tick. This is a real, reproducible scenario, covered by
  `test_trapped_actors.gd`'s `_check_hostile_ticks_remaining_syncs_with_real_work_progress()`
  (a wolf one tile from a trench, with only a colony colonist nearby). Because
  `WorldState._actor_may_reserve_target()` treats a `trapped` actor as "may only reserve its own
  tile", no such job is ever submitted.

The giver still shares the `_route_budget` ledger correctly with `RescueGiver`, `GlobalAssignment`,
and the toil executor's re-routes: `GlobalAssignment.tick()` clears it once at its start, earlier
in the same `tick()` call, and every later consumer (including this giver) draws from that
freshly cleared budget.

### Decision table

The table applies to every actor with a `combat` component whose faction's relation to `colony` is
`hostile` (`Relations.relation(actor_faction, "colony")`, read off the runtime `factionId` field
exactly like `CombatTargeting`; never `Relations.is_hostile()`, ADR 021's documented pitfall).
`advance()` evaluates the steps in this fixed order: rule 2, then the retarget check (rule 2.5),
then rule 1, then rules 3-5.

1. `CombatTargeting.nearest_adjacent_hostile()` is non-empty: do nothing further; the existing
   adjacent-only attack rule already has it.
2. `CombatGiver.owns(actor_id)` (an open flee episode): do nothing at all. Never submit,
   interrupt, or keep tracking an approach job for an actor `CombatGiver` owns, so fleeing keeps
   its priority over approaching by construction rather than by a race. This is checked first
   because it must release tracking even on a tick where adjacency also just became true;
   otherwise a fleeing actor that walked adjacent that tick keeps a stale approach association.

   2.5. **Retarget check.** If the tracked job's recorded target is lost, or the job is queued and
   blocked as unreachable (see "Retargeting" below), cancel it and drop the association. This runs
   before rule 1 so that rule 1's "do nothing" cannot skip the cleanup.
3. A non-terminal `approach` job is still tracked for this actor: leave it running.
4. No job is tracked (never was, or rule 2.5 just cancelled one) and the actor is not adjacent to
   a hostile: pick the single nearest reachable target and submit one fresh single-leg `approach`
   job.
5. No reachable target at all: do nothing this tick. This is re-evaluated every tick rather than
   latched, and leaves the actor free for `IncidentScheduler`'s walk-then-wait to drive.

`approach_giver.gd`'s class doc comment is the authoritative, current version of this table.

### Target set and selection order

The target set is every living actor and every placed object with a health entry
(`WorldState.get_object_faction_id`/`_object_health_at`, the same accessors `CombatTargeting`'s
adjacent scan reads) that the acting actor's faction relation makes it hostile to; never a
species-specific list.

Selection mirrors `need_giver.gd`'s single-subject, multi-candidate, real-route-ranked search
(one actor, many candidate tiles) rather than `rescue_giver.gd`'s double loop (many candidate
rescuers, each against many targets). For each hostile target, `ApproachGiver` picks that target's
single Chebyshev-adjacent tile nearest the acting actor, among tiles that are passable for its
faction, reservation-eligible, not already another job's live target reservation, and
region-reachable: one candidate tile per target, not up to eight.

Candidates are pre-sorted by Chebyshev distance for a cheap search order and early-stop pruning,
then ranked by real route length, one bounded `RerouteType.resume()` per tick through the shared
`WorldState._route_budget` ledger that `rescue_giver.gd` and `combat_giver.gd` already use
(ADR 004); never a fresh synchronous full search. Chebyshev rather than Manhattan distance is
required: movement permits diagonals, so Manhattan distance can exceed a candidate's true route
cost and is not an admissible lower bound for early stopping, whereas Chebyshev distance never
exceeds the real route length. Ties are broken deterministically: an actor candidate before an
object candidate, then ascending target id (actor) or ascending `"%d_%d"` tile key (object). The
top-ranked candidate is re-checked for a reservation race at commit time, mirroring
`need_giver.gd`'s commit phase.

The committed job is submitted through `GlobalAssignment.submit_autonomous()`, the same entry
point `CombatGiver` and `IncidentScheduler` use, so a non-colony actor is never refused by the
ordinary `may_be_ordered` gate.

### `approach` is an ordinary job kind

`content/jobs.json` gains `{"kind": "approach", "labour": "", "toils": ["reserve", "go_to", "work",
"release_all"], "work_ticks": 1}`, the same walk-then-finish-in-one-tick shape `flee` and
`incident` use. Arrival at the adjacent tile completes the job through
`WorldState._toil_on_work_complete()`'s existing generic fallthrough (no new branch); on the next
tick the actor is adjacent and `combat_resolver.gd`'s attack rule takes over. An `approach` job
whose route becomes unreachable mid-walk is cancelled (never resubmitted through the ordinary
gated `submit()`) at `WorldState._toil_on_unreachable()`, where `approach` joins `incident` and
`flee` in that kind-aware boundary.

### Retargeting

Every tick it looks at a tracked actor, `advance()` checks the job's recorded target
(`_job_targets`) before its scheduler status:

1. **Target died or was destroyed.** An actor target no longer in the tick's roster, or present
   but `health.dead`; or an object target whose health entry and placed-object record have both
   cleared (by `_damage_object()`'s zero-hp `_set_object(x, y, "")` or any other system). This is
   checked whether the job is active or queued, since the target is gone either way.
2. **Queued and blocked as unreachable.** A tracked job still `"queued"` with JobQueue's
   `BLOCKED_TARGET_UNREACHABLE` reason, the same reason `combat_giver.gd` watches for its flee legs
   (via a local copy of the typed-reason constant). JobQueue retries an unreachable queued target
   indefinitely, so this never resolves by itself.

Either trigger cancels the job through `_cancel_job` (a constructor callable wired to
`WorldState._cancel_autonomous_job`, the same shared `_finish_job()` boundary `combat_giver.gd`'s
`_cancel_job` and `rescue_giver.gd`'s `_retire_job` use), drops the association
(`_tracking`/`_job_targets`/`_job_actor`), and falls through into rule 4's search in the same tick.
A job already cancelled elsewhere this tick (by `WorldState._toil_on_unreachable()`, when an
active job's route becomes unreachable mid-walk) is detected the same way, by its status no longer
reading `"active"` or `"queued"`, and falls through identically.

When a fresh search finds no reachable target, the giver does nothing that tick (rule 5). It never
cancels or interferes with an unrelated incident job because its own search failed; it simply
stops submitting until a target becomes reachable again, which may be never for an actor that is
permanently walled off.

### Flee priority

The flee priority `CombatGiver` owns (hp below `flee_hp_fraction`) needs no extra production code.
`WorldState._interrupt_current_job()` already pauses (never cancels) whatever job an actor is
executing, regardless of kind, through the boundary `NeedGiver` and `CombatGiver` share. Rule 2's
`_release_tracking()` keeps `_job_targets`/`_job_actor` alive (dropping only `_tracking`), so a
paused approach job is re-adopted, not resubmitted, once the flee episode closes.

### Persistence: the job's target association is not derivable from the queue

Unlike `CombatGiver`'s `_fleeing` (an actor_id -> job_id map that can always be rebuilt from the
restored scheduler queue via `restrict_to_for()`), `ApproachGiver`'s job_id -> target association
cannot be re-derived after a load: an object target has no living record to re-scan, and even an
actor target cannot safely be re-derived from adjacency alone (the same situation as
`rescue_giver.gd`'s `_job_victim`, ADR 026/029). `ApproachGiver` exposes
`get_job_targets()`/`restore_job_targets()`, and `state_codec.gd` persists the association verbatim
as a new optional top-level `approachJobTargets` field (an array of `{jobId, kind, actorId}` or
`{jobId, kind, tile}` entries). The change is additive with no `schemaVersion` bump; an older save
simply omits the field, as with `combatBlockedTargets` and `rescueVictimAssignments`.
`game-state.schema.json`'s `jobs.kind` enum gains `"approach"`; the new field is not added to any
`required` array. `save_io.gd`'s separate job-kind whitelist (the duplicate list ADR 021 found and
fixed for `flee`) also gains `"approach"`, with a `_valid_approach_job_targets()` structural check.
`WorldState.state_hash()` includes the association (JSON-safe-encoded through the same
`state_codec.gd` helper), since it affects the next commit and adjacency decision.

`ApproachGiver`'s actor_id -> job_id tracking (`_tracking`) is not persisted. Like `CombatGiver`'s
`_fleeing` and `rescue_giver.gd`'s `_pending`, it is rebuilt after a load from the restored
scheduler queue: `restore_job_targets()` re-adopts every non-terminal `approach` job for the actor
it is restricted to.

**Backward compatibility:** `approachRetiredActors`, written by the earlier retirement design (see
"Revision notes"), stays in `game-state.schema.json` and in `save_io.gd`'s accepted top-level
fields and structural validator, so saves written by that version still load. `state_codec.gd`'s
`decode()` no longer reads it and new saves never write it.

## Non-goals

- No change to `combat_resolver.gd`'s attack rule, `combat_giver.gd`'s flee semantics or
  `combatBlockedTargets`, or any existing flee/combat test's assertions.
- No wolf-specific or trader-specific content: `content/actors.json`, `content/incidents.json`, and
  `content/factions.json` are untouched, and the existing `wolf` actor definition is reused as a
  test fixture only.
- No presentation or rendering work.

## Consequences

- `docs/architecture/core-budgets.json`'s cap for `game/scripts/core/world_state.gd` first rose
  from 3769 to 3808 (+39) for the giver's construction and wiring (`_build_dimension_services()`,
  the call site in `tick()` and its doc comment explaining why the giver runs after
  `_advance_colonists()`), the `_toil_on_unreachable()`/`_cleanup_actor_scheduling()` additions,
  and the `state_hash()` entries for the job-target association and the retired-actor set. Removing
  the retired-actor entry later lowered it to 3804 (-4), net of the new `cancel_job` constructor
  argument. Each cap equals the file's exact post-change line count, the convention used by every
  core-budget ADR since ADR 015.
- `approach_giver.gd` carries none of this budget: job-giver modules are not core-budgeted files,
  matching `need_giver.gd`, `haul_giver.gd`, `rescue_giver.gd`, and `combat_giver.gd`.
- Removing `"approach_retired_actors"` from `state_hash()`'s snapshot changed every literal baseline
  hash sensitive to its shape: `test_world_state_determinism.gd`'s `PRE_INCIDENT_BASELINE_HASH` and
  `test_toils_dig_chop_regression.gd`'s `EXPECTED_HASH`/`COLONY_EXPECTED_HASH` were re-captured by
  running each test under the pinned Godot version, per the "never hand-derive a hash" rule in
  [AGENTS.md](../../AGENTS.md).
- `test_combat.gd` proves that:
  - a wolf spawned at a map edge, with no destination given by the test, walks to a tile
    Chebyshev-adjacent to a closed colony door and starts fighting (`attacked_by` event,
    `get_actor_combat_reason() == "fighting"`);
  - an actor already adjacent to a hostile target is never given an approach job, and an actor
    `CombatGiver.owns()` is never given or kept on one;
  - two fresh runs of the same seed and scenario produce identical `state_hash()` at every sampled
    tick through an in-progress approach, and a save taken mid-approach (job queued or active)
    reloads with the same tracked target and continues;
  - the actor retargets after its target actor dies and after its target object is destroyed;
  - a fully walled-off actor ends with no approach job queued or active, leaving
    `IncidentScheduler` free to drive it
    (`_check_approach_falls_back_to_incident_when_fully_walled_off()`);
  - an active approach job is paused (not left `"active"`, never orphaned) the moment hp drops
    below the threshold, a flee job takes over, and approaching resumes once hp recovers, through
    ordinary target selection (not necessarily the same target);
  - a stale job is cancelled even while the actor is adjacent to, and fighting, a different
    hostile (`_check_approach_cancels_stale_target_while_adjacent_to_different_hostile()`; a second
    hostile is re-pinned next to the moving hunter every tick so adjacency persists);
  - the giver's fallback never interferes with an unrelated incident job
    (`_check_approach_fallback_never_interferes_with_unrelated_incident_job()`): a genuine
    `_incidents.propose()` job runs to completion while a separately committed approach job for a
    sealed-off target stays `"queued"` behind it, and that job is swept up by the ordinary despawn
    cleanup (`WorldState._cleanup_actor_scheduling()`), not cancelled by this giver;
  - the queued-and-unreachable trigger works in isolation
    (`_check_approach_retargets_when_queued_job_goes_blocked_unreachable()`): a gapless wall that
    never touches the destination tile cuts only the route, and the job is cancelled without ever
    passing through `"active"`, which only that trigger can cause.

  Every retarget and fallback check asserts that
  `ReservationInvariantsType.find_orphaned_reservations()` stays empty throughout, not just at the
  end.

## Revision notes

- **Retirement replaced by retargeting.** The first version cancelled-only an approach job that
  became unreachable and then *retired* the actor (`_retired`), blocking any further search until
  `forget()` cleared it on death, removal, or a change in faction relation. The retired set was
  persisted as `approachRetiredActors` and included in `state_hash()`. Retargeting (above)
  replaced this permanent latch, and the retired set and its persistence were removed.
- **Rule order.** An early version checked adjacency (rule 1) before `CombatGiver.owns()` (rule 2),
  which left a stale association on an actor that became adjacent on the tick it started fleeing.
  A later version ran the retarget check after rule 1, so a dead target's job, and its reservation,
  stayed tracked forever whenever the actor happened to be adjacent to a different hostile. Both
  were fixed by the fixed order described in the decision table.
- **Distance metric.** Early-stop pruning originally used Manhattan distance, which is not
  admissible under diagonal movement and could prune a genuinely nearer target; it now uses
  Chebyshev distance.

## Alternatives considered

- **Rank every Chebyshev-adjacent tile of every target (up to 8 per target) instead of one per
  target.** Rejected: it multiplies the bounded per-tick route-search budget by up to 8x for no
  behavioural gain. One canonical nearest-adjacent tile per target is deterministic and
  sufficient; a future ADR can widen it if a real scenario needs it.
- **Reuse `rescue_giver.gd`'s double-loop shape (candidates of candidates).** Rejected: that shape
  exists because rescue ranks *rescuer* candidates, each against several *target* tiles for one
  fixed victim. The roles do not transfer to one fixed actor ranking several hostile targets.
  `need_giver.gd`'s single-subject, multi-target-tile ranking is the closer precedent and is what
  this module mirrors.
