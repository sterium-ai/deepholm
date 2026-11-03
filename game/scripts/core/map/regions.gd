extends RefCounted

## Regions (foundation-for-breadth.md §3): connected walkable areas under physical passability
## (no factions, no rooms). Ids are 1.. (0 = impassable) and stable across unrelated edits.
## The full build numbers regions in flat-index order of their first tile (row-run union, A2);
## on_tile_changed() only re-floods the changed tile's neighbourhood (split or merge into the
## lowest id), never the whole map.
## Every layer is partitioned on its own (ADR 045 §4, ADR 068): ids are global, layer 0 is
## numbered first (so a single-layer map keeps its ids) and a region never spans layers. The
## region graph joins the two regions of every vertical link; a component's label is its lowest
## region id, rebuilt lazily (O(regions + links)) after a link or a region changed.
## same_region() stays planar; reachable() is the cross-layer query.

const VerticalLinksType = preload("res://scripts/core/map/vertical_links.gd")

var _width: int
var _height: int
var _layer_count: int = 1
var _layer_size: int
var _passable: Callable
## (tile: Vector3i) -> bool on every layer; unset on a surface-only map (rooms' inner map).
var _passable_tile: Callable
var _region_of := PackedInt32Array()
var _next_id: int = 1
## _flood_visit()'s visited set: tile index -> the epoch that visited it.
var _visited := PackedInt32Array()
var _visit_epoch := 0
## The map's links; null on a surface-only map.
var _links: VerticalLinksType
## Region id -> its graph component's label (lowest id); stale while _graph_dirty.
var _labels := PackedInt32Array()
var _graph_dirty := true

## passable(x, y) is the surface rule. passable_mask (optional) is Passability.passable_mask(),
## every layer's tiles as 1/0 in flat-index order, so the build calls nothing per tile. With
## layer_count > 1, passable_tile(tile) and link_flags(tile) (Passability's) cover the deeper
## layers and their links; without passable_tile the map is surface-only.
func _init(width: int, height: int, passable: Callable, passable_mask := PackedByteArray(),
		layer_count := 1, passable_tile := Callable(), link_flags := Callable()) -> void:
	_width = width
	_height = height
	_layer_size = width * height
	_passable = passable
	_passable_tile = passable_tile
	_layer_count = maxi(layer_count, 1) if passable_tile.is_valid() else 1
	_region_of.resize(_layer_size * _layer_count)
	_region_of.fill(0)
	var mask := passable_mask
	if mask.size() > _region_of.size():
		mask = mask.slice(0, _region_of.size())
	if mask.size() != _region_of.size():
		mask = PackedByteArray()
		mask.resize(_region_of.size())
		for index in _region_of.size():
			mask[index] = 1 if _passable_at(_coord(index)) else 0
	_build(mask)
	if _layer_count > 1 and link_flags.is_valid():
		_links = VerticalLinksType.new(width, height, _layer_count, passable_tile, link_flags)

## The map's links (null on a surface-only map).
func vertical_links() -> VerticalLinksType:
	return _links

## 0 for an out-of-bounds or impassable surface tile.
func region_id(x: int, y: int) -> int:
	if not _in_bounds(x, y):
		return 0
	return _region_of[_index(x, y)]

## The region of a tile on any layer; 0 out of bounds or impassable.
func region_of(tile: Vector3i) -> int:
	if not _in_bounds_3d(tile):
		return 0
	return _region_of[_flat(tile)]

## The region graph component of tile's region (its lowest region id); 0 with no region.
func component_of(tile: Vector3i) -> int:
	var id := region_of(tile)
	if id == 0 or _links == null or _links.size() == 0:
		return id
	if _graph_dirty:
		_rebuild_graph()
	return _labels[id]

## True when a and b share a nonzero region id; false for any out-of-bounds or impassable endpoint.
## Planar: two regions joined by a link are still different regions (reachable() crosses links).
func same_region(a: Vector3i, b: Vector3i) -> bool:
	var ra := region_of(a)
	if ra == 0:
		return false
	return region_of(b) == ra

## A job target's reachability across layers: a passable target is reachable when it shares
## from's graph component; an impassable one (worked from beside it) when an orthogonal
## neighbour on its own layer does; out of bounds never is.
func reachable(from: Vector3i, target: Vector3i) -> bool:
	if not _in_bounds_3d(target):
		return false
	var from_component := component_of(from)
	if from_component == 0:
		return false
	if region_of(target) != 0:
		return component_of(target) == from_component
	for neighbour in _orthogonal(target):
		if component_of(neighbour) == from_component:
			return true
	return false

## Call after (x, y)'s passability may have changed; a no-op when it did not.
func on_passability_changed(x: int, y: int) -> void:
	on_tile_changed(Vector3i(x, y, TileGrid.SURFACE))

