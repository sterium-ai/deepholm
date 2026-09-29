# ADR 031: Hostile approach job-giver

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** a new module (`game/scripts/core/combat/approach_giver.gd`),
  `game/scripts/core/world_state.gd` (orchestration only, per ADR 011), `game/content/jobs.json`,
  `docs/architecture/contracts/game-state.schema.json`, `game/scripts/core/persistence/state_codec.gd`,
  `game/scripts/core/persistence/save_io.gd`, `docs/architecture/core-budgets.json`,
  `docs/architecture/orders-and-movement.md`, `docs/architecture/save-system.md`,
  `game/scripts/tests/test_combat.gd`. Round-3 revision (issue #391, t2) additionally touches
  `game/scripts/tests/test_world_state_determinism.gd`/`test_toils_dig_chop_regression.gd`
  (`state_hash()` literal baselines only, re-captured, not new coverage).
- **Implements:** issue #390 (t1 of #389), issue #391 (t2 of #389, round-3 revision below); ADR 020
  (combat resolution), ADR 025 (route-budget/multi-tick search precedent).

## Decision

ADR 020 gave a hostile actor two behaviours: fight when adjacent, flee below its own
`flee_hp_fraction`. Neither one ever *walks toward* a hostile target it has not yet reached — a
wolf spawned across the map from the colony had no way to close the distance on its own. This task
adds the third, alongside `combat_resolver.gd`/`combat_targeting.gd`/`combat_giver.gd` in
`game/scripts/core/combat/`: `approach_giver.gd` (`ApproachGiver`), a job-giver deciding WHEN an
`approach` job should exist, exactly like `CombatGiver` decides `flee` (never a per-colonist loop
or job-state machine in `world_state.gd`, per ADR 011).

`WorldState.tick()` calls `ApproachGiver.advance()` once per tick, after `_apply_combat()` (which
runs `CombatResolver.resolve_tick()` then `CombatGiver.advance()`) — the same "runs after the
attack/flee decisions" ordering ADR 020 already established, so both existing rules get first say
every tick before this one runs. Unlike `CombatGiver`, this giver is wired to run AFTER
`_advance_colonists()`, not alongside `_apply_combat()`, for two reasons discovered while writing
its own test coverage:

- Its rule-1 "already adjacent" check must see this tick's POST-movement positions -- the exact
  ones `CombatResolver.resolve_tick()` will check first thing next tick, since nothing moves in
  between. Checking PRE-movement positions (as `_apply_combat()` would) submits a redundant
  approach job for an actor that simply walked into range this same tick.
- An actor trapped this very tick (`WorldState._trap_actor()`, ADR 025) already carries `trapped`
  by the time this giver looks at it, so it can never win a same-tick race for that actor's own
  scheduler slot against a freshly submitted `escape_trench` job. Both submit at the same priority
  and the scheduler only tries one candidate per worker per tick; an approach job submitted the
  same tick an actor falls into a trench (a real, reproducible scenario surfaced by
  `test_trapped_actors.gd`'s own `_check_hostile_ticks_remaining_syncs_with_real_work_progress()`,
  which spawns a wolf one tile from a trench with nothing else nearby but a colony-faction
  colonist) would otherwise delay `escape_trench`'s own first activation by a tick, one tick this
  giver has no legitimate claim to. Running after `_advance_colonists()` means the actor already
  reads `trapped` (which `WorldState._actor_may_reserve_target()` treats as "may only reserve its
  own tile") before this giver's own target search ever runs, so no such job is ever submitted at
  all.

Still shares the shared `_route_budget` ledger correctly with `RescueGiver`/`GlobalAssignment`/the
toil executor's own re-routes: `GlobalAssignment.tick()` clears it once at its own start, earlier
in the same `tick()` call, and every consumer after that point (including this giver) draws from
that same freshly-cleared budget.

### Decision table

For every actor with a `combat` component whose own faction's relation to `colony` is `hostile`
(`Relations.relation(actor_faction, "colony")`, read off the runtime `factionId` field exactly like
`CombatTargeting` — never `Relations.is_hostile()`, ADR 020's own documented pitfall). `advance()`
itself checks rule 2 BEFORE rule 1 (round-2 review finding 3): both are "do nothing" outcomes for job
submission, but only rule 2 releases tracking, and it must do so even on a tick where adjacency also
just became true — otherwise a fleeing actor that walked adjacent this same tick keeps a stale
approach association instead of having it released:

1. `CombatTargeting.nearest_adjacent_hostile()` is non-empty — do nothing; the existing
   adjacent-only attack rule already has it.
2. `CombatGiver.owns(actor_id)` (an open flee episode) — do nothing at all: never submit,
   interrupt, or keep tracking an approach job for an actor `CombatGiver` currently owns, so
   "fleeing keeps its priority over approaching" holds by construction, not a race.
3. Neither of the above, and a non-terminal `approach` job is already tracked for this actor —
   leave it running.
4. Neither of the above, no job is tracked, and the actor is not retired (see "Retirement" below) —
   pick the single nearest reachable target and submit one fresh single-leg `approach` job.
5. No reachable target at all, or the actor is retired — do nothing.

### Target set and selection order

The target set is every living actor and every placed object with a health entry
(`WorldState.get_object_faction_id`/`_object_health_at`, the same accessors `CombatTargeting`'s own
adjacent scan reads) that the acting actor's own faction relation makes it hostile to — never a
species-specific list.

Selection mirrors `need_giver.gd`'s own single-subject, multi-candidate, real-route-ranked search
(one actor, many candidate tiles) rather than `rescue_giver.gd`'s double loop (many candidate
rescuers, each against many targets): for each hostile target, `ApproachGiver` picks that target's
own single Chebyshev-adjacent tile nearest the acting actor (among those passable for its own
faction, reservation-eligible, not already another job's live target reservation, and
region-reachable) — one candidate tile per target, not up to eight. Candidates are pre-sorted by
Chebyshev distance (not Manhattan: round-2 review finding 4 — movement permits diagonals, so
Manhattan distance can exceed a candidate's true route cost and is not a safe, admissible lower
bound for the early-stop pruning below; Chebyshev distance never exceeds the real route length) for
a cheap search order and early-stop pruning, then ranked by real route
length one bounded `RerouteType.resume()` per tick through the shared `WorldState._route_budget`
ledger `rescue_giver.gd`/`combat_giver.gd` already establish (ADR 004) — never a fresh synchronous
full search. Ties are broken deterministically: an actor candidate before an object candidate,
then ascending target id (actor) or ascending `"%d_%d"` tile key (object). The top-ranked candidate
is re-checked for a reservation race at commit time, mirroring `need_giver.gd`'s own commit phase.

The committed job is submitted through `GlobalAssignment.submit_autonomous()` — the same entry
point `CombatGiver`/`IncidentScheduler` use — so a non-colony actor is never refused by the
ordinary `may_be_ordered` gate.

### `approach` is an ordinary job kind

`content/jobs.json` gains `{"kind": "approach", "labour": "", "toils": ["reserve", "go_to", "work",
"release_all"], "work_ticks": 1}` — the identical walk-then-finish-in-one-tick shape `flee`/
`incident` already use, so arrival at the adjacent tile completes the job through
`WorldState._toil_on_work_complete()`'s existing generic fallthrough (no new branch needed); the
next tick, the actor is adjacent and rule 1 of `combat_resolver.gd`'s own attack rule takes over.
An `approach` job whose route becomes unreachable mid-walk is cancelled-only at
`WorldState._toil_on_unreachable()` (added alongside `incident`/`flee` in that kind-aware boundary),
never resubmitted through the ordinary gated `submit()`. Round-2 review finding 2: `advance()` must
NOT then treat the actor as merely untracked and pick a fresh candidate the very next tick — that
IS retargeting on unreachability, which this task's own Non-goals put out of scope (t2 of #389).
Instead `ApproachGiver` RETIRES the actor (`_retired`, rule 5) the moment its tracked job ends
without ever reaching adjacency (cancelled or failed), and the actor stays retired — no further
search, ever — until `forget()` clears it (death/removal, or its own faction relation to `colony`
stops being hostile). Choosing when a retired actor may search again belongs to t2. This task's own
test only exercises a target that survives the whole approach; it does not construct an unreachable
mid-approach scenario.

### Persistence: the job's own target association, not derivable from the queue

Unlike `CombatGiver`'s `_fleeing` (an actor_id -> job_id map, always reconstructable from the
scheduler's own restored queue via `restrict_to_for()`), `ApproachGiver`'s job_id -> target
association cannot be re-derived after a load: an object target has no living record to re-scan,
and even an actor target is not safely re-derived by adjacency alone (mirrors
`rescue_giver.gd`'s own `_job_victim` precedent, ADR 025/027). `ApproachGiver` exposes
`get_job_targets()`/`restore_job_targets()`; `state_codec.gd` persists it verbatim as a new,
optional top-level `approachJobTargets` field (an array of `{jobId, kind, actorId}` or `{jobId,
kind, tile}` entries) — additive, no `schemaVersion` bump, an older save simply omits it, exactly
like `combatBlockedTargets`/`rescueVictimAssignments`. `game-state.schema.json`'s `jobs.kind` enum
gains `"approach"`; the new field is not added to any `required` array.
`save_io.gd`'s own separate job-kind whitelist (the same duplicate list ADR 020 found and fixed for
`flee`) gains `"approach"` too, with its own `_valid_approach_job_targets()` structural check.
`WorldState.state_hash()` includes the association (JSON-safe-encoded through the same
`state_codec.gd` helper), since it affects the next commit/adjacency decision.

Retirement (round-2 review finding 2, see above) is likewise not reconstructable after a load — a
retired actor owns no job at all, so there is nothing in the restored scheduler queue to re-scan.
`ApproachGiver` exposes `get_retired_actors()`/`restore_retired_actors()`; `state_codec.gd` persists
the set verbatim as a new, optional top-level `approachRetiredActors` field (a plain array of
`actor_id` strings) — additive, no `schemaVersion` bump, an older save simply omits it.
`save_io.gd` gains `_valid_approach_retired_actors()`. `WorldState.state_hash()` includes it, since
it gates whether the next tick may submit a fresh approach job for that actor.

`ApproachGiver`'s own actor_id -> job_id tracking (`_tracking`) is, like `CombatGiver`'s
`_fleeing`/`rescue_giver.gd`'s `_pending`, rebuilt after a load from the scheduler's restored queue
(`restore_job_targets()` re-adopts every non-terminal `approach` job for the actor it is restricted
to), never persisted itself.

## Non-goals (this task)

- No retargeting when the current target dies or becomes unreachable mid-approach (t2).
- No change to `combat_resolver.gd`'s attack rule, `combat_giver.gd`'s flee semantics/
  `combatBlockedTargets`, or any existing flee/combat test's assertions.
- No wolf-specific or trader-specific content — `content/actors.json`/`content/incidents.json`/
  `content/factions.json` are untouched; the existing `wolf` actor definition is reused as a test
  fixture only.
- No presentation/rendering work.

## Consequences

- `docs/architecture/core-budgets.json`'s cap for `game/scripts/core/world_state.gd` rises from
  3769 to 3808 (+39) for the giver's own construction/wiring call sites (`_build_dimension_services()`,
  `tick()`'s own call site and its doc comment explaining why this giver runs after
  `_advance_colonists()` rather than alongside `_apply_combat()`), the `_toil_on_unreachable()`/
  `_cleanup_actor_scheduling()` additions, and the `state_hash()` entries for the giver's own job
  target association and (round-2 review finding 2) its retired-actor set — matching the file's
  exact post-change line count, per the convention ADR 016/017/018/020/022/024/025/026/027/028/029/030
  already set.
- `approach_giver.gd` itself carries none of this budget — job-giver modules are not core-budgeted
  files today, matching `need_giver.gd`/`haul_giver.gd`/`rescue_giver.gd`/`combat_giver.gd`.
- `test_combat.gd` proves: a wolf spawned at a map edge, with no destination ever given by the
  test, walks itself to a tile Chebyshev-adjacent to a closed colony door and starts fighting
  (`attacked_by` event, `get_actor_combat_reason() == "fighting"`); an actor already adjacent to a
  hostile target is never given an approach job; an actor `CombatGiver.owns()` is never given or
  kept on one; two fresh runs of the same seed/scenario produce identical `state_hash()` at every
  sampled tick through an in-progress approach; and a save taken mid-approach (job queued or
  active) reloads with the same tracked target and continues, `state_hash()` covering it.

## Round-2 review fixes

`codex`'s round-2 review found four issues in the first implementation, all addressed in place
(the decision table, target-selection, persistence and consequences sections above already reflect
the corrected design):

1. An unrelated regenerated-resource rewrite of `game/data/tilesets/terrain_tileset.tres` (a
   byproduct of running `godot --headless --path game --import` in a local checkout) had
   leaked into the diff. Reverted to `origin/main`'s exact content; this task never touches tileset
   resources.
2. `advance()` treated an unreachable-cancelled `approach` job as "no job tracked" and immediately
   started a fresh search the very next tick — retargeting on unreachability, out of this task's
   scope (t2). Fixed by retiring the actor instead (`_retired`, persisted via
   `get_retired_actors()`/`restore_retired_actors()`/`approachRetiredActors`); see "`approach` is an
   ordinary job kind" and "Persistence" above.
3. The adjacency check (rule 1) ran before the `CombatGiver.owns()` check (rule 2), so an actor that
   became adjacent the same tick `CombatGiver` claimed it kept a stale approach association instead
   of having it released. Fixed by checking ownership first; see "Decision table" above.
4. `_search_can_stop()`'s early-stop pruning compared a candidate's Manhattan distance against the
   shortest route found so far, but movement permits diagonals, so Manhattan distance is not an
   admissible (never-overestimating) lower bound on real route length and could prune away a
   genuinely nearer target. Fixed by using Chebyshev distance instead; see "Target set and selection
   order" above.

## Round-3 revision (issue #391, t2 of #389)

t1 (above) explicitly deferred retargeting on target loss/unreachability and locked an actor
permanently out of further search (`_retired`) once its tracked job ended without reaching
adjacency. This revision implements retargeting and removes that permanent latch.

### Retarget triggers

`ApproachGiver.advance()` now checks a tracked job's own recorded target (`_job_targets`) BEFORE
its scheduler status, every tick it looks at that actor:

1. **Target died or was destroyed.** An actor target no longer present in the tick's own roster, or
   present but `health.dead`, or an object target whose health entry AND placed-object record have
   both cleared (`_damage_object()`'s own zero-hp `_set_object(x, y, "")`, or cleared by any other
   system) — checked regardless of the job's current status, active or queued, since the target is
   gone either way.
2. **Queued and blocked-unreachable.** A tracked job still `"queued"` with JobQueue's own
   `BLOCKED_TARGET_UNREACHABLE` reason — the identical reason `combat_giver.gd` already watches for
   its own flee legs (a local copy of the same typed-reason constant, job_queue.gd not owned by this
   task), because JobQueue retries an unreachable queued target forever on its own; it never resolves
   itself.

Either trigger cancels the job through `_cancel_job` (a new constructor callable wired to
`WorldState._cancel_autonomous_job` — the same shared `_finish_job()` boundary
`combat_giver.gd`'s own `_cancel_job`/`rescue_giver.gd`'s own `_retire_job` already use), drops the
association (`_tracking`/`_job_targets`/`_job_actor`), and falls through into rule 4's own search
**the same tick** — never waiting a tick, and never latching a permanent "no further search" state.
A job already cancelled elsewhere this same tick (`WorldState._toil_on_unreachable()`, once an
active job's own route becomes unreachable mid-walk after activation — t1's own pre-existing path,
unchanged) is detected the same way, by its status no longer reading `"active"`/`"queued"`, and
falls through identically.

### Fallback: no permanent retirement

`_retired` (and its persistence — `get_retired_actors()`/`restore_retired_actors()`/
`state_hash()`'s `"approach_retired_actors"` entry/`state_codec.gd`'s `"approachRetiredActors"`
field) is removed outright. When a fresh rule-4 search finds no reachable target at all, this giver
does nothing that tick — rule 5, exactly as before, but now re-evaluated fresh every tick rather than
latched permanently — leaving the actor free for `IncidentScheduler`'s own walk-then-wait to drive.
This giver never cancels or interferes with an unrelated incident job merely because its own
retargeting search failed; it simply stops submitting anything until a target becomes reachable
again (including never, for an actor genuinely walled off forever).

**Backward compatibility:** `"approachRetiredActors"` stays in `game-state.schema.json` and
`save_io.gd`'s own accepted top-level fields/structural validator (both otherwise unchanged) purely
so a save written before this revision still loads; `state_codec.gd`'s `decode()` simply no longer
reads it. New saves never write the field.

### Priority (task B): confirmed, not changed

The hp-fraction-below-`flee_hp_fraction` priority CombatGiver already owns — t1's own rule-2
`owns()`-check deference — needed no production change: `WorldState._interrupt_current_job()`
already pauses (never cancels) whatever job an actor is currently executing, kind-agnostically,
through the same boundary `NeedGiver`/`CombatGiver` already share, and rule 2's own
`_release_tracking()` already keeps `_job_targets`/`_job_actor` alive (dropping only `_tracking`) so
a paused approach job is re-adopted, not resubmitted, once the flee episode closes. `test_combat.gd`
now proves this end to end: an active approach job is paused (not left `"active"`, never orphaned)
the instant hp drops below threshold, a flee job takes over, and approaching resumes — through
`ApproachGiver`'s own ordinary target-selection logic, not necessarily the same target as before —
once hp recovers, `find_orphaned_reservations()` empty throughout.

### Re-captured state_hash() literals

Removing `"approach_retired_actors"` from `state_hash()`'s snapshot dict moves every literal
baseline hash sensitive to the dict's shape, exactly as adding the key did in t1's own round-2
review: `test_world_state_determinism.gd`'s `PRE_INCIDENT_BASELINE_HASH` and
`test_toils_dig_chop_regression.gd`'s `EXPECTED_HASH`/`COLONY_EXPECTED_HASH`, all three re-captured
by running their own test under this exact Godot version, per AGENTS.md's "never hand-derive a
hash" rule.

### Consequences

- `docs/architecture/core-budgets.json`'s cap for `world_state.gd` LOWERS from 3808 to 3804 (-4):
  removing the retired-actor `state_hash()` entry outweighs the one new `cancel_job` argument added
  to the giver's own construction call site.
- `test_combat.gd` gains four checks: an actor-death retarget, an object-destruction retarget, a
  fully-walled-off fallback (no approach job left queued/active, `IncidentScheduler` free to drive
  the actor), and the flee-interrupt-and-resume proof above — every one asserting
  `WorldState.find_orphaned_reservations()`-equivalent (`ReservationInvariantsType.
  find_orphaned_reservations()`) stays empty throughout, not just at the end.
- Every pre-existing `test_combat.gd` check, including t1's own, passes unmodified.

## Round-4 revision (round-1 review of the round-3 revision)

`codex`'s round-1 review of the round-3 revision above found a stale-job path the retarget triggers
missed, and two of the round-3 tests that did not actually isolate the mechanisms they claimed to.

### Retarget triggers now precede rule 1, not just rule 3

`advance()`'s own evaluation order used to be: rule 2 (`CombatGiver.owns()`), then rule 1
(`nearest_adjacent_hostile()`), then — only if rule 1's own early `continue` had not already fired —
the retarget triggers from the round-3 revision above. That let rule 1's "do nothing, the attack rule
already has it" outcome silently skip the retarget cleanup: a tracked job's own recorded target could
die or be destroyed on a tick the actor also happened to stand adjacent to a completely different
hostile (the attack rule's own target, never this stale job's), and the dead target's job — along with
its reservation — stayed tracked forever, since rule 1 returned before the cleanup ever ran.

Fixed by moving the retarget-trigger check (target died/destroyed, or queued+
`BLOCKED_TARGET_UNREACHABLE`) to run immediately after rule 2, unconditionally, BEFORE rule 1's own
adjacency check. Rule 1 now runs only once that cleanup step is done — so it still correctly says "do
nothing further" once the actor's own tracked-job bookkeeping is current, but it can no longer skip
that bookkeeping in the first place. See `approach_giver.gd`'s own class doc comment (rule 2.5) for the
authoritative up-to-date decision table.

`test_combat.gd` gains `_check_approach_cancels_stale_target_while_adjacent_to_different_hostile()`:
a hunter commits to a distant colony target, a second hostile actor is then kept pinned adjacent to
the hunter's own current tile every tick (needed because the hunter's active route keeps moving it;
a one-shot placement would drift out of adjacency before the bug could even be exercised), the
original tracked target is killed, and the check proves the stale job is still cancelled and its
association dropped the same tick it can be, even while the actor stays reported `"fighting"` the
whole time.

