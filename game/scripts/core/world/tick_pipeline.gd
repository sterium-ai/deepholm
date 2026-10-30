class_name TickPipeline
extends RefCounted

## WorldState.tick(): the ordered per-tick phases (PHASES) and the worker/commitment lists the
## scheduler phase reads. Roster, calendar and alert set arrive as Callables (decode replaces them).
## Invariants:
## - Phases run in PHASES order, every tick, each exactly once; the order is
##   behaviour (same seed + commands -> same events and state_hash()).
## - caches_begin/caches_end bracket every other phase: the actor and item
##   lookup caches are trusted only inside them (A4).
## - area_orders runs before the clock advances: commands of tick T expand
##   before T advances.
## - rescue_giver runs after scheduler (which clears the shared _route_budget
##   ledger) and before advance_colonists (which honours it).
## - incidents_activate/escapes_activate run before advance_colonists, so a
##   freshly activated actor's first toil runs this same tick.
## - approach_giver runs after advance_colonists, so it sees post-movement positions and traps.
## - dig_finds drains after advance_colonists, in ascending job-id order
##   whatever order colonists completed in (ADR 026).
## - farming runs after advance_colonists, so a sow or harvest completed this tick has its
##   crop record before tick() returns (a save never sees a sown tile without one, ADR 059).
## - refused_reservations drains after advance_colonists: a need resolving
##   there can trigger a further refusal, which must drain before tick() returns.
## - Rebuilt by WorldState._build_dimension_services() together with the
##   givers it calls, so it never holds a stale NeedGiver/RescueGiver.

const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")

const PHASES: Array[String] = ["caches_begin", "area_orders", "clock", "needs_decay", "need_giver", "haul_giver",
	"construction_giver", "craft_giver", "combat", "scheduler", "site_fetch_resolve", "rescue_giver",
	"incidents_activate", "escapes_activate", "advance_colonists", "approach_giver", "dig_finds",
	"farming", "refused_reservations", "collect_queue_events", "calendar_alerts", "incidents_advance", "tick_event", "caches_end"]

var _clock: SeededClock
var _area_orders: AreaOrders
var _needs_system: NeedsSystem
var _need_giver: NeedGiver
var _haul_giver: HaulGiver
var _construction_giver: ConstructionGiver
var _craft_giver: CraftGiver
var _combat_system: CombatSystem
var _combat_giver: CombatGiver
var _construction: ConstructionSystem
var _scheduler: AssignmentType
var _passability: Passability
var _tile_grid: TileGrid
var _toils: ToilExecutor
var _calendar: Callable # () -> CalendarService, the live calendar
var _rescue_giver: RescueGiver
var _trench: TrenchSystem
var _incidents: IncidentScheduler
var _approach_giver: ApproachGiver
var _item_table: ItemTable
var _event_log: EventLog
var _calendar_alert_giver: CalendarAlertGiver
var _progress_table: WorkProgress
## colonist_id -> in-flight re-route search, shared by reference with ToilExecutor.
var _reroutes: Dictionary
var _toil_hooks: Dictionary
var _colonists: Callable # () -> Array[Dictionary], the live roster
var _calendar_alerts_fired: Callable # () -> Dictionary, the live fired-window set
var _resolve_refused_reservations: Callable # () -> void
var _route: Callable # (colonist) -> the mover component's route or null
var _tick_priority: int
var _farming: Callable # () -> void, FarmSystem.advance (growth, then FarmGiver)
## A4's per-tick lookup caches: trusted only between caches_begin and caches_end.
var _actor_index: ActorIndex
## Same order as PHASES.
var _phases: Array[Callable] = []
## Site-fetch jobs active before this tick's scheduler phase; read by site_fetch_resolve.
var _site_fetch_jobs_before: Dictionary = {}

