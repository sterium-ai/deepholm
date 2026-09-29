class_name RouteSearch
extends RefCounted

## Standalone deterministic, budgeted route search: bounded uniform-cost
## (Dijkstra-style) search over WorldState.passability()'s per-tile cost. See
## README.md for the integration contract. A RouteSearch instance is the
## per-request object that a caller (for example a colonist's job) keeps
## across ticks: each call to resume() advances the same search by at most
## STEP_BUDGET steps and never restarts from the source tile.
##
## The map itself is caller-owned: cost_fn(tile: Vector2i) -> Variant must be
## deterministic and non-mutating, returning either a bool (true = passable,
## cost 1; false = impassable, matching the module's original contract) or a
## numeric per-tile movement cost where a value <= 0 means impassable and a
## positive value is the cost to enter that tile (rock/hazard vs. floor/soil/
## furniture rules live with the caller, not here). bounds_min/bounds_max are
## inclusive and fix a finite search space, which is what lets this module
## ever confirm a target is unreachable rather than merely "still searching".
##
## Invalid endpoints: a start tile that is out of bounds or not passable is
## never a valid place to search from, so _init() reports STATUS_UNREACHABLE
## immediately (before the start == target shortcut and before the frontier
## is seeded), with an empty path. This also covers a same-tile request whose
## single tile is out of bounds or blocked: it is unreachable, not found. A
## target that is out of bounds or impassable needs no separate check: it can
## never be enqueued as visited or matched, so resume() proves it unreachable
## once the bounded search space is exhausted, the same as any other
## unreachable target.

## Maximum number of frontier expansions a single resume() call may perform.
## Later code reuses this constant rather than
## a duplicated literal so the per-tick route budget stays in one place.
const STEP_BUDGET := 64

const STATUS_SEARCHING := "searching"
const STATUS_FOUND := "found"
const STATUS_UNREACHABLE := "unreachable"

var _start: Vector2i
var _target: Vector2i
var _cost_fn: Callable
var _bounds_min: Vector2i
var _bounds_max: Vector2i

var _status: String = STATUS_SEARCHING
var _frontier: Array[Vector2i] = []
var _visited: Dictionary = {}
var _came_from: Dictionary = {}
var _path: Array[Vector2i] = []
## Best known accumulated path cost per tile, keyed like _visited. Not part of
## snapshot()/restore(): it is rebuilt from _came_from on restore() instead,
## so the persisted shape (and StateCodec/save_io.gd, which are out of this
## task's scope) stay exactly as before.
var _cost: Dictionary = {}

func _init(start: Vector2i, target: Vector2i, cost_fn: Callable,
		bounds_min: Vector2i, bounds_max: Vector2i) -> void:
	assert(cost_fn.is_valid())
	assert(bounds_min.x <= bounds_max.x and bounds_min.y <= bounds_max.y)
	_start = start
	_target = target
	_cost_fn = cost_fn
	_bounds_min = bounds_min
	_bounds_max = bounds_max
	if not _in_bounds(start) or _cost_of(start) <= 0.0:
		_status = STATUS_UNREACHABLE
		return
	if start == target:
		_status = STATUS_FOUND
		_path = [start]
		return
	_visited[start] = true
	_cost[start] = 0.0
	_frontier.append(start)

## Current status: "searching", "found", or "unreachable". Never call again
## once this is not "searching": the search has already reached its terminal
## outcome and resume() would be a no-op.
func get_status() -> String:
	return _status

func is_terminal() -> bool:
	return _status != STATUS_SEARCHING

## Deterministic tile path from start to target, inclusive. Empty until
## get_status() == STATUS_FOUND.
func get_path() -> Array[Vector2i]:
	return _path.duplicate()

## Advances this search by at most STEP_BUDGET frontier expansions (a "step"
## is one tile dequeued and expanded) and returns the resulting status.
## A found or unreachable status is sticky and consumes no further budget on
## later calls: unreachable is only ever reported once the finite bounded
## search space (bounds_min..bounds_max) is fully exhausted, never merely
## because a single call's budget ran out.
##
## Uniform-cost (Dijkstra-style) expansion: each step dequeues the frontier
## tile with the lowest accumulated cost (ties broken by earliest insertion,
## which for a uniform cost-1 map is exactly FIFO order -- see README.md for
## why this makes uniform-cost maps behave identically to the plain
## breadth-first search this module used before). Because a tile's entry
## cost depends only on the tile itself, not on which neighbor enters it, the
## first tile to discover a given neighbor is always the cheapest predecessor
## for it (every predecessor with a lower-or-equal accumulated cost has
## already been dequeued and expanded first), so marking a tile visited at
## discovery time -- and declaring STATUS_FOUND the moment the target is
## discovered -- remains correct for weighted costs, not just cost 1.
func resume() -> String:
	if _status != STATUS_SEARCHING:
		return _status
	var steps := 0
	while steps < STEP_BUDGET and not _frontier.is_empty():
		var current_index := _pop_min_index()
		var current: Vector2i = _frontier[current_index]
		_frontier.remove_at(current_index)
		var current_cost: float = _cost[current]
		steps += 1
		for neighbor in _ordered_neighbors(current):
			if _visited.has(neighbor):
				continue
			if not _in_bounds(neighbor):
				continue
			var edge_cost := _cost_of(neighbor)
			if edge_cost <= 0.0:
				continue
			_visited[neighbor] = true
			_came_from[neighbor] = current
			_cost[neighbor] = current_cost + edge_cost
			if neighbor == _target:
				_status = STATUS_FOUND
				_path = _reconstruct_path(neighbor)
				return _status
			_frontier.append(neighbor)
	if _frontier.is_empty():
		_status = STATUS_UNREACHABLE
	return _status

