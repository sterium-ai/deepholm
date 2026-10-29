class_name RouteSearch
extends RefCounted

## Deterministic, budgeted, resumable A* route search (ADR 054, see README.md). A caller keeps one
## instance per request across ticks; resume() advances it by at most STEP_BUDGET steps and never
## restarts. cost_fn(tile) must be deterministic and non-mutating: a bool (true = cost 1) or a
## number (<= 0 impassable); every positive cost must be >= min_cost (asserted). Bounds are
## inclusive and finite, which is what lets the search prove a target unreachable. An
## out-of-bounds or impassable start, or a target that reachable(start, target) refuses
## (Passability.region_reachable), is STATUS_UNREACHABLE at once.

## Maximum frontier expansions per resume(); the single source of the per-tick route budget.
const STEP_BUDGET := 64

## Default heuristic weight: content move costs are integers and <= 0 is impassable.
const MIN_TILE_COST := 1.0

const STATUS_SEARCHING := "searching"
const STATUS_FOUND := "found"
const STATUS_UNREACHABLE := "unreachable"

## Neighbours are discovered in row-major order (y, then x); with the frontier order below this
## fixes which of several equally cheap paths is returned. The offsets already are in that order.
const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1),
]

var _start: Vector2i
var _target: Vector2i
var _cost_fn: Callable
var _bounds_min: Vector2i
var _bounds_max: Vector2i
var _min_cost: float

var _status: String = STATUS_SEARCHING
## Best parent of every discovered tile except _start, in discovery order (snapshot()'s
## "visited"); a cheaper parent found later overwrites the value in place.
var _came_from: Dictionary = {}
## Best known accumulated cost g of every discovered tile, _start included.
var _g: Dictionary = {}
## True once _start is visited; false for a search that ended in _init().
var _seeded := false
var _path: Array[Vector2i] = []
## Frontier ordered by (f = g + h, h, latest insertion): a min-heap of insertion numbers over
## _entry_f/_entry_h/_entry_tile. _open maps each open tile to its live entry; a tile whose g
## drops is pushed again (moving to the end of _open) and its stale entry skipped when popped,
## so _open's key order is insertion order (snapshot()'s "frontier"). With min_cost 0 no g
## improves and ties pop earliest first: exactly the pre-A8 Dijkstra search.
var _open: Dictionary = {}
var _heap := PackedInt64Array()
var _entry_f := PackedFloat64Array()
var _entry_h := PackedFloat64Array()
var _entry_tile: Array[Vector2i] = []
## Tiles expanded by the latest resume(); read by MeasuredRoute, not part of snapshot().
var _last_resume_steps := 0

func _init(start: Vector2i, target: Vector2i, cost_fn: Callable,
		bounds_min: Vector2i, bounds_max: Vector2i, reachable: Callable = Callable(),
		min_cost: float = MIN_TILE_COST) -> void:
	assert(cost_fn.is_valid())
	assert(bounds_min.x <= bounds_max.x and bounds_min.y <= bounds_max.y)
	assert(min_cost >= 0.0)
	_start = start
	_target = target
	_cost_fn = cost_fn
	_bounds_min = bounds_min
	_bounds_max = bounds_max
	_min_cost = min_cost
	if not _in_bounds(start) or _cost_of(start) <= 0.0:
		_status = STATUS_UNREACHABLE
		return
	if start == target:
		_status = STATUS_FOUND
		_path = [start]
		return
	if reachable.is_valid():
		var same_region: bool = reachable.call(start, target)
		if not same_region:
			_status = STATUS_UNREACHABLE
			return
	_seeded = true
	_g[start] = 0.0
	_frontier_push(start, 0.0)

## "searching", "found" or "unreachable"; the last two are terminal.
func get_status() -> String:
	return _status

func is_terminal() -> bool:
	return _status != STATUS_SEARCHING

## Inclusive tile path from start to target; empty until STATUS_FOUND.
func get_path() -> Array[Vector2i]:
	return _path.duplicate()

