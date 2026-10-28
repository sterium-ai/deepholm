class_name ToolFetchToil
extends RefCounted

## fetch_tool toil (colonist-ai.md 2/3.3): reserves the nearest free matching tool (ground,
## stockpile, or held but unreserved), walks there through ToilExecutor's go_to stepping and
## picks it up; with no match it reports blocked_no_tool instead of stalling. Every
## dependency is injected; no WorldState or scene dependency.

const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")

const TOIL_FETCH_TOOL := "fetch_tool"

var _job_kinds: Dictionary
var _get_tool_items: Callable
var _get_tool_item: Callable
var _tool_reservation_of: Callable
var _reserve_tool: Callable
var _release_tool: Callable
var _pick_up_tool: Callable
var _drop_tool_ground: Callable
## WorldState's worker view (A5): the live worker actors, read only.
var _get_colonists: Callable
## ToilExecutor.advance_go_to/_record, bound as callables.
var _advance_go_to: Callable
var _record: Callable
## job_id -> tool ids proven unreachable in the current fetch attempt, so the next-nearest
## is tried. Persisted (ADR 013, "Persistence"): forgetting it on load would change the run.
var _excluded: Dictionary = {}

func _init(job_kinds: Dictionary, get_tool_items: Callable, get_tool_item: Callable,
		tool_reservation_of: Callable, reserve_tool: Callable, release_tool: Callable,
		pick_up_tool: Callable, drop_tool_ground: Callable, get_colonists: Callable,
		advance_go_to: Callable, record: Callable) -> void:
	_job_kinds = job_kinds
	_get_tool_items = get_tool_items
	_get_tool_item = get_tool_item
	_tool_reservation_of = tool_reservation_of
	_reserve_tool = reserve_tool
	_release_tool = release_tool
	_pick_up_tool = pick_up_tool
	_drop_tool_ground = drop_tool_ground
	_get_colonists = get_colonists
	_advance_go_to = advance_go_to
	_record = record

func _tool_kind_for(job: Dictionary) -> String:
	return String(_job_kinds.get(String(job["kind"]), {}).get("needs_tool", ""))

## Read-only counterpart of satisfied() for callers outside advance()
## (NeedsSystem.resume_paused_job(), StateCodec). Never reserves: satisfied() does, and
## reserving a phase earlier reorders fair-queue scoring (test_movement_scheduling_load.gd).
func needs(colonist: Dictionary, job: Dictionary, job_id: String) -> bool:
	var def: Dictionary = _job_kinds.get(String(job["kind"]), {})
	if not (TOIL_FETCH_TOOL in (def.get("toils", []) as Array)):
		return false
	var kind := String(def.get("needs_tool", ""))
	if kind.is_empty():
		return false
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty() or _held_tool_kind(colonist) != kind:
		return true
	var owner := String(_tool_reservation_of.call(held_id))
	return not (owner == job_id or owner.is_empty())

## True once the kind needs no tool, or the colonist holds a matching tool whose reservation
## job_id owns or can acquire (a held tool must be reserved, or another job could take it).
func satisfied(colonist: Dictionary, job: Dictionary, job_id: String) -> bool:
	var kind := _tool_kind_for(job)
	if kind.is_empty():
		return true
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty() or _held_tool_kind(colonist) != kind:
		return false
	var owner := String(_tool_reservation_of.call(held_id))
	if owner == job_id:
		return true
	if not owner.is_empty():
		return false
	return bool(_reserve_tool.call(held_id, job_id))

func _held_tool_kind(colonist: Dictionary) -> String:
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty():
		return ""
	return String(_get_tool_item.call(held_id).get("kind", ""))

func _colonist_position_map() -> Dictionary:
	return ToolMatchingType.colonist_position_map(_get_colonists.call())

## Owner id when a candidate is held by another, busy colonist, else "". Mirrors
## ToolDropToil.waiting_for_handover() because ToilExecutor's wait gate runs before this
## call creates the reservation; without it the tool would be taken from a busy hand.
func _held_by_busy_foreign(item_id: String, colonist_id: String) -> String:
	var item: Dictionary = _get_tool_item.call(item_id)
	if item.is_empty():
		return ""
	var location: Dictionary = item.get("location", {})
	if String(location.get("type", "")) != "held":
		return ""
	var holder := String(location.get("colonist_id", ""))
	if holder.is_empty() or holder == colonist_id or not _colonist_busy(holder):
		return ""
	return holder

## Every tool held by another, busy colonist: the first search excludes them so a free
## alternative beats a handover wait.
func _busy_held_item_ids(colonist_id: String) -> Array:
	var ids: Array = []
	for item in (_get_tool_items.call() as Array):
		if not _held_by_busy_foreign(String(item["id"]), colonist_id).is_empty():
			ids.append(String(item["id"]))
	return ids

func _colonist_busy(colonist_id: String) -> bool:
	for c in (_get_colonists.call() as Array):
		if String(c["id"]) == colonist_id:
			return c.get("route") != null or c.get("work") != null
	return false

## The tile a colonist's (possibly still resolving) route walks toward; same as ToolDropToil's.
func _route_effective_target(route: Dictionary) -> Vector2i:
	var rerouting: Variant = route.get("rerouting")
	if rerouting != null:
		return rerouting["target"]
	var path: Array = route["path"]
	return path[path.size() - 1]

## job_id's pursued fetch_tool destination, or null when it needs none or has no
## reservation yet. No side effects.
func current_target(colonist: Dictionary, job: Dictionary, job_id: String) -> Variant:
	if not needs(colonist, job, job_id):
		return null
	var reserved := _reserved_tool_for(job_id)
	if reserved.is_empty():
		return null
	return ToolMatchingType.item_target(reserved, _colonist_position_map())

