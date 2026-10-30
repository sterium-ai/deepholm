class_name TileGrid
extends RefCounted

## Terrain: map size, row-major tile kinds, the water-tile cache, the dirty-cell log and the
## region/room maps (regions.gd/rooms.gd).
## Invariants:
## - tiles[tile_index(x, y)] is (x, y)'s kind; width/height change only in StateCodec.decode().
## - regions, rooms and the water cache are built on first use, never in _init().
## - dirty_cells is append-only and never persisted; past MAX_DIRTY_CELLS it is trimmed to
##   RETAINED_DIRTY_CELLS and dirty_base (absolute cursor of dirty_cells[0]) moves on (A6).
## - mark_dirty() follows every tile-kind/object change; wholesale replacement calls reset_cells().
## - Hashed: width, height, tiles. Caches and the dirty-cell log are derived, not hashed.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const RegionMapType = preload("res://scripts/core/map/regions.gd")
const RoomMapType = preload("res://scripts/core/map/rooms.gd")

const TILE_WATER := ContentRegistryType.TILE_WATER

var width: int
var height: int
var tiles: Array[String] = []
var water_tile_cache: Array[Vector2i] = []
var water_tile_cache_built := false
const MAX_DIRTY_CELLS := 4096
const RETAINED_DIRTY_CELLS := 3072

var dirty_cells: Array[Vector2i] = []
## Absolute cursor of dirty_cells[0]: how many entries retention dropped.
var dirty_base: int = 0
var regions: RegionMapType
var rooms: RoomMapType

## Passability's hooks (bind_passability()): per-tile refresh, reset, passable/door
## queries and the packed masks regions/rooms build from.
var _refresh_cell: Callable
var _reset_cells: Callable
var _passable_at: Callable
var _door_at: Callable
var _passable_mask: Callable
var _room_cell_flags: Callable
## (x, y) -> String: the object kind at a tile ("" when none).
var _get_object: Callable
## (x, y) -> bool: rooms.gd's has_stockpile.
var _is_in_any_zone: Callable

func _init(p_width: int, p_height: int, get_object: Callable, is_in_any_zone: Callable) -> void:
	width = p_width
	height = p_height
	_get_object = get_object
	_is_in_any_zone = is_in_any_zone

## The save field this grid owns inside "map": "tiles" (width/height are written by StateCodec).
func encode() -> Dictionary:
	return {"tiles": tiles.duplicate()}

## Wired by Passability._init() before any query; an unbound grid only keeps its own bookkeeping.
func bind_passability(refresh_cell: Callable, reset: Callable, passable_at: Callable, door_at: Callable,
		passable_mask: Callable, room_cell_flags: Callable) -> void:
	_refresh_cell = refresh_cell
	_reset_cells = reset
	_passable_at = passable_at
	_door_at = door_at
	_passable_mask = passable_mask
	_room_cell_flags = room_cell_flags

## map is the save's "map" object; width/height were already set from it.
func decode(map: Dictionary) -> void:
	tiles = Array(map["tiles"], TYPE_STRING, "", null)
	reset_cells()

## After tiles or objects were replaced wholesale, not through mark_dirty().
func reset_cells() -> void:
	if _reset_cells.is_valid():
		_reset_cells.call()

## Adds this grid's state_hash() entries to snapshot (see the class doc for what is left out).
func hash_into(snapshot: Dictionary) -> void:
	snapshot["width"] = width
	snapshot["height"] = height
	snapshot["tiles"] = tiles

func get_tile(x: int, y: int) -> String:
	return tiles[tile_index(x, y)]

func get_tiles() -> Array[String]:
	return tiles.duplicate()

## The only flat-index formula in the core (ADR 045 §2, L1): row-major on one layer, so
## layer 0's indices are y * width + x. Static for callers that hold a width, not a grid
## (regions, rooms, passability, worldgen, saves, area orders).
static func flat_index(x: int, y: int, grid_width: int) -> int:
	return y * grid_width + x

## flat_index()'s inverse.
static func flat_coord(index: int, grid_width: int) -> Vector2i:
	return Vector2i(index % grid_width, index / grid_width)

func index_of(tile: Vector2i) -> int:
	return flat_index(tile.x, tile.y, width)

## index_of()'s inverse.
func coord_of(index: int) -> Vector2i:
	return flat_coord(index, width)

