class_name ZoneTable
extends RefCounted

## WorldState's stockpile zones: id -> {id, x, y, width, height} rectangles
## and the id counter. Plain data, no scene/node/wall-clock dependency.
##
## Invariants:
## - Ids are "zone_%d" drawn from next_zone_id and never reused; zones never
##   overlap (zone_add checks overlaps() first).
## - Zones are rectangle bookkeeping only: adding or removing one never
##   acquires or releases a reservation.
## - state_hash() covers zones and next_zone_id (hash_into()); both are persisted.

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

## zone_add's mutation: returns the new zone's id.
func add(x: int, y: int, width: int, height: int) -> String:
	var zone_id := "zone_%d" % next_zone_id
	next_zone_id += 1
	zones[zone_id] = {"id": zone_id, "x": x, "y": y,
		"width": width, "height": height}
	return zone_id

## zone_remove's mutation: returns the removed rectangle.
func remove(zone_id: String) -> Dictionary:
	var removed: Dictionary = zones[zone_id]
	zones.erase(zone_id)
	return removed

## is_in_any_zone callable for HaulGiver, ConstructionGiver, ItemTable and rooms.gd's has_stockpile.
func is_in_any_zone(x: int, y: int) -> bool:
	for zone in zones.values():
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