## Advances by at most STEP_BUDGET expansions. Terminal statuses are sticky; unreachable is only
## reported once the bounded space is exhausted, never because the budget ran out. h is
## consistent (a step changes the Manhattan distance by 1 and costs >= min_cost), so a closed
## tile's g is final. FOUND at the target's discovery is a cheapest path: any other one leaves
## through an open tile o with f(o) >= f(current) and costs >= g(current) + cost(target) (ADR 054).
func resume() -> String:
	_last_resume_steps = 0
	if _status != STATUS_SEARCHING:
		return _status
	# Hot loop: bounds test and _cost_of() inlined (same checks, same order) for speed.
	var min_x := _bounds_min.x
	var min_y := _bounds_min.y
	var max_x := _bounds_max.x
	var max_y := _bounds_max.y
	var steps := 0
	while steps < STEP_BUDGET and not _open.is_empty():
		var current := _frontier_pop()
		var current_cost: float = _g[current]
		steps += 1
		for offset in NEIGHBOR_OFFSETS:
			var neighbor := current + offset
			if neighbor == _start:
				continue
			var known := _came_from.has(neighbor)
			if known and not _open.has(neighbor):
				continue
			if neighbor.x < min_x or neighbor.x > max_x or neighbor.y < min_y or neighbor.y > max_y:
				continue
			var result: Variant = _cost_fn.call(neighbor)
			var edge_cost: float
			if typeof(result) == TYPE_BOOL:
				edge_cost = 1.0 if result else 0.0
			else:
				edge_cost = float(result)
			if edge_cost <= 0.0:
				continue
			assert(edge_cost >= _min_cost, "RouteSearch: a tile cost below min_cost makes the heuristic inadmissible")
			var cost := current_cost + edge_cost
			if known:
				var best: float = _g[neighbor]
				if cost >= best:
					continue
			_came_from[neighbor] = current
			_g[neighbor] = cost
			if neighbor == _target:
				_status = STATUS_FOUND
				_path = _reconstruct_path(neighbor)
				_last_resume_steps = steps
				return _status
			_frontier_push(neighbor, cost)
	if _open.is_empty():
		_status = STATUS_UNREACHABLE
		_heap.clear()
	_last_resume_steps = steps
	return _status

## Native-Variant continuation state; callers translate Vector2i through their codec
## (state_codec.gd). Copies the whole search: for save/hash time only, per-tick readers use summary().
## "cost" is the accumulated cost g of every visited tile (A7): a search can span a map change,
## so its costs are part of the continuation and are never recomputed from the current map.
func snapshot() -> Dictionary:
	var frontier: Array[Vector2i] = []
	frontier.assign(_open.keys())
	return {"start": _start, "target": _target, "status": _status,
		"frontier": frontier, "visited": _visited_in_insertion_order(),
		"came_from": _came_from.duplicate(), "cost": _g.duplicate(), "path": _path.duplicate()}

## Runs search to a terminal status: its path's step count, or -1 when unreachable.
static func finish_steps(search: RouteSearch) -> int:
	while not search.is_terminal():
		search.resume()
	if search.get_status() != STATUS_FOUND:
		return -1
	return search.get_path().size() - 1

## The constant-size part of snapshot() (start, target, status), cheap enough for every tick.
func summary() -> Dictionary:
	return {"start": _start, "target": _target, "status": _status}

## Resumes an in-flight search from snapshot(). Call right after construction with the current
## cost_fn/bounds/min_cost (a Callable cannot be persisted). The frontier is re-pushed in its saved
## order with its saved costs, so the restored search expands exactly as the uninterrupted one
## even when the map changed since a tile was visited. A state without "cost" (a save from
## before schema v5) rebuilds the costs from the current map, as those saves always did.
func restore(state: Dictionary) -> void:
	_start = state["start"]
	_target = state["target"]
	_status = state["status"]
	_seeded = (state["visited"] as Dictionary).has(_start)
	_came_from = (state["came_from"] as Dictionary).duplicate()
	_path.clear()
	for tile in state["path"]:
		_path.append(tile)
	if not _seeded:
		_g = {}
	elif state.has("cost"):
		_g = (state["cost"] as Dictionary).duplicate()
	else:
		_g = _rebuild_costs()
	_open.clear()
	_heap.clear()
	_entry_f.clear()
	_entry_h.clear()
	_entry_tile.clear()
	for tile in state["frontier"]:
		var g: float = _g[tile]
		_frontier_push(tile, g)

