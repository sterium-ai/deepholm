class_name ToolDropToil
extends RefCounted

## drop_tool toil, the tool handover wait and the destroyed-mid-job failure path (ADR 013),
## injected into ToilExecutor like tool_fetch_toil.gd; no WorldState or scene dependency.
##  - holder side: a colonist whose held tool is reserved by another job drops it (in place,
##    or at the nearest free stockpile cell within TOOL_DROP_RADIUS) before its next job;
##  - requester side: waiting_for_handover() holds fetch_tool until the tool is dropped. No
##    persisted wait state: dropping releases the tool's reservation, so the requester
##    re-reserves it like any free candidate;
##  - a reserved tool that disappears fails the current toil, releases every reservation of
##    the job and requeues it through on_no_tool_found's backoff.

const TOIL_DROP_TOOL := "drop_tool"
const TOIL_FETCH_TOOL := "fetch_tool"
const TOIL_WORK := "work"
const TOIL_GO_TO := "go_to"
## Small radius a foreign-reserved-tool detour prefers over dropping in place.
const TOOL_DROP_RADIUS := 5

var _job_kinds: Dictionary
var _work_ticks: Dictionary
var _passability: Callable
var _cell_occupied: Callable
var _is_cell_free: Callable
var _get_zones: Callable
var _tool_reservation_of: Callable
var _tool_item_lookup: Callable
var _tool_reservation_table: Callable
var _release_all_tool_reservations: Callable
var _drop_tool_ground: Callable
var _drop_tool_stockpile: Callable
var _work_progress_clear: Callable
var _reroutes: Dictionary
var _advance_go_to: Callable
var _record: Callable
## WorldState's worker view (A5): the live worker actors, read only.
var _get_colonists: Callable
var _get_tool_items: Callable
## Live colonist lookup by id (returns the live record); only _reconcile_stale_holders()
## uses it, to fix a foreign colonist's held_tool.
var _find_colonist: Callable
## WorldState.get_assignments(), to find a foreign holder's active job (the drop-leg marker
## is keyed by job_id).
var _get_assignments: Callable
## Drop-leg identity marker: per job, the tool item id its colonist is dropping right now;
## the only signal is_dropping() reads. Set when a drop starts, cleared when it ends; never
## re-derived from reservations or held_tool. Persisted on the active job's blockingJobId
## (JobQueue.set_active_item_marker()), never itemId, which is a haul's cargo (ADR 013).
var _set_active_item: Callable
var _get_active_item: Callable

func _init(job_kinds: Dictionary, work_ticks: Dictionary, passability: Callable, cell_occupied: Callable,
		is_cell_free: Callable, get_zones: Callable, tool_reservation_of: Callable, tool_item_lookup: Callable,
		tool_reservation_table: Callable, release_all_tool_reservations: Callable, drop_tool_ground: Callable,
		drop_tool_stockpile: Callable, work_progress_clear: Callable, reroutes: Dictionary,
		advance_go_to: Callable, record: Callable, get_colonists: Callable,
		get_tool_items: Callable, set_active_item: Callable, get_active_item: Callable,
		find_colonist: Callable, get_assignments: Callable) -> void:
	_job_kinds = job_kinds
	_work_ticks = work_ticks
	_passability = passability
	_cell_occupied = cell_occupied
	_is_cell_free = is_cell_free
	_get_zones = get_zones
	_tool_reservation_of = tool_reservation_of
	_tool_item_lookup = tool_item_lookup
	_tool_reservation_table = tool_reservation_table
	_release_all_tool_reservations = release_all_tool_reservations
	_drop_tool_ground = drop_tool_ground
	_drop_tool_stockpile = drop_tool_stockpile
	_work_progress_clear = work_progress_clear
	_reroutes = reroutes
	_advance_go_to = advance_go_to
	_record = record
	_get_colonists = get_colonists
	_get_tool_items = get_tool_items
	_set_active_item = set_active_item
	_get_active_item = get_active_item
	_find_colonist = find_colonist
	_get_assignments = get_assignments

## True once the held tool is reserved by a job other than job_id: the decision to start a
## fresh drop, never a leg-continuation check (see is_dropping()).
func needs_drop(colonist: Dictionary, job_id: String) -> bool:
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty():
		return false
	var owner := String(_tool_reservation_of.call(held_id))
	return not owner.is_empty() and owner != job_id

## job_id's reserved tool id, read off the ReservationTable: a destroyed item leaves its
## reservation behind, so only this lookup still finds it.
func _reserved_item_id_for(job_id: String) -> String:
	var owners: Dictionary = (_tool_reservation_table.call() as ReservationTable).snapshot()
	for item_id in owners:
		if String(owners[item_id]) == job_id:
			return String(item_id)
	return ""

