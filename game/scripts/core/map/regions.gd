extends RefCounted

## F5 "Regions" (foundation-for-breadth.md §3): partitions the map into
## connected walkable areas using a caller-supplied passability rule
## (WorldState.passability(x, y)["passable"]), assigning each a stable
## integer id (1.., 0 = impassable/no region) that never changes for an
## unrelated map edit. Physical passability only -- no faction awareness and
## no rooms (see rooms.gd); see docs/architecture/foundation-for-breadth.md's non-goals.
##
## on_passability_changed(x, y) recomputes only the tile(s) actually affected
## by a change at (x, y): a local flood-fill from that tile's own
## neighbourhood, splitting a region into two ids when a passable tile
## becomes impassable and its neighbours are no longer mutually connected, or
## merging neighbouring regions into the lowest of their ids when an
## impassable tile becomes passable. It never recomputes the whole map.

var _width: int
var _height: int
var _passable: Callable
var _region_of: Array[int] = []
var _next_id: int = 1

func _init(width: int, height: int, passable: Callable) -> void:
	_width = width
	_height = height
	_passable = passable
	_region_of.resize(width * height)
	_region_of.fill(0)
	for y in height:
		for x in width:
			var index := _index(x, y)
			if _region_of[index] == 0 and bool(_passable.call(x, y)):
				_flood_assign(Vector2i(x, y), _next_id)
				_next_id += 1

## 0 for an out-of-bounds or impassable tile.
func region_id(x: int, y: int) -> int:
	if not _in_bounds(x, y):
		return 0
	return _region_of[_index(x, y)]

## True when a and b sit in the same connected walkable area: both in bounds,
## both passable (nonzero region id), and that id equal. Symmetric, and false
## for any out-of-bounds or impassable endpoint -- an impassable tile has no
## region membership of its own, whatever passable tiles surround it.
func same_region(a: Vector2i, b: Vector2i) -> bool:
	var ra := region_id(a.x, a.y)
	if ra == 0:
		return false
	return region_id(b.x, b.y) == ra

## Scheduler-facing reachability check for a job's target tile, mirroring
## GlobalAssignment._routable()'s treatment of an impassable work target: a
## chop/forage/dig tile is worked by standing adjacent to it, never stood on.
## Bounds-checks target explicitly (out of bounds is never reachable) before
## falling back to same_region(); unlike same_region(), an impassable target
## (region id 0) is still reachable when any of its orthogonal neighbours
## shares from's region.
func reachable(from: Vector2i, target: Vector2i) -> bool:
	if not _in_bounds(target.x, target.y):
		return false
	if same_region(from, target):
		return true
	if region_id(target.x, target.y) != 0:
		return false
	for neighbour in _orthogonal(target):
		if same_region(from, neighbour):
			return true
	return false

## Call after (x, y)'s passability may have changed (WorldState's
## place_object/remove_object and dig/chop/forage tile transforms). A no-op
## when the tile's own passability did not actually change.
func on_passability_changed(x: int, y: int) -> void:
	if not _in_bounds(x, y):
		return
	var index := _index(x, y)
	var was_passable := _region_of[index] != 0
	var is_passable := bool(_passable.call(x, y))
	if was_passable == is_passable:
		return
	if not is_passable:
		_region_of[index] = 0
		_resplit_neighbours(Vector2i(x, y))
		return
	_merge_neighbours(Vector2i(x, y))

## A single cell can only disconnect its own orthogonal neighbours from one
## another (removing one graph vertex splits its neighbourhood into at most
## as many pieces as it had edges): the first neighbour keeps old_id, and any
## neighbour not reachable from it within the surviving old_id tiles starts a
## freshly relabelled component.
func _resplit_neighbours(tile: Vector2i) -> void:
	var neighbours := _passable_neighbours(tile)
	if neighbours.size() < 2:
		return
	var old_id := region_id(neighbours[0].x, neighbours[0].y)
	var visited: Dictionary = {}
	_flood_visit(neighbours[0], old_id, visited)
	for i in range(1, neighbours.size()):
		var neighbour: Vector2i = neighbours[i]
		if visited.has(_index(neighbour.x, neighbour.y)):
			continue
		_flood_relabel(neighbour, old_id, _next_id)
		_next_id += 1

