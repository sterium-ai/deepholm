class_name ZoneTable
extends RefCounted

## Zones: id -> {id, x, y, z, width, height} rectangles on layer z and the id counter. A stockpile zone has
## no "kind" key; a farm zone (F1) adds {"kind": "farm", "crop": <crops.json id>}, a forest zone
## (F6a, ADR 067) {"kind": "forest"}.
## A stockpile (F5a, ADR 064) may add "groups" (sorted item groups it accepts) and "priority"
## (1-3); each key is absent at its default (every group, priority 2), so an unconfigured
## stockpile is the pre-F5a record and hashes as before.
## Invariants:
## - Ids are "zone_%d" drawn from next_zone_id and never reused; zones never
##   overlap (zone_add checks overlaps() first).
## - Zones are rectangle bookkeeping only: adding or removing one never
##   acquires or releases a reservation.
## - Only stockpile zones store items: is_in_any_zone() and get_stockpile_zones() skip farm and
##   forest zones, so an item lying on one of their tiles is hauled like any loose item.
## - state_hash() covers zones and next_zone_id (hash_into()); both are persisted.
## - An item's group is its items.json "kind"; item_groups lists every group some item has.

const TileGridType = preload("res://scripts/core/map/tile_grid.gd")

const FARM_KIND := "farm"
const FOREST_KIND := "forest"
const MIN_PRIORITY := 1
const DEFAULT_PRIORITY := 2
const MAX_PRIORITY := 3
## stockpiles_for_item()'s distance to a stockpile on another layer: after any on the item's layer.
const OTHER_LAYER_DISTANCE := 1 << 30

var zones: Dictionary = {}
var next_zone_id: int = 1
## Sorted distinct items.json kinds: the groups a stockpile filter can name.
var item_groups: Array[String] = []
## item id -> its group.
var _group_of: Dictionary = {}

## item_definitions: WorldState's items.json entries by id.
func _init(item_definitions: Dictionary = {}) -> void:
	for item_id: String in item_definitions:
		var entry: Dictionary = item_definitions[item_id]
		var group: String = entry.get("kind", "")
		_group_of[item_id] = group
	item_groups = groups_of(item_definitions.values())

## The sorted distinct "kind"s of items.json entries (SaveIO's save rules use it too).
static func groups_of(item_entries: Array) -> Array[String]:
	var groups: Array[String] = []
	for entry: Dictionary in item_entries:
		var group: String = entry.get("kind", "")
		if not groups.has(group):
			groups.append(group)
	groups.sort()
	return groups

## The save fields this table owns: "zones" and "nextZoneId".
func encode() -> Dictionary:
	return {"zones": StateCodec._encode_zones(zones), "nextZoneId": next_zone_id}

func decode(state: Dictionary) -> void:
	zones = StateCodec._decode_zones(state["zones"])
	next_zone_id = int(state["nextZoneId"])

## Adds this table's state_hash() entries to snapshot.
func hash_into(snapshot: Dictionary) -> void:
	snapshot["zones"] = zones
	snapshot["next_zone_id"] = next_zone_id

func get_zones() -> Array[Dictionary]:
	var keys := zones.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		copy.append((zones[key] as Dictionary).duplicate(true))
	return copy

func get_zone(id: String) -> Dictionary:
	if not zones.has(id):
		return {}
	return (zones[id] as Dictionary).duplicate(true)

## The stockpile zones only, id-sorted copies like get_zones(): haul and tool-drop destinations.
func get_stockpile_zones() -> Array[Dictionary]:
	return get_zones().filter(func(zone: Dictionary) -> bool: return not zone.has("kind"))

## The stockpiles that accept group, id-sorted: ToolDropToil's drop zones with group "tool".
func get_stockpile_zones_for_group(group: String) -> Array[Dictionary]:
	return get_stockpile_zones().filter(func(zone: Dictionary) -> bool:
		return not zone.has("groups") or (zone["groups"] as Array).has(group))

## The farm zones only, id-sorted copies (FarmGiver's work list).
func get_farm_zones() -> Array[Dictionary]:
	return get_zones().filter(func(zone: Dictionary) -> bool: return zone.get("kind", "") == FARM_KIND)

func get_forest_zones() -> Array[Dictionary]:
	return get_zones().filter(func(zone: Dictionary) -> bool: return zone.get("kind", "") == FOREST_KIND)

## zone_add's mutation: returns the new zone's id. crop is set for a farm zone only; forest
## marks a forest zone (which names no crop).
func add(origin: Vector3i, width: int, height: int, crop: String = "", forest: bool = false) -> String:
	var zone_id := "zone_%d" % next_zone_id
	next_zone_id += 1
	zones[zone_id] = {"id": zone_id, "x": origin.x, "y": origin.y, "z": origin.z,
		"width": width, "height": height}
	if not crop.is_empty():
		zones[zone_id]["kind"] = FARM_KIND
		zones[zone_id]["crop"] = crop
	elif forest:
		zones[zone_id]["kind"] = FOREST_KIND
	return zone_id

