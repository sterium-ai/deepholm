# Route search contract

> **In short:** How the game finds a walking path between two tiles a little at a time, so long searches never slow the game down and always give the same answer.

`RouteSearch` is a plain `RefCounted` module implementing ADR 003 principle 1
and the bounded route-work budget in `docs/architecture/simulation-boundaries.md`.
It has no dependency on `WorldState`, `JobQueue`, or the viewer: the
owning simulation constructs one `RouteSearch` per outstanding route request,
keeps that same instance across ticks, and calls `resume()` once per
colonist within that colonist's own per-tick budget slice. This module does
not schedule, prioritize, or share budget across colonists.

## Inputs and per-request state

Construct with `start: Vector2i`, `target: Vector2i`, a deterministic
`cost_fn(tile: Vector2i) -> Variant`, an inclusive `bounds_min`/
`bounds_max` rectangle and, optionally, `reachable(from, target) -> bool`
(the region check, below) and `min_cost` (the heuristic weight, default
`MIN_TILE_COST = 1.0`). `cost_fn` must not mutate anything and encodes the
caller's rules (`WorldState.passability(x, y)["cost"]` for the vertical
slice: floor/soil cost 1, a passable object's own `move_cost`, 0 for
anything impassable); this module has no tile-type knowledge of its own.
`cost_fn` may return either:

- a `bool` — `true` means passable with cost 1, `false` means impassable.
  This lets a caller pass a plain passability predicate.
- a number — the cost to enter that tile; a value `<= 0` means impassable, a
  positive value is the tile's movement cost (a chair costs more than a
  floor tile, for example).

Every positive cost must be `>= min_cost` (asserted in debug builds); the
content schemas make `move_cost` an integer and a cost `<= 0` impassable, so
every enterable tile costs at least 1 and the default fits every map in the
game. `min_cost = 0` turns the heuristic off (plain Dijkstra, see below).

Bounds fix a finite search space — required so the module can eventually
*prove* a target unreachable rather than only exhaust one call's budget.

The constructed object is the "per-request object": its frontier queue,
visited set, and parent map live on the instance and persist for as long as
the caller holds onto it. There is no separate save/restore step; resuming
means calling `resume()` again on the same instance.

- `RouteSearch.STEP_BUDGET = 64`: the most frontier tiles a single `resume()`
  call may expand. Callers reuse this constant instead of a new literal.
- `resume()` advances the search by at most `STEP_BUDGET` steps and returns
  the status string. Call it again on the same instance to continue; it
  never restarts from `start`.
- `get_status()` is one of `STATUS_SEARCHING`, `STATUS_FOUND`, or
  `STATUS_UNREACHABLE`. `is_terminal()` is `status != STATUS_SEARCHING`.
- `get_path()` returns the tile path from `start` to `target`, inclusive,
  once `STATUS_FOUND`; empty otherwise.

## Determinism and tie-break

The search is a bounded A* search (ADR 054) over 4-directional neighbors,
using `cost_fn`'s per-tile cost as edge weight and the heuristic
`h = Manhattan distance to target × min_cost`, so it always finds the
*cheapest* path (lowest total cost), not merely the shortest one in tile
count, while expanding roughly the tiles along the way instead of a disc
around the start. Each step dequeues the open tile first in this order and
closes it:

1. lowest `f = g + h` (accumulated cost plus estimate);
2. then lowest `h` (the tile nearer the target);
3. then the **latest** pushed (so the search follows one line across a
   plateau of equal `f` instead of widening along all of it).

Neighbors of a tile are discovered in ascending row-major coordinate order
(lowest `y` first, then lowest `x`). The heuristic is consistent, so a closed
tile's cost is final; an open tile whose cost drops when a cheaper neighbor
is expanded later gets the cheaper parent and is re-pushed (the old entry is
skipped when popped). `STATUS_FOUND` is declared when the target is
discovered, which ADR 054 shows is still a cheapest path. Among several
equally cheap paths the one returned is fixed by the order above, and may
differ from the one the pre-A8 Dijkstra search returned. Given the same
`cost_fn`, `start`, `target`, bounds and `min_cost`, `resume()` calls always
take the same number of calls and produce the same path.

With `min_cost = 0` the heuristic is 0, no cost ever improves after
discovery and equal costs pop earliest-first: exactly the pre-A8
uniform-cost search, which on a uniform cost-1 map is breadth-first search.
`test_route_search_recorded.gd` keeps that mode pinned to the values recorded
before A3. No randomness is used or needed; this module
never calls `randi()`, reads wall-clock/engine time, or runs on
`_process`/`_physics_process`.

## Frontier structure and snapshots

The frontier is a binary min-heap of entry numbers (one entry per push, in
insertion order) compared by the order above, plus a map from each open tile
to its live entry. Neighbors come from the constant `NEIGHBOR_OFFSETS` table
(already row-major). `test_route_search_recorded.gd` pins paths, statuses,
expansion counts and a mid-search `snapshot()` digest for every A0 benchmark
case, once as Dijkstra (values recorded before A3) and once as A* (recorded
by A8), and checks that both modes' paths cost the same;
`test_route_astar.gd` checks the same cost equality on seeded random weighted
maps.

