class_name ToolItemStore
extends RefCounted

## Identity-bearing tool items (axe/pick): a stable id and a location (ground, held or
## stockpile), unlike ItemTable's stackable piles, plus their job reservations. A ground tool a
## haul_tool job left on the ground (F5a-b: set down by a failed job, or hauled out of a rejecting
## stockpile onto the ground beside it) also carries "set_down": true until it is stocked or held
## again, so HaulGiver re-plans it whatever the zone filters say by then.
## state_hash() and StateCodec read items, next_id and reservations directly.

const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")

var items: Dictionary = {}
var next_id: int = 1
var reservations: ReservationTableType = ReservationTableType.new()

var _find_colonist: Callable

func _init(find_colonist: Callable) -> void:
	_find_colonist = find_colonist

## Every tool item, id-sorted, detached; "location" is ground {x, y}, held {colonist_id} or stockpile {x, y}.
func get_items() -> Array[Dictionary]:
	var keys := items.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		copy.append((items[key] as Dictionary).duplicate(true))
	return copy

## {} when item_id is unknown.
func get_item(item_id: String) -> Dictionary:
	if not items.has(item_id):
		return {}
	return (items[item_id] as Dictionary).duplicate(true)

## A new tool on the ground at tile; the caller already checked kind is a tool kind.
func spawn_ground(kind: String, tile: Vector3i) -> String:
	var item_id := "tool_%d" % next_id
	next_id += 1
	items[item_id] = {"id": item_id, "kind": kind, "location": {"type": "ground", "x": tile.x, "y": tile.y, "z": tile.z}}
	return item_id

## To the ground, clearing held_tool and releasing its reservation; false when unknown.
## set_down marks a tool a haul_tool job left on the ground (see above); any other drop clears it.
func set_ground(item_id: String, tile: Vector3i, set_down: bool = false) -> bool:
	if not items.has(item_id):
		return false
	_clear_holder(item_id)
	_release_reservation_for_drop(item_id)
	items[item_id]["location"] = {"type": "ground", "x": tile.x, "y": tile.y, "z": tile.z}
	_mark_set_down(item_id, set_down)
	return true

## Onto a stockpile cell, like set_ground().
func set_stockpile(item_id: String, tile: Vector3i) -> bool:
	if not items.has(item_id):
		return false
	_clear_holder(item_id)
	_release_reservation_for_drop(item_id)
	items[item_id]["location"] = {"type": "stockpile", "x": tile.x, "y": tile.y, "z": tile.z}
	_mark_set_down(item_id, false)
	return true

## Whether a ground or stockpile tool lies on cell (a held tool lies nowhere).
func lies_at(cell: Vector3i) -> bool:
	for item: Dictionary in items.values():
		var location: Dictionary = item["location"]
		if String(location["type"]) in ["ground", "stockpile"] and TileGrid.tile_of(location) == cell:
			return true
	return false

## Into colonist_id's hand; false when either is unknown or the hand holds another tool.
func set_held(item_id: String, colonist_id: String) -> bool:
	if not items.has(item_id):
		return false
	var colonist: Dictionary = _find_colonist.call(colonist_id)
	if colonist.is_empty():
		return false
	var current_held := WorkerType.get_held_tool(colonist)
	if not current_held.is_empty() and current_held != item_id:
		return false
	_clear_holder(item_id)
	items[item_id]["location"] = {"type": "held", "colonist_id": colonist_id}
	_mark_set_down(item_id, false)
	WorkerType.set_held_tool(colonist, item_id)
	return true

## Stored sparsely: the key is present only while true.
func _mark_set_down(item_id: String, set_down: bool) -> void:
	if set_down:
		items[item_id]["set_down"] = true
	else:
		(items[item_id] as Dictionary).erase("set_down")

## Clears held_tool from item_id's holder, if any.
func _clear_holder(item_id: String) -> void:
	var location: Dictionary = (items.get(item_id, {}) as Dictionary).get("location", {})
	if String(location.get("type", "")) != "held":
		return
	var colonist: Dictionary = _find_colonist.call(String(location["colonist_id"]))
	if not colonist.is_empty() and WorkerType.get_held_tool(colonist) == item_id:
		WorkerType.clear_held_tool(colonist)

## For an explicit drop only: a pickup must keep the picking-up job's reservation.
func _release_reservation_for_drop(item_id: String) -> void:
	var owner_job_id := reservations.owner(item_id)
	if not owner_job_id.is_empty():
		reservations.release(item_id, owner_job_id)

## Reserves item_id for job_id, refusing an item already reserved by another job.
func reserve(item_id: String, job_id: String) -> bool:
	if not items.has(item_id):
		return false
	return reservations.acquire(item_id, job_id)

## Called on every terminal job transition, so no reservation outlives its job.
func release(item_id: String, job_id: String) -> bool:
	return reservations.release(item_id, job_id)

func reservation_of(item_id: String) -> String:
	return reservations.owner(item_id)

func is_reserved(item_id: String) -> bool:
	return reservations.is_reserved(item_id)

func release_all(job_id: String) -> void:
	reservations.release_all(job_id)
