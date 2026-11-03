extends RefCounted

## Rooms (foundation-for-breadth.md §3): components of open tiles (passable, not a door),
## found by an inner RegionMap over that stricter rule. A component is a room only when
## enclosed (its flood never reaches the map edge or an open outside) and its boundary has
## at least one door.
## on_passability_changed() keeps each tile's last open/door state (_cell_state): when it is
## unchanged (a bed placed, soil tilled) only bed membership updates (A2); otherwise the rooms
## around the tile are re-flooded.
## Covers the surface layer (z = 0) only: a tile on any other layer has no region until L3
## builds one map per layer (ADR 045 §4).

const RegionMapType = preload("res://scripts/core/map/regions.gd")

## _cell_state bits.
const OPEN := 1
const DOOR := 2

var _width: int
var _height: int
var _is_door: Callable
## passable and not a door: the inner RegionMap's rule.
var _open: Callable
var _has_bed: Callable
var _is_stockpile: Callable
var _inner: RegionMapType

var _tiles_by_area: Dictionary = {}
var _door_count_by_area: Dictionary = {}
## area id -> {tile index: true} for every member tile with a bed (has_bed is "not empty").
var _bed_tiles_by_area: Dictionary = {}
var _enclosed_by_area: Dictionary = {}
## Tile index -> OPEN/DOOR bits as last built or refreshed.
var _cell_state := PackedByteArray()
## _rebuild_area()'s member set: tile index -> the epoch that reached it.
var _member_epoch := PackedInt32Array()
var _epoch := 0

## has_stockpile is derived per lookup (a zone spans tiles no single change touches), unlike
## has_bed. cell_flags (optional) is Passability.room_cell_flags(), so the build calls nothing per tile.
func _init(width: int, height: int, passable: Callable, is_door: Callable, has_bed: Callable, is_stockpile: Callable,
		cell_flags := PackedByteArray()) -> void:
	_width = width
	_height = height
	_is_door = is_door
	_has_bed = has_bed
	_is_stockpile = is_stockpile
	_open = func(x: int, y: int) -> bool:
		return bool(passable.call(x, y)) and not bool(is_door.call(x, y))
	_cell_state.resize(width * height)
	var open_mask := PackedByteArray()
	open_mask.resize(width * height)
	for y in height:
		for x in width:
			var index := _index(x, y)
			var door := false
			var is_open := false
			if cell_flags.size() == width * height:
				door = cell_flags[index] & 2 != 0
				is_open = cell_flags[index] & 1 != 0 and not door
			else:
				door = bool(is_door.call(x, y))
				is_open = bool(passable.call(x, y)) and not door
			open_mask[index] = 1 if is_open else 0
			_cell_state[index] = (OPEN if is_open else 0) | (DOOR if door else 0)
	_inner = RegionMapType.new(width, height, _open, open_mask)
	_member_epoch.resize(width * height)
	_member_epoch.fill(0)
	var seeds: Dictionary = {}
	for y in height:
		for x in width:
			var id := _inner.region_id(x, y)
			if id != 0 and not seeds.has(id):
				seeds[id] = Vector3i(x, y, TileGrid.SURFACE)
	for id in seeds:
		_rebuild_area(id, seeds[id])

## {} for a tile with no recognised room; otherwise
## {"id", "size", "door_count", "has_bed", "has_stockpile", "tiles"}.
func get_room_at(x: int, y: int) -> Dictionary:
	var id := _inner.region_id(x, y)
	if id == 0 or not bool(_enclosed_by_area.get(id, false)) or int(_door_count_by_area.get(id, 0)) < 1:
		return {}
	var tiles: Array[Vector3i] = _tiles_by_area[id]
	var has_stockpile := false
	for tile in tiles:
		if bool(_is_stockpile.call(tile)):
			has_stockpile = true
			break
	return {
		"id": id, "size": tiles.size(), "door_count": _door_count_by_area[id],
		"has_bed": not (_bed_tiles_by_area[id] as Dictionary).is_empty(), "has_stockpile": has_stockpile, "tiles": tiles.duplicate(),
	}

