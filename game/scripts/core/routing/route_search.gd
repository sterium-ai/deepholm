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

## Tie-break rule: candidate neighbors are expanded in ascending row-major
## tile-coordinate order (lowest y first, then lowest x), matching the
## row-major tile indexing used elsewhere in the simulation core. This fixes
## which of several equally short paths is returned, so the same map/start/
## target always yields the same path. For any tile the four offsets below
## already are in that order, so no per-step sort is needed.
const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1),
]

var _start: Vector2i
var _target: Vector2i
var _cost_fn: Callable
var _bounds_min: Vector2i
var _bounds_max: Vector2i

var _status: String = STATUS_SEARCHING
## Parent of every visited tile except _start, in discovery order. The
## visited set is _start plus these keys; snapshot() spells it out as
## "visited" (same insertion order) instead of keeping a second Dictionary.
var _came_from: Dictionary = {}
## True once _start itself is visited (the frontier was seeded). False for a
## search that ended in _init() (invalid start, start == target), whose
## snapshot() "visited" is empty.
var _seeded := false
var _path: Array[Vector2i] = []
## The frontier, ordered by (accumulated cost, insertion order): a binary
## min-heap of the distinct costs still waiting (_cost_heap) and, per cost, a
## FIFO of its tiles (_buckets). Insertion numbers (_next_seq) only grow, so
## each FIFO is already in insertion order and popping the head of the
## cheapest FIFO is exactly the "lowest cost, earliest insertion" pick the
## linear scan made, without sifting a heap of every frontier tile. A tile's
## cost is fixed when it is discovered. snapshot() merges the FIFOs back by
## insertion number, so the persisted "frontier" is the same
## insertion-ordered list the linear-scan frontier held before A3.
var _cost_heap := PackedFloat64Array()
var _buckets: Dictionary = {}
var _next_seq := 0
## Tiles expanded by the latest resume() call (0 once terminal). MeasuredRoute
## adds it to its expansion count; it is not part of snapshot().
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
	_last_resume_steps = 0
	if _status != STATUS_SEARCHING:
		return _status
	# Hot loop: the bounds test and _cost_of() are inlined (same checks, same
	# order) because a GDScript call per neighbor dominated the step cost.
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

## Native-Variant continuation state (start, target, status, frontier,
## visited, came_from, path). Vector2i values are not JSON-safe; a caller
## that persists this across a save boundary translates through its own
## codec (see game/scripts/core/persistence/state_codec.gd). "frontier" is
## in insertion order. This copies the whole search, so it is meant for save
## and hash time; per-tick status readers use summary().
func snapshot() -> Dictionary:
	return {"start": _start, "target": _target, "status": _status,
		"frontier": _frontier_in_insertion_order(), "visited": _visited_in_insertion_order(),
		"came_from": _came_from.duplicate(), "path": _path.duplicate()}

## The constant-size part of snapshot() (start, target, status), cheap
## enough to refresh on every tick. ToilExecutor keeps this on
## route.rerouting while a search is live; StateCodec writes the full
## snapshot() at encode time.
func summary() -> Dictionary:
	return {"start": _start, "target": _target, "status": _status}

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

## Normalizes a cost_fn call result to a float cost: a bool result preserves
## this module's original contract (true = cost 1, false = impassable/cost
## 0); any numeric result is used as-is. resume() inlines the same rule.
func _cost_of(tile: Vector2i) -> float:
	var result: Variant = _cost_fn.call(tile)
	if typeof(result) == TYPE_BOOL:
		return 1.0 if result else 0.0
	return float(result)

## Accumulated path cost per visited tile, rebuilt from _came_from after
## restore() (it is not part of the persisted snapshot), so a resumed search
## still knows each frontier tile's heap key without changing the snapshot's
## shape.
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

## The tiles waiting at one accumulated cost, oldest first; entries before
## head are already expanded.
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

## Removes and returns the oldest tile at the lowest cost; a cost whose FIFO
## empties leaves the cost heap.
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

## snapshot()'s "visited": _start (once seeded) followed by every discovered
## tile, which is the order the tiles were marked in.
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