func _init(clock: SeededClock, area_orders: AreaOrders, needs_system: NeedsSystem, need_giver: NeedGiver,
		haul_giver: HaulGiver, construction_giver: ConstructionGiver, combat_system: CombatSystem,
		combat_giver: CombatGiver, construction: ConstructionSystem, scheduler: AssignmentType,
		passability: Passability, tile_grid: TileGrid, toils: ToilExecutor, calendar: Callable,
		rescue_giver: RescueGiver, trench: TrenchSystem, incidents: IncidentScheduler,
		approach_giver: ApproachGiver, item_table: ItemTable, event_log: EventLog,
		calendar_alert_giver: CalendarAlertGiver, progress_table: WorkProgress, reroutes: Dictionary,
		toil_hooks: Dictionary, colonists: Callable, calendar_alerts_fired: Callable,
		resolve_refused_reservations: Callable, route: Callable, tick_priority: int, actor_index: ActorIndex,
		farming: Callable, craft_giver: CraftGiver) -> void:
	_clock = clock
	_area_orders = area_orders
	_needs_system = needs_system
	_need_giver = need_giver
	_haul_giver = haul_giver
	_construction_giver = construction_giver
	_craft_giver = craft_giver
	_combat_system = combat_system
	_combat_giver = combat_giver
	_construction = construction
	_scheduler = scheduler
	_passability = passability
	_tile_grid = tile_grid
	_toils = toils
	_calendar = calendar
	_rescue_giver = rescue_giver
	_trench = trench
	_incidents = incidents
	_approach_giver = approach_giver
	_item_table = item_table
	_event_log = event_log
	_calendar_alert_giver = calendar_alert_giver
	_progress_table = progress_table
	_reroutes = reroutes
	_toil_hooks = toil_hooks
	_colonists = colonists
	_calendar_alerts_fired = calendar_alerts_fired
	_resolve_refused_reservations = resolve_refused_reservations
	_route = route
	_tick_priority = tick_priority
	_actor_index = actor_index
	_farming = farming
	_phases = [_phase_caches_begin, _area_orders.advance, _phase_clock, _needs_system.decay_needs, _phase_need_giver,
		_phase_haul_giver, _phase_construction_giver, _phase_craft_giver, _phase_combat, _phase_scheduler, _phase_site_fetch_resolve,
		_phase_rescue_giver, _incidents.activate_pending, _trench.activate_pending_escapes, _advance_colonists,
		_phase_approach_giver, _item_table.resolve_dig_finds, _farming, _resolve_refused_reservations,
		_event_log.collect_queue_events, _phase_calendar_alerts, _phase_incidents_advance, _phase_tick_event, _phase_caches_end]
	assert(_phases.size() == PHASES.size(), "TickPipeline: one Callable per PHASES entry")

## Advances exactly one tick.
func run() -> void:
	for phase in _phases:
		phase.call()

## The phase Callables in PHASES order (BenchCommon.profiled_tick() times each).
func phases() -> Array[Callable]:
	return _phases

func _roster() -> Array[Dictionary]:
	return _colonists.call()

func _current_calendar() -> CalendarService:
	return _calendar.call()

func _alerts_fired() -> Dictionary:
	return _calendar_alerts_fired.call()

func _phase_caches_begin() -> void:
	_actor_index.begin_tick(_roster()); _item_table.begin_tick()

func _phase_caches_end() -> void:
	_actor_index.end_tick(); _item_table.end_tick()

func _phase_clock() -> void:
	_clock.advance(1)

func _phase_need_giver() -> void:
	_need_giver.advance(_colonists_not_combat_owned(), _clock.tick)

func _phase_haul_giver() -> void:
	_haul_giver.advance(_clock.tick)

func _phase_construction_giver() -> void:
	_construction_giver.advance(_clock.tick)

## F2 (ADR 061): workbench bills and their craft_fetch/craft_work jobs, before the scheduler.
func _phase_craft_giver() -> void:
	_craft_giver.advance(_clock.tick)

func _phase_combat() -> void:
	_combat_system.apply_combat(_clock.tick)

func _phase_scheduler() -> void:
	_site_fetch_jobs_before = _construction.active_site_fetch_job_ids()
	_scheduler.tick(_clock.tick, _scheduler_workers(), _passability.is_passable, Vector2i.ZERO,
		Vector2i(_tile_grid.width - 1, _tile_grid.height - 1), _toils.get_labour, _current_calendar().active_boost, _roster(),
		_committed_jobs(), _tile_grid.get_regions().reachable)

## Swaps a just-activated site_fetch job's placeholder source before it moves.
func _phase_site_fetch_resolve() -> void:
	_construction.resolve_freshly_activated_site_fetch_sources(_site_fetch_jobs_before)
	_site_fetch_jobs_before = {}

## Its commitments reach the scheduler's committed-proposal path next tick (rescue_giver.gd).
func _phase_rescue_giver() -> void:
	_rescue_giver.advance(_trench.rescue_candidates(), _trench.trapped_rescue_victims(), _clock.tick)

func _phase_approach_giver() -> void:
	_approach_giver.advance(_roster(), _clock.tick)

