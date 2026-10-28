extends RefCounted

## F5 "Regions" (foundation-for-breadth.md §3): partitions the map into
## connected walkable areas using a caller-supplied passability rule
## (WorldState.passability(x, y)["passable"]), assigning each a stable
## integer id (1.., 0 = impassable/no region) that never changes for an
## unrelated map edit. Physical passability only -- no faction awareness and
## no rooms (see rooms.gd); see docs/architecture/foundation-for-breadth.md's non-goals.
##
## The full build numbers regions in row-major order of their first tile
## (the first region met scanning rows top to bottom, left to right is 1).
## It labels whole row runs of passable tiles and joins the runs that touch
## across rows (A2), which gives the same ids as a flood-fill from each
## unlabelled tile in scan order without visiting tiles one by one.
##
## on_passability_changed(x, y) recomputes only the tile(s) actually affected
## by a change at (x, y): a local flood-fill from that tile's own
## neighbourhood, splitting a region into two ids when a passable tile
## becomes impassable and its neighbours are no longer mutually connected, or
## merging neighbouring regions into the lowest of their ids when an
## impassable tile becomes passable. It never recomputes the whole map.
## Floods work on flat tile indices (y * width + x) and never allocate per tile.

var _width: int
var _height: int
var _passable: Callable
var _region_of := PackedInt32Array()
var _next_id: int = 1
## _flood_visit()'s visited set: tile index -> the epoch that visited it.
var _visited := PackedInt32Array()
var _visit_epoch := 0

## passable_mask, when given, is every tile's passable(x, y) as 1/0 in
## row-major order (Passability.passable_mask()), so the build calls nothing
## per tile; passable still answers on_passability_changed().
func _init(width: int, height: int, passable: Callable, passable_mask := PackedByteArray()) -> void:
	_width = width
	_height = height
	_passable = passable
	_region_of.resize(width * height)
	_region_of.fill(0)
	var mask := passable_mask
	if mask.size() != width * height:
		mask = PackedByteArray()
		mask.resize(width * height)
		for y in height:
			for x in width:
				mask[_index(x, y)] = 1 if bool(_passable.call(x, y)) else 0
	_build(mask)

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

## The full-map partition the constructor runs once. Each row's passable runs
## (found with PackedByteArray.find()) are unioned with the runs of the row
## above they overlap (4-connectivity: a shared column); each run's set then
## takes the next id the first time one of its runs is met in row-major run
## order, which is the order of each region's first tile.
func _build(mask: PackedByteArray) -> void:
	var run_start := PackedInt32Array()
	var run_end := PackedInt32Array()
	var parent := PackedInt32Array()
	var above_first := 0
	var above_end := 0
	for y in _height:
		var row := y * _width
		var row_end := row + _width
		var first := run_start.size()
		var above := above_first
		var pos := row
		while pos < row_end:
			var start := mask.find(1, pos)
			if start == -1 or start >= row_end:
				break
			var end := mask.find(0, start)
			if end == -1 or end > row_end:
				end = row_end
			var run := run_start.size()
			run_start.append(start)
			run_end.append(end)
			parent.append(run)
			while above < above_end and run_end[above] + _width <= start:
				above += 1
			var touching := above
			while touching < above_end and run_start[touching] + _width < end:
				_union(parent, run, touching)
				touching += 1
			pos = end
		above_first = first
		above_end = run_start.size()
	var id_of_root := PackedInt32Array()
	id_of_root.resize(run_start.size())
	id_of_root.fill(0)
	for run in run_start.size():
		var root := _find(parent, run)
		var id := id_of_root[root]
		if id == 0:
			id = _next_id
			_next_id += 1
			id_of_root[root] = id
		for index in range(run_start[run], run_end[run]):
			_region_of[index] = id

func _find(parent: PackedInt32Array, run: int) -> int:
	var root := run
	while parent[root] != root:
		root = parent[root]
	while parent[run] != root:
		var next := parent[run]
		parent[run] = root
		run = next
	return root

func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var root_a := _find(parent, a)
	var root_b := _find(parent, b)
	if root_a < root_b:
		parent[root_b] = root_a
	elif root_b < root_a:
		parent[root_a] = root_b

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
	_visit_epoch += 1
	_flood_visit(_index(neighbours[0].x, neighbours[0].y), old_id)
	for i in range(1, neighbours.size()):
		var neighbour: Vector2i = neighbours[i]
		if _visited[_index(neighbour.x, neighbour.y)] == _visit_epoch:
			continue
		_flood_relabel(_index(neighbour.x, neighbour.y), old_id, _next_id)
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
			_flood_relabel(_index(neighbour.x, neighbour.y), id, keep)

## Marks (with _visit_epoch) every tile reachable from start while still
## carrying old_id, without mutating _region_of -- used to prove two
## neighbours of a newly impassable tile remain connected without
## relabelling anything.
func _flood_visit(start: int, old_id: int) -> void:
	if _region_of[start] != old_id:
		return
	if _visited.size() != _region_of.size():
		_visited.resize(_region_of.size())
		_visited.fill(0)
	_visited[start] = _visit_epoch
	var frontier := PackedInt32Array([start])
	while not frontier.is_empty():
		var current := frontier[frontier.size() - 1]
		frontier.resize(frontier.size() - 1)
		for direction in 4:
			var neighbour := _step(current, direction)
			if neighbour == -1 or _visited[neighbour] == _visit_epoch or _region_of[neighbour] != old_id:
				continue
			_visited[neighbour] = _visit_epoch
			frontier.append(neighbour)

## Bounded flood-fill confined to tiles currently carrying old_id, relabelling
## them to new_id -- the actual work behind a split's new component or a
## merge's absorbed region.
func _flood_relabel(start: int, old_id: int, new_id: int) -> void:
	if _region_of[start] != old_id:
		return
	_region_of[start] = new_id
	var frontier := PackedInt32Array([start])
	while not frontier.is_empty():
		var current := frontier[frontier.size() - 1]
		frontier.resize(frontier.size() - 1)
		for direction in 4:
			var neighbour := _step(current, direction)
			if neighbour == -1 or _region_of[neighbour] != old_id:
				continue
			_region_of[neighbour] = new_id
			frontier.append(neighbour)

## The index of index's orthogonal neighbour in _orthogonal()'s order (0 up,
## 1 left, 2 right, 3 down), or -1 past the map edge.
func _step(index: int, direction: int) -> int:
	match direction:
		0:
			return index - _width if index >= _width else -1
		1:
			return index - 1 if index % _width > 0 else -1
		2:
			return index + 1 if index % _width < _width - 1 else -1
		_:
			return index + _width if index < _region_of.size() - _width else -1

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
