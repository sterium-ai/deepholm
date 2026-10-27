class_name TileGrid
extends RefCounted

## WorldState's terrain: the map dimensions, the row-major tile kinds, the
## lazily built water-tile cache, the append-only dirty-cell log, and the
## lazily built region/room maps (regions.gd/rooms.gd). Plain data, no
## scene/node/wall-clock dependency; the passability and object rules the
## region/room maps read arrive as Callables.
##
## Invariants:
## - tiles[y * width + x] is (x, y)'s tile kind; width/height never change
##   after construction except through StateCodec.decode() (a saved map's
##   exact size), always before tiles is replaced.
## - regions, rooms and the water cache are built on first use, never in
##   _init(), so StateCodec.decode()'s direct tiles/objects overwrite never
##   leaves them stale. Every later tile/object change keeps them in sync
##   (on_passability_changed(), update_water_tile_cache()).
## - dirty_cells is append-only, never cleared on read and never persisted: a
##   viewer keeps a cursor into it (get_dirty_cells_since(), A6). Retention is
##   bounded: past MAX_DIRTY_CELLS the oldest entries are dropped down to
##   RETAINED_DIRTY_CELLS and dirty_base, the absolute cursor of
##   dirty_cells[0], moves past them. Colonist/item movement never appends here.
## - state_hash() covers width, height and tiles (hash_into()); the caches
##   and the dirty-cell log are derived and deliberately left out.

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

## (x, y, faction_id = "colony") -> Dictionary: WorldState.passability().
var _passability: Callable
## (x, y) -> String: the object kind at a tile ("" when none).
var _get_object: Callable
## (x, y) -> bool: rooms.gd's has_stockpile.
var _is_in_any_zone: Callable

func _init(p_width: int, p_height: int, passability: Callable, get_object: Callable, is_in_any_zone: Callable) -> void:
	width = p_width
	height = p_height
	_passability = passability
	_get_object = get_object
	_is_in_any_zone = is_in_any_zone

## The save field this grid owns inside "map": "tiles" (width/height are written by StateCodec).
func encode() -> Dictionary:
	return {"tiles": tiles.duplicate()}

## map is the save's "map" object; width/height were already set from it.
func decode(map: Dictionary) -> void:
	tiles = Array(map["tiles"], TYPE_STRING, "", null)

## Adds this grid's state_hash() entries to snapshot (see the class doc for what is left out).
func hash_into(snapshot: Dictionary) -> void:
	snapshot["width"] = width
	snapshot["height"] = height
	snapshot["tiles"] = tiles

func get_tile(x: int, y: int) -> String:
	return tiles[tile_index(x, y)]

func get_tiles() -> Array[String]:
	return tiles.duplicate()

func tile_index(x: int, y: int) -> int:
	return y * width + x

## Appends to the dirty-cell log. Duplicates are left in (a tile dug then built
## on is two real changes); a reader keys its consumed index by Array size.
func mark_dirty(x: int, y: int) -> void:
	dirty_cells.append(Vector2i(x, y))
	if dirty_cells.size() > MAX_DIRTY_CELLS:
		var drop := dirty_cells.size() - RETAINED_DIRTY_CELLS
		dirty_cells = dirty_cells.slice(drop)
		dirty_base += drop

## The retained cells whose tile kind or object changed, in order: append-only,
## never cleared (the viewer-purity rule allows only get_*/apply/tick/get_events,
## so this cannot be a clear-on-read drain).
func get_dirty_cells() -> Array[Vector2i]:
	return dirty_cells.duplicate()

## The dirty-cell log as a cursor stream (A6): {"cells", "next", "truncated"}.
## "cells" are the retained entries from absolute position `cursor` on, in
## order; "next" is the cursor for the following call; "truncated" is true when
## retention already dropped entries at or after `cursor`.
func get_dirty_cells_since(cursor: int) -> Dictionary:
	var start := clampi(cursor - dirty_base, 0, dirty_cells.size())
	return {"cells": dirty_cells.slice(start), "next": dirty_base + dirty_cells.size(), "truncated": cursor < dirty_base}

func get_regions() -> RegionMapType:
	if regions == null:
		regions = RegionMapType.new(width, height, func(x, y): return _passability.call(x, y)["passable"])
	return regions

func get_water_tiles() -> Array[Vector2i]:
	if not water_tile_cache_built:
		for y in height:
			for x in width:
				if tiles[tile_index(x, y)] == TILE_WATER:
					water_tile_cache.append(Vector2i(x, y))
		water_tile_cache_built = true
	return water_tile_cache

## Keeps the water cache in sync at the "tile actually changed kind" boundary
## (e.g. forage turning a water tile under a berry bush into floor), so a
## former water tile is never offered as a water source. A no-op until built.
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
		rooms = RoomMapType.new(width, height, func(x, y): return _passability.call(x, y)["passable"],
			func(x, y): return bool(_passability.call(x, y)["is_door"]), func(x, y): return _get_object.call(x, y) == "bed",
			_is_in_any_zone)
	return rooms

## {} for a tile with no recognised room; otherwise RoomMapType.get_room_at().
func get_room_at(x: int, y: int) -> Dictionary:
	return get_rooms().get_room_at(x, y)
