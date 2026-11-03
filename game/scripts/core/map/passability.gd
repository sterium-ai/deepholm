class_name Passability
extends RefCounted

## Movement and faction rules (ADR 014): whether a tile and its object can be crossed, at what
## cost and by which faction (doors), plus who may be ordered or reserve colony items.
## Its only state is a per-tile packed cache (A2), neither persisted nor hashed: built on first
## query, refreshed by TileGrid.mark_dirty(), dropped by reset_cells(); a tile whose kind no
## longer matches _kind is recomputed. Direct ObjectTable writes must call reset_cells().
## Invariants:
## - passability() is the one movement rule: out of bounds and unknown objects are impassable;
##   a passable object supplies its own move cost. faction_id only matters for a door.
## - Faction rules fail open (true) for an undeclared faction id.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")

const PASSABLE := 1
const DOOR := 2

var _content: ContentRegistryType
var _tile_grid: TileGridType
var _object_table: ObjectTableType
## content/objects.json and tiles.json indexed by id (WorldState's maps, shared by reference).
var _object_definitions: Dictionary
var _tile_definitions: Dictionary
## (actor_id) -> String: a roster or staged incident actor's faction.
var _actor_faction: Callable
## (colonist_id) -> Dictionary: the live roster actor, {} when unknown.
var _find_colonist: Callable

## The per-tile cache (class doc), sized TileGrid.tiles.size() (every layer) when _built.
var _built := false
var _width := 0
var _flags := PackedByteArray()
var _cost := PackedInt32Array()
var _colony_cost := PackedInt32Array()
var _colony_passable := PackedByteArray()
## Tile index -> the TileGrid.tiles entry the arrays were computed from.
var _kind: Array[String] = []
## faction_id -> bool: _faction_may_pass_doors() (content is frozen).
var _door_rule_by_faction: Dictionary = {}
## Tile kind -> [flags, cost], from _tile_definitions.
var _tile_rule_by_kind: Dictionary = {}

func _init(content: ContentRegistryType, tile_grid: TileGridType, object_table: ObjectTableType,
		object_definitions: Dictionary, tile_definitions: Dictionary, actor_faction: Callable, find_colonist: Callable) -> void:
	_content = content
	_tile_grid = tile_grid
	_object_table = object_table
	_object_definitions = object_definitions
	_tile_definitions = tile_definitions
	_actor_faction = actor_faction
	_find_colonist = find_colonist
	tile_grid.bind_passability(refresh_cell, reset_cells, passable_at, door_at, passable_mask, room_cell_flags)

## The public rule as a Dictionary, for callers outside the hot paths.
func passability(tile: Vector3i, faction_id: String = "colony") -> Dictionary:
	if not _tile_grid.contains(tile):
		return {"passable": false, "cost": 0, "is_door": false}
	var index := _fresh_index(tile)
	var flags := _flags[index]
	if flags & DOOR and not _faction_may_pass_doors(faction_id):
		return {"passable": false, "cost": 0, "is_door": true}
	return {"passable": flags & PASSABLE != 0, "cost": _cost[index], "is_door": flags & DOOR != 0}

## passability(tile)["passable"] (colony) on layer 0: regions' and rooms' planar rule
## (they cover the surface until L3).
func passable_at(x: int, y: int) -> bool:
	if x < 0 or x >= _tile_grid.width or y < 0 or y >= _tile_grid.height:
		return false
	return _colony_passable[_fresh_index(Vector3i(x, y, TileGridType.SURFACE))] == 1

## passability(tile)["is_door"] (any faction) on layer 0, for rooms.
func door_at(x: int, y: int) -> bool:
	if x < 0 or x >= _tile_grid.width or y < 0 or y >= _tile_grid.height:
		return false
	return _flags[_fresh_index(Vector3i(x, y, TileGridType.SURFACE))] & DOOR != 0

## Layer 0's passable_at() as 1/0, row-major (RegionMap's full build).
func passable_mask() -> PackedByteArray:
	_refresh_all()
	return _colony_passable.slice(0, _tile_grid.layer_size())

## Layer 0's passable_at() (bit 1) and door_at() (bit 2), row-major (RoomMap's full build).
func room_cell_flags() -> PackedByteArray:
	_refresh_all()
	var flags := PackedByteArray()
	flags.resize(_tile_grid.layer_size())
	for index in flags.size():
		flags[index] = _colony_passable[index] | (2 if _flags[index] & DOOR else 0)
	return flags

## TileGrid.mark_dirty()'s hook: tile's kind or object changed.
func refresh_cell(tile: Vector3i) -> void:
	if _built:
		_write_cell(_tile_grid.index_of(tile))

## TileGrid.reset_cells()'s hook: rebuilt on the next query.
func reset_cells() -> void:
	_built = false

## tile's index into the arrays (in bounds), built and fresh (class doc).
func _fresh_index(tile: Vector3i) -> int:
	if not _built or _width != _tile_grid.width or _kind.size() != _tile_grid.tiles.size():
		_build()
	var index := _tile_grid.index_of(tile)
	if _tile_grid.tiles[index] != _kind[index]:
		_write_cell(index)
	return index