### Two round-3 fallback/retarget tests did not isolate what they claimed to

`_check_approach_falls_back_to_incident_when_fully_walled_off()` used a wolf appended directly to the
roster (`_spawn_actor()`), never through `IncidentScheduler`, so it could not actually prove that an
*unrelated* incident job's own walk-then-wait lifecycle survives this giver's own fallback untouched
— there was no incident job in the fixture at all. The same test also never inspected the cancelled
job's own `reason`, so its wall-off could equally have been proven by
`WorldState._toil_on_unreachable()`'s pre-existing active-route cancellation instead of the
queued+`BLOCKED_TARGET_UNREACHABLE` trigger this revision's own "Retarget triggers" section added —
the two mechanisms were never distinguished.

Both gaps are closed with two new, narrowly-targeted checks (the original test is kept unchanged
alongside them — it still proves the general "sealed in on every side" case):

- `_check_approach_fallback_never_interferes_with_unrelated_incident_job()` proposes a genuine
  `_incidents.propose()` actor/job (a short walk-then-wait entirely on the actor's own side of a
  corridor) and lets a *separate*, already-committed `approach` job for a colony target beyond a
  sealed corridor sit alongside it. `GlobalAssignment.tick()`'s own worker exclusivity (a busy
  worker's other queued entries are never re-selected for activation) means that approach job can
  only ever sit `"queued"`, never `"active"`, for as long as the incident job keeps the actor busy —
  so the incident job runs to completion and despawns the actor entirely on its own schedule, and the
  now-orphaned approach job is swept up by the ordinary despawn cleanup
  (`WorldState._cleanup_actor_scheduling()`), never by this giver reaching in to cancel it. Proves
  non-interference in both directions: the incident never stalls waiting on approach, and approach
  never needs the incident to yield anything.