`snapshot()` copies the whole search (frontier: the open tiles in insertion
order; visited: every discovered tile; came_from: each tile's best parent;
path); its shape is the one it had before A8, so saves are unaffected and a
search saved by an older build is a valid A* state to continue from. It is meant for save and hash time. `summary()` is the
constant-size part (`start`, `target`, `status`; `MeasuredRoute` adds
`expansions` and `resume_calls`): `ToilExecutor` keeps it on a colonist's
`route.rerouting` while a re-route is live, and `StateCodec` writes the live
search's full `snapshot()` when a save encodes, so the save format is
unchanged. `WorldState.state_hash()` hashes that same full `snapshot()` in
place of the summary (`StateCodec._hash_colonists()`), so two in-flight
re-routes that differ only in their frontier, visited set or parent map
never hash equal (`test_reroute_state_hash.gd`).

## Invalid endpoints

A `start` tile that is out of bounds or whose `cost_fn` result is impassable
(`false`, or a cost `<= 0`) is never a valid place to search from: the
constructor checks this before the `start ==
target` shortcut and before seeding the frontier, and reports
`STATUS_UNREACHABLE` immediately with an empty path. This also covers a
same-tile request (`start == target`) whose single tile is out of bounds or
blocked — it is reported unreachable, not found. A `target` that is out of
bounds or impassable needs no separate check: such a tile can never be
enqueued as visited or matched against, so `resume()` proves it unreachable
once the bounded search space is exhausted, exactly like any other
unreachable target.

## Region check

A caller that passes `reachable(from, target) -> bool` has the request
refused in the constructor, before the frontier is seeded, when it returns
false: `STATUS_UNREACHABLE` with no expansion and an empty snapshot. Every
simulation caller passes `Passability.region_reachable` (`Regions.reachable()`:
same region, or an impassable work target with a neighbor in that region):
`WorldState._route_search_factory()` (ToilExecutor's go_to re-routes and
`_route_cost()`), `NeedGiver`, `RescueGiver` and `ApproachGiver`.
`GlobalAssignment.tick()` makes the same check itself before it creates its
search, and `GlobalAssignment.restore_scheduling()` passes it (from
`StateCodec`) to the unbudgeted re-run of each pending "found" pair on load. Regions follow the colony's passability, which no faction's
passability exceeds (only doors differ, and the colony may pass them), so the
check never refuses a target the search could reach; it only ends a doomed
search at once instead of after it exhausts the map.

## Searching vs. unreachable

`STATUS_SEARCHING` means "still searching, call resume() again"; it does not
imply the target is reachable. `STATUS_UNREACHABLE` is only ever reported
once the frontier is empty, i.e. every tile reachable from `start` within
bounds has been visited and none of them is `target` — never merely because
one call's budget ran out. Once a search reaches `STATUS_FOUND` or
`STATUS_UNREACHABLE`, it is terminal: `resume()` is a no-op that returns the
same status without expanding any further tiles, so a walled-off target
never keeps consuming budget on later calls.

## Example

```gdscript
var cost_fn := func(tile: Vector2i) -> int: return map_movement_cost(tile) # 0 = impassable
var search := RouteSearch.new(start, target, cost_fn, Vector2i.ZERO, Vector2i(map_width - 1, map_height - 1))
var status := search.resume() # STATUS_FOUND, STATUS_UNREACHABLE, or STATUS_SEARCHING
while status == RouteSearch.STATUS_SEARCHING:
	status = search.resume() # call again next tick with the same instance
if status == RouteSearch.STATUS_FOUND:
	var path := search.get_path()
```

`WorldState` wires this to `passability(x, y)["cost"]` (see
[`docs/architecture/colonist-ai.md`](../../../../docs/architecture/colonist-ai.md)
section 3.5); `GlobalAssignment` wraps that in `_routable()` so a route may
still terminate on an otherwise impassable job target.

`test_routing_budget.gd` covers: a short route completing within one call's
budget; a route landing exactly on the `STEP_BUDGET` boundary (completes in
one call) versus one step beyond it (needs a second call), which pins the
64-step constant rather than merely "a budget exists"; an open grid with two
equally short paths asserting the documented coordinate tie-break; a long
route that reports `STATUS_SEARCHING` after the first call and completes on
a later call from persisted state, with two identical runs taking the same
number of calls and producing the same path; a target walled off by rock
reporting `STATUS_UNREACHABLE` and staying terminal on further calls instead
of re-searching; blocked/out-of-bounds start tiles (including same-tile
requests) reporting `STATUS_UNREACHABLE` rather than `STATUS_FOUND`; and a
weighted case proving the search is genuinely cost-based rather than
tile-count shortest-path — a shorter route through three cost-3 tiles loses
to a longer, cheaper all-cost-1 route, and removing the costly tiles flips
the choice back to the direct route.

This is a search primitive, not job or reservation semantics: it has no
concept of a colonist, a claim, priority, or fairness across colonists.
Those belong to the job queue and the global scheduler
(`game/scripts/core/jobs/`, `game/scripts/core/scheduling/`).
