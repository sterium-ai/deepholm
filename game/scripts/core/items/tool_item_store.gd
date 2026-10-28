class_name ToolItemStore
extends RefCounted

## Identity-bearing tool items (axe/pick): a stable id and a location (ground, held or
## stockpile), unlike ItemTable's stackable piles, plus their job reservations.
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

## A new tool on the ground at (x, y); the caller already checked kind is a tool kind.
func spawn_ground(kind: String, x: int, y: int) -> String:
	var item_id := "tool_%d" % next_id
	next_id += 1
	items[item_id] = {"id": item_id, "kind": kind, "location": {"type": "ground", "x": x, "y": y}}
	return item_id

## To the ground, clearing held_tool and releasing its reservation; false when unknown.
func set_ground(item_id: String, x: int, y: int) -> bool:
	if not items.has(item_id):
		return false
	_clear_holder(item_id)
	_release_reservation_for_drop(item_id)
	items[item_id]["location"] = {"type": "ground", "x": x, "y": y}
	return true

## Onto a stockpile cell, like set_ground().
func set_stockpile(item_id: String, x: int, y: int) -> bool:
	if not items.has(item_id):
		return false
	_clear_holder(item_id)
	_release_reservation_for_drop(item_id)
	items[item_id]["location"] = {"type": "stockpile", "x": x, "y": y}
	return true

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
	WorkerType.set_held_tool(colonist, item_id)
	return true

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
