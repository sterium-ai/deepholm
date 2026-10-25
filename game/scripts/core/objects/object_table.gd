class_name ObjectTable
extends RefCounted

## WorldState's placed objects (ADR 039): kind per occupied tile, plus the
## parallel faction, health, footprint-origin and orientation maps. Plain
## data, no scene/node/wall-clock dependency; it marks changed tiles dirty and
## keeps regions/rooms current through the sibling TileGrid.
##
## Invariants:
## - Every map is keyed "%d_%d" (object_key()). objects/object_factions carry
##   an entry on every footprint tile; object_health and object_orientation
##   only on the origin tile; object_origin only on a non-origin footprint
##   tile (absent means "this tile is its own origin").
## - Factions, health and orientation are parallel maps, never nested inside
##   objects, because StateCodec's object encoding assumes a plain kind String
##   per entry. orientation is absent (never "") when unrotated.
## - set_object() is the only mutator of a placed object: it clears the whole
##   existing footprint first, then marks every touched tile dirty and tells
##   regions/rooms, so their bookkeeping is never skipped.
## - state_hash() covers objects and object_health (hash_into()); a wall's
##   damage changes future combat, so hp must hash. object_factions is
##   deliberately left out; object_origin/object_orientation are re-derived
##   from the persisted per-origin record on decode() and not hashed.

const TileGridType = preload("res://scripts/core/map/tile_grid.gd")

var objects: Dictionary = {}
var object_factions: Dictionary = {}
var object_health: Dictionary = {}
var object_origin: Dictionary = {}
var object_orientation: Dictionary = {}

## content/objects.json indexed by id (WorldState's _object_definitions, shared by reference).
var _object_definitions: Dictionary
var _tile_grid: TileGridType

func _init(object_definitions: Dictionary, tile_grid: TileGridType) -> void:
	_object_definitions = object_definitions
	_tile_grid = tile_grid

## The save field this table owns: "objects" (one record per origin tile).
func encode() -> Dictionary:
	return {"objects": StateCodec._encode_objects(objects, object_factions, object_health, object_origin, object_orientation)}

## Expands each persisted per-origin record back out to every footprint tile.
func decode(state: Dictionary) -> void:
	var decoded_objects: Dictionary = {}
	var decoded_factions: Dictionary = {}
	var decoded_health: Dictionary = {}
	var decoded_origin: Dictionary = {}
	var decoded_orientation: Dictionary = {}
	for record in StateCodec._decode_objects(state["objects"]):
		var origin: Vector2i = record["origin"]
		var origin_key := "%d_%d" % [origin.x, origin.y]
		var kind: String = record["kind"]
		var orientation: String = record["orientation"]
		for tile in object_footprint_tiles(kind, origin, orientation):
			var key := "%d_%d" % [tile.x, tile.y]
			decoded_objects[key] = kind
			decoded_factions[key] = record["factionId"]
			if key != origin_key:
				decoded_origin[key] = origin
		if record.has("health"):
			decoded_health[origin_key] = (record["health"] as Dictionary).duplicate()
		if not orientation.is_empty():
			decoded_orientation[origin_key] = orientation
	objects = decoded_objects
	object_factions = decoded_factions
	object_health = decoded_health
	object_origin = decoded_origin
	object_orientation = decoded_orientation

## Adds this table's state_hash() entries to snapshot (see the class doc for what is left out).
func hash_into(snapshot: Dictionary) -> void:
	snapshot["objects"] = objects
	snapshot["object_health"] = object_health

func get_object(x: int, y: int) -> String:
	return String(objects.get(object_key(x, y), ""))

## "" (like get_object()'s own "none") when no object is placed here.
func get_object_faction_id(x: int, y: int) -> String:
	return String(object_factions.get(object_key(x, y), ""))

func get_objects() -> Array[Dictionary]:
	var keys := objects.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		var coords := String(key).split("_")
		copy.append({"x": int(coords[0]), "y": int(coords[1]), "kind": String(objects[key]),
			"faction_id": String(object_factions.get(key, "colony"))})
	return copy

## (x, y)'s footprint origin: (x, y) itself unless it is a non-origin tile of a multi-tile object.
func object_origin_at(x: int, y: int) -> Vector2i:
	return object_origin.get(object_key(x, y), Vector2i(x, y))