## Call after tile's passability or link ends may have changed, on any layer; a no-op when
## neither its region nor a link changed.
func on_tile_changed(tile: Vector3i) -> void:
	if not _in_bounds_3d(tile):
		return
	if _links != null and _links.on_tile_changed(tile):
		_graph_dirty = true
	var index := _flat(tile)
	var was_passable := _region_of[index] != 0
	var is_passable := _passable_at(tile)
	if was_passable == is_passable:
		return
	_graph_dirty = true
	if not is_passable:
		_region_of[index] = 0
		_resplit_neighbours(tile)
		return
	_merge_neighbours(tile)

## The constructor's full partition: row runs unioned with overlapping runs above on the same
## layer, ids handed out in flat-index order of each region's first tile.
func _build(mask: PackedByteArray) -> void:
	var run_start := PackedInt32Array()
	var run_end := PackedInt32Array()
	var parent := PackedInt32Array()
	var above_first := 0
	var above_end := 0
	for row_number in _height * _layer_count:
		if row_number % _height == 0:
			# A layer's first row has nothing above it on its own layer.
			above_first = run_start.size()
			above_end = above_first
		var row := row_number * _width
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

## Unions the two regions of every link (lowest id as root), then labels every id in ascending
## order: deterministic and O(regions + links).
func _rebuild_graph() -> void:
	_labels.resize(_next_id)
	for id in _next_id:
		_labels[id] = id
	for lower in _links.lower_indices():
		var a := _region_of[lower]
		var b := _region_of[lower + _layer_size]
		if a != 0 and b != 0:
			_union(_labels, a, b)
	for id in _next_id:
		_labels[id] = _find(_labels, id)
	_graph_dirty = false

## One removed cell can only disconnect its own neighbours: the first keeps old_id, any
## neighbour no longer reachable from it is relabelled as a fresh component.
func _resplit_neighbours(tile: Vector3i) -> void:
	var neighbours := _passable_neighbours(tile)
	if neighbours.size() < 2:
		return
	var old_id := region_of(neighbours[0])
	_visit_epoch += 1
	_flood_visit(_flat(neighbours[0]), old_id)
	for i in range(1, neighbours.size()):
		var neighbour: Vector3i = neighbours[i]
		if _visited[_flat(neighbour)] == _visit_epoch:
			continue
		_flood_relabel(_flat(neighbour), old_id, _next_id)
		_next_id += 1

## The newly passable tile joins the lowest id among its passable
## neighbours' regions (or starts a fresh one with none); every other
## neighbour region relabels to that id.
func _merge_neighbours(tile: Vector3i) -> void:
	var index := _flat(tile)
	var neighbours := _passable_neighbours(tile)
	if neighbours.is_empty():
		_region_of[index] = _next_id
		_next_id += 1
		return
	var keep := region_of(neighbours[0])
	for neighbour in neighbours:
		keep = mini(keep, region_of(neighbour))
	_region_of[index] = keep
	var merged: Dictionary = {}
	for neighbour in neighbours:
		var id := region_of(neighbour)
		if id != keep and not merged.has(id):
			merged[id] = true
			_flood_relabel(_flat(neighbour), id, keep)

## Marks every tile reachable from start within old_id, without relabelling.
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

## Relabels the old_id component reachable from start to new_id.
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

## The index of index's orthogonal neighbour on its own layer in _orthogonal()'s order (0 up,
## 1 left, 2 right, 3 down), or -1 past the layer's edge.
func _step(index: int, direction: int) -> int:
	match direction:
		0:
			return index - _width if index % _layer_size >= _width else -1
		1:
			return index - 1 if index % _width > 0 else -1
		2:
			return index + 1 if index % _width < _width - 1 else -1
		_:
			return index + _width if index % _layer_size < _layer_size - _width else -1

func _passable_neighbours(tile: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for neighbour in _orthogonal(tile):
		if _in_bounds(neighbour.x, neighbour.y) and _passable_at(neighbour):
			result.append(neighbour)
	return result

## The surface keeps its (x, y) rule; deeper layers use passable_tile.
func _passable_at(tile: Vector3i) -> bool:
	if tile.z == TileGrid.SURFACE:
		return bool(_passable.call(tile.x, tile.y))
	return bool(_passable_tile.call(tile))

func _orthogonal(tile: Vector3i) -> Array[Vector3i]:
	return [Vector3i(tile.x, tile.y - 1, tile.z), Vector3i(tile.x - 1, tile.y, tile.z),
		Vector3i(tile.x + 1, tile.y, tile.z), Vector3i(tile.x, tile.y + 1, tile.z)]

func _index(x: int, y: int) -> int:
	return TileGrid.flat_index(x, y, _width)

func _flat(tile: Vector3i) -> int:
	return tile.z * _layer_size + tile.y * _width + tile.x

func _coord(index: int) -> Vector3i:
	return Vector3i(index % _width, index / _width % _height, index / _layer_size)

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < _width and y >= 0 and y < _height

func _in_bounds_3d(tile: Vector3i) -> bool:
	return _in_bounds(tile.x, tile.y) and tile.z >= 0 and tile.z < _layer_count
