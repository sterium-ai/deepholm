extends RefCounted

## F5 "Rooms" (foundation-for-breadth.md §3): a room is a maximal connected
## component of tiles reachable through passable, non-door tiles -- both an
## impassable tile/object (a wall) and a door object stop the flood, unlike
## RegionMap (regions.gd), where a door is just another passable tile. Reuses
## RegionMapType's own incremental split/merge algorithm by wrapping a second
## instance built over that stricter "open" predicate (physically passable
## and not a door), rather than re-implementing flood-fill. Because the flood
## already absorbs every reachable open neighbour, a component's boundary is
## by construction entirely walls and/or doors; the only extra rule this adds
## is that a component only counts as a *room* once its boundary includes at
## least one door (door_count >= 1) -- a sealed box with no entrance, or the
## great outdoors bounded only by the map edge, is not a room.
##
## on_passability_changed(x, y) is called from the same WorldState mutation
## sites as RegionMap's own hook (_set_object -- covers wall/door/bed add and
## remove -- and dig/chop/forage/till/sow/sleep's tile transforms). Rooms
## depend only on which tiles are open and which are doors, plus where beds
## stand, so it keeps each tile's last seen open/door state (_cell_state):
## when (x, y)'s state is unchanged (soil -> plowed_soil, a bed placed or
## removed) no room's shape can have changed and only (x, y)'s bed membership
## is updated (A2); otherwise every room touching (x, y)'s neighbourhood is
## re-flooded. A bed changes has_bed without flipping physical passability,
## which is why this tracks more than the inner RegionMap's own gate.
##
## "Enclosed by impassable tiles/walls" means a
## component's flood never reaches the map boundary: _rebuild_area() treats
## an out-of-bounds neighbour of a member tile the same as it treats a
## boundary door candidate below -- it marks the component "open to the
## outside" -- and get_room_at() refuses to recognise an open component as a
## room regardless of its door_count, so a lone door standing on the open
## map (nothing bounds the flood at all) or the outdoors surrounding a real
## walled box (bounded on one side only, by that box's own walls) never
## qualifies just because a door happens to sit on its component's frontier.

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

## passable/is_door mirror WorldState.passability(x, y)'s own "passable"/
## "is_door" fields; has_bed is get_object(x, y) == "bed"; is_stockpile is
## whether (x, y) falls in an active zone_add stockpile zone -- WorldState
## owns zone data, so has_stockpile is derived per lookup in get_room_at()
## rather than tracked incrementally like has_bed (a zone can span many
## tiles no single on_passability_changed(x, y) call touches).
## cell_flags, when given, is every tile's passable (bit 1) and is_door (bit 2)
## in row-major order (Passability.room_cell_flags()), so the build calls
## neither per tile.
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
				seeds[id] = Vector2i(x, y)
	for id in seeds:
		_rebuild_area(id, seeds[id])

## {} for a tile with no recognised room (not open, open but not fully
## enclosed by walls/doors, or enclosed with door_count < 1); otherwise
## {"id", "size", "door_count", "has_bed", "has_stockpile", "tiles"}.
func get_room_at(x: int, y: int) -> Dictionary:
	var id := _inner.region_id(x, y)
	if id == 0 or not bool(_enclosed_by_area.get(id, false)) or int(_door_count_by_area.get(id, 0)) < 1:
		return {}
	var tiles: Array[Vector2i] = _tiles_by_area[id]
	var has_stockpile := false
	for tile in tiles:
		if bool(_is_stockpile.call(tile.x, tile.y)):
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
			if bool(_has_bed.call(x, y)):
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
	for tile in [Vector2i(x, y), Vector2i(x, y - 1), Vector2i(x - 1, y), Vector2i(x + 1, y), Vector2i(x, y + 1)]:
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

## Bounded flood confined to _inner's id (never the whole map): walks every
## open member tile, and for each, its non-member orthogonal neighbours --
## impassable ones are the plain wall boundary; door ones are counted once
## each (a room wrapping around a doorway must not double-count it) and never
## crossed into. A member tile with an out-of-bounds neighbour means the
## component reaches the map edge with nothing there to stop it, exactly
## like reaching an ordinary open (non-wall, non-door) tile would -- both
## clear `enclosed`, since "enclosed by impassable tiles/walls" requires the
## flood to be stopped on every side, not merely to contain a door somewhere.
## Members are listed in the order the flood first reaches them, seed first.
func _rebuild_area(id: int, seed: Vector2i) -> void:
	_clear_area(id)
	_epoch += 1
	var tiles: Array[Vector2i] = [seed]
	var doors: Dictionary = {}
	var beds: Dictionary = {}
	var enclosed := true
	var frontier: Array[Vector2i] = [seed]
	_member_epoch[_index(seed.x, seed.y)] = _epoch
	while not frontier.is_empty():
		var current: Vector2i = frontier.pop_back()
		if bool(_has_bed.call(current.x, current.y)):
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
const _OFFSETS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]

func _index(x: int, y: int) -> int:
	return y * _width + x

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < _width and y >= 0 and y < _height