func tile_index(x: int, y: int) -> int:
	return flat_index(x, y, width)

## The String tile keys (ADR 045 §2). Saves, events, reservations and state_hash() carry them,
## so L1 keeps every format byte for byte and only gives each one owner; replacing them with
## flat-index ints is a save change for a later task.
const TARGET_KEY_PREFIX := "tile:"
const CELL_KEY_PREFIX := "cell:"

## "x_y": objects, ground berries, work progress, combat targets and the save/hash boundary.
static func coord_key(x: int, y: int) -> String:
	return "%d_%d" % [x, y]

## coord_key()'s inverse.
static func coord_of_key(key: String) -> Vector2i:
	var coords := key.split("_")
	return Vector2i(int(coords[0]), int(coords[1]))

## "tile:x,y": a reservation on a work or build target (namespaced against "item:"/"cell:").
static func target_key(x: int, y: int) -> String:
	return "%s%d,%d" % [TARGET_KEY_PREFIX, x, y]

## "cell:x,y": a haul destination cell's reservation.
static func cell_key(x: int, y: int) -> String:
	return "%s%d,%d" % [CELL_KEY_PREFIX, x, y]

## "x,y": a construction site's origin (ConstructionGiver) and the tile part of an area order's
## expanded command id ("<commandId>:x,y").
static func comma_key(x: int, y: int) -> String:
	return "%d,%d" % [x, y]

## The three planar metrics (ADR 045 §4) stay three formulas, never merged into one distance.
## Manhattan: nearest-candidate ranking and travel penalties.
static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)

## Chebyshev: the <= 1 "next to" test (8 neighbours) and square rings.
static func chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

## Squared Euclidean: flee-candidate comparison.
static func distance_sq(a: Vector2i, b: Vector2i) -> int:
	var dx := a.x - b.x
	var dy := a.y - b.y
	return dx * dx + dy * dy

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height

## Appends to the dirty-cell log (duplicates kept) and refreshes (x, y)'s passability.
func mark_dirty(x: int, y: int) -> void:
	dirty_cells.append(Vector2i(x, y))
	if dirty_cells.size() > MAX_DIRTY_CELLS:
		var drop := dirty_cells.size() - RETAINED_DIRTY_CELLS
		dirty_cells = dirty_cells.slice(drop)
		dirty_base += drop
	if _refresh_cell.is_valid():
		_refresh_cell.call(x, y)

## The retained changed cells, in order; never cleared on read (viewers may only read).
func get_dirty_cells() -> Array[Vector2i]:
	return dirty_cells.duplicate()

## The dirty-cell log as a cursor stream (A6): {"cells", "next", "truncated"}; truncated
## when retention already dropped entries at or after `cursor`.
func get_dirty_cells_since(cursor: int) -> Dictionary:
	var start := clampi(cursor - dirty_base, 0, dirty_cells.size())
	return {"cells": dirty_cells.slice(start), "next": dirty_base + dirty_cells.size(), "truncated": cursor < dirty_base}

func get_regions() -> RegionMapType:
	if regions == null:
		regions = RegionMapType.new(width, height, _passable_at, _passable_mask.call())
	return regions

func get_water_tiles() -> Array[Vector2i]:
	if not water_tile_cache_built:
		for y in height:
			for x in width:
				if tiles[tile_index(x, y)] == TILE_WATER:
					water_tile_cache.append(Vector2i(x, y))
		water_tile_cache_built = true
	return water_tile_cache

## Keeps the water cache in sync when a tile changes kind; a no-op until built.
func update_water_tile_cache(x: int, y: int, was_water: bool, is_water: bool) -> void:
	if not water_tile_cache_built or was_water == is_water:
		return
	if is_water:
		water_tile_cache.append(Vector2i(x, y))
	else:
		var index := water_tile_cache.find(Vector2i(x, y))
		if index != -1:
			water_tile_cache.remove_at(index)

func get_rooms() -> RoomMapType:
	if rooms == null:
		rooms = RoomMapType.new(width, height, _passable_at, _door_at, func(x, y): return _get_object.call(x, y) == "bed",
			_is_in_any_zone, _room_cell_flags.call())
	return rooms

## {} for a tile with no recognised room; otherwise RoomMapType.get_room_at().
func get_room_at(x: int, y: int) -> Dictionary:
	return get_rooms().get_room_at(x, y)
