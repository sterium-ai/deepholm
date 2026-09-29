class_name ToolItemStore
extends RefCounted

## Identity-bearing tool item CRUD + reservation lifecycle (axe/pick: a stable
## id and a location -- ground, held, or stockpile -- distinct from
## WorldState._items' stackable piles), extracted out of world_state.gd purely
## to keep that file under its line budget (docs/architecture/
## core-budgets.json). Holds exactly the state world_state.gd owned directly
## before (items, next_id, reservations); state_hash()/state_codec.gd read and
## rebuild them through the plain fields below exactly as they read any other
## WorldState-owned collection. find_colonist is injected (not a WorldState
## reference) so this stays plain data-in/data-out like WorldState's other
## injected collaborators (colonist-ai.md/AGENTS.md's simulation rules).

const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")

var items: Dictionary = {}
var next_id: int = 1
var reservations: ReservationTableType = ReservationTableType.new()

var _find_colonist: Callable

func _init(find_colonist: Callable) -> void:
	_find_colonist = find_colonist

## Every tool item, id-sorted for determinism, detached. Each entry's
## "location" is one of {"type":"ground","x","y"}, {"type":"held","colonist_id"}
## or {"type":"stockpile","x","y"}.
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

## Declares a new tool item lying on the ground at (x, y) and returns its id.
## Caller (WorldState.spawn_ground_tool_item) already checked kind is a
## declared tool kind.
func spawn_ground(kind: String, x: int, y: int) -> String:
	var item_id := "tool_%d" % next_id
	next_id += 1
	items[item_id] = {"id": item_id, "kind": kind, "location": {"type": "ground", "x": x, "y": y}}
	return item_id

## Moves an existing tool item to lie on the ground, clearing held_tool and
## releasing whatever job reservation it carried. False when item_id unknown.
func set_ground(item_id: String, x: int, y: int) -> bool:
	if not items.has(item_id):
		return false
	_clear_holder(item_id)
	_release_reservation_for_drop(item_id)
	items[item_id]["location"] = {"type": "ground", "x": x, "y": y}
	return true

## Moves an existing tool item onto a stockpile cell, same as set_ground().
## False when item_id is unknown.
func set_stockpile(item_id: String, x: int, y: int) -> bool:
	if not items.has(item_id):
		return false
	_clear_holder(item_id)
	_release_reservation_for_drop(item_id)
	items[item_id]["location"] = {"type": "stockpile", "x": x, "y": y}
	return true

## Moves an existing tool item into colonist_id's hand. False when
## item_id/colonist_id is unknown, or colonist_id already holds a different
## item -- a caller must drop/move that item first.
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

## Clears held_tool from whichever colonist currently holds item_id, if it is
## currently held by one; a no-op otherwise.
func _clear_holder(item_id: String) -> void:
	var location: Dictionary = (items.get(item_id, {}) as Dictionary).get("location", {})
	if String(location.get("type", "")) != "held":
		return
	var colonist: Dictionary = _find_colonist.call(String(location["colonist_id"]))
	if not colonist.is_empty() and WorkerType.get_held_tool(colonist) == item_id:
		WorkerType.clear_held_tool(colonist)

## Releases whatever job reservation item_id currently carries, for an
## explicit drop -- distinct from set_held()'s pickup path, which must NOT
## clear the picking-up job's own reservation.
func _release_reservation_for_drop(item_id: String) -> void:
	var owner_job_id := reservations.owner(item_id)
	if not owner_job_id.is_empty():
		reservations.release(item_id, owner_job_id)

## Reserves item_id for job_id, refusing an item already reserved by another job.
func reserve(item_id: String, job_id: String) -> bool:
	if not items.has(item_id):
		return false
	return reservations.acquire(item_id, job_id)

## Releases item_id's reservation; call on every terminal job transition so no
## reservation ever outlives its job.
func release(item_id: String, job_id: String) -> bool:
	return reservations.release(item_id, job_id)

func reservation_of(item_id: String) -> String:
	return reservations.owner(item_id)

func is_reserved(item_id: String) -> bool:
	return reservations.is_reserved(item_id)

func release_all(job_id: String) -> void:
	reservations.release_all(job_id)