## Every item id job_id reserves: a job can hold several, and the ReservationTable's
## iteration order need not surface the destroyed one first.
func _reserved_item_ids_for(job_id: String) -> Array[String]:
	var owners: Dictionary = (_tool_reservation_table.call() as ReservationTable).snapshot()
	var ids: Array[String] = []
	for item_id in owners:
		if String(owners[item_id]) == job_id:
			ids.append(String(item_id))
	return ids

## {} unless job_id's reserved tool is held by another, busy colonist that has not dropped it,
## else {"item_id", "holder_colonist_id"}. ToilExecutor's wait gate and the tool_handover.gd
## overlay share it so they never disagree. An idle holder is never waited on (it would never drop).
func waiting_for_handover(colonist_id: String, job_id: String) -> Dictionary:
	var item_id := _reserved_item_id_for(job_id)
	if item_id.is_empty():
		return {}
	var item: Dictionary = _tool_item_lookup.call(item_id)
	if item.is_empty():
		return {}
	var location: Dictionary = item.get("location", {})
	if String(location.get("type", "")) != "held":
		return {}
	var holder := String(location.get("colonist_id", ""))
	if holder.is_empty() or holder == colonist_id or not _colonist_busy(holder):
		return {}
	return {"item_id": item_id, "holder_colonist_id": holder}

func _colonist_busy(colonist_id: String) -> bool:
	for c in (_get_colonists.call() as Array):
		if String(c["id"]) == colonist_id:
			return c.get("route") != null or c.get("work") != null
	return false

## True once any item id job_id reserves no longer exists, held or still being travelled to;
## a surviving reservation must never mask a destroyed one.
func active_tool_missing(job_id: String) -> bool:
	for item_id in _reserved_item_ids_for(job_id):
		if _tool_item_lookup.call(item_id).is_empty():
			return true
	return false

