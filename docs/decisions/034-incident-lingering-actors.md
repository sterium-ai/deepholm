# ADR 034: Lingering incident actors (`spawn.lingers`)

> **In short:** Raiders used to vanish the moment they arrived, before they could attack. Incidents can now mark their actors to stay in the world after arriving, so hostile visitors actually walk up to the colony and fight.

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `game/content/schemas/incidents.schema.json`, `game/content/incidents.json`,
  `game/scripts/core/incidents/incident_scheduler.gd`, `game/scripts/tests/test_incidents.gd`.
- **Extends:** ADR 017 (incidents), ADR 033 (`ApproachGiver`).

## Problem

`GlobalAssignment` gives each worker exactly one active scheduler assignment at a time (ADR 004).
`ApproachGiver` (ADR 033) submits its `approach` job through `GlobalAssignment.submit_autonomous()`
restricted to the same actor, so a hostile incident actor already busy with its `incident`
walk-then-wait job can only have that `approach` job sit `queued` behind it. This is by design: the
same worker-slot exclusivity lets a colonist's queued job wait its turn.

`IncidentScheduler.on_job_finished()` (the shared `WorldState._finish_job()` hook, called on every
terminal transition of an `incident` job) unconditionally removed the actor from the world the
instant that job ended, via `_remove_colonist.call(actor_id)`. So the moment a hostile actor's short
walk-then-wait job completed, freeing its worker slot for the queued `approach` job, the actor that
job was restricted to no longer existed. The hand-off ADR 033 assumed ("a hand-off actor simply
exists in the world once its worker slot frees") never happened for an incident-spawned actor:
`ApproachGiver`'s queued job went stale and was swept up by `WorldState._cleanup_actor_scheduling()`
once the actor vanished, without ever activating.

## Decision

Add an optional, content-driven boolean field to the spawn extension point: `spawn.lingers`
(`game/content/schemas/incidents.schema.json`, default `false` when absent). It is a plain boolean
with no new cross-reference check; `ContentRegistry`'s existing load/validate path covers it like
every other scalar field. It is threaded through existing methods of `incident_scheduler.gd` only,
with no new hook:

1. `_spawn()` reads `spawn_def.get("lingers", false)` and passes it to `_spawn_one()`.
2. `_spawn_one()` passes it to `propose()` as a new fourth parameter, defaulted to `false` so
   every existing three-argument call (including direct `propose()` calls in `test_incidents.gd`)
   keeps compiling and behaving unchanged.
3. `propose()` stores it on the staged entry (`_staged[job_id]["lingers"]`).
4. `activate_pending()`, where it already calls `_append_colonist.call(actor)` for an activated
   job, records the actor's id in a new instance dictionary, `_lingering_actors`, when the staged
   entry's `lingers` flag is true.
5. `on_job_finished()` checks `_lingering_actors` before its existing `_remove_colonist.call(actor_id)`
   line. An actor found there is left in the world and dropped from the dictionary instead of being
   removed. The flag is one-shot: it is consumed by the first terminal transition after activation,
   not a permanent mode.

No new call site, hook, or field is added to `world_state.gd`. From the tick `on_job_finished()`
leaves it in place, a lingering actor is an ordinary actor to every other per-tick system
(`ApproachGiver`'s hostile search, `CombatGiver`'s flee, `CombatResolver`'s adjacent attack), exactly
like one appended through any other path. Nothing else needs to change for the hand-off to work,
because `GlobalAssignment`'s worker-slot rules already let the queued `approach` job activate once the
worker frees up; this change only stops the actor from being deleted first.

`wildlife_wander` and `trader_visit` never set `spawn.lingers`; their existing despawn-after-wait
lifecycle (`test_incidents.gd`'s `_check_actor_despawns_after_exact_wait`) is unchanged. A new
test-only content row, `raider_incursion` (`raiders` faction, hostile to `colony` per
`content/factions.json`; `wolf` actor def reused as a fixture only, following ADR 033's precedent),
sets `spawn.lingers: true` and exercises the full hand-off end to end in `test_incidents.gd`. It is
fired through the ordinary day-gated daily draw (not `force_spawn`/`spawn_incident`, which bypass
`min_day` and would not prove the gating). Its arrival job runs to completion, the actor survives
that completion, and, with no destination supplied by the test, `ApproachGiver` alone walks it to a
colony door that its incident-picked target was deliberately not adjacent to, where it fights.

## Persistence: explicitly not covered

`_lingering_actors` is not persisted; `state_codec.gd`, `save_io.gd`, and `game-state.schema.json`
are unchanged. This is a deliberate, documented gap. If a save is taken between an actor's arrival
and its arrival job's natural completion and then reloaded, the flag is lost: `IncidentScheduler`
re-associates the active job with the actor via `adopt()` as before, but `_lingering_actors` starts
empty, so the actor despawns when that job completes, as it did before this change. Carrying
`spawn.lingers`'s runtime effect across a save/reload boundary is left as a follow-up.

## Consequences

- `game/scripts/core/incidents/incident_scheduler.gd` gains one instance dictionary and small,
  additive edits to existing methods; the only new public API is `propose()`'s optional parameter.
- No `core-budgets.json` change: `incident_scheduler.gd` is not a core-budgeted file (job-giver-style
  modules under `game/scripts/core/incidents/` are not budgeted, matching `need_giver.gd`,
  `haul_giver.gd`, `combat_giver.gd`, and `approach_giver.gd`).
- `docs/architecture/extension-points.md`'s Incident section documents `spawn.lingers`.
- A real `wolf_attack` content row using this field is now possible but is not implemented here; this
  change adds no wolf-specific content or tunables.

## Alternatives considered

- **A permanent "never despawn" flag on the actor, set at spawn time.** Rejected: it conflates a
  one-shot hand-off (survive exactly one arrival-job completion) with a standing actor property. A
  future incident wanting a second lingering hand-off after a second job would need the flag restored,
  which the chosen shape (re-set by `activate_pending()` on every fresh activation) already supports,
  while a permanent flag could not distinguish "already handed off once" from "still pending".
- **Hook the hand-off into `world_state.gd` directly (e.g. a lingering set owned by
  `world_state.gd`).** Rejected: the incident lifecycle (`propose`/`activate_pending`/`on_job_finished`)
  already fully owns spawning and despawning this actor; `world_state.gd` only orchestrates. Keeping
  the flag local to `IncidentScheduler` needs no new `world_state.gd` field, call site, or hook,
  in line with the "one work engine" rule in [AGENTS.md](../../AGENTS.md).