- `_check_approach_retargets_when_queued_job_goes_blocked_unreachable()` seals the only corridor to a
  tracked job's own target — using a full, gapless wall column that never touches the destination
  tile itself, so the tile stays bare/reservation-eligible and only the ROUTE is cut, isolating
  JobQueue's own reachability check from the separate reservation-eligibility gate a held/occupied
  destination tile would instead trip — immediately after the job first commits (`"queued"`, empty
  reason), then proves it is cancelled without EVER passing through `"active"` at all. Since the only
  other cancellation trigger this giver watches for (target death/destruction) cannot fire here (the
  target actor is untouched), a queued-to-terminal transition that never touches `"active"` can only
  have come through the queued+`BLOCKED_TARGET_UNREACHABLE` branch.

### Consequences

- No production behaviour changes beyond the control-flow reordering in `advance()` itself (a
  same-file reordering, no new fields, no persistence changes, no `core-budgets.json` change).
- `test_combat.gd` gains three checks (above); every pre-existing check, including every prior
  revision's own, passes unmodified.

## Alternatives considered

- **Rank every Chebyshev-adjacent tile of every target (up to 8 per target) instead of one per
  target.** Rejected: multiplies the bounded per-tick route-search budget by up to 8x for no
  behavioural gain this task's own acceptance needs — one canonical nearest-adjacent-tile per
  target is deterministic and sufficient, and a future task can widen it with its own ADR if a real
  scenario needs it.
- **Reuse `rescue_giver.gd`'s exact double-loop shape (candidates-of-candidates).** Rejected: that
  shape exists because rescue ranks *rescuer* candidates, each against several *target* tiles for
  one fixed victim — the roles do not transfer to one fixed actor ranking several hostile targets.
  `need_giver.gd`'s single-subject, multi-target-tile ranking is the closer precedent and is what
  this module mirrors instead.
