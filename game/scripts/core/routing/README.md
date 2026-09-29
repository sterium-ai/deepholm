# Route search contract (#46)

`RouteSearch` is a plain `RefCounted` module implementing ADR 003 principle 1
and the bounded route-work budget in `docs/architecture/simulation-boundaries.md`.
It has no dependency on `WorldState`, `JobQueue`, or the viewer: the
owning simulation constructs one `RouteSearch` per outstanding route request,
keeps that same instance across ticks, and calls `resume()` once per
colonist within that colonist's own per-tick budget slice. This module does
not schedule, prioritize, or share budget across colonists.

## Inputs and per-request state

Construct with `start: Vector2i`, `target: Vector2i`, a deterministic
`cost_fn(tile: Vector2i) -> Variant`, and an inclusive `bounds_min`/
`bounds_max` rectangle. `cost_fn` must not mutate anything and encodes the
caller's rules (`WorldState.passability(x, y)["cost"]` for the vertical
slice: floor/soil cost 1, a passable object's own `move_cost`, 0 for
anything impassable); this module has no tile-type knowledge of its own.
`cost_fn` may return either:

- a `bool` — `true` means passable with cost 1, `false` means impassable.
  This is the module's original contract and lets any caller written before
  this task keep passing a plain passability predicate unchanged.
- a number — the cost to enter that tile; a value `<= 0` means impassable, a
  positive value is the tile's movement cost (a chair costs more than a
  floor tile, for example).

Bounds fix a finite search space — required so the module can eventually
*prove* a target unreachable rather than only exhaust one call's budget.

The constructed object is the "per-request object": its frontier queue,
visited set, and parent map live on the instance and persist for as long as
the caller holds onto it. There is no separate save/restore step; resuming
means calling `resume()` again on the same instance.

- `RouteSearch.STEP_BUDGET = 64`: the most frontier tiles a single `resume()`
  call may expand. Later tasks reuse this constant instead of a new literal.
- `resume()` advances the search by at most `STEP_BUDGET` steps and returns
  the status string. Call it again on the same instance to continue; it
  never restarts from `start`.
- `get_status()` is one of `STATUS_SEARCHING`, `STATUS_FOUND`, or
  `STATUS_UNREACHABLE`. `is_terminal()` is `status != STATUS_SEARCHING`.
- `get_path()` returns the tile path from `start` to `target`, inclusive,
  once `STATUS_FOUND`; empty otherwise.

## Determinism and tie-break

The search is a bounded uniform-cost (Dijkstra-style) search over
4-directional neighbors, using `cost_fn`'s per-tile cost as edge weight, so
it always finds the *cheapest* path (lowest total cost), not merely the
shortest one in tile count. Each step dequeues the not-yet-expanded tile
with the lowest accumulated cost from the frontier. Ties — either between
tiles at the same accumulated cost, or every tile on a uniform cost-1 map —
are broken deterministically: neighbors of a tile are expanded in ascending
row-major coordinate order (lowest `y` first, then lowest `x`), matching the
row-major tile indexing used elsewhere in the simulation core, and among
frontier tiles at equal cost the earliest-discovered tile is dequeued first.
Because a tile's cost depends only on the tile itself (not on which neighbor
enters it), the first predecessor to discover a given tile is always its
cheapest predecessor, so a uniform cost-1 map's tie-break and results are
*identical* to this module's original plain breadth-first search — this is
what lets every uniform-cost caller (and every existing `is_passable`-style
boolean callable) keep working unchanged. Given the same `cost_fn`, `start`,
`target`, and bounds, `resume()` calls always take the same number of calls
and produce the same path. No randomness is used or needed; this module
never calls `randi()`, reads wall-clock/engine time, or runs on
`_process`/`_physics_process`.

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
`docs/architecture/colonist-ai.md` section 3.5); `GlobalAssignment` wraps
that in `_routable()` so a route may still terminate on an otherwise-
impassable job target (see below).

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
the choice back to the direct route. Run the issue's import, headless test,
and forbidden-core-API scan commands.

This is a search primitive, not job or reservation semantics: it has no
concept of a colonist, a claim, priority, or fairness across colonists.
Those remain the responsibility of a future task per this module's
non-goals.