## Destroyed-mid-job failure: fails the toil actually in flight, releases every reservation
## of job_id, reconciles every stale holder, clears execution state and requeues through
## on_no_tool_found. held_tool is cleared only when the destroyed item is the one held.
func fail_for_destroyed_tool(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var destroyed_ids: Array[String] = []
	for item_id in _reserved_item_ids_for(job_id):
		if _tool_item_lookup.call(item_id).is_empty():
			destroyed_ids.append(item_id)
	var current_toil := _toil_in_flight(colonist, job_id, job, hooks, destroyed_ids)
	_release_all_tool_reservations.call(job_id)
	_reconcile_stale_holders(destroyed_ids)
	colonist["route"] = null; colonist["work"] = null; _reroutes.erase(colonist["id"]); _set_active_item.call(job_id, "")
	if _work_progress_clear.is_valid() and _work_ticks.has(String(job["kind"])):
		_work_progress_clear.call(job["target"])
	var kind := String(_job_kinds.get(String(job["kind"]), {}).get("needs_tool", ""))
	(hooks["on_no_tool_found"] as Callable).call(job_id, String(colonist["id"]), kind)
	_record.call(current_toil, "failed:tool_destroyed")

## The toil driving the colonist now, read off execution state (not off needs(), which
## reports a replacement the instant the tool vanishes): work, a concurrent drop, else
## go_to (return leg) if the destroyed id was held, fetch_tool if not yet picked up.
func _toil_in_flight(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary, destroyed_ids: Array[String]) -> String:
	if colonist.get("work") != null:
		return TOIL_WORK
	if is_dropping(colonist, job_id, job, hooks):
		return TOIL_DROP_TOOL
	if String(colonist.get("held_tool", "")) in destroyed_ids:
		return TOIL_GO_TO
	return TOIL_FETCH_TOOL

## Clears held_tool for whoever physically holds a destroyed id (ToolItemStore cannot once
## the item is gone, and set_held() would refuse that holder forever), and unwinds that
## holder's in-flight drop leg for the same item so its route is not misread next tick.
func _reconcile_stale_holders(destroyed_ids: Array[String]) -> void:
	if destroyed_ids.is_empty():
		return
	var assignments: Dictionary = _get_assignments.call()
	for c in (_get_colonists.call() as Array):
		var held := String(c.get("held_tool", ""))
		if not (held in destroyed_ids):
			continue
		var holder_id := String(c["id"])
		var live: Dictionary = _find_colonist.call(holder_id)
		if live.is_empty():
			continue
		var holder_job_id := String((assignments.get(holder_id, {}) as Dictionary).get("job_id", ""))
		if not holder_job_id.is_empty() and live.get("route") != null and String(_get_active_item.call(holder_job_id)) == held:
			live["route"] = null
			_reroutes.erase(holder_id)
			_set_active_item.call(holder_job_id, "")
		live["held_tool"] = ""

## True while a drop leg started by advance() is in flight: the persisted marker names the
## item the colonist holds. Never derived from reservations, which can flip either way for
## unrelated reasons (ADR 013, "Drop-leg identity marker").
func is_dropping(colonist: Dictionary, job_id: String, _job: Dictionary = {}, _hooks: Dictionary = {}) -> bool:
	var marked := String(_get_active_item.call(job_id))
	return colonist.get("route") != null and not marked.is_empty() \
		and marked == String(colonist.get("held_tool", ""))

func _route_effective_target(route: Dictionary) -> Vector2i:
	var rerouting: Variant = route.get("rerouting")
	if rerouting != null:
		return rerouting["target"]
	var path: Array = route["path"]
	return path[path.size() - 1]

## drop_tool toil: drop in place, or at the nearest free stockpile cell within
## TOOL_DROP_RADIUS chosen once at start, never retargeted mid-travel (ADR 013). Arrival
## re-validates the cell (free, still in a zone) and falls back to dropping in place.
## The marker is set at entry and cleared on every completion path.
func advance(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty():
		colonist["route"] = null; _reroutes.erase(colonist["id"]); _set_active_item.call(job_id, ""); return
	_set_active_item.call(job_id, held_id)
	var route: Variant = colonist.get("route")
	var target: Vector2i
	if route == null:
		var from := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var cell: Variant = _find_drop_cell(from)
		if cell == null:
			_drop_tool_ground.call(held_id, from.x, from.y)
			_record.call(TOIL_DROP_TOOL, "complete")
			_set_active_item.call(job_id, "")
			return
		target = cell
	else:
		target = _route_effective_target(route)
	var passable := func(tile: Vector2i) -> float: return float(_passability.call(tile.x, tile.y)["cost"])
	var on_arrive := func(_c: Dictionary, _jid: String) -> void:
		if _cell_still_free(target, colonist.get("id")) and _in_any_zone(target):
			_drop_tool_stockpile.call(held_id, target.x, target.y)
		else:
			_drop_tool_ground.call(held_id, int(colonist["x"]), int(colonist["y"]))
		_record.call(TOIL_DROP_TOOL, "complete")
		_set_active_item.call(job_id, "")
	if _advance_go_to.call(colonist, job_id, target, passable, TOIL_DROP_TOOL, on_arrive) == "unreachable":
		_drop_tool_ground.call(held_id, int(colonist["x"]), int(colonist["y"]))
		_set_active_item.call(job_id, "")

## Also refuses a cell holding a tool item: the shared cell_occupied callable only checks
## colonists and stackable items.
func _cell_still_free(cell: Vector2i, excluding_colonist_id) -> bool:
	if not (bool(_is_cell_free.call(cell.x, cell.y)) and bool(_passability.call(cell.x, cell.y)["passable"]) \
			and not bool(_cell_occupied.call(cell.x, cell.y, excluding_colonist_id))):
		return false
	for tool_item in (_get_tool_items.call() as Array):
		var location: Dictionary = tool_item.get("location", {})
		if String(location.get("type", "")) in ["ground", "stockpile"] \
				and int(location.get("x", -1)) == cell.x and int(location.get("y", -1)) == cell.y:
			return false
	return true

func _in_any_zone(cell: Vector2i) -> bool:
	for zone in (_get_zones.call() as Array):
		if cell.x >= int(zone["x"]) and cell.x < int(zone["x"]) + int(zone["width"]) \
				and cell.y >= int(zone["y"]) and cell.y < int(zone["y"]) + int(zone["height"]):
			return true
	return false

## Nearest free stockpile cell within TOOL_DROP_RADIUS (HaulGiver.find_free_haul_cell()'s
## checks, read-only). The job's own target is eligible: is_dropping() reads only the marker.
func _find_drop_cell(from: Vector2i) -> Variant:
	if not _get_zones.is_valid():
		return null
	var best: Variant = null
	var best_distance := -1
	for zone in (_get_zones.call() as Array):
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				var cell := Vector2i(x, y)
				if not _cell_still_free(cell, ""):
					continue
				var distance: int = TileGrid.manhattan(cell, from)
				if distance > TOOL_DROP_RADIUS:
					continue
				if best == null or distance < best_distance or (distance == best_distance and (x < best.x or (x == best.x and y < best.y))):
					best = cell; best_distance = distance
	return best
