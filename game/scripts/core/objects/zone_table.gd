class_name ZoneTable
extends RefCounted

## Zones: id -> {id, x, y, width, height} rectangles and the id counter. A stockpile zone has
## no "kind" key; a farm zone (F1) adds {"kind": "farm", "crop": <crops.json id>}.
## Invariants:
## - Ids are "zone_%d" drawn from next_zone_id and never reused; zones never
##   overlap (zone_add checks overlaps() first).
## - Zones are rectangle bookkeeping only: adding or removing one never
##   acquires or releases a reservation.
## - Only stockpile zones store items: is_in_any_zone() and get_stockpile_zones() skip farm
##   zones, so an item lying on a farm tile is hauled like any loose item.
## - state_hash() covers zones and next_zone_id (hash_into()); both are persisted.

const FARM_KIND := "farm"

var zones: Dictionary = {}
var next_zone_id: int = 1

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

## The farm zones only, id-sorted copies (FarmGiver's work list).
func get_farm_zones() -> Array[Dictionary]:
	return get_zones().filter(func(zone: Dictionary) -> bool: return zone.get("kind", "") == FARM_KIND)

## zone_add's mutation: returns the new zone's id. crop is set for a farm zone only.
func add(x: int, y: int, width: int, height: int, crop: String = "") -> String:
	var zone_id := "zone_%d" % next_zone_id
	next_zone_id += 1
	zones[zone_id] = {"id": zone_id, "x": x, "y": y,
		"width": width, "height": height}
	if not crop.is_empty():
		zones[zone_id]["kind"] = FARM_KIND
		zones[zone_id]["crop"] = crop
	return zone_id

## zone_remove's mutation: returns the removed rectangle.
func remove(zone_id: String) -> Dictionary:
	var removed: Dictionary = zones[zone_id]
	zones.erase(zone_id)
	return removed

## is_in_any_zone callable for HaulGiver, ConstructionGiver, ItemTable and rooms.gd's has_stockpile:
## true inside a stockpile zone (a farm zone stores nothing, see the class doc).
func is_in_any_zone(x: int, y: int) -> bool:
	for zone: Dictionary in zones.values():
		if zone.has("kind"):
			continue
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		if x >= zx and x < zx + int(zone["width"]) and y >= zy and y < zy + int(zone["height"]):
			return true
	return false

## Half-open interval overlap test on both axes.
func overlaps(x: int, y: int, width: int, height: int) -> bool:
	for zone in zones.values():
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		var zw: int = zone["width"]
		var zh: int = zone["height"]
		if x < zx + zw and zx < x + width and y < zy + zh and zy < y + height:
			return true
	return false
