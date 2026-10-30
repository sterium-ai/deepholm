class_name TileGrid
extends RefCounted

## Terrain: map size, layer count, the tile kinds of every layer, the water-tile cache, the
## dirty-cell log and the region/room maps (regions.gd/rooms.gd).
## Invariants:
## - tiles[index_of(c)] is c's kind; tiles.size() == layer_count * layer_size() (ADR 045 §2:
##   z outermost, so layer 0's indices are y * width + x); width/height/layer_count change
##   only in StateCodec.decode(), which also writes them. Regions and rooms cover layer 0.
## - regions, rooms and the water cache are built on first use, never in _init().
## - dirty_cells is append-only and never persisted; past MAX_DIRTY_CELLS it is trimmed to
##   RETAINED_DIRTY_CELLS and dirty_base (absolute cursor of dirty_cells[0]) moves on (A6).
## - mark_dirty() follows every tile-kind/object change; wholesale replacement calls reset_cells().
## - Hashed: width, height, layer_count, tiles. Caches and the dirty-cell log are derived, not hashed.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const RegionMapType = preload("res://scripts/core/map/regions.gd")
const RoomMapType = preload("res://scripts/core/map/rooms.gd")

const TILE_WATER := ContentRegistryType.TILE_WATER

var width: int
var height: int
## Layers 0..layer_count-1; never shrinks (ADR 045 §2).
var layer_count: int = 1
## The most layers a save may declare (MapValidator, SaveWire's allocation guard); F4 sets the
## gameplay limit within it.
const MAX_LAYER_COUNT := 64
## The surface layer: incidents, spawns and the (x, y) shorthands of WorldState's queries
## address it until a layer-aware caller exists (L3/L4/F4).
const SURFACE := 0
var tiles: Array[String] = []
var water_tile_cache: Array[Vector3i] = []
var water_tile_cache_built := false
const MAX_DIRTY_CELLS := 4096
const RETAINED_DIRTY_CELLS := 3072

var dirty_cells: Array[Vector3i] = []
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
## (tile: Vector3i) -> String: the object kind at a tile ("" when none).
var _get_object: Callable
## (tile: Vector3i) -> bool: rooms.gd's has_stockpile.
var _is_in_any_zone: Callable

func _init(p_width: int, p_height: int, get_object: Callable, is_in_any_zone: Callable) -> void:
	width = p_width
	height = p_height
	_get_object = get_object
	_is_in_any_zone = is_in_any_zone

## The save field this grid owns inside "map": "tiles" (width/height/layerCount are written by
## StateCodec), every layer in flat-index order.
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

## map is the save's "map" object; width/height/layer_count were already set from it.
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
	snapshot["layer_count"] = layer_count
	snapshot["tiles"] = tiles

## (x, y)'s kind on the surface.
func get_tile(x: int, y: int) -> String:
	return tiles[tile_index(x, y)]

func tile_at(tile: Vector3i) -> String:
	return tiles[index_of(tile)]

func get_tiles() -> Array[String]:
	return tiles.duplicate()

## Tiles per layer (ADR 045 §2).
func layer_size() -> int:
	return width * height

## The only flat-index formulas in the core (ADR 045 §2): z outermost, then row-major, so layer
## 0's indices are y * width + x. Static for callers that hold the size, not a grid (regions,
## rooms, passability, worldgen, saves, area orders).
static func flat_index(x: int, y: int, grid_width: int) -> int:
	return y * grid_width + x

## flat_index()'s inverse: the planar (x, y) inside one layer or rectangle, not a map tile.
static func flat_coord(index: int, grid_width: int) -> Vector2i:
	return Vector2i(index % grid_width, index / grid_width)

## A map tile's index across layers.
static func index_in(tile: Vector3i, grid_width: int, grid_height: int) -> int:
	return tile.z * grid_width * grid_height + flat_index(tile.x, tile.y, grid_width)

## index_in()'s inverse.
static func coord_in(index: int, grid_width: int, grid_height: int) -> Vector3i:
	var size := grid_width * grid_height
	var planar := index % size
	return Vector3i(planar % grid_width, planar / grid_width, index / size)

func index_of(tile: Vector3i) -> int:
	return index_in(tile, width, height)

## index_of()'s inverse.
func coord_of(index: int) -> Vector3i:
	return coord_in(index, width, height)

func tile_index(x: int, y: int) -> int:
	return flat_index(x, y, width)

## The tile a record's flat "x"/"y"/"z" fields name (actors, items, zones, benches).
static func tile_of(record: Dictionary) -> Vector3i:
	return Vector3i(int(record["x"]), int(record["y"]), int(record["z"]))

## Writes tile into a record's flat "x"/"y"/"z" fields (tile_of()'s inverse).
static func write_tile(record: Dictionary, tile: Vector3i) -> void:
	record["x"] = tile.x
	record["y"] = tile.y
	record["z"] = tile.z

## The String tile keys (ADR 045 §2). Saves, events, reservations and state_hash() carry them,
## so a surface tile (z = 0) keeps L1's format byte for byte and a deeper one appends its layer;
## replacing them with flat-index ints is a save change for a later task.
const TARGET_KEY_PREFIX := "tile:"
const CELL_KEY_PREFIX := "cell:"