func _phase_calendar_alerts() -> void:
	_calendar_alert_giver.advance(_clock.tick, _current_calendar(), _alerts_fired())

func _phase_incidents_advance() -> void:
	_incidents.advance(_clock.tick)

func _phase_tick_event() -> void:
	_event_log.insert_event({
		"type": "tick_advanced",
		"tick": _clock.tick,
		"system_priority": _tick_priority,
		"entity_id": "world",
		"sequence": _event_log.next_sequence(),
		"data": {}
	})

## Every colonist except one CombatGiver owns (an open flee episode), so a need
## search or onset never touches the NeedsSystem.paused_jobs entry it owns.
func _colonists_not_combat_owned() -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for colonist in _roster():
		if _combat_giver.owns(String(colonist["id"])):
			continue
		filtered.append(colonist)
	return filtered

## Every colonist not mid-search for a need source (colonist-ai.md 3.1), so the
## scheduler never activates work for one NeedGiver has not finished deciding about.
func _colonists_not_searching_need() -> Array[Dictionary]:
	var searching := _need_giver.searching_colonist_ids()
	var fleeing := _combat_giver.get_committed_jobs()
	var filtered: Array[Dictionary] = []
	for colonist in _roster():
		var colonist_id: String = String(colonist["id"])
		# A fleeing actor mid need-search must still be proposed, or its flee commitment never reaches the scheduler.
		if searching.has(colonist_id) and not fleeing.has(colonist_id):
			continue
		filtered.append(colonist)
	return filtered

## GlobalAssignment.tick()'s `committed_needs`: worker id -> the one job it proposes,
## bypassing scoring. Merged rescue, then need, then flee: a need beats a rescue for
## the same actor (colonist-ai.md 3.1/3.6) and a flee beats both (rule 4).
func _committed_jobs() -> Dictionary:
	var committed: Dictionary = _rescue_giver.get_pending_assignments().duplicate()
	var needing := _need_giver.get_pending_assignments()
	for actor_id in needing:
		committed[actor_id] = needing[actor_id]
	var fleeing := _combat_giver.get_committed_jobs()
	for actor_id in fleeing:
		committed[actor_id] = fleeing[actor_id]
	return committed

## The roster minus need-searchers, plus every staged incident actor (F5): proposed
## and routed like any worker, in the world only once its job activates.
func _scheduler_workers() -> Array[Dictionary]:
	var workers := _colonists_not_searching_need()
	workers.append_array(_incidents.staged_actors())
	return workers

## One tick of every colonist's route/work, ascending id, through _toils.advance() only
## (never a branch on job kind: one work engine).
func _advance_colonists() -> void:
	var assignments := _scheduler.get_assignments()
	var ordered: Array[Dictionary] = _roster().duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	for colonist in ordered:
		var colonist_id: String = colonist["id"]
		var assignment: Variant = assignments.get(colonist_id)
		if assignment == null:
			if _route.call(colonist) != null or colonist.get("work") != null:
				_progress_table.suspend(colonist.get("work"))
				colonist["route"] = null
				colonist["work"] = null
				_reroutes.erase(colonist["id"])
			continue
		var job_id: String = assignment["job_id"]
		var job := _scheduler.queue.view_job(job_id) # read-only (A5)
		if job.is_empty() or String(job.get("status", "")) != "active":
			continue
		# The scheduler phase may reassign a colonist the tick a command frees it: clear
		# route/work naming any other job so the new one starts fresh.
		var route: Variant = _route.call(colonist)
		var work: Variant = colonist.get("work")
		if (route != null and route["job_id"] != job_id) or (work != null and work["job_id"] != job_id):
			if work != null and work["job_id"] != job_id:
				_progress_table.suspend(work)
			colonist["route"] = null
			colonist["work"] = null
			_reroutes.erase(colonist["id"])
		# A fresh rescue activation re-checks its path's safety before the first drive and
		# retires the commitment (the victim may pick another rescuer) rather than walk it.
		if String(job.get("kind", "")) == "rescue" and _route.call(colonist) == null and colonist.get("work") == null \
				and not _trench.rescue_activation_safe(colonist, job, assignment.get("path", [])):
			_trench.retire_rescue_job(job_id, job)
			continue
		var tile_before := Vector2i(int(colonist["x"]), int(colonist["y"]))
		_trench.trap_tile_before = tile_before
		_toils.advance(colonist, job_id, job, assignment.get("path", []), _toil_hooks)
		_trench.check_trench_arrival(colonist, job_id, tile_before)
