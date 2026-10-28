class_name NeedsSystem
extends RefCounted

## Colonist needs (colonist-ai.md 3.1/3.6/3.8, ADR 009/012/024): decay and the needs/labour
## backfill, pausing and resuming a colonist's current job around a need (or combat)
## interrupt, the exposed need reason and need_unmet event, the kind-aware source lookups
## and the effect of a completed need job. NeedGiver decides when a need job exists; this
## module is what it depends on.
##
## Invariants:
## - paused_jobs (colonist_id -> job_id) is the only record of a job suspended by an
##   interrupt. It is shared with CombatGiver's flee episode and is persisted
##   ("pausedJobs", sorted by colonist id); it is not part of state_hash().
## - need_status is runtime only: never saved or hashed; a loaded world starts empty.
## - ensure_needs() rebuilds a colonist missing needs/labourTable/health/accumulator in
##   _spawn_colonists()'s field order, never by appending: state_hash() hashes
##   JSON.stringify(colonists), which is sensitive to key insertion order.
## - Need definitions are WorldState's live Dictionary, shared by reference with NeedGiver
##   (tests mutate a kind's rate_per_day in place).

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const NeedsType = preload("res://scripts/core/actors/components/needs.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ToolItemStoreType = preload("res://scripts/core/items/tool_item_store.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const RegionMapType = preload("res://scripts/core/map/regions.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const TrenchSystemType = preload("res://scripts/core/actors/trench_system.gd")

const TILE_WATER := ContentRegistryType.TILE_WATER
const REASON_NEED_UNMET_PREFIX := "need_unmet:"

## colonist_id -> the scheduler job_id a need (or combat) interrupt paused.
var paused_jobs: Dictionary = {}
## colonist_id -> last exposed need reason ("" when none, colonist-ai.md 3.8).
var need_status: Dictionary = {}

var _content: ContentRegistryType
var _need_definitions: Dictionary
var _need_full: int
var _event_priority: int
var _clock: SeededClock
var _calendar: CalendarServiceType
var _scheduler: AssignmentType
var _toils: ToilExecutorType
var _progress_table: WorkProgressType
var _tool_store: ToolItemStoreType
var _item_table: ItemTableType
var _tile_grid: TileGridType
var _object_table: ObjectTableType
var _event_log: EventLogType
var _trench: TrenchSystemType
var _get_colonists: Callable
var _find_colonist: Callable
var _colonist_within_reach: Callable
var _advance_go_to_or_resubmit: Callable
var _combat_owns: Callable
var _route: Callable
var _labour_table: Callable
var _default_labour_table: Callable
var _ensure_health: Callable
var _ensure_combat: Callable
## (old, new) -> void when ensure_needs() swaps a roster entry for a rebuilt Dictionary:
## WorldState's ActorIndex.replaced (A4).
var on_actor_replaced: Callable = func(_old: Dictionary, _new: Dictionary) -> void: pass

## need_definitions is WorldState's live Dictionary (by reference); event_priority is
## WorldState.PRIORITY_TICK. get_colonists is a lambda: StateCodec.decode() reassigns
## WorldState._colonists.
func _init(content: ContentRegistryType, need_definitions: Dictionary, need_full: int, event_priority: int,
		clock: SeededClock, calendar: CalendarServiceType, scheduler: AssignmentType, toils: ToilExecutorType,
		progress_table: WorkProgressType, tool_store: ToolItemStoreType, item_table: ItemTableType,
		tile_grid: TileGridType, object_table: ObjectTableType, event_log: EventLogType, trench: TrenchSystemType,
		get_colonists: Callable, find_colonist: Callable, colonist_within_reach: Callable,
		advance_go_to_or_resubmit: Callable, combat_owns: Callable, route: Callable, labour_table: Callable,
		default_labour_table: Callable, ensure_health: Callable, ensure_combat: Callable) -> void:
	_content = content
	_need_definitions = need_definitions
	_need_full = need_full
	_event_priority = event_priority
	_clock = clock
	_calendar = calendar
	_scheduler = scheduler
	_toils = toils
	_progress_table = progress_table
	_tool_store = tool_store
	_item_table = item_table
	_tile_grid = tile_grid
	_object_table = object_table
	_event_log = event_log
	_trench = trench
	_get_colonists = get_colonists
	_find_colonist = find_colonist
	_colonist_within_reach = colonist_within_reach
	_advance_go_to_or_resubmit = advance_go_to_or_resubmit
	_combat_owns = combat_owns
	_route = route
	_labour_table = labour_table
	_default_labour_table = default_labour_table
	_ensure_health = ensure_health
	_ensure_combat = ensure_combat

## The save field this module owns, in StateCodec's wire shape.
func encode() -> Dictionary:
	return {"pausedJobs": StateCodec._encode_paused_jobs(paused_jobs)}

func decode(state: Dictionary) -> void:
	paused_jobs = StateCodec._decode_paused_jobs(state["pausedJobs"])

## "" when no exposed need reason (colonist-ai.md 3.8): need_unmet:<kind> once
## a search exhausts every source, blocked_source_reserved/unreachable
## transiently mid-search, "" again once committed or with no need at all.
func get_colonist_need_reason(colonist_id: String) -> String:
	return String(need_status.get(colonist_id, ""))

## The colonist's live "needs" component (ADR 012): mutating it mutates the colonist.
func _needs(colonist: Dictionary) -> Dictionary:
	var needs_component: Variant = ActorTableType.get_component(colonist, "needs", _content)
	return needs_component if needs_component != null else {}

## Backfills every declared need kind to full and every declared labour kind to its
## default on a worker missing either (a hand-built fixture). Idempotent; rebuilds in
## field order (class doc). has() is checked alongside the accessor because the "worker"
## wrapper defaults an absent labourTable to {}.
func ensure_needs() -> void:
	var colonists: Array[Dictionary] = _get_colonists.call()
	for i in colonists.size():
		var colonist: Dictionary = colonists[i]
		# A generic actor (wolf/trader) has no worker component: rebuilding it would drop its own fields.
		if not ActorTableType.has_component(colonist, "worker", _content):
			continue
		var needs_component: Variant = ActorTableType.get_component(colonist, "needs", _content)
		var worker_component: Variant = ActorTableType.get_component(colonist, "worker", _content)
		var health_component: Variant = ActorTableType.get_component(colonist, "health", _content)
		var accumulator_component: Variant = colonist.get("needsAccumulator")
		var needs_missing := not (colonist.has("needs") and needs_component is Dictionary)
		var labour_table_missing := not (colonist.has("labourTable") and worker_component is Dictionary
			and worker_component["labourTable"] is Dictionary)
		var health_missing := not (colonist.has("health") and health_component is Dictionary)
		var accumulator_missing := not (accumulator_component is Dictionary)
		if needs_missing or labour_table_missing or health_missing or accumulator_missing:
			colonist = {
				"id": colonist["id"], "kind": colonist["kind"],
				"x": colonist["x"], "y": colonist["y"],
				"needs": {} if needs_missing else needs_component,
				"needsAccumulator": {} if accumulator_missing else accumulator_component,
				"labourTable": {} if labour_table_missing else worker_component["labourTable"],
				"route": _route.call(colonist),
				"work": colonist.get("work"),
				"hands": colonist.get("hands", []),
				"trapped": colonist.get("trapped"), # unconditional, never dropped by this repair
				"held_tool": worker_component["held_tool"] if worker_component is Dictionary else "",
				"factionId": String(colonist.get("factionId", "colony")) }
			if not health_missing:
				colonist["health"] = health_component
			on_actor_replaced.call(colonists[i], colonist)
			colonists[i] = colonist
		var needs: Dictionary = _needs(colonist)
		for kind in _need_definitions.keys():
			if not needs.has(kind):
				needs[kind] = _need_full
		var accumulator: Dictionary = colonist.get("needsAccumulator", {})
		for kind in _need_definitions.keys():
			if not accumulator.has(kind):
				accumulator[kind] = 0
		var labour_table: Dictionary = _labour_table.call(colonist)
		var defaults: Dictionary = _default_labour_table.call()
		for kind in defaults.keys():
			if not labour_table.has(kind):
				labour_table[kind] = defaults[kind]

## Per-tick decay (NeedsType.apply_tick(), ADR 012/024) at content/needs.json's
## rate_per_day (the mutable definitions, not actors.json's copy) through a per-need
## integer accumulator against day_length_ticks; re-clamps health.
func decay_needs() -> void:
	ensure_needs()
	_ensure_health.call()
	_ensure_combat.call()
	_object_table.ensure_object_health()
	var rates: Dictionary = {}
	for kind in _need_definitions.keys():
		rates[kind] = int(_need_definitions[kind].get("rate_per_day", 0))
	var needs_tunables := {"rates": rates, "day_length_ticks": _calendar.day_length_ticks()}
	for colonist in _get_colonists.call():
		NeedsType.apply_tick(colonist, needs_tunables)
		HealthType.apply_tick(colonist)

## Pauses a colonist's current job (colonist-ai.md 3.6): clears colonist.work (its
## progress suspended) or, at a toil boundary (work null), reads the job off the
## scheduler assignment. A no-op when the colonist holds no assignment.
func pause_work_job(colonist: Dictionary) -> void:
	var colonist_id: String = colonist["id"]
	var work: Variant = colonist.get("work")
	if work != null:
		paused_jobs[colonist_id] = String(work["job_id"])
		_progress_table.suspend(work)
		colonist["work"] = null
		return
	var assignment: Variant = _scheduler.get_assignments().get(colonist_id)
	if assignment != null:
		paused_jobs[colonist_id] = String(assignment["job_id"])

## Sends a colonist back to its paused job; returns the job_id to resume the
## assignment for, or "" when the job is gone or terminal. A first go_to leg gets
## a fresh route: the colonist may have walked away and back.
func resume_paused_job(colonist: Dictionary) -> String:
	var colonist_id: String = colonist["id"]
	if not paused_jobs.has(colonist_id):
		return ""
	var job_id: String = String(paused_jobs[colonist_id])
	paused_jobs.erase(colonist_id)
	var job := _scheduler.queue.get_job(job_id)
	if job.is_empty() or String(job.get("status", "")) not in ["active", "queued"]:
		return ""
	if String(job.get("kind", "")) == "rescue":
		return _resume_paused_rescue(colonist, job_id, job)
	# A needs_tool job whose tool is no longer satisfied defers entirely to
	# ToilExecutor's fetch_tool -> go_to -> work: a route or work timer started here
	# would be reused by _advance_fetch_tool() as its own travel leg.
	if _toils.needs_fetch_tool(colonist, job, job_id):
		colonist["route"] = null
		return job_id
	if InventoryType.is_carrying(colonist):
		return job_id
	var target: Vector2i = job["target"]
	if _colonist_within_reach.call(colonist, target):
		# Only start the timer when this leg leads into work (a haul/build leg's
		# next toil is pick_up, left to the ordinary advance() dispatch).
		if _toils.leads_into_work(String(job["kind"]), true):
			_toils.start_work(colonist, job_id)
		return job_id
	colonist["route"] = null
	_advance_go_to_or_resubmit.call(colonist, job_id, job, target)
	if String(_scheduler.queue.get_job(job_id).get("status", "")) not in ["active", "queued"]:
		return ""
	return job_id

## Rescue resume: a budgeted re-route (ToilExecutor.advance_go_to(), shared
## _route_budget) under TrenchSystem.rescue_routable_to() (never through a trench, exact
## target only). Never starts work here: the target's reservation may not be reacquired
## yet (resume_interrupted_job() calls this before resume_assignment()). A proven
## unreachable commitment is retired, not resubmitted.
func _resume_paused_rescue(colonist: Dictionary, job_id: String, job: Dictionary) -> String:
	var target: Vector2i = job["target"]
	colonist["route"] = null
	if Vector2i(int(colonist["x"]), int(colonist["y"])) == target:
		return job_id
	var passable := _trench.rescue_routable_to(target, String(colonist.get("factionId", "colony")))
	if _toils.advance_go_to(colonist, job_id, target, passable) == "unreachable":
		_trench.retire_rescue_job(job_id, job)
		return ""
	return job_id

## interrupt_current_job callable (NeedGiver, RescueGiver, CombatGiver; ADR 009): pauses,
## releases the paused job's tool reservations (suspend_assignment() only knows JobQueue's
## table), then suspends the assignment. A no-op when nothing was paused.
func interrupt_current_job(colonist: Dictionary) -> void:
	var colonist_id: String = colonist["id"]
	pause_work_job(colonist)
	if not paused_jobs.has(colonist_id):
		return
	var job_id: String = String(paused_jobs[colonist_id])
	_tool_store.release_all(job_id)
	_scheduler.suspend_assignment(colonist_id, job_id)

## resume_interrupted_job callable: resumes, then restores the suspended assignment
## (ADR 009). Deferred while CombatGiver owns the colonist (a flee episode): resuming
## would overwrite the flee assignment; CombatGiver's recovery calls this again once
## owns() is false. A haul/site_fetch job that failed to reactivate while its colonist
## still carries the cargo stays in paused_jobs, so a later cancel finds the carrier.
func resume_interrupted_job(colonist_id: String) -> void:
	if _combat_owns.call(colonist_id):
		return
	var colonist: Dictionary = _find_colonist.call(colonist_id)
	if colonist.is_empty() or not paused_jobs.has(colonist_id):
		return
	var job_id := resume_paused_job(colonist)
	if job_id.is_empty():
		return
	_scheduler.resume_assignment(colonist_id, job_id)
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("status", "")) == "active":
		return
	if String(job.get("kind", "")) in ["haul", "site_fetch"] and InventoryType.is_carrying(colonist):
		paused_jobs[colonist_id] = job_id

