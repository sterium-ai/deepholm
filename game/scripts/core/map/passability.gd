class_name Passability
extends RefCounted

## The movement and faction rules (ADR 014, F3/F5): whether a tile and its
## object can be crossed, at what cost, and by which faction (doors), plus the
## faction rules for ordering and reserving colony items. Reads the sibling
## TileGrid/ObjectTable; actor factions arrive as Callables. Holds no state of
## its own, so it is neither persisted nor hashed.
##
## Invariants:
## - passability() is the one authoritative movement rule: out of bounds and
##   an unknown object kind are impassable; an impassable object blocks its
##   tile; a passable one supplies its own move cost instead of the tile's.
## - faction_id only matters for a door; it defaults to "colony".
## - Every faction rule fails open (true) for a faction id the registry does
##   not declare, so a lookup miss never silently blocks doors or orders.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")

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

func _init(content: ContentRegistryType, tile_grid: TileGridType, object_table: ObjectTableType,
		object_definitions: Dictionary, tile_definitions: Dictionary, actor_faction: Callable, find_colonist: Callable) -> void:
	_content = content
	_tile_grid = tile_grid
	_object_table = object_table
	_object_definitions = object_definitions
	_tile_definitions = tile_definitions
	_actor_faction = actor_faction
	_find_colonist = find_colonist

func passability(x: int, y: int, faction_id: String = "colony") -> Dictionary:
	if x < 0 or x >= _tile_grid.width or y < 0 or y >= _tile_grid.height:
		return {"passable": false, "cost": 0, "is_door": false}
	var object_kind := _object_table.get_object(x, y)
	if not object_kind.is_empty():
		var object_definition: Dictionary = _object_definitions.get(object_kind, {})
		if object_definition.is_empty():
			return {"passable": false, "cost": 0, "is_door": false}
		var is_door := bool(object_definition.get("is_door", false))
		if is_door and not _faction_may_pass_doors(faction_id):
			return {"passable": false, "cost": 0, "is_door": true}
		var object_passable := bool(object_definition.get("passable", false))
		return {
			"passable": object_passable,
			"cost": int(object_definition.get("move_cost", 0)) if object_passable else 0,
			"is_door": is_door
		}
	var tile_kind := _tile_grid.get_tile(x, y)
	var tile_definition: Dictionary = _tile_definitions.get(tile_kind, {})
	var tile_passable := bool(tile_definition.get("passable", false))
	return {"passable": tile_passable, "cost": int(tile_definition.get("move_cost", 0)) if tile_passable else 0, "is_door": false}

## rules.may_pass_doors (ADR 014) for a door object.
func _faction_may_pass_doors(faction_id: String) -> bool:
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_pass_doors", true))

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

## GlobalAssignment.set_order_eligibility() (F3): checked for every worker
## before it may be proposed for any job (the gate that reaches haul). A
## trapped actor may never be ordered; an unknown id fails open.
func colonist_may_be_ordered(colonist_id: String) -> bool:
	if _find_colonist.call(colonist_id).get("trapped") != null: return false
	return faction_may_be_ordered(_actor_faction.call(colonist_id))

## GlobalAssignment.set_reservation_gate() (F3): checked before a reserve
## step or a resume's reactivate(), never after, so a refused actor never
## transiently holds a reservation.
func colonist_may_reserve_colony_items(colonist_id: String) -> bool:
	return faction_may_reserve_colony_items(_actor_faction.call(colonist_id))

## RouteSearch's colony cost callable (also GlobalAssignment.restore_scheduling()'s).
func is_passable(tile: Vector2i) -> float:
	return float(passability(tile.x, tile.y)["cost"])

## Faction-aware cost callable (IncidentScheduler's spawn/target selection): the
## colony-only is_passable() would let wildlife use a tile only reachable through a door.
func passable_for_faction(tile: Vector2i, faction_id: String) -> float:
	return float(passability(tile.x, tile.y, faction_id)["cost"])

## GlobalAssignment's autonomous passability (F5): an incident actor routes under its own faction.
func passable_for_worker(actor_id: String, tile: Vector2i) -> float:
	return passable_for_faction(tile, _actor_faction.call(actor_id))

## CombatGiver's flee-candidate check: the full passability() under the actor's own faction.
func passable_for_flee(actor_id: String, x: int, y: int) -> Dictionary:
	return passability(x, y, _actor_faction.call(actor_id))

## CombatGiver's region check for a flee candidate, so it never picks a
## passable tile in a pocket disconnected from the actor.
func region_reachable(from: Vector2i, target: Vector2i) -> bool:
	return _tile_grid.get_regions().reachable(from, target)
