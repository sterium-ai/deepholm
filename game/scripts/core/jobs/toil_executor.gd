class_name ToilExecutor
extends RefCounted

## Generic toil execution (colonist-ai.md 3.3): a job kind is data (content/jobs.json
## {kind, labour, toils}) and the fixed toil vocabulary is implemented once here, never as
## per-kind branches. The scheduler satisfies "reserve"; finishing the job satisfies
## "release_all". go_to owns re-routing (colonist-ai.md 3.5) through the injected
## route_search_factory; this module only steps the search object it returns.

## Only for its STATUS_FOUND/STATUS_UNREACHABLE vocabulary; never constructed here.
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToolFetchToilType = preload("res://scripts/core/jobs/tool_fetch_toil.gd")
const ToolDropToilType = preload("res://scripts/core/jobs/tool_drop_toil.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const TOIL_RESERVE := "reserve"
const TOIL_GO_TO := "go_to"
const TOIL_PICK_UP := "pick_up"
const TOIL_WORK := "work"
const TOIL_PLACE := "place"
const TOIL_DEPOSIT := "deposit"
const TOIL_CONSUME := "consume"
const TOIL_FETCH_TOOL := "fetch_tool"
const TOIL_DROP_TOOL := "drop_tool"
const TOIL_RELEASE_ALL := "release_all"
## ADR 040: "deposit" is its own verb (hands -> a site's held_materials, no ground item),
## so "place" never branches on site vs cell.
const VOCABULARY: Array[String] = [
	TOIL_RESERVE, TOIL_GO_TO, TOIL_PICK_UP, TOIL_WORK, TOIL_PLACE, TOIL_DEPOSIT, TOIL_CONSUME, TOIL_FETCH_TOOL, TOIL_DROP_TOOL, TOIL_RELEASE_ALL
]

## Typed failure reasons returned by pick_up/place/deposit.
const REASON_ITEM_NOT_FOUND := "item_not_found"
const REASON_ITEM_OUT_OF_REACH := "item_out_of_reach"
const REASON_HANDS_FULL := "hands_full"
const REASON_NOT_CARRYING := "not_carrying"
const REASON_DESTINATION_BLOCKED := "destination_blocked"
const REASON_SOURCE_GONE := "source_gone"
const REASON_SOURCE_OUT_OF_REACH := "source_out_of_reach"
const REASON_SITE_GONE := "site_gone"

## Execution trace for test_architecture_rules.gd: each toil entered/completed. Never read
## by production code.
var trace: Array[Dictionary] = []
## (actor) -> void after a route step writes x/y: WorldState's ActorIndex.moved (A4).
var on_actor_moved: Callable = func(_actor: Dictionary) -> void: pass

func clear_trace() -> void:
	trace.clear()

func _record(toil: String, phase: String) -> void:
	trace.append({"toil": toil, "phase": phase})

## The content bundle ActorTable.get_component() (ADR 012) resolves a
## colonist's "route" (its "mover" component) against.
var _content
var _job_kinds: Dictionary = {}
var _move_ticks_per_tile: int
var _work_ticks: Dictionary
var _passability: Callable
var _job_lookup: Callable
var _item_lookup: Callable
var _remove_item: Callable
var _place_item: Callable
var _cell_occupied: Callable
var _source_valid: Callable
var _work_progress_get: Callable
var _work_progress_set: Callable
var _work_progress_clear: Callable
## Live re-route searches by colonist id, the same Dictionary as WorldState._reroutes
## (StateCodec rebuilds it). route.rerouting holds only the search's summary(); the codec
## and state_hash() use the full snapshot() from here.
var _reroutes: Dictionary
## fetch_tool toil (colonist-ai.md 2/3.3), built once _job_kinds is loaded.
var _tool_fetch: ToolFetchToilType
## (start, target, passable) -> a fresh bounded RerouteType-shaped search with WorldState's
## map bounds; keeps this module decoupled from both (colonist-ai.md 3.5).
var _route_search_factory: Callable
## colonist_id -> true once its one route resume per tick (ADR 004) is spent; shared with
## GlobalAssignment.set_route_budget() and cleared at the start of every tick, so an
## activation and a fetch_tool leg never resume two searches in the same tick.
var _route_budget: Dictionary
## (job) -> Vector2i: the tile a job's work toil runs on (ToilBindings.work_target_for());
## job["target"] when unset.
var _work_target_for: Callable
## ConstructionSystem's site lookup and deposit (returns units accepted, clamped to need),
## for the "deposit" toil.
var _site_exists: Callable
var _site_deposit: Callable
## drop_tool toil, the handover wait and the destroyed-mid-job path (ADR 013); needs _tool_fetch.
var _tool_drop: ToolDropToilType

## passability(x, y, faction_id) is WorldState.passability(); every call threads the actor's
## own factionId (F5) so a non-colony actor never uses colony door rules. item_lookup,
## remove_item and place_item are ItemTable's ground-item API (ADR 037: units, not whole
## stacks). source_valid(job_id) says a need job's source is still consumable.
## work_progress_get/set/clear are WorkProgress's job-scoped store (colonist-ai.md 3.6):
## an interrupt never loses progress and another job on the tile never inherits it.
func _init(move_ticks_per_tile: int, work_ticks: Dictionary, passability: Callable, job_lookup: Callable,
		content_registry,
		item_lookup: Callable = Callable(), remove_item: Callable = Callable(), place_item: Callable = Callable(),
		cell_occupied: Callable = Callable(), source_valid: Callable = Callable(),
		work_progress_get: Callable = Callable(), work_progress_set: Callable = Callable(),
		work_progress_clear: Callable = Callable(), reroutes: Dictionary = {},
		route_search_factory: Callable = Callable(), get_tool_items: Callable = Callable(),
		get_tool_item: Callable = Callable(), tool_reservation_of: Callable = Callable(),
		reserve_tool: Callable = Callable(), release_tool: Callable = Callable(),
		pick_up_tool: Callable = Callable(), drop_tool_ground: Callable = Callable(),
		get_colonists: Callable = Callable(), route_budget: Dictionary = {},
		get_zones: Callable = Callable(), is_cell_free: Callable = Callable(), drop_tool_stockpile: Callable = Callable(),
		release_all_tool_reservations: Callable = Callable(), tool_reservation_table: Callable = Callable(),
		set_active_drop_item: Callable = Callable(), get_active_drop_item: Callable = Callable(),
		find_colonist: Callable = Callable(), get_assignments: Callable = Callable(),
		work_target_for: Callable = Callable(), site_exists: Callable = Callable(),
		site_deposit: Callable = Callable()) -> void:
	_move_ticks_per_tile = move_ticks_per_tile
	_work_ticks = work_ticks
	_passability = passability
	_job_lookup = job_lookup
	_content = content_registry
	_item_lookup = item_lookup
	_remove_item = remove_item
	_place_item = place_item
	_cell_occupied = cell_occupied
	_source_valid = source_valid
	_work_progress_get = work_progress_get
	_work_progress_set = work_progress_set
	_work_progress_clear = work_progress_clear
	_reroutes = reroutes
	_route_search_factory = route_search_factory
	_route_budget = route_budget
	_work_target_for = work_target_for
	_site_exists = site_exists
	_site_deposit = site_deposit
	_job_kinds = _load_job_kinds()
	_tool_fetch = ToolFetchToilType.new(_job_kinds, get_tool_items, get_tool_item, tool_reservation_of,
		reserve_tool, release_tool, pick_up_tool, drop_tool_ground, get_colonists,
		advance_go_to, _record)
	_tool_drop = ToolDropToilType.new(_job_kinds, work_ticks, passability, cell_occupied, is_cell_free, get_zones,
		tool_reservation_of, get_tool_item, tool_reservation_table, release_all_tool_reservations,
		drop_tool_ground, drop_tool_stockpile, work_progress_clear, reroutes, advance_go_to,
		_record, get_colonists, get_tool_items, set_active_drop_item, get_active_drop_item,
		find_colonist, get_assignments)

## The colonist's "mover" route via ActorTable (ADR 012): the live object, so field writes
## mutate the colonist; a wholesale replacement must still assign colonist["route"].
func _route(colonist: Dictionary):
	var mover_component: Variant = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

func has_kind(kind: String) -> bool:
	return _job_kinds.has(kind)

func get_toils(kind: String) -> Array:
	return (_job_kinds.get(kind, {}).get("toils", []) as Array).duplicate()

func get_labour(kind: String) -> String:
	return String(_job_kinds.get(kind, {}).get("labour", ""))

static func is_known_toil(name: String) -> bool:
	return name in VOCABULARY

## colonist-ai.md 3.6: "work" yes, everything else (pick_up/consume named
## explicitly, go_to/reserve/place/release_all by the same default) no.
static func is_interruptible_toil(name: String) -> bool:
	return name == TOIL_WORK

## go_to toil: begins the route along the assignment's path, or starts work at once when
## already on/adjacent to the target (path.size() <= 1).
func start_assignment(colonist: Dictionary, job_id: String, path: Array, on_arrive: Callable = Callable()) -> void:
	_record(TOIL_GO_TO, "enter")
	if path.size() <= 1:
		if on_arrive.is_valid():
			on_arrive.call(colonist, job_id)
		else:
			start_work(colonist, job_id)
		return
	colonist["route"] = {
		"job_id": job_id,
		"path": path,
		"step": 0,
		"move_ticks_remaining": _move_ticks_per_tile,
		"rerouting": null,
	}

## work toil: fixed duration per kind, resumed from stored progress after an interrupt
## (colonist-ai.md 3.6). A kind without work ticks (haul) is a no-op: colonist.work stays
## null and the caller drives the next toil.
func start_work(colonist: Dictionary, job_id: String) -> void:
	_record(TOIL_GO_TO, "complete")
	var job: Dictionary = _job_lookup.call(job_id)
	if not _work_ticks.has(job["kind"]):
		return
	_record(TOIL_WORK, "enter")
	var ticks_remaining: int = int(_work_ticks[job["kind"]])
	if _work_progress_get.is_valid():
		var stored: Variant = _work_progress_get.call(_work_target(job), job_id)
		if stored != null:
			ticks_remaining = int(stored)
	colonist["work"] = {"job_id": job_id, "ticks_remaining": ticks_remaining}

## work_target_for passthrough; job["target"] when unset.
func _work_target(job: Dictionary) -> Vector2i:
	if _work_target_for.is_valid():
		return _work_target_for.call(job)
	return job["target"]

## Steps the movement timer along a resolved path; true when the next tile became
## impassable (the caller re-routes). on_arrive, when set, replaces start_work() at the end
## (fetch_tool's travel leg).
func advance_route_step(colonist: Dictionary, on_arrive: Callable = Callable()) -> bool:
	var route: Dictionary = _route(colonist)
	var path: Array = route["path"]
	var step: int = int(route["step"])
	var next_tile: Vector2i = path[step + 1]
	if not bool(_passability.call(next_tile.x, next_tile.y, String(colonist.get("factionId", "colony")))["passable"]):
		return true
	route["move_ticks_remaining"] -= 1
	if route["move_ticks_remaining"] > 0:
		return false
	step += 1
	var arrived: Vector2i = path[step]
	colonist["x"] = arrived.x
	colonist["y"] = arrived.y
	on_actor_moved.call(colonist)
	route["step"] = step
	if step == path.size() - 1:
		var job_id: String = route["job_id"]
		colonist["route"] = null
		if on_arrive.is_valid():
			on_arrive.call(colonist, job_id)
		else:
			start_work(colonist, job_id)
	else:
		route["move_ticks_remaining"] = _move_ticks_per_tile
	return false

## go_to toil (colonist-ai.md 3.3/3.5): one tile per _move_ticks_per_tile, re-validating the
## next tile; a blocked tile or a leg with no precomputed path starts a bounded re-route.
## `passable` is the search's cost function; the found path is trimmed against the target's
## true passability so an impassable target (tree, ore) ends one tile short.
## Returns "" while progressing, or "unreachable" with route/work and the reroute entry
## already cleared; the caller resubmits or fails the job.
## record_as/on_arrive let fetch_tool reuse this leg. force_trim_last always drops the last
## tile (a site that is still passable but will become impassable).
func advance_go_to(colonist: Dictionary, job_id: String, target: Vector2i, passable: Callable,
		record_as: String = TOIL_GO_TO, on_arrive: Callable = Callable(), force_trim_last: bool = false) -> String:
	# Step-off rule: on a force-trim target the one-tile path would start work under the
	# coming object, so re-aim at the first passable orthogonal neighbour (N/W/E/S) until the
	# colonist has left the tile.
	if force_trim_last:
		var standing := Vector2i(int(colonist["x"]), int(colonist["y"]))
		if standing == target:
			var step_off := _step_off_tile(standing, String(colonist.get("factionId", "colony")))
			if step_off != standing:
				target = step_off
				force_trim_last = false
	var route: Variant = _route(colonist)
	if route == null:
		_record(record_as, "enter")
		# Never []: entity_validator's _valid_entity_route() needs a tile, and a save can land
		# before the search resolves. Only persistence reads it until the search replaces it.
		var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
		colonist["route"] = {
			"job_id": job_id, "path": [current], "step": 0,
			"move_ticks_remaining": _move_ticks_per_tile, "rerouting": null,
		}
		return _begin_go_to_reroute(colonist, job_id, target, passable, record_as, on_arrive, force_trim_last)
	if route["rerouting"] != null:
		return _resume_go_to_reroute(colonist, route, job_id, target, passable, record_as, on_arrive, force_trim_last)
	if advance_route_step(colonist, on_arrive):
		return _begin_go_to_reroute(colonist, job_id, target, passable, record_as, on_arrive, force_trim_last)
	return ""

func _begin_go_to_reroute(colonist: Dictionary, job_id: String, target: Vector2i, passable: Callable,
		record_as: String = TOIL_GO_TO, on_arrive: Callable = Callable(), force_trim_last: bool = false) -> String:
	var route: Dictionary = _route(colonist)
	var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var search: Variant = _route_search_factory.call(start, target, passable)
	_reroutes[colonist["id"]] = search
	route["rerouting"] = search.summary()
	return _resume_go_to_reroute(colonist, route, job_id, target, passable, record_as, on_arrive, force_trim_last)

func _resume_go_to_reroute(colonist: Dictionary, route: Dictionary, job_id: String, target: Vector2i, passable: Callable,
		record_as: String = TOIL_GO_TO, on_arrive: Callable = Callable(), force_trim_last: bool = false) -> String:
	var colonist_id: String = colonist["id"]
	var search: Variant = _reroutes[colonist_id]
	if not search.is_terminal() and not bool(_route_budget.get(colonist_id, false)):
		search.resume()
		_route_budget[colonist_id] = true
	route["rerouting"] = search.summary()
	if not search.is_terminal():
		return ""
	if search.get_status() == RerouteType.STATUS_FOUND:
		_reroutes.erase(colonist_id)
		var new_path: Array = search.get_path()
		if new_path.size() > 1 and (force_trim_last or not bool(_passability.call(target.x, target.y, String(colonist.get("factionId", "colony")))["passable"])):
			new_path = new_path.slice(0, new_path.size() - 1)
		if new_path.size() <= 1:
			colonist["route"] = null
			if on_arrive.is_valid():
				on_arrive.call(colonist, job_id)
			else:
				start_work(colonist, job_id)
		else:
			colonist["route"] = {
				"job_id": job_id, "path": new_path, "step": 0,
				"move_ticks_remaining": _move_ticks_per_tile, "rerouting": null,
			}
		return ""
	_reroutes.erase(colonist_id)
	colonist["route"] = null
	colonist["work"] = null
	return "unreachable"

## work toil: counts the timer down; on completion clears colonist.work and returns the job
## id ("" while working). The completion effect and release_all stay with the caller.
func advance_work_step(colonist: Dictionary) -> String:
	var work: Dictionary = colonist["work"]
	work["ticks_remaining"] -= 1
	var job_id: String = work["job_id"]
	if work["ticks_remaining"] > 0:
		if _work_progress_set.is_valid():
			var job: Dictionary = _job_lookup.call(job_id)
			_work_progress_set.call(_work_target(job), int(work["ticks_remaining"]), job_id)
		return ""
	colonist["work"] = null
	if _work_progress_clear.is_valid():
		var finished_job: Dictionary = _job_lookup.call(job_id)
		_work_progress_clear.call(_work_target(finished_job))
	_record(TOIL_WORK, "complete")
	return job_id

## pick_up toil (colonist-ai.md 3.3): re-validates the item and reach every call, failing
## typed (also REASON_HANDS_FULL). Moves min(count, stack, free hands) units; count < 0
## means the whole stack. Moving 0 is a no-op success: hands never hold a count-0 entry.
func pick_up(colonist: Dictionary, item_id: String, count: int = -1) -> Dictionary:
	var item: Dictionary = _item_lookup.call(item_id)
	if item.is_empty():
		return {"ok": false, "reason": REASON_ITEM_NOT_FOUND}
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var item_tile := Vector2i(int(item["x"]), int(item["y"]))
	if TileGrid.chebyshev(colonist_tile, item_tile) > 1:
		return {"ok": false, "reason": REASON_ITEM_OUT_OF_REACH}
	var hands_free := InventoryType.free_capacity(colonist)
	if hands_free <= 0:
		return {"ok": false, "reason": REASON_HANDS_FULL}
	var requested: int = int(item["count"]) if count < 0 else count
	var moved: int = mini(mini(requested, int(item["count"])), hands_free)
	if moved <= 0:
		return {"ok": true, "item_id": item_id, "count": 0}
	_remove_item.call(item_id, moved)
	assert(moved > 0, "hands never hold a count-0 entry")
	InventoryType.add_to_hands(colonist, String(item["kind"]), moved)
	_record(TOIL_PICK_UP, "complete")
	return {"ok": true, "item_id": item_id, "count": moved}

## place toil (colonist-ai.md 3.3): re-validates carrying and a free, passable, in-bounds
## cell every call, failing typed. Drops one fresh ground item per hands kind, then clears
## hands; zone membership is not checked here.
func place(colonist: Dictionary, cell: Vector2i) -> Dictionary:
	if not InventoryType.is_carrying(colonist):
		return {"ok": false, "reason": REASON_NOT_CARRYING}
	if not bool(_passability.call(cell.x, cell.y)["passable"]):
		return {"ok": false, "reason": REASON_DESTINATION_BLOCKED}
	if bool(_cell_occupied.call(cell.x, cell.y, colonist.get("id"))):
		return {"ok": false, "reason": REASON_DESTINATION_BLOCKED}
	var placed_ids: Array[String] = []
	for entry in InventoryType.hands_snapshot(colonist):
		placed_ids.append(String(_place_item.call(String(entry["kind"]), int(entry["count"]), cell.x, cell.y)))
	InventoryType.clear_hands(colonist)
	_record(TOIL_PLACE, "complete")
	return {"ok": true, "item_ids": placed_ids}

## deposit toil (ADR 040): re-validates carrying and the site, failing typed. Transfers each
## hands kind clamped to what the site still needs; any excess stays in hands.
func deposit(colonist: Dictionary, site_id: String) -> Dictionary:
	if not InventoryType.is_carrying(colonist):
		return {"ok": false, "reason": REASON_NOT_CARRYING}
	if not bool(_site_exists.call(site_id)):
		return {"ok": false, "reason": REASON_SITE_GONE}
	for entry in InventoryType.hands_snapshot(colonist):
		var accepted: int = int(_site_deposit.call(site_id, String(entry["kind"]), int(entry["count"])))
		if accepted > 0:
			InventoryType.remove_from_hands(colonist, String(entry["kind"]), accepted)
	_record(TOIL_DEPOSIT, "complete")
	return {"ok": true}

## consume toil (colonist-ai.md 3.3): one-tick, all-or-nothing need step. Re-validates the
## job, reach and source_valid(); never mutates needs or the ground itself: the caller
## applies the kind's effect after {"ok": true}.
func consume(colonist: Dictionary, job_id: String) -> Dictionary:
	var job: Dictionary = _job_lookup.call(job_id)
	if job.is_empty():
		return {"ok": false, "reason": REASON_SOURCE_GONE}
	var target: Vector2i = job["target"]
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	if TileGrid.chebyshev(colonist_tile, target) > 1:
		return {"ok": false, "reason": REASON_SOURCE_OUT_OF_REACH}
	if _source_valid.is_valid() and not bool(_source_valid.call(job_id)):
		return {"ok": false, "reason": REASON_SOURCE_GONE}
	_record(TOIL_CONSUME, "complete")
	return {"ok": true}

## Per-colonist toil-sequence advance (colonist-ai.md 3.3): walks job["kind"]'s declared
## toils, reading which is current off the colonist's route/work/hands, never off the kind.
## `hooks` (ToilBindings) supplies only what WorldState may resolve: targets, passability,
## unreachable and completion effects. assignment_path is the scheduler's path for the
## first go_to; later go_to legs start their own bounded search.
func advance(colonist: Dictionary, job_id: String, job: Dictionary, assignment_path: Array, hooks: Dictionary) -> void:
	var toils := get_toils(String(job["kind"]))
	# A destroyed active reservation fails the job before any route interpretation, including
	# is_dropping()'s leg check, which could otherwise misread the fetch leg as a drop.
	if TOIL_FETCH_TOOL in toils and _tool_drop.active_tool_missing(job_id):
		_tool_drop.fail_for_destroyed_tool(colonist, job_id, job, hooks)
		return
	if _tool_drop.is_dropping(colonist, job_id, job, hooks) \
			or (_route(colonist) == null and colonist.get("work") == null and _tool_drop.needs_drop(colonist, job_id)):
		_tool_drop.advance(colonist, job_id, job, hooks)
		if _tool_drop.is_dropping(colonist, job_id, job, hooks): return # still travelling; else fall through same tick
	if TOIL_FETCH_TOOL in toils:
		if not _tool_drop.waiting_for_handover(String(colonist["id"]), job_id).is_empty(): return
		if not _tool_fetch.satisfied(colonist, job, job_id): _tool_fetch.advance(colonist, job_id, job, hooks); return
	# A [go_to, work] shape chains a just-started route/work into its first step the same tick;
	# other shapes advance at most one toil per tick. Read off the toils array, not the kind.
	if "work" in toils:
		if _route(colonist) == null and colonist.get("work") == null:
			_start_current_toil(colonist, job_id, job, toils, assignment_path, hooks)
		if _route(colonist) != null:
			_continue_go_to(colonist, job_id, job, hooks)
		if colonist.get("work") != null:
			var finished_job_id := advance_work_step(colonist)
			if not finished_job_id.is_empty():
				(hooks["on_work_complete"] as Callable).call(finished_job_id)
		return
	if colonist.get("work") != null:
		var finished_job_id := advance_work_step(colonist)
		if not finished_job_id.is_empty():
			(hooks["on_work_complete"] as Callable).call(finished_job_id)
		return
	if _route(colonist) != null:
		_continue_go_to(colonist, job_id, job, hooks)
		return
	_start_current_toil(colonist, job_id, job, toils, assignment_path, hooks)

## Whether the go_to about to run is the job's first leg. Carrying only means "past
## pick_up" for kinds that declare a pick_up (cargo from an interrupted haul does not make a
## dig's only leg "leg two"); hooks["is_first_leg"] overrides it for multi-source site_fetch
## (ADR 038, ToilBindings._toil_is_first_leg()).
func _is_first_leg(toils: Array, colonist: Dictionary, job: Dictionary, hooks: Dictionary) -> bool:
	if not (TOIL_PICK_UP in toils):
		return true
	if hooks.has("is_first_leg"):
		return bool((hooks["is_first_leg"] as Callable).call(job, colonist))
	return not InventoryType.is_carrying(colonist)

## Attempts the current toil once (from _next_toil_index()), only with route and work both
## null. The first go_to uses the precomputed assignment_path; later ones search via
## _continue_go_to().
func _start_current_toil(colonist: Dictionary, job_id: String, job: Dictionary, toils: Array, assignment_path: Array, hooks: Dictionary) -> void:
	var index := _next_toil_index(toils, colonist, job, hooks)
	if index >= toils.size():
		return
	match String(toils[index]):
		"go_to":
			var is_first: bool = _is_first_leg(toils, colonist, job, hooks)
			var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
			var use_assignment_path: bool = is_first and assignment_path.size() > 0 and assignment_path[0] == current
			# go_to_skip_assignment_path: the job was retargeted after the scheduler planned its path,
			# so force a fresh bounded search instead of walking toward a stale target.
			if use_assignment_path and hooks.has("go_to_skip_assignment_path"):
				use_assignment_path = not bool((hooks["go_to_skip_assignment_path"] as Callable).call(job))
			if use_assignment_path:
				start_assignment(colonist, job_id, assignment_path, _arrival_hook(toils, is_first))
			else:
				_continue_go_to(colonist, job_id, job, hooks)
		"work":
			start_work(colonist, job_id)
		"pick_up":
			var item_id: String = (hooks["item_id_for"] as Callable).call(job)
			# pick_up_count_for clamps a site_fetch pick_up to what is still needed, leaving hands
			# free for other kinds; absent, pick_up() takes the whole stack.
			var count := -1
			if hooks.has("pick_up_count_for"):
				count = int((hooks["pick_up_count_for"] as Callable).call(job, colonist))
			var result := pick_up(colonist, item_id, count)
			if result.get("ok", false):
				# Lets site_fetch's planner retarget the next source now that hands are updated.
				if hooks.has("on_pick_up_success"):
					(hooks["on_pick_up_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		"place":
			var cell: Vector2i = (hooks["cell_for"] as Callable).call(job)
			var result := place(colonist, cell)
			if result.get("ok", false):
				(hooks["on_place_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		"deposit":
			var site_id: String = (hooks["site_id_for"] as Callable).call(job)
			var result := deposit(colonist, site_id)
			if result.get("ok", false):
				(hooks["on_deposit_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		"consume":
			var result := consume(colonist, job_id)
			if result.get("ok", false):
				(hooks["on_consume_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		_:
			pass

## The next undone toil ("reserve" excluded) for a colonist with nothing in flight. pick_up
## is done once carrying. A go_to followed by "work" is never pre-empted (only the
## scheduler's path decides whether the target is occupiable); a go_to followed by anything
## else is done once the colonist is within reach of its target.
func _next_toil_index(toils: Array, colonist: Dictionary, job: Dictionary, hooks: Dictionary) -> int:
	var is_first: bool = _is_first_leg(toils, colonist, job, hooks)
	for i in range(toils.size()):
		match String(toils[i]):
			"reserve", "fetch_tool":
				continue
			"go_to":
				var next_toil := String(toils[i + 1]) if i + 1 < toils.size() else ""
				if next_toil == "work":
					return i
				var target: Vector2i = (hooks["go_to_target"] as Callable).call(job, is_first)
				if _within_reach(colonist, target):
					continue
				return i
			"pick_up":
				if not is_first:
					continue
				return i
			_:
				return i
	return toils.size()

## Continues or begins the go_to toward hooks' target for the current leg; on "unreachable"
## calls on_unreachable (resubmit a first leg, fail a later one).
func _continue_go_to(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var toils := get_toils(String(job["kind"]))
	var is_first: bool = _is_first_leg(toils, colonist, job, hooks)
	var target: Vector2i = (hooks["go_to_target"] as Callable).call(job, is_first)
	var passable: Callable = (hooks["go_to_passable"] as Callable).call(job, is_first, target, String(colonist.get("factionId", "colony")))
	var force_trim_last := false
	if hooks.has("go_to_force_trim_last"):
		force_trim_last = bool((hooks["go_to_force_trim_last"] as Callable).call(job, is_first))
	if advance_go_to(colonist, job_id, target, passable, TOIL_GO_TO, _arrival_hook(toils, is_first), force_trim_last) == "unreachable":
		(hooks["on_unreachable"] as Callable).call(job_id, job, is_first)

## The toil after the go_to that is_first selects. Decides the arrival effect: a leg leading
## into pick_up must never auto-start a work timer on arrival (ADR 028).
func _next_toil_after_go_to(toils: Array, is_first: bool) -> String:
	var seen_pick_up := false
	for i in range(toils.size()):
		var name := String(toils[i])
		if name == TOIL_PICK_UP:
			seen_pick_up = true
			continue
		if name != TOIL_GO_TO:
			continue
		if (not seen_pick_up) == is_first:
			return String(toils[i + 1]) if i + 1 < toils.size() else ""
	return ""

## on_arrive for the go_to is_first selects: the default start_work when it leads into a
## work toil, else a no-op so the next toil is dispatched on the following tick.
func _arrival_hook(toils: Array, is_first: bool) -> Callable:
	if _next_toil_after_go_to(toils, is_first) == TOIL_WORK:
		return Callable()
	return Callable(self, "_no_op_arrive")

## Records its own "complete", like every on_arrive; only bound for a genuine go_to.
func _no_op_arrive(_colonist: Dictionary, _job_id: String) -> void:
	_record(TOIL_GO_TO, "complete")

## Chebyshev "on or adjacent to" reach test (colonist-ai.md 3.3).
func _within_reach(colonist: Dictionary, tile: Vector2i) -> bool:
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	return TileGrid.chebyshev(colonist_tile, tile) <= 1

## Read-only counterpart of _tool_fetch.satisfied() for NeedsSystem.resume_paused_job() and StateCodec:
## decides whether to route/start work directly or defer to fetch_tool.
func needs_fetch_tool(colonist: Dictionary, job: Dictionary, job_id: String) -> bool:
	return _tool_fetch.needs(colonist, job, job_id)

## advance_go_to()'s step-off target: the first passable orthogonal neighbour of `tile`
## (N, W, E, S), else `tile` itself.
func _step_off_tile(tile: Vector2i, faction_id: String) -> Vector2i:
	for offset in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var next: Vector2i = tile + offset
		if bool(_passability.call(next.x, next.y, faction_id)["passable"]):
			return next
	return tile

## Read-only counterpart of _arrival_hook() for resumed go_to legs (NeedsSystem,
## WorldState._advance_go_to_or_resubmit()): true only when that leg leads into a work toil.
func leads_into_work(kind: String, is_first: bool) -> bool:
	return _next_toil_after_go_to(get_toils(kind), is_first) == TOIL_WORK

## Passthrough for WorldState.get_jobs()'s handover overlay (tool_handover.gd).
func waiting_for_handover(colonist_id: String, job_id: String) -> Dictionary:
	return _tool_drop.waiting_for_handover(colonist_id, job_id)

## Persistence passthrough: true while the in-flight route is a drop_tool leg, so a restored
## search uses the drop toil's plain passability.
func is_dropping_leg(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> bool:
	return _tool_drop.is_dropping(colonist, job_id, job, hooks)

## Persistence passthrough (ADR 013): job_id -> tool ids proven unreachable in the current
## fetch attempt.
func get_fetch_tool_excluded() -> Dictionary:
	return _tool_fetch.get_excluded()

func restore_fetch_tool_excluded(excluded: Dictionary) -> void:
	_tool_fetch.restore_excluded(excluded)

## job kind -> its jobs.json entry, from the session ContentRegistry (base bundle plus content
## packs), so a pack's job kind runs like a base one (F1: a crop's own sow/harvest jobs).
func _load_job_kinds() -> Dictionary:
	var kinds: Dictionary = {}
	var registry: ContentRegistry = _content
	for entry: Dictionary in registry.list("jobs"):
		kinds[String(entry["kind"])] = entry.duplicate(true)
	return kinds