## Every tile fresh: one native Array comparison when nothing changed.
func _refresh_all() -> void:
	if not _built or _width != _tile_grid.width or _kind.size() != _tile_grid.tiles.size():
		_build()
	elif _kind != _tile_grid.tiles:
		for index in _kind.size():
			if _tile_grid.tiles[index] != _kind[index]:
				_write_cell(index)

func _build() -> void:
	_width = _tile_grid.width
	var size := _tile_grid.tiles.size()
	_kind.resize(size)
	_flags.resize(size)
	_cost.resize(size)
	_colony_cost.resize(size)
	_colony_passable.resize(size)
	_built = true
	for index in size:
		_write_cell(index)

## The rule of the class doc for one tile, into every array.
func _write_cell(index: int) -> void:
	var flags := 0
	var cost := 0
	var tile_kind := _tile_grid.tiles[index] if index < _tile_grid.tiles.size() else ""
	_kind[index] = tile_kind
	var object_kind := String(_object_table.objects.get(index, ""))
	if not object_kind.is_empty():
		var object_definition: Dictionary = _object_definitions.get(object_kind, {})
		if not object_definition.is_empty():
			if bool(object_definition.get("passable", false)):
				flags = PASSABLE
				cost = int(object_definition.get("move_cost", 0))
			if bool(object_definition.get("is_door", false)):
				flags |= DOOR
	elif index < _tile_grid.tiles.size():
		if not _tile_rule_by_kind.has(tile_kind):
			var tile_definition: Dictionary = _tile_definitions.get(tile_kind, {})
			var tile_passable := bool(tile_definition.get("passable", false))
			_tile_rule_by_kind[tile_kind] = [PASSABLE if tile_passable else 0, int(tile_definition.get("move_cost", 0)) if tile_passable else 0]
		var rule: Array = _tile_rule_by_kind[tile_kind]
		flags = rule[0]
		cost = rule[1]
	_flags[index] = flags
	_cost[index] = cost
	var colony_blocked := flags & DOOR != 0 and not _faction_may_pass_doors("colony")
	_colony_cost[index] = 0 if colony_blocked else cost
	_colony_passable[index] = 1 if flags & PASSABLE and not colony_blocked else 0

## rules.may_pass_doors (ADR 014) for a door object.
func _faction_may_pass_doors(faction_id: String) -> bool:
	if _door_rule_by_faction.has(faction_id):
		return _door_rule_by_faction[faction_id]
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	var rule := true
	if not faction.is_empty():
		rule = bool(faction.get("rules", {}).get("may_pass_doors", true))
	_door_rule_by_faction[faction_id] = rule
	return rule

## rules.may_be_ordered (F3): whether faction_id may be named as an order's assignee.
func faction_may_be_ordered(faction_id: String) -> bool:
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_be_ordered", true))

## rules.may_reserve_colony_items (F3), checked before a job's reserve step may stand.
func faction_may_reserve_colony_items(faction_id: String) -> bool:
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_reserve_colony_items", true))

## GlobalAssignment's order-eligibility gate (F3): a trapped actor is never ordered;
## an unknown id fails open.
func colonist_may_be_ordered(colonist_id: String) -> bool:
	if _find_colonist.call(colonist_id).get("trapped") != null: return false
	return faction_may_be_ordered(_actor_faction.call(colonist_id))

## GlobalAssignment's reservation gate (F3), checked before reserving, never after, so a
## refused actor never transiently holds a reservation.
func colonist_may_reserve_colony_items(colonist_id: String) -> bool:
	return faction_may_reserve_colony_items(_actor_faction.call(colonist_id))

## RouteSearch's colony cost callable: passability(tile)["cost"].
func is_passable(tile: Vector3i) -> float:
	if tile.x < 0 or tile.x >= _tile_grid.width or tile.y < 0 or tile.y >= _tile_grid.height or tile.z < 0 or tile.z >= _tile_grid.layer_count:
		return 0.0
	# _fresh_index() inlined: this runs four times per route expansion.
	var index := TileGridType.index_in(tile, _width, _tile_grid.height)
	if not _built or _width != _tile_grid.width or _kind.size() != _tile_grid.tiles.size() or _tile_grid.tiles[index] != _kind[index]:
		index = _fresh_index(tile)
	return float(_colony_cost[index])

## Faction-aware cost callable: is_passable() would let wildlife through colony doors.
func passable_for_faction(tile: Vector3i, faction_id: String) -> float:
	if not _tile_grid.contains(tile):
		return 0.0
	var index := _fresh_index(tile)
	if _flags[index] & DOOR and not _faction_may_pass_doors(faction_id):
		return 0.0
	return float(_cost[index])

## GlobalAssignment's autonomous passability (F5): an incident actor routes under its own faction.
func passable_for_worker(actor_id: String, tile: Vector3i) -> float:
	return passable_for_faction(tile, _actor_faction.call(actor_id))

## CombatGiver's flee-candidate check: the full passability() under the actor's own faction.
func passable_for_flee(actor_id: String, tile: Vector3i) -> Dictionary:
	return passability(tile, _actor_faction.call(actor_id))

## CombatGiver's flee check: never a tile in a pocket disconnected from the actor.
func region_reachable(from: Vector3i, target: Vector3i) -> bool:
	return _tile_grid.get_regions().reachable(from, target)
