# ADR 032: Lingering incident actors (`spawn.lingers`)

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `game/content/schemas/incidents.schema.json`, `game/content/incidents.json`,
  `game/scripts/core/incidents/incident_scheduler.gd`, `game/scripts/tests/test_incidents.gd`.
- **Implements:** issue #398 (t1 of #396); builds on ADR 018 (incidents), ADR 031 (`ApproachGiver`,
  issue #390/#391).

## Problem

`GlobalAssignment` gives each worker exactly one active scheduler assignment at a time (ADR 004).
`ApproachGiver` (ADR 031) submits its own `approach` job through `GlobalAssignment.submit_autonomous()`
restricted to the same actor, so a hostile incident actor already busy on its own `incident`
walk-then-wait job can only ever have that `approach` job sit `queued` behind it — by design, the
same worker-slot exclusivity that lets a colonist's queued job wait its turn.

`IncidentScheduler.on_job_finished()` (the shared `WorldState._finish_job()` hook, every terminal
transition of an `incident` job) unconditionally removed the actor from the world the instant that
job ended, `_remove_colonist.call(actor_id)`, with no exception. So the moment a hostile actor's own
short walk-then-wait job completed — freeing its worker slot for the queued `approach` job to finally
activate — the actor it was restricted to no longer existed. The hand-off ADR 031 assumed ("a
hand-off actor simply exists in the world once its worker slot frees") never actually happened for an
incident-spawned actor: `ApproachGiver`'s own queued job simply went stale and was swept up by
`WorldState._cleanup_actor_scheduling()` once the actor vanished, never activating.

## Decision

Add an optional, content-driven boolean field to the spawn extension point: `spawn.lingers`
(`game/content/schemas/incidents.schema.json`, default `false` when absent — a plain boolean, no
new cross-reference check, `ContentRegistry`'s existing load/validate path covers it like every other
scalar field). Threaded through `incident_scheduler.gd`'s existing four call sites only, no new hook:

1. `_spawn()` reads `spawn_def.get("lingers", false)` and passes it to `_spawn_one()`.
2. `_spawn_one()` passes it through to `propose()` as a new fourth parameter, defaulted to `false` so
   every existing 3-arg call (including `test_incidents.gd`'s own direct `propose()` calls) keeps
   compiling and behaving unchanged.
3. `propose()` stores it on the staged entry (`_staged[job_id]["lingers"]`).
4. `activate_pending()`, at the point it already calls `_append_colonist.call(actor)` for an activated
   job, records the actor's id in a new instance dictionary, `_lingering_actors`, when the staged
   entry's `lingers` flag is true.
5. `on_job_finished()` checks `_lingering_actors` before its existing `_remove_colonist.call(actor_id)`
   line: an actor found there is left in the world and dropped from the dictionary (a one-shot flag,
   consumed on the first terminal transition after activation, not a permanent mode) instead of being
   removed.

No new call site, hook, or field is added to `world_state.gd`. From the tick `on_job_finished()`
leaves it in place, a lingering actor is an ordinary actor to every other per-tick system —
`ApproachGiver`'s hostile search, `CombatGiver`'s flee, `CombatResolver`'s adjacent-attack — exactly
like one appended through any other path. Nothing else needs to change for the hand-off to work,
because `GlobalAssignment`'s worker-slot rules already let the queued `approach` job activate once the
worker frees up; this task only stops the actor from being deleted out from under it first.

`wildlife_wander`/`trader_visit` never set `spawn.lingers`; their existing despawn-after-wait lifecycle
(`test_incidents.gd`'s `_check_actor_despawns_after_exact_wait`) is unchanged. A new test-only content
row, `raider_incursion` (`raiders` faction, hostile to `colony` per `content/factions.json`; `wolf`
actor def, reused as a fixture only, per ADR 031's own precedent), sets `spawn.lingers: true` and
exercises the full hand-off end to end in `test_incidents.gd`: fired through the ordinary day-gated
daily draw (not `force_spawn`/`spawn_incident`, which bypass `min_day` and would not prove the
gating), its arrival job runs to completion, the actor survives that completion, and — with no
destination ever supplied by the test — `ApproachGiver` alone then walks it to a colony door its own
incident-picked target was deliberately not adjacent to, and it fights.

## Persistence: explicitly not covered

`_lingering_actors` is not persisted. No change to `state_codec.gd`, `save_io.gd`, or
`game-state.schema.json`. This is a deliberate, documented gap, not an oversight: a save taken between
an actor's arrival and its arrival job's natural completion, then reloaded, loses the flag — on
reload, `IncidentScheduler` re-associates the active job with the actor via `adopt()` exactly as
before this change, but `_lingering_actors` starts empty, so the actor despawns on that job's
completion post-reload exactly as it would have before this change existed. Closing that gap (carrying
`spawn.lingers`'s runtime effect across a save/reload boundary) is left as a follow-up, not built here.

## Consequences

- `game/scripts/core/incidents/incident_scheduler.gd` gains one instance dictionary and four small,
  additive edits to existing methods; no new public API beyond `propose()`'s new optional parameter.
- No `core-budgets.json` change: `incident_scheduler.gd` is not a core-budgeted file (job-giver-style
  modules under `game/scripts/core/incidents/` are not budgeted today, matching `need_giver.gd`/
  `haul_giver.gd`/`combat_giver.gd`/`approach_giver.gd`).
- `docs/architecture/extension-points.md`'s Incident section documents `spawn.lingers`.
- Issue #304 (a real `wolf_attack` content row using this same field) is unblocked by this change but
  is not implemented here; this task adds no wolf-specific content or tunables.

## Alternatives considered

- **A permanent "never despawn" flag on the actor itself, set at spawn time.** Rejected: conflates a
  one-shot hand-off (survive exactly one arrival-job completion) with a standing actor property. A
  future incident wanting a second lingering hand-off after a second job would need the flag restored,
  which this shape (re-set by `activate_pending()` on every fresh activation) already supports for
  free, while a permanent flag would not distinguish "already handed off once" from "still pending."
- **Hook the hand-off into `world_state.gd` directly (e.g. a `world_state.gd`-owned lingering set).**
  Rejected: the incident lifecycle (`propose`/`activate_pending`/`on_job_finished`) already fully owns
  spawning and despawning this actor; `world_state.gd` only orchestrates. Keeping the flag local to
  `IncidentScheduler` needs no new `world_state.gd` field, call site, or hook, per this task's own
  Non-goals and AGENTS.md's "one work engine" rule.