func _reconstruct_path(end: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [end]
	var cursor := end
	while cursor != _start:
		cursor = _came_from[cursor]
		path.append(cursor)
	path.reverse()
	return path

## bool true = cost 1, false = impassable; numbers as-is. resume() inlines the same rule.
func _cost_of(tile: Vector2i) -> float:
	var result: Variant = _cost_fn.call(tile)
	if typeof(result) == TYPE_BOOL:
		return 1.0 if result else 0.0
	return float(result)

## Accumulated cost per visited tile from the current map: only for a state saved without
## "cost" (schema < v5), see restore().
func _rebuild_costs() -> Dictionary:
	var costs := {_start: 0.0}
	for tile in _came_from.keys():
		_cost_up_to(tile, costs)
	return costs

func _cost_up_to(tile: Vector2i, costs: Dictionary) -> float:
	if costs.has(tile):
		return costs[tile]
	var parent: Vector2i = _came_from[tile]
	var cost := _cost_up_to(parent, costs) + _cost_of(tile)
	costs[tile] = cost
	return cost

func _in_bounds(tile: Vector2i) -> bool:
	return (tile.x >= _bounds_min.x and tile.x <= _bounds_max.x
		and tile.y >= _bounds_min.y and tile.y <= _bounds_max.y)

# --- frontier --------------------------------------------------------------

## Opens tile (or re-opens it at a lower g) with the next insertion number.
func _frontier_push(tile: Vector2i, g: float) -> void:
	var h := float(absi(tile.x - _target.x) + absi(tile.y - _target.y)) * _min_cost
	var seq := _entry_tile.size()
	_entry_f.append(g + h)
	_entry_h.append(h)
	_entry_tile.append(tile)
	_open.erase(tile)
	_open[tile] = seq
	var i := _heap.size()
	_heap.append(seq)
	while i > 0:
		var parent := (i - 1) >> 1
		if not _entry_before(seq, _heap[parent]):
			break
		_heap[i] = _heap[parent]
		i = parent
	_heap[i] = seq

## Pops the first open tile in frontier order, skipping stale entries; only called while _open
## is not empty, so a live entry is always found.
func _frontier_pop() -> Vector2i:
	var tile := _start
	while not _heap.is_empty():
		var seq := _heap[0]
		_heap_pop()
		tile = _entry_tile[seq]
		var live: int = _open.get(tile, -1)
		if live == seq:
			_open.erase(tile)
			break
	return tile

func _heap_pop() -> void:
	var last := _heap.size() - 1
	var seq := _heap[last]
	_heap.resize(last)
	if last == 0:
		return
	var i := 0
	while true:
		var child := 2 * i + 1
		if child >= last:
			break
		if child + 1 < last and _entry_before(_heap[child + 1], _heap[child]):
			child += 1
		if not _entry_before(_heap[child], seq):
			break
		_heap[i] = _heap[child]
		i = child
	_heap[i] = seq

## Lower f, then lower h, then the later insertion (the earlier one when min_cost is 0).
func _entry_before(a: int, b: int) -> bool:
	if _entry_f[a] != _entry_f[b]:
		return _entry_f[a] < _entry_f[b]
	if _entry_h[a] != _entry_h[b]:
		return _entry_h[a] < _entry_h[b]
	return a < b if _min_cost == 0.0 else a > b

## snapshot()'s "visited": _start (once seeded), then every discovered tile in marking order.
func _visited_in_insertion_order() -> Dictionary:
	var visited := {}
	if not _seeded:
		return visited
	visited[_start] = true
	for tile in _came_from.keys():
		visited[tile] = true
	return visited
