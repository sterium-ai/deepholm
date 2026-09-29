# ADR 016: Regions wiring raises two core budgets

- **Status:** accepted
- **Date:** 2026-09-20
- **Scope:** `docs/architecture/core-budgets.json` caps for
  `game/scripts/core/world_state.gd` and
  `game/scripts/core/scheduling/global_assignment.gd`.
- **Implements:** F5 in `docs/architecture/foundation-for-breadth.md`; issue #292.

## Decision

Wiring `RegionMap` (`game/scripts/core/map/regions.gd`) into the two core files it must
touch raises their `core-budgets.json` caps:

- `world_state.gd`: 1842 -> 1855. WorldState owns a lazily-built `RegionMap` (so a save/load's
  direct `_tiles`/`_objects` overwrite in `state_codec.gd` never leaves a partition stale) and
  calls `on_passability_changed()` from every mutation that can flip a tile's passability
  (`_set_object()`, `_toil_on_work_complete()`'s tile transforms).
- `global_assignment.gd`: 586 -> 596. `tick()` gains an optional `region_check` parameter,
  consulted once per pending candidate immediately before it would otherwise construct a
  `RouteType`.

Both additions are orchestration — a field, a lazy accessor, call-sites at existing mutation
points, and one extra tick parameter consulted at one call-site — not new decision logic, so
none of it fits the toil executor, a job-giver module, or content. It cannot move out of
`world_state.gd`/`global_assignment.gd` without breaking the "core files are state and
orchestration only" rule the other direction: region membership must stay in lock-step with
every passability-changing mutation, and the scheduler's pre-check must run inside the same
per-candidate loop that already tracks ADR 004's budgets.

## Consequences

The two caps now equal the files' exact post-change line counts, matching how every prior
`core-budgets.json` entry was set (the cap this change replaces was itself the exact
pre-change line count). Neither ADR 004's per-tick budgets (32 candidate examinations, 64
frontier expansions) nor its ranking/aging policy change; `region_check` only removes work
that would otherwise prove unreachable the expensive way.
