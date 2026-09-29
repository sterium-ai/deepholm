class_name ToolFetchToil
extends RefCounted

## fetch_tool toil (colonist-ai.md 2/3.3, issue #271): finds (or resumes
## travel toward) the nearest free matching tool -- ground, stockpile, or held
## by another colonist but unreserved -- reserves it, walks there via the
## injected advance_go_to (ToilExecutor's own go_to stepping, reused like a
## re-route with no precomputed path), and hands off to pickup on arrival. No
## matching tool anywhere reports blocked_no_tool through the injected hooks
## instead of stalling the colonist. Extracted out of toil_executor.gd purely
## to keep that file under its line budget (docs/architecture/
## core-budgets.json); every dependency is injected the same way
## ToilExecutor's own route_search_factory already is, so this stays decoupled
## from WorldState and from Godot scene/node state.

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
var _get_colonists: Callable
## ToilExecutor.advance_go_to/_record, bound as callables so this toil can
## drive the same go_to stepping and execution trace without ToilExecutor
## exposing a wider surface than those two methods.
var _advance_go_to: Callable
var _record: Callable
## job_id -> Array[String] of tool ids already proven unreachable within a
## job's current fetch_tool attempt (issue #271 round 3), so the next-nearest
## match is tried instead of the same excluded one forever. Persisted via
## get_excluded()/restore_excluded() below (issue #271 round 6 review/ADR
## 012, state_codec.gd schemaVersion 17): a save/load mid-attempt that forgot
## this set would re-try an already-excluded candidate, changing every
## subsequent tick from an uninterrupted run's.
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

## Read-only counterpart of satisfied(), for callers outside ToilExecutor.
## advance() (WorldState._resume_paused_job(), round 4 review) that must decide
## whether to route/start-work directly or defer entirely to this toil --
## starting a route toward the job target, or the work timer, before this
## check would let a stale route/work state get reused as this toil's own
## travel leg once advance() runs. Deliberately does NOT call satisfied()
## itself: that method's own "already holds a free matching tool" branch
## reserves it as a side effect, and calling that a tick-phase earlier than
## before measurably reordered downstream fair-queue scoring across a long run
## and pushed an already-tight idle-streak bound over its limit
## (test_movement_scheduling_load.gd). Mirrors satisfied()'s own
## same-colonist-holds-it-and-it's-free-or-already-ours logic without ever
## reserving; the real reservation still happens at its original place and
## time, inside advance()'s own satisfied() call.
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

## True once job["kind"] has no needs_tool, or the colonist holds a matching
## item AND job_id owns (or can acquire) its reservation -- kind alone is not
## enough, or a reused held tool would stay unreserved and a different job
## could take it mid-work; already reserved by a different job is not
## satisfied either.
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

## Round 2 review (issue #266): a candidate reserved this same tick may
## already be held by a different, currently BUSY colonist (route or work in
## flight) -- exactly ToolDropToil.waiting_for_handover()'s own "case (b)"
## condition, duplicated here (rather than injected from ToolDropToil, which
## does not exist yet at ToolFetchToil construction time) because
## ToilExecutor.advance()'s own waiting_for_handover() gate only runs BEFORE
## calling this method, so it cannot see a reservation this very call is about
## to create: without this check, advance() below would start travel (or, for
## an already-adjacent holder, arrive and pick up) the same tick the
## reservation lands, stealing the tool out of a busy colonist's hand instead
## of waiting for its own drop_tool toil.
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

## Every tool item id currently held by a DIFFERENT, busy colonist (round 6
## review): advance()'s own first candidate search excludes these so a free
## alternative is preferred over manufacturing a handover wait a farther match
## would have avoided. Reuses _held_by_busy_foreign()'s own case (b) test
## rather than duplicating it.
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

## Read-only counterpart of _route_effective_target() (ToolDropToil's own copy):
## the tile a colonist's current, possibly-still-resolving route is actually
## walking toward.
func _route_effective_target(route: Dictionary) -> Vector2i:
	var rerouting = route.get("rerouting")
	if rerouting != null:
		return rerouting["target"]
	var path: Array = route["path"]
	return path[path.size() - 1]

## Read-only: job_id's currently pursued fetch_tool destination, or null when
## this job does not need fetch_tool at all or has no reservation yet.
## ToolDropToil.is_dropping() calls this (round 2 review) to tell an in-flight
## fetch_tool leg apart from a genuine drop leg -- both can be true at once
## for the SAME colonist (a leftover foreign-reserved tool held while fetching
## an unrelated new one) without the fetch leg's own route ever being a drop.
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

## Persistence (toil_executor.gd/state_codec.gd, issue #271 round 6/ADR 012).
func get_excluded() -> Dictionary:
	return _excluded.duplicate(true)

func restore_excluded(excluded: Dictionary) -> void:
	_excluded = excluded.duplicate(true)

## Whatever tool item job_id currently reserves, or {} when it holds none yet
## (colonist-ai.md 3.4: reservations are the source of truth, not colonist
## state, so a retry after an interrupt finds its own prior reservation here
## rather than searching and reserving a second item).
func _reserved_tool_for(job_id: String) -> Dictionary:
	for item in (_get_tool_items.call() as Array):
		if String(_tool_reservation_of.call(String(item["id"]))) == job_id:
			return item
	return {}

