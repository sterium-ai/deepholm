# ADR 054: A* route search and the region check before every search

> **In short:** Route searches now aim at their target (A*) instead of spreading out in every
> direction, so a long walk costs a few hundred tile checks instead of fifteen thousand. The
> path is still a cheapest one, but when several paths cost the same the game may now pick a
> different one than before. A target in a walled-off area is refused at once, before any
> search, wherever a search is started.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** simulation (routing)
- **Extends:** ADR 003 (bounded, resumable route work), A3's heap frontier
  (`game/scripts/core/routing/README.md`)
- **Implements:** BACKLOG A8

## Context

`RouteSearch` was a bounded uniform-cost (Dijkstra) search: it expands every tile cheaper than
the target, a disc whose area grows with the square of the distance. The A0 benchmark measured
15,462 expansions and 242 ticks of route budget (64 expansions per tick) for one path of
distance 256 on the generated 256×256 map, and 32,641 on the open grid. A colonist sent across
the map stood still for four seconds of game time before taking a step.

A target in another walkable region (a pocket walled off by rock, water or walls) was only
refused by the scheduler (`GlobalAssignment.tick()`'s `region_check`). Every other search
(go_to re-routes, need/rescue/approach target searches, `_route_cost()`) exhausted the whole
reachable map, budget slice by budget slice, before it could report the target unreachable.

## Decision

1. **A* with an admissible, consistent heuristic.** `h(tile) = (|dx| + |dy|) × min_cost` to the
   target. `min_cost` is a constructor argument defaulting to `RouteSearch.MIN_TILE_COST = 1.0`:
   the content schemas make `move_cost` an integer and a cost `<= 0` impassable, so every
   enterable tile costs at least 1. A cost below `min_cost` is asserted in debug builds. One step
   changes the Manhattan distance by exactly 1 and costs at least `min_cost`, so `h` is
   consistent and a closed tile's accumulated cost `g` is final.
2. **Frontier order (the new deterministic tie-break).** The open tile popped next is the first
   by:
   1. lowest `f = g + h`;
   2. then lowest `h` (nearer the target);
   3. then the **latest** insertion (one heap entry per push; insertion numbers only grow).

   Neighbors are still discovered in row-major order (north, west, east, south). The same map,
   start, target, bounds and `min_cost` always give the same expansions, calls and path.
3. **Cost improvement.** Unlike Dijkstra with per-tile costs, A* can discover a tile from a
   parent that is not its cheapest: an open tile whose `g` drops when a later neighbor expands
   takes the cheaper parent and is pushed again; the stale entry is skipped when popped.
4. **Found on discovery (kept).** The search still stops the moment the target is discovered.
   This stays optimal: when tile `c` (with the lowest `f` of all open tiles) discovers target
   `T`, any other path to `T` leaves the closed set through some open tile `o` with
   `f(o) >= f(c)`, then enters at least `|o − T| − 1` tiles costing `>= min_cost` and finally
   `T`, so it costs at least `g(o) + h(o) − min_cost + cost(T) >= g(c) + cost(T)`, the cost of
   the path through `c` (`h(c) = min_cost` since `c` is adjacent to `T`).
5. **Dijkstra mode.** With `min_cost = 0`, `h` is 0, no `g` ever improves and equal keys pop
   earliest-first, which is exactly the pre-A8 search (same expansions and snapshots). The tests
   use it as the reference the A* paths are compared with.
6. **Region check in the constructor.** `RouteSearch.new(..., reachable: Callable = Callable(),
   min_cost := MIN_TILE_COST)`: when `reachable(start, target)` is false the search ends at once
   as `STATUS_UNREACHABLE`, with no expansion and an empty snapshot. Every simulation caller
   passes `Passability.region_reachable`: `WorldState._route_search_factory()` (ToilExecutor's
   go_to re-routes and `_route_cost()`), `NeedGiver`, `RescueGiver` and `ApproachGiver`.
   `GlobalAssignment.tick()` keeps its own identical pre-check (unchanged), and
   `GlobalAssignment.restore_scheduling()` (called by `StateCodec` on load) passes it to
   `_resolve_path()`, which re-runs each pending "found" pair's search without a step budget: a
   target cut off between being found and being saved is refused instead of sweeping the map
   synchronously on load. Region membership
   follows the colony's passability, which no faction exceeds (factions differ only at doors and
   the colony may pass doors), so the check never refuses a target the search could reach.
7. **Saves.** `snapshot()` keeps its shape (`start`, `target`, `status`, `frontier` as the open
   tiles in insertion order, `visited` as every discovered tile, `came_from` as each tile's
   current best parent, `path`). No schema change. A Dijkstra state saved by an older build is a
   valid A* state (closed tiles have final costs, open tiles their best known cost), so it
   continues to a cheapest path; it may pick a different equal-cost path than the older build
   would have.

**Accepted consequence: equal-cost paths may differ.** A colonist given the same order on the
same map may take a different, equally cheap path than before A8. Path *costs* never change.
Event logs, `state_hash()` values and scenario dumps that include those paths, travel ticks or
in-flight search snapshots change accordingly; the determinism tests that pinned them are
re-recorded (see Acceptance criteria).

## Alternatives considered

- **First-in-first-out among equal `(f, h)`** (A3's insertion order). Measured on the generated
  map at d=256: 2,382 expansions in 38 calls, above the 1,500 / 25 bound. Following the most
  recent tile across a plateau of equal `f` gives 266 expansions in 5 calls.
- **Stop when the target is popped** (textbook A*). Costs extra expansions for the same path
  cost, and the proof above shows the discovery-time stop is already optimal.
- **No cost improvement (close on discovery, as before).** Wrong with A*: it can return a more
  expensive path.
- **Hierarchical pathfinding / jump point search.** A8's numbers meet the bound without them;
  hierarchical search stays a non-goal (BACKLOG A8).
- **Region check inside each caller.** Five places create searches, each a chance to forget it; the
  optional constructor argument puts it beside the search it guards.

## Consequences

- Routing work drops by one to two orders of magnitude on long paths (A8 handoff:
  `docs/orca/handoffs/A8.md`).
- An unreachable go_to target is reported on the tick its route breaks instead of after the
  search has swept the map.
- A future content change with a move cost below 1 must lower `min_cost` (the debug assertion
  catches it in every test).

## Acceptance criteria

- [x] `game/scripts/core/routing/README.md` and `docs/architecture/orders-and-movement.md`
  updated.
- [x] `test_route_search_recorded.gd`: the pre-A3 Dijkstra values kept unchanged (min_cost 0),
  an A* table recorded, every A* path costs exactly what the Dijkstra path costs, generated
  d=256 within 1,500 expansions and 25 calls. `test_route_astar.gd` (new): the same cost
  equality and mid-search restore on seeded random weighted maps, and the region check refuses
  a walled-off target with no expansion and never changes a reachable outcome.
- [x] Save/migration impact: none (snapshot shape unchanged).
- [x] Determinism tests that pinned an equal-cost path were updated quoting this ADR; the list
  and the reason per test are in `docs/orca/handoffs/A8.md`.