func on_passability_changed(x: int, y: int) -> void:
	if not _in_bounds(x, y):
		return
	var index := _index(x, y)
	var state := (OPEN if bool(_open.call(x, y)) else 0) | (DOOR if bool(_is_door.call(x, y)) else 0)
	var area := _inner.region_id(x, y)
	if state == _cell_state[index] and (area == 0 or _bed_tiles_by_area.has(area)):
		if area != 0:
			var beds: Dictionary = _bed_tiles_by_area[area]
			if bool(_has_bed.call(Vector3i(x, y, TileGrid.SURFACE))):
				beds[index] = true
			else:
				beds.erase(index)
		return
	_cell_state[index] = state
	var before := _neighbourhood_ids(x, y)
	_inner.on_passability_changed(x, y)
	var after := _neighbourhood_ids(x, y)
	for id in before:
		if not after.has(id):
			_clear_area(id)
	for id in after:
		_rebuild_area(id, after[id])

## Distinct nonzero region ids among (x, y) and its orthogonal neighbours,
## each mapped to a tile the caller can reseed a flood from.
func _neighbourhood_ids(x: int, y: int) -> Dictionary:
	var found: Dictionary = {}
	for tile in [Vector3i(x, y, TileGrid.SURFACE), Vector3i(x, y - 1, TileGrid.SURFACE), Vector3i(x - 1, y, TileGrid.SURFACE), Vector3i(x + 1, y, TileGrid.SURFACE), Vector3i(x, y + 1, TileGrid.SURFACE)]:
		if not _in_bounds(tile.x, tile.y):
			continue
		var id := _inner.region_id(tile.x, tile.y)
		if id != 0 and not found.has(id):
			found[id] = tile
	return found

func _clear_area(id: int) -> void:
	_tiles_by_area.erase(id)
	_door_count_by_area.erase(id)
	_bed_tiles_by_area.erase(id)
	_enclosed_by_area.erase(id)

## Flood confined to _inner's id: each door on the boundary counts once; a member next to the
## map edge clears `enclosed`. Members are listed in flood order, seed first.
func _rebuild_area(id: int, seed: Vector3i) -> void:
	_clear_area(id)
	_epoch += 1
	var tiles: Array[Vector3i] = [seed]
	var doors: Dictionary = {}
	var beds: Dictionary = {}
	var enclosed := true
	var frontier: Array[Vector3i] = [seed]
	_member_epoch[_index(seed.x, seed.y)] = _epoch
	while not frontier.is_empty():
		var current: Vector3i = frontier.pop_back()
		if bool(_has_bed.call(current)):
			beds[_index(current.x, current.y)] = true
		for direction in 4:
			var neighbour := current + _OFFSETS[direction]
			if not _in_bounds(neighbour.x, neighbour.y):
				enclosed = false
				continue
			var ni := _index(neighbour.x, neighbour.y)
			if _inner.region_id(neighbour.x, neighbour.y) == id:
				if _member_epoch[ni] != _epoch:
					_member_epoch[ni] = _epoch
					tiles.append(neighbour)
					frontier.append(neighbour)
			elif bool(_is_door.call(neighbour.x, neighbour.y)):
				doors[ni] = true
	_tiles_by_area[id] = tiles
	_door_count_by_area[id] = doors.size()
	_bed_tiles_by_area[id] = beds
	_enclosed_by_area[id] = enclosed

## Up, left, right, down: RegionMap's _orthogonal() order.
const _OFFSETS: Array[Vector3i] = [Vector3i(0, -1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0)]

func _index(x: int, y: int) -> int:
	return TileGrid.flat_index(x, y, _width)

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < _width and y >= 0 and y < _height