## zone_remove's mutation: returns the removed rectangle.
func remove(zone_id: String) -> Dictionary:
	var removed: Dictionary = zones[zone_id]
	zones.erase(zone_id)
	return removed

## is_in_any_zone callable for HaulGiver, ConstructionGiver, ItemTable and rooms.gd's has_stockpile:
## true inside a stockpile zone (a farm zone stores nothing, see the class doc).
func is_in_any_zone(tile: Vector3i) -> bool:
	for zone: Dictionary in zones.values():
		if zone.has("kind") or int(zone["z"]) != tile.z:
			continue
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		if tile.x >= zx and tile.x < zx + int(zone["width"]) and tile.y >= zy and tile.y < zy + int(zone["height"]):
			return true
	return false

## zone_set_stockpile's "groups" payload: "a,b" -> ["a", "b"], "" -> [] (names unchecked).
static func parse_groups(text: String) -> Array[String]:
	var groups: Array[String] = []
	if not text.is_empty():
		groups.assign(text.split(","))
	return groups

## zone_set_stockpile's mutation: groups (validated names) and priority, stored sparsely.
func set_stockpile(zone_id: String, groups: Array[String], priority: int) -> void:
	var zone: Dictionary = zones[zone_id]
	var sorted := groups.duplicate()
	sorted.sort()
	zone.erase("groups")
	zone.erase("priority")
	if sorted != item_groups:
		zone["groups"] = sorted
	if priority != DEFAULT_PRIORITY:
		zone["priority"] = priority

static func priority_of(zone: Dictionary) -> int:
	var priority: int = zone.get("priority", DEFAULT_PRIORITY)
	return priority

func accepts(zone: Dictionary, item_kind: String) -> bool:
	if zone.has("kind"):
		return false
	return not zone.has("groups") or (zone["groups"] as Array).has(_group_of.get(item_kind, ""))

## HaulGiver's "already stored" test: inside a stockpile that accepts the item's group.
func accepts_item_at(tile: Vector3i, item_kind: String) -> bool:
	for zone: Dictionary in zones.values():
		if _contains(zone, tile):
			return accepts(zone, item_kind)
	return false

## The stockpiles that accept item_kind, highest priority first, then nearest to from (Manhattan
## to the rectangle; a stockpile on another layer ranks after every one on from's layer), then
## zone id: HaulGiver's destination order.
func stockpiles_for_item(item_kind: String, from: Vector3i) -> Array[Dictionary]:
	var ranked: Array[Dictionary] = []
	for zone in get_stockpile_zones():
		if accepts(zone, item_kind):
			zone["_distance"] = _distance_to(zone, from)
			ranked.append(zone)
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if priority_of(a) != priority_of(b):
			return priority_of(a) > priority_of(b)
		var a_distance: int = a["_distance"]
		var b_distance: int = b["_distance"]
		if a_distance != b_distance:
			return a_distance < b_distance
		var a_id: String = a["id"]
		var b_id: String = b["id"]
		return a_id < b_id)
	for zone in ranked:
		zone.erase("_distance")
	return ranked

## Manhattan distance from `from` to the zone rectangle's nearest cell (0 inside it); no planar
## distance across layers, so a zone on another layer is OTHER_LAYER_DISTANCE away.
static func _distance_to(zone: Dictionary, from: Vector3i) -> int:
	var zz: int = zone["z"]
	if zz != from.z:
		return OTHER_LAYER_DISTANCE
	var zx: int = zone["x"]
	var zy: int = zone["y"]
	var zw: int = zone["width"]
	var zh: int = zone["height"]
	return TileGridType.manhattan(from, Vector3i(clampi(from.x, zx, zx + zw - 1), clampi(from.y, zy, zy + zh - 1), zz))

static func _contains(zone: Dictionary, tile: Vector3i) -> bool:
	var zx: int = zone["x"]
	var zy: int = zone["y"]
	var zw: int = zone["width"]
	var zh: int = zone["height"]
	var zz: int = zone["z"]
	return zz == tile.z and tile.x >= zx and tile.x < zx + zw and tile.y >= zy and tile.y < zy + zh

## Half-open interval overlap test on both axes, on origin's layer.
func overlaps(origin: Vector3i, width: int, height: int) -> bool:
	var x := origin.x
	var y := origin.y
	for zone in zones.values():
		if int(zone["z"]) != origin.z:
			continue
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		var zw: int = zone["width"]
		var zh: int = zone["height"]
		if x < zx + zw and zx < x + width and y < zy + zh and zy < y + height:
			return true
	return false