## set_reason callable for NeedGiver: the cache get_colonist_need_reason() reads.
func set_need_reason(colonist_id: String, reason: String) -> void:
	need_status[colonist_id] = reason

## emit_need_unmet callable for NeedGiver (colonist-ai.md 3.1: panel and alert list).
func emit_need_unmet_event(colonist_id: String, kind: String) -> void:
	var reason := "%s%s" % [REASON_NEED_UNMET_PREFIX, kind]
	_event_log.insert_event({
		"type": "need_unmet", "tick": _clock.tick, "system_priority": _event_priority,
		"entity_id": colonist_id, "sequence": _event_log.next_sequence(), "data": {"kind": kind, "reason": reason},
	})

## Kind-aware sources (a ground-berries tile for food, water tiles, a bed for rest),
## never in toil_executor.gd or NeedGiver, minus those no colonist can reach: NeedGiver's
## search would flood-fill the whole component before giving up on one. Every colonist
## gets this same list, including sources only another colonist reaches (a walled-in
## colonist still searches them; test_combat's flee-during-need-search check relies on it).
## A4: reachability goes through region ids, once per source (O(sources)), instead
## of RegionMap.reachable() per source per colonist; NeedGiver calls this once per
## kind per pass. A passable source belongs to its own region, an impassable one
## (water) to each region among its orthogonal neighbours: reachable()'s own rule.
func need_source_candidates(kind: String) -> Array[Vector2i]:
	var candidates := _raw_need_sources(kind)
	if _get_colonists.call().is_empty():
		return candidates
	var regions := _tile_grid.get_regions()
	var colonist_regions: Dictionary = {}
	for colonist: Dictionary in _get_colonists.call():
		var x: int = colonist["x"]
		var y: int = colonist["y"]
		colonist_regions[regions.region_id(x, y)] = true
	colonist_regions.erase(0) # reachable() is false from a tile with no region
	return candidates.filter(func(candidate: Vector2i) -> bool:
		return _regions_reaching(regions, candidate).any(func(region: int) -> bool: return colonist_regions.has(region)))

