class_name RouteSearch
extends RefCounted

## Deterministic, budgeted, resumable uniform-cost route search (see README.md). A caller keeps one
## instance per request across ticks; resume() advances it by at most STEP_BUDGET steps and never
## restarts. cost_fn(tile) must be deterministic and non-mutating: a bool (true = cost 1) or a
## number (<= 0 impassable). Bounds are inclusive and finite, which is what lets the search prove
## a target unreachable. An out-of-bounds or impassable start is STATUS_UNREACHABLE at once.

## Maximum frontier expansions per resume(); the single source of the per-tick route budget.
const STEP_BUDGET := 64

const STATUS_SEARCHING := "searching"
const STATUS_FOUND := "found"
const STATUS_UNREACHABLE := "unreachable"

## Neighbours are expanded in row-major order (y, then x), which fixes which of several equally
## short paths is returned. The offsets below already are in that order.
const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1),
]

var _start: Vector2i
var _target: Vector2i
var _cost_fn: Callable
var _bounds_min: Vector2i
var _bounds_max: Vector2i

var _status: String = STATUS_SEARCHING
## Parent of every visited tile except _start, in discovery order (snapshot()'s "visited").
var _came_from: Dictionary = {}
## True once _start is visited; false for a search that ended in _init().
var _seeded := false
var _path: Array[Vector2i] = []
## Frontier ordered by (cost, insertion): a min-heap of distinct costs plus a FIFO per cost.
## Insertion numbers only grow, so the head of the cheapest FIFO is the "lowest cost, earliest
## insertion" pick. snapshot() merges the FIFOs back into one insertion-ordered list.
var _cost_heap := PackedFloat64Array()
var _buckets: Dictionary = {}
var _next_seq := 0
## Tiles expanded by the latest resume(); read by MeasuredRoute, not part of snapshot().
var _last_resume_steps := 0

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
	_seeded = true
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
## reported once the bounded space is exhausted, never because the budget ran out. A tile's entry
## cost depends only on the tile, so the first discovery is the cheapest predecessor and marking
## visited (and FOUND) at discovery stays correct for weighted costs.
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
	while steps < STEP_BUDGET and not _cost_heap.is_empty():
		var current_cost: float = _cost_heap[0]
		var current := _frontier_pop()
		steps += 1
		for offset in NEIGHBOR_OFFSETS:
			var neighbor := current + offset
			if neighbor == _start or _came_from.has(neighbor):
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
			_came_from[neighbor] = current
			if neighbor == _target:
				_status = STATUS_FOUND
				_path = _reconstruct_path(neighbor)
				_last_resume_steps = steps
				return _status
			_frontier_push(neighbor, current_cost + edge_cost)
	if _cost_heap.is_empty():
		_status = STATUS_UNREACHABLE
	_last_resume_steps = steps
	return _status

## Native-Variant continuation state; callers translate Vector2i through their codec
## (state_codec.gd). Copies the whole search: for save/hash time only, per-tick readers use summary().
func snapshot() -> Dictionary:
	return {"start": _start, "target": _target, "status": _status,
		"frontier": _frontier_in_insertion_order(), "visited": _visited_in_insertion_order(),
		"came_from": _came_from.duplicate(), "path": _path.duplicate()}

## The constant-size part of snapshot() (start, target, status), cheap enough for every tick.
func summary() -> Dictionary:
	return {"start": _start, "target": _target, "status": _status}

## Resumes an in-flight search from snapshot(). Call right after construction with the current
## cost_fn/bounds (a Callable cannot be persisted).
func restore(state: Dictionary) -> void:
	_start = state["start"]
	_target = state["target"]
	_status = state["status"]
	_seeded = (state["visited"] as Dictionary).has(_start)
	_came_from = (state["came_from"] as Dictionary).duplicate()
	_path.clear()
	for tile in state["path"]:
		_path.append(tile)
	var costs := _rebuild_costs()
	_cost_heap.clear()
	_buckets.clear()
	_next_seq = 0
	for tile in state["frontier"]:
		_frontier_push(tile, costs[tile])

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

## Accumulated cost per visited tile, rebuilt after restore() (not part of the snapshot).
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

## Tiles waiting at one cost, oldest first; entries before head are already expanded.
class Bucket:
	var tiles: Array[Vector2i] = []
	var seqs: Array[int] = []
	var head := 0

## Queues tile at cost with the next insertion number.
func _frontier_push(tile: Vector2i, cost: float) -> void:
	var bucket: Bucket = _buckets.get(cost)
	if bucket == null:
		bucket = Bucket.new()
		_buckets[cost] = bucket
		_cost_heap_push(cost)
	bucket.tiles.append(tile)
	bucket.seqs.append(_next_seq)
	_next_seq += 1

## Pops the oldest tile at the lowest cost; an emptied FIFO leaves the cost heap.
func _frontier_pop() -> Vector2i:
	var cost := _cost_heap[0]
	var bucket: Bucket = _buckets[cost]
	var tile: Vector2i = bucket.tiles[bucket.head]
	bucket.head += 1
	if bucket.head == bucket.tiles.size():
		_buckets.erase(cost)
		_cost_heap_pop()
	return tile

func _cost_heap_push(cost: float) -> void:
	var i := _cost_heap.size()
	_cost_heap.append(cost)
	while i > 0:
		var parent := (i - 1) >> 1
		if _cost_heap[parent] <= cost:
			break
		_cost_heap[i] = _cost_heap[parent]
		i = parent
	_cost_heap[i] = cost

func _cost_heap_pop() -> void:
	var last := _cost_heap.size() - 1
	var cost := _cost_heap[last]
	_cost_heap.resize(last)
	if last == 0:
		return
	var i := 0
	while true:
		var child := 2 * i + 1
		if child >= last:
			break
		if child + 1 < last and _cost_heap[child + 1] < _cost_heap[child]:
			child += 1
		if cost <= _cost_heap[child]:
			break
		_cost_heap[i] = _cost_heap[child]
		i = child
	_cost_heap[i] = cost

## snapshot()'s "visited": _start (once seeded), then every discovered tile in marking order.
func _visited_in_insertion_order() -> Dictionary:
	var visited := {}
	if not _seeded:
		return visited
	visited[_start] = true
	for tile in _came_from.keys():
		visited[tile] = true
	return visited

## The frontier tiles ordered by insertion number (snapshot()'s shape).
func _frontier_in_insertion_order() -> Array[Vector2i]:
	var seqs: Array[int] = []
	var tiles: Array[Vector2i] = []
	for cost in _buckets:
		var bucket: Bucket = _buckets[cost]
		for i in range(bucket.head, bucket.tiles.size()):
			seqs.append(bucket.seqs[i])
			tiles.append(bucket.tiles[i])
	var order := range(tiles.size())
	order.sort_custom(func(a: int, b: int) -> bool: return seqs[a] < seqs[b])
	var frontier: Array[Vector2i] = []
	for i in order:
		frontier.append(tiles[i])
	return frontier