## The ",z" or "_z" suffix of a key: empty on the surface.
static func _layer_suffix(tile: Vector3i, separator: String) -> String:
	return "" if tile.z == 0 else "%s%d" % [separator, tile.z]

## "x_y" ("x_y_z" below the surface): objects, ground berries, work progress, combat targets
## and the save/hash boundary.
static func coord_key(tile: Vector3i) -> String:
	return "%d_%d%s" % [tile.x, tile.y, _layer_suffix(tile, "_")]

## coord_key()'s inverse.
static func coord_of_key(key: String) -> Vector3i:
	var coords := key.split("_")
	return Vector3i(int(coords[0]), int(coords[1]), int(coords[2]) if coords.size() > 2 else 0)

## "tile:x,y[,z]": a reservation on a work or build target (namespaced against "item:"/"cell:").
static func target_key(tile: Vector3i) -> String:
	return "%s%s" % [TARGET_KEY_PREFIX, comma_key(tile)]

## "cell:x,y[,z]": a haul destination cell's reservation.
static func cell_key(tile: Vector3i) -> String:
	return "%s%s" % [CELL_KEY_PREFIX, comma_key(tile)]

## "x,y[,z]": a construction site's origin (ConstructionGiver) and the tile part of an area
## order's expanded command id ("<commandId>:x,y").
static func comma_key(tile: Vector3i) -> String:
	return "%d,%d%s" % [tile.x, tile.y, _layer_suffix(tile, ",")]

## comma_key()'s inverse.
static func coord_of_comma_key(key: String) -> Vector3i:
	var coords := key.split(",")
	return Vector3i(int(coords[0]), int(coords[1]), int(coords[2]) if coords.size() > 2 else 0)

## The three planar metrics (ADR 045 §4) stay three formulas, never merged into one distance.
## Each is defined on one layer only: a call across layers fails the assert.
## Manhattan: nearest-candidate ranking and travel penalties.
static func manhattan(a: Vector3i, b: Vector3i) -> int:
	assert(a.z == b.z, "manhattan() across layers")
	return absi(a.x - b.x) + absi(a.y - b.y)

## Chebyshev: the <= 1 "next to" test (8 neighbours) and square rings.
static func chebyshev(a: Vector3i, b: Vector3i) -> int:
	assert(a.z == b.z, "chebyshev() across layers")
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

## Squared Euclidean: flee-candidate comparison.
static func distance_sq(a: Vector3i, b: Vector3i) -> int:
	assert(a.z == b.z, "distance_sq() across layers")
	var dx := a.x - b.x
	var dy := a.y - b.y
	return dx * dx + dy * dy

## The far corner of the map, every layer included (RouteSearch's inclusive bounds_max).
func bounds_max() -> Vector3i:
	return Vector3i(width - 1, height - 1, layer_count - 1)

## A map tile: inside the width/height and 0 <= z < layer_count.
func contains(tile: Vector3i) -> bool:
	return in_bounds(tile.x, tile.y) and tile.z >= 0 and tile.z < layer_count

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height

## Appends to the dirty-cell log (duplicates kept) and refreshes tile's passability.
func mark_dirty(tile: Vector3i) -> void:
	dirty_cells.append(tile)
	if dirty_cells.size() > MAX_DIRTY_CELLS:
		var drop := dirty_cells.size() - RETAINED_DIRTY_CELLS
		dirty_cells = dirty_cells.slice(drop)
		dirty_base += drop
	if _refresh_cell.is_valid():
		_refresh_cell.call(tile)

## The retained changed cells, in order; never cleared on read (viewers may only read).
func get_dirty_cells() -> Array[Vector3i]:
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

## Every water tile of every layer, in ascending flat index.
func get_water_tiles() -> Array[Vector3i]:
	if not water_tile_cache_built:
		for index in tiles.size():
			if tiles[index] == TILE_WATER:
				water_tile_cache.append(coord_of(index))
		water_tile_cache_built = true
	return water_tile_cache

## Keeps the water cache in sync when a tile changes kind; a no-op until built.
func update_water_tile_cache(tile: Vector3i, was_water: bool, is_water: bool) -> void:
	if not water_tile_cache_built or was_water == is_water:
		return
	if is_water:
		water_tile_cache.append(tile)
	else:
		var index := water_tile_cache.find(tile)
		if index != -1:
			water_tile_cache.remove_at(index)

func get_rooms() -> RoomMapType:
	if rooms == null:
		rooms = RoomMapType.new(width, height, _passable_at, _door_at, func(tile: Vector3i) -> bool: return _get_object.call(tile) == "bed",
			_is_in_any_zone, _room_cell_flags.call())
	return rooms

## Regions' and rooms' hook after tile's passability may have changed (they cover the surface).
func on_passability_changed(tile: Vector3i) -> void:
	if tile.z == SURFACE:
		get_regions().on_passability_changed(tile.x, tile.y)
		get_rooms().on_passability_changed(tile.x, tile.y)

## {} for a tile with no recognised room; otherwise RoomMapType.get_room_at().
func get_room_at(tile: Vector3i) -> Dictionary:
	return get_rooms().get_room_at(tile.x, tile.y) if tile.z == SURFACE else {}