func _raw_need_sources(kind: String) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	match kind:
		"food":
			for key in _item_table.ground_berries.keys():
				if int(_item_table.ground_berries[key]) <= 0:
					continue
				var coords := String(key).split("_")
				candidates.append(Vector2i(int(coords[0]), int(coords[1])))
		"water":
			candidates = _tile_grid.get_water_tiles()
		"rest":
			candidates = _object_table.tiles_of_kind("bed")
	return candidates

## The distinct nonzero region ids `regions.reachable(from, target)` is true from.
func _regions_reaching(regions: RegionMapType, target: Vector2i) -> Array[int]:
	var reached_by: Array[int] = []
	if target.x < 0 or target.y < 0 or target.x >= _tile_grid.width or target.y >= _tile_grid.height:
		return reached_by
	var own := regions.region_id(target.x, target.y)
	if own != 0:
		reached_by.append(own)
		return reached_by
	for offset: Vector2i in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var region := regions.region_id(target.x + offset.x, target.y + offset.y)
		if region != 0 and not reached_by.has(region):
			reached_by.append(region)
	return reached_by

## claimed_targets callable for NeedGiver: targets of queued/active need jobs, so two
## concurrent searches never pick the same not-yet-reserved source (colonist-ai.md 3.4).
func need_job_targets() -> Dictionary:
	var claimed: Dictionary = {}
	for job in _scheduler.queue.get_jobs_of_kinds(["eat_food", "drink_water", "sleep"]):
		if not need_kind_for_job(String(job["kind"])).is_empty() and job["status"] in ["queued", "active"]:
			claimed[job["target"]] = true
	return claimed