## The newly passable tile joins the lowest id among its passable
## neighbours' regions (or starts a fresh one with none); every other
## neighbour region relabels to that id.
func _merge_neighbours(tile: Vector2i) -> void:
	var index := _index(tile.x, tile.y)
	var neighbours := _passable_neighbours(tile)
	if neighbours.is_empty():
		_region_of[index] = _next_id
		_next_id += 1
		return
	var keep := region_id(neighbours[0].x, neighbours[0].y)
	for neighbour in neighbours:
		keep = mini(keep, region_id(neighbour.x, neighbour.y))
	_region_of[index] = keep
	var merged: Dictionary = {}
	for neighbour in neighbours:
		var id := region_id(neighbour.x, neighbour.y)
		if id != keep and not merged.has(id):
			merged[id] = true
			_flood_relabel(neighbour, id, keep)

## Marks every tile reachable from start while still carrying old_id, without
## mutating _region_of -- used to prove two neighbours of a newly impassable
## tile remain connected without relabelling anything.
func _flood_visit(start: Vector2i, old_id: int, visited: Dictionary) -> void:
	if _region_of[_index(start.x, start.y)] != old_id:
		return
	visited[_index(start.x, start.y)] = true
	var frontier: Array[Vector2i] = [start]
	while not frontier.is_empty():
		var current: Vector2i = frontier.pop_back()
		for neighbour in _orthogonal(current):
			if not _in_bounds(neighbour.x, neighbour.y):
				continue
			var ni := _index(neighbour.x, neighbour.y)
			if visited.has(ni) or _region_of[ni] != old_id:
				continue
			visited[ni] = true
			frontier.append(neighbour)

## Bounded flood-fill confined to tiles currently carrying old_id, relabelling
## them to new_id -- the actual work behind a split's new component or a
## merge's absorbed region.
func _flood_relabel(start: Vector2i, old_id: int, new_id: int) -> void:
	var start_index := _index(start.x, start.y)
	if _region_of[start_index] != old_id:
		return
	_region_of[start_index] = new_id
	var frontier: Array[Vector2i] = [start]
	while not frontier.is_empty():
		var current: Vector2i = frontier.pop_back()
		for neighbour in _orthogonal(current):
			if not _in_bounds(neighbour.x, neighbour.y):
				continue
			var ni := _index(neighbour.x, neighbour.y)
			if _region_of[ni] != old_id:
				continue
			_region_of[ni] = new_id
			frontier.append(neighbour)

## Bounded flood-fill over currently-unassigned (0) passable tiles, assigning
## id -- the full-map partition the constructor uses once.
func _flood_assign(start: Vector2i, id: int) -> void:
	_region_of[_index(start.x, start.y)] = id
	var frontier: Array[Vector2i] = [start]
	while not frontier.is_empty():
		var current: Vector2i = frontier.pop_back()
		for neighbour in _orthogonal(current):
			if not _in_bounds(neighbour.x, neighbour.y):
				continue
			var ni := _index(neighbour.x, neighbour.y)
			if _region_of[ni] != 0:
				continue
			if not bool(_passable.call(neighbour.x, neighbour.y)):
				continue
			_region_of[ni] = id
			frontier.append(neighbour)

func _passable_neighbours(tile: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for neighbour in _orthogonal(tile):
		if _in_bounds(neighbour.x, neighbour.y) and bool(_passable.call(neighbour.x, neighbour.y)):
			result.append(neighbour)
	return result

func _orthogonal(tile: Vector2i) -> Array[Vector2i]:
	return [Vector2i(tile.x, tile.y - 1), Vector2i(tile.x - 1, tile.y),
		Vector2i(tile.x + 1, tile.y), Vector2i(tile.x, tile.y + 1)]

func _index(x: int, y: int) -> int:
	return y * _width + x

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < _width and y >= 0 and y < _height