func _excluded_for(job_id: String) -> Array:
	return _excluded.get(job_id, [])

func _exclude(job_id: String, item_id: String) -> void:
	var list: Array = _excluded.get(job_id, [])
	list.append(item_id)
	_excluded[job_id] = list

func _clear_excluded(job_id: String) -> void:
	_excluded.erase(job_id)

## Persistence (StateCodec, ADR 013).
func get_excluded() -> Dictionary:
	return _excluded.duplicate(true)

func restore_excluded(excluded: Dictionary) -> void:
	_excluded = excluded.duplicate(true)

## The tool item job_id reserves, or {}: reservations are the source of truth (colonist-ai.md
## 3.4), so a retry after an interrupt reuses its own reservation.
func _reserved_tool_for(job_id: String) -> Dictionary:
	for item in (_get_tool_items.call() as Array):
		if String(_tool_reservation_of.call(String(item["id"]))) == job_id:
			return item
	return {}

## Reserves and walks to the nearest free matching tool; an unreachable candidate is excluded
## and the next tried, and blocked_no_tool is reported only when all are exhausted. A fresh
## reservation first skips busy-held candidates, so a farther free tool beats a handover
## wait (ADR 013, "Candidate preference").
func advance(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var kind := _tool_kind_for(job)
	var reserved := _reserved_tool_for(job_id)
	var freshly_reserved := reserved.is_empty()
	if freshly_reserved:
		var from := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var excluded: Array = _excluded_for(job_id)
		var colonist_id := String(colonist["id"])
		var found := ToolMatchingType.find_nearest_free_tool(kind, from, job_id,
			_get_tool_items.call(), _tool_reservation_of, _colonist_position_map(),
			excluded + _busy_held_item_ids(colonist_id))
		if not found.get("found", false):
			found = ToolMatchingType.find_nearest_free_tool(kind, from, job_id,
				_get_tool_items.call(), _tool_reservation_of, _colonist_position_map(), excluded)
		if not found.get("found", false):
			_report_no_tool_found(job_id, String(colonist["id"]), kind, hooks)
			return
		_reserve_tool.call(String(found["item_id"]), job_id)
		reserved = _get_tool_item.call(String(found["item_id"]))
	var item_id := String(reserved["id"])
	# The candidate may have just been reserved from a busy holder this tick: check before
	# any travel or pickup starts.
	if not _held_by_busy_foreign(item_id, String(colonist["id"])).is_empty():
		return
	var target: Variant = ToolMatchingType.item_target(reserved, _colonist_position_map())
	if target == null:
		_exclude_candidate(job_id, item_id)
		return
	# A freshly (re)acquired reservation makes any earlier route stale (the holder may have
	# moved the item), so discard it and search fresh. Only then: an already-held
	# reservation keeps following its in-flight route.
	if freshly_reserved:
		var route: Variant = colonist.get("route")
		if route != null and _route_effective_target(route) != target:
			colonist["route"] = null
	var passable: Callable = (hooks["go_to_passable"] as Callable).call(job, true, target)
	var on_arrive := func(c: Dictionary, jid: String) -> void: _arrive(c, jid, kind, item_id, hooks)
	if _advance_go_to.call(colonist, job_id, target, passable, TOIL_FETCH_TOOL, on_arrive) == "unreachable":
		_exclude_candidate(job_id, item_id)

## Releases item_id and records it as unreachable. Does not try the next candidate this tick:
## each go_to search spends the colonist's route budget (ADR 004's per-tick bound).
func _exclude_candidate(job_id: String, item_id: String) -> void:
	_release_tool.call(item_id, job_id)
	_exclude(job_id, item_id)

## Clears this job's fetch attempt and reports blocked_no_tool.
func _report_no_tool_found(job_id: String, colonist_id: String, kind: String, hooks: Dictionary) -> void:
	_clear_excluded(job_id)
	(hooks["on_no_tool_found"] as Callable).call(job_id, colonist_id, kind)

## Re-validates the reserved tool is still there and in reach before picking it up. A
## colonist still holding an unreserved tool from an earlier job drops it on the ground
## first: set_held() refuses a second tool.
func _arrive(colonist: Dictionary, job_id: String, kind: String, item_id: String, hooks: Dictionary) -> void:
	var item: Dictionary = _get_tool_item.call(item_id)
	var owner := String(_tool_reservation_of.call(item_id))
	var target: Variant = ToolMatchingType.item_target(item, _colonist_position_map()) if not item.is_empty() else null
	if item.is_empty() or owner != job_id or target == null or not _within_reach(colonist, target):
		_release_tool.call(item_id, job_id)
		_report_no_tool_found(job_id, String(colonist["id"]), kind, hooks)
		return
	var held_id := String(colonist.get("held_tool", ""))
	if not held_id.is_empty() and held_id != item_id:
		_drop_tool_ground.call(held_id, int(colonist["x"]), int(colonist["y"]))
	if not bool(_pick_up_tool.call(item_id, String(colonist["id"]))):
		_release_tool.call(item_id, job_id)
		_report_no_tool_found(job_id, String(colonist["id"]), kind, hooks)
		return
	_clear_excluded(job_id)
	_record.call(TOIL_FETCH_TOOL, "complete")

## Chebyshev "on or adjacent to" reach test (colonist-ai.md 3.3).
func _within_reach(colonist: Dictionary, tile: Vector2i) -> bool:
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	return maxi(absi(colonist_tile.x - tile.x), absi(colonist_tile.y - tile.y)) <= 1