## Reverse of NeedGiver.JOB_KIND_BY_NEED; "" for a non-need job kind.
func need_kind_for_job(job_kind: String) -> String:
	match job_kind:
		"eat_food": return "food"
		"drink_water": return "water"
		"sleep": return "rest"
		_: return ""

## source_valid callable for ToilExecutor's consume(): water never runs out; food needs a
## ground berry still at the target; rest needs the bed still there.
func consume_source_valid(job_id: String) -> bool:
	var job := _scheduler.queue.get_job(job_id)
	if job.is_empty():
		return false
	var target: Vector2i = job["target"]
	match String(job["kind"]):
		"eat_food":
			return _item_table.get_ground_berries(target.x, target.y) > 0
		"drink_water":
			return _tile_grid.get_tile(target.x, target.y) == TILE_WATER
		"sleep":
			return _object_table.get_object(target.x, target.y) == "bed"
		_:
			return false

## A completed need job's effect: restores the need (sleep scaled by
## bedroom_rest_multiplier in a recognised bedroom); eat_food also consumes the berry.
func apply_need_effect(colonist: Dictionary, job: Dictionary) -> void:
	var need_kind := need_kind_for_job(String(job["kind"]))
	if need_kind.is_empty():
		return
	var need_def: Dictionary = _need_definitions.get(need_kind, {})
	var restore := float(need_def.get("restore", _need_full))
	if String(job["kind"]) == "sleep":
		var target: Vector2i = job["target"]
		if bool(_tile_grid.get_room_at(target.x, target.y).get("has_bed", false)):
			restore *= float(need_def.get("bedroom_rest_multiplier", 1.0))
	var needs: Dictionary = _needs(colonist)
	needs[need_kind] = mini(_need_full, int(restore))
	if String(job["kind"]) == "eat_food":
		var target: Vector2i = job["target"]
		_item_table.consume_ground_berry(target.x, target.y)