## Kind's declared [w, h] footprint (default [1, 1] on a lookup miss), swapped
## when orientation is "vertical" and the kind is rotatable.
func object_footprint_size(kind: String, orientation: String) -> Vector2i:
	var definition: Dictionary = _object_definitions.get(kind, {})
	var footprint: Array = definition.get("footprint", [1, 1])
	var width := int(footprint[0])
	var height := int(footprint[1])
	if orientation == "vertical" and bool(definition.get("rotatable", false)):
		return Vector2i(height, width)
	return Vector2i(width, height)

## Every tile kind occupies from origin, row-major, origin first: the one place
## set_object() and footprint validation compute this, so they never disagree.
func object_footprint_tiles(kind: String, origin: Vector2i, orientation: String) -> Array[Vector2i]:
	var size := object_footprint_size(kind, orientation)
	var tiles: Array[Vector2i] = []
	for dy in size.y:
		for dx in size.x:
			tiles.append(Vector2i(origin.x + dx, origin.y + dy))
	return tiles

## Places kind with its whole footprint at origin (x, y), or clears with kind "".
## Clearing from any footprint tile erases the whole object; a bare tile still
## marks exactly that one tile. faction_id/orientation default to "colony"/"".
func set_object(x: int, y: int, kind: String, faction_id: String = "colony", orientation: String = "") -> void:
	var origin := Vector2i(x, y)
	var origin_key := object_key(x, y)
	var existing_origin := object_origin_at(x, y)
	var existing_origin_key := object_key(existing_origin.x, existing_origin.y)
	var existing_kind := String(objects.get(existing_origin_key, ""))
	var clear_tiles: Array[Vector2i] = [origin]
	if not existing_kind.is_empty():
		clear_tiles = object_footprint_tiles(existing_kind, existing_origin, String(object_orientation.get(existing_origin_key, "")))
		object_orientation.erase(existing_origin_key)
	for tile in clear_tiles:
		var clear_key := object_key(tile.x, tile.y)
		objects.erase(clear_key)
		object_factions.erase(clear_key)
		object_health.erase(clear_key)
		object_origin.erase(clear_key)
		_tile_grid.mark_dirty(tile.x, tile.y)
		_tile_grid.get_regions().on_passability_changed(tile.x, tile.y)
		_tile_grid.get_rooms().on_passability_changed(tile.x, tile.y)
	if kind.is_empty():
		return
	var definition: Dictionary = _object_definitions.get(kind, {})
	for tile in object_footprint_tiles(kind, origin, orientation):
		var key := object_key(tile.x, tile.y)
		objects[key] = kind
		object_factions[key] = faction_id
		if key != origin_key:
			object_origin[key] = origin
		_tile_grid.mark_dirty(tile.x, tile.y)
		_tile_grid.get_regions().on_passability_changed(tile.x, tile.y)
		_tile_grid.get_rooms().on_passability_changed(tile.x, tile.y)
	if definition.has("max_health"):
		object_health[origin_key] = {"hp": int(definition.get("health", definition["max_health"])), "maxHp": int(definition["max_health"])}
	else:
		object_health.erase(origin_key)
	if not orientation.is_empty():
		object_orientation[origin_key] = orientation

## {} when no health-bearing object is here; every footprint tile reports the
## one pool stored at the origin.
func object_health_at(x: int, y: int) -> Dictionary:
	var origin := object_origin_at(x, y)
	return (object_health.get(object_key(origin.x, origin.y), {}) as Dictionary).duplicate()

## Damages the object at (x, y) (any footprint tile), clearing the whole
## object through set_object() at 0 hp. A no-op without a health pool.
func damage_object(x: int, y: int, amount: int) -> void:
	var origin := object_origin_at(x, y)
	var key := object_key(origin.x, origin.y)
	if not object_health.has(key):
		return
	var health: Dictionary = object_health[key]
	health["hp"] = maxi(0, int(health["hp"]) - amount)
	if int(health["hp"]) <= 0:
		set_object(origin.x, origin.y, "")

## Backfills full health for an origin whose kind declares max_health but has
## no entry: an older save, or a fixture writing objects[key] directly.
func ensure_object_health() -> void:
	for key in objects.keys():
		if object_origin.has(key):
			continue
		if object_health.has(key):
			continue
		var kind := String(objects[key])
		var definition: Dictionary = _object_definitions.get(kind, {})
		if not definition.has("max_health"):
			continue
		object_health[key] = {"hp": int(definition.get("health", definition["max_health"])), "maxHp": int(definition["max_health"])}

## JSON-safe key for every map above.
func object_key(x: int, y: int) -> String:
	return "%d_%d" % [x, y]