## Native-Variant continuation state (start, target, status, frontier,
## visited, came_from, path). Vector2i values are not JSON-safe; a caller
## that persists this across a save boundary translates through its own
## codec (see game/scripts/core/persistence/state_codec.gd).
func snapshot() -> Dictionary:
	return {"start": _start, "target": _target, "status": _status,
		"frontier": _frontier.duplicate(), "visited": _visited.duplicate(),
		"came_from": _came_from.duplicate(), "path": _path.duplicate()}

## Overwrites this instance's continuation state from a snapshot()
## Dictionary, resuming an in-flight search rather than restarting it. Call
## immediately after construction: the constructor's own seeding (based on
## the start/target passed to new()) is discarded. cost_fn/bounds are not
## part of the snapshot and must already be current (passed to _init()
## before this call), since a Callable cannot be persisted.
func restore(state: Dictionary) -> void:
	_start = state["start"]
	_target = state["target"]
	_status = state["status"]
	_frontier.clear()
	for tile in state["frontier"]:
		_frontier.append(tile)
	_visited = (state["visited"] as Dictionary).duplicate()
	_came_from = (state["came_from"] as Dictionary).duplicate()
	_path.clear()
	for tile in state["path"]:
		_path.append(tile)
	_rebuild_costs()

func _reconstruct_path(end: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [end]
	var cursor := end
	while cursor != _start:
		cursor = _came_from[cursor]
		path.append(cursor)
	path.reverse()
	return path

## Normalizes a cost_fn call result to a float cost: a bool result preserves
## this module's original contract (true = cost 1, false = impassable/cost
## 0); any numeric result is used as-is.
func _cost_of(tile: Vector2i) -> float:
	var result = _cost_fn.call(tile)
	if typeof(result) == TYPE_BOOL:
		return 1.0 if result else 0.0
	return float(result)

## Rebuilds _cost (not part of the persisted snapshot) from _came_from after
## restore(), so a resumed search still knows each visited/frontier tile's
## accumulated cost without changing the snapshot's shape.
func _rebuild_costs() -> void:
	_cost = {}
	_cost[_start] = 0.0
	for tile in _visited.keys():
		_cost_up_to(tile)

func _cost_up_to(tile: Vector2i) -> float:
	if _cost.has(tile):
		return _cost[tile]
	var parent: Vector2i = _came_from[tile]
	var cost := _cost_up_to(parent) + _cost_of(tile)
	_cost[tile] = cost
	return cost

## Selects the frontier index with the lowest accumulated cost, breaking ties
## by earliest insertion (the frontier array is itself in insertion order),
## which is what makes a uniform cost-1 map behave exactly like the plain
## FIFO breadth-first search this module used before.
func _pop_min_index() -> int:
	var best := 0
	var best_cost: float = _cost[_frontier[0]]
	for i in range(1, _frontier.size()):
		var candidate_cost: float = _cost[_frontier[i]]
		if candidate_cost < best_cost:
			best = i
			best_cost = candidate_cost
	return best

func _in_bounds(tile: Vector2i) -> bool:
	return (tile.x >= _bounds_min.x and tile.x <= _bounds_max.x
		and tile.y >= _bounds_min.y and tile.y <= _bounds_max.y)

## Tie-break rule: candidate neighbors are expanded in ascending row-major
## tile-coordinate order (lowest y first, then lowest x), matching the
## row-major tile indexing used elsewhere in the simulation core. This fixes
## which of several equally short paths is returned, so the same map/start/
## target always yields the same path.
func _ordered_neighbors(tile: Vector2i) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = [
		Vector2i(tile.x, tile.y - 1),
		Vector2i(tile.x - 1, tile.y),
		Vector2i(tile.x + 1, tile.y),
		Vector2i(tile.x, tile.y + 1),
	]
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x
	)
	return candidates
