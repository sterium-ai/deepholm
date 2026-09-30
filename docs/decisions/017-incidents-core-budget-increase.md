# ADR 017: Incidents wiring raises two core budgets

> **In short:** Adding incidents (visitors such as wolves or traders arriving on their own) needed more lines in two core files, so their size limits were raised to match.

- **Status:** accepted
- **Date:** 2026-09-20 (amended 2026-09-21)
- **Scope:** `docs/architecture/core-budgets.json` caps for `game/scripts/core/world_state.gd`
  and `game/scripts/core/scheduling/global_assignment.gd`.
- **Implements:** F5 in [`foundation-for-breadth.md`](../architecture/foundation-for-breadth.md).

## Decision

Wiring `IncidentScheduler` (`game/scripts/core/incidents/incident_scheduler.gd`) into
`world_state.gd` raises its `core-budgets.json` cap: 1917 -> 2026. `global_assignment.gd`'s own
cap rises 586 -> 673 for `submit_autonomous()`, the `_may_be_ordered`-only gate skip, the
target-aware autonomous reservation gate and the autonomous route passability (see
[ADR 014](014-factions-and-relations.md), Amendment 6). `toil_executor.gd`'s
own existing cap (698) already had enough headroom for threading a faction argument through its
passability call sites (691 lines post-change) and needs no change.

`WorldState` owns the scheduler (constructed once in `_init()` alongside `_random`, mirroring
`RegionMap`/`RoomMap`'s own ADR 015/016 precedent for a lazily-or-eagerly-owned F5 module) and:

- calls `_incidents.advance(tick)` once per `tick()` (the day-gated draw);
- passes the staged (proposed, not yet spawned) incident actors to `_scheduler.tick()` alongside
  the roster (`_scheduler_workers()`), and calls `_incidents.activate_pending()` once per tick
  right after it, so a proposed actor enters the world only the tick its own job is confirmed
  active — and a job the actor's own faction-aware search proved unreachable is retired unspawned
  (`docs/architecture/orders-and-movement.md`, "Incident jobs");
- submits an incident actor's own job through `_submit_incident_job()`
  (`GlobalAssignment.submit_autonomous()`: restricted to the actor, exempt only from
  `_may_be_ordered`, gated by the target-aware `_actor_may_reserve_target()` and routed under
  `_passable_for_worker()`, never exempt from the reservation table or the ordinary
  `tick()`/`advance_selection()` clock);
- performs the incident job's lifecycle cleanup at the one shared finish boundary,
  `_finish_job()` (drop the staged proposal or despawn the actor via
  `IncidentScheduler.on_job_finished()`; clear the wait stamped at activation), so every
  terminal transition — work completion, unreachable travel, a gate refusal, any
  complete/cancel/fail/invalidate_job command — behaves identically; `_toil_on_unreachable()`
  keeps a one-line `"incident"` branch (cancel instead of resubmit);
- dispatches the `spawn_incident` debug command through the same `apply()` match statement
  `set_faction`/`zone_add` already use;
- exposes `_append_colonist`/`_remove_colonist_by_id`/`_passable_for_faction`/`_is_bare_tile`/
  `_get_job`/`_set_work_progress` as method-bound callables (never a raw Array reference, which
  `StateCodec.decode()`'s wholesale `world._colonists` reassignment would strand), and
  `_reconcile_incident_jobs_after_load()` for `StateCodec.decode()`.

`_advance_colonists()` needs no incident-specific carve-out at all: an incident actor's job lives
in `_scheduler`/`_scheduler.queue` exactly like any other assignment. `toil_executor.gd` threads
the acting colonist/actor's own `factionId` through every `_passability` call site and the
`go_to_passable` hook; every parameter defaults `"colony"`, so every pre-existing call site is
unchanged.

All of this is orchestration and small predicates — a field, two `tick()` call sites, one
`apply()` case, one hook branch, a handful of accessor/predicate methods — not new decision
logic: the actual day-gating, budget draw, spawn-tile/target selection, staging and activation
bookkeeping live in `incident_scheduler.gd` itself, which carries no core-budget cap. It cannot
move out of `world_state.gd` without breaking the "core files are state and orchestration only"
rule the other direction: the `apply()` dispatch, the finish boundary and the toil hooks must
live where `apply()`/`_finish_job()`/`_toil_on_unreachable()` themselves already live.

## Consequences

Both caps now equal their file's exact post-change line count, matching every prior
`core-budgets.json` entry (including the caps ADR 015/016 set, which `world_state.gd`'s increases
further). `job_queue.gd`'s cap and clock/tick semantics are untouched: its own public API
(`get_reservations()`, `tick()`, `suspend()`/`reactivate()`) is enough, reached only through
`global_assignment.gd`'s existing `queue.advance_selection()` call. Terminal job records
(completed/cancelled/failed) are retained by `JobQueue` for every job kind, as before; retiring
them is a queue-owned concern outside this decision.

## Revision notes

An earlier version activated pending incident jobs through a dedicated
`_activate_pending_incident_jobs()` pass and a pending-wait-ticks map. It was replaced by the
activation-gated spawning, target-aware reservation gate and shared-finish cleanup described
above; the caps listed here reflect the final design.