## Finds (or resumes travel toward) the nearest free matching tool -- ground,
## stockpile, or held by another colonist but unreserved -- reserves it, and
## walks there via the injected advance_go_to like a re-route with no
## precomputed path. An unreachable candidate is excluded and the next-nearest
## tried until one works or all are exhausted; only then is blocked_no_tool
## reported.
##
## Round 6 review (issue #266): the search runs TWICE when freshly reserving --
## first excluding every candidate currently held by a busy colonist (issue
## #266's own handover case), falling back to the unfiltered search (which can
## land on a busy-held candidate, exactly as before this round) only when that
## first pass finds nothing. Before this, the plain nearest-match search could
## park a freshly assigned job into an immediate multi-tick handover wait while
## a farther but immediately free tool of the same kind sat unused, even though
## that busy holder's OWN other job was itself eligible work a colonist could
## otherwise be doing -- test_movement_scheduling_load.gd's own "no idle while
## eligible work exists" invariant caught this directly once restored to its
## original, unexempted form (docs/decisions/012-tool-toils.md's "Round 6
## review"). A genuine handover wait (no free match anywhere) still happens
## when it must; this only avoids manufacturing one that a free alternative
## would have avoided.
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
	# Round 2 review: this candidate may have just been reserved from a busy
	# foreign holder this very tick, before ToilExecutor's own
	# waiting_for_handover() gate ever gets a chance to run again -- checked
	# here, before any travel/pickup starts, not merely on the next call.
	if not _held_by_busy_foreign(item_id, String(colonist["id"])).is_empty():
		return
	var target = ToolMatchingType.item_target(reserved, _colonist_position_map())
	if target == null:
		_exclude_candidate(job_id, item_id)
		return
	# Round 2 review: a reservation freshly (re)acquired this call -- there was
	# none a moment ago -- means the PREVIOUS attempt's own route, if any, was
	# frozen while waiting_for_handover() blocked this toil from running (or
	# simply abandoned after an exclusion): its target is stale the instant a
	# holder's own drop_tool toil physically moves the item, and
	# advance_go_to() never re-targets an already-resolved route on its own, so
	# it must be discarded here to search fresh toward `target`. Gated to
	# freshly_reserved only: an ALREADY-held reservation's target legitimately
	# drifts tick to tick while its idle holder simply walks around (never
	# releasing/re-reserving), and that ordinary case must keep following the
	# same already-in-flight route rather than restarting it every tick.
	if freshly_reserved:
		var route = colonist.get("route")
		if route != null and _route_effective_target(route) != target:
			colonist["route"] = null
	var passable: Callable = (hooks["go_to_passable"] as Callable).call(job, true, target)
	var on_arrive := func(c: Dictionary, jid: String) -> void: _arrive(c, jid, kind, item_id, hooks)
	if _advance_go_to.call(colonist, job_id, target, passable, TOIL_FETCH_TOOL, on_arrive) == "unreachable":
		_exclude_candidate(job_id, item_id)

## Releases item_id and remembers it as tried-and-unreachable. Deliberately
## does NOT re-enter advance() for the next-nearest candidate in the same tick:
## each candidate's own go_to search already consumes its per-tick
## route-search budget (advance_go_to()/MeasuredRoute.resume()), so chaining
## candidate after candidate here could run an unbounded number of resume()
## calls for one colonist in one tick whenever several candidates in a row
## prove immediately unreachable -- violating ADR 004's aggregate routing
## bound (round 4 review). The next candidate is instead picked up naturally
## on the next tick's ToilExecutor.advance() -> satisfied() -> advance() call,
## which excludes every id _attempts already recorded.
func _exclude_candidate(job_id: String, item_id: String) -> void:
	_release_tool.call(item_id, job_id)
	_exclude(job_id, item_id)

## Clears this job's fetch attempt and reports blocked_no_tool.
func _report_no_tool_found(job_id: String, colonist_id: String, kind: String, hooks: Dictionary) -> void:
	_clear_excluded(job_id)
	(hooks["on_no_tool_found"] as Callable).call(job_id, colonist_id, kind)

## Re-validates the reserved tool is still there and in reach before picking it
## up (mirroring pick_up()'s own re-validation), since travel toward a
## colonist-held tool can outlast the holder standing still. A colonist that
## finished an unrelated job still holding its own now-unreserved tool (e.g. a
## pick, arriving to fetch an axe) drops it to the ground first: set_tool_item_
## held() refuses to hand over a second tool, and dropping it here -- not a
## full drop_tool toil/handover wait, both out of this task's scope -- is the
## minimal behaviour that lets one colonist do more than one needs_tool labour.
func _arrive(colonist: Dictionary, job_id: String, kind: String, item_id: String, hooks: Dictionary) -> void:
	var item: Dictionary = _get_tool_item.call(item_id)
	var owner := String(_tool_reservation_of.call(item_id))
	var target = ToolMatchingType.item_target(item, _colonist_position_map()) if not item.is_empty() else null
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

## Chebyshev "on or adjacent to" reach test (colonist-ai.md 3.3), mirroring
## ToilExecutor's own _within_reach() for pick_up/place.
func _within_reach(colonist: Dictionary, tile: Vector2i) -> bool:
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	return maxi(absi(colonist_tile.x - tile.x), absi(colonist_tile.y - tile.y)) <= 1
