class_name WorldState
extends RefCounted

## The simulation façade: wires the core modules and exposes apply()/tick(), the
## read-only getters, state_hash() and save glue. It holds the roster, the seed/RNG
## streams and the callbacks modules reach each other through; state lives in the modules.

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ToolHandoverType = preload("res://scripts/core/jobs/tool_handover.gd")
const ToolItemStoreType = preload("res://scripts/core/items/tool_item_store.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const NeedGiverType = preload("res://scripts/core/jobs/givers/need_giver.gd")
const RescueGiverType = preload("res://scripts/core/jobs/givers/rescue_giver.gd")
const HaulGiverType = preload("res://scripts/core/jobs/givers/haul_giver.gd")
const CalendarAlertGiverType = preload("res://scripts/core/jobs/givers/calendar_alert_giver.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ContentTablesType = preload("res://scripts/core/content/content_tables.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const ViewSnapshotType = preload("res://scripts/core/world/view_snapshot.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const WorldSeedingType = preload("res://scripts/core/worldgen/world_seeding.gd")
const IncidentSchedulerType = preload("res://scripts/core/incidents/incident_scheduler.gd")
const RelationsType = preload("res://scripts/core/relations/relations.gd")
const CombatGiverType = preload("res://scripts/core/combat/combat_giver.gd")
const ApproachGiverType = preload("res://scripts/core/combat/approach_giver.gd")
const ConstructionSystemType = preload("res://scripts/core/objects/construction_system.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const ZoneTableType = preload("res://scripts/core/objects/zone_table.gd")
const ConstructionGiverType = preload("res://scripts/core/jobs/givers/construction_giver.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")
const TrenchSystemType = preload("res://scripts/core/actors/trench_system.gd")
const TradeSystemType = preload("res://scripts/core/economy/trade_system.gd")
const NeedsSystemType = preload("res://scripts/core/actors/needs_system.gd")
const CombatSystemType = preload("res://scripts/core/actors/combat_system.gd")
const ToilBindingsType = preload("res://scripts/core/jobs/toil_bindings.gd")
const CommandRouterType = preload("res://scripts/core/world/command_router.gd")
const TickPipelineType = preload("res://scripts/core/world/tick_pipeline.gd")
const OrderHandlerType = preload("res://scripts/core/commands/handlers/order_handler.gd")
const ConstructionHandlerType = preload("res://scripts/core/commands/handlers/construction_handler.gd")
const ZoneHandlerType = preload("res://scripts/core/commands/handlers/zone_handler.gd")
const ActorHandlerType = preload("res://scripts/core/commands/handlers/actor_handler.gd")
const IncidentHandlerType = preload("res://scripts/core/commands/handlers/incident_handler.gd")
const ActorIndexType = preload("res://scripts/core/actors/actor_index.gd")
const WorldSetupType = preload("res://scripts/core/world/world_setup.gd")

## Default/fixture map size; a new game's size comes from mapgen.json via boot.gd.
const MAP_WIDTH := 48
const MAP_HEIGHT := 48
const TILE_ROCK := ContentRegistryType.TILE_ROCK
const TILE_SOIL := ContentRegistryType.TILE_SOIL
const TILE_FLOOR := ContentRegistryType.TILE_FLOOR
const TILE_PLOWED_SOIL := ContentRegistryType.TILE_PLOWED_SOIL
const TILE_PLANTED := ContentRegistryType.TILE_PLANTED
const TILE_HAZARD := ContentRegistryType.TILE_HAZARD
const TILE_TREE := ContentRegistryType.TILE_TREE
const TILE_WATER := ContentRegistryType.TILE_WATER
const TILE_TRENCH := ContentRegistryType.TILE_TRENCH
const COLONIST_COUNT := ContentRegistryType.COLONIST_COUNT
const DEFAULT_TRENCH_CLIMB_TICKS := TrenchSystemType.DEFAULT_TRENCH_CLIMB_TICKS
## Distinct from each other and from IncidentScheduler/WorldGenerator salts: no two streams share draws.
const GEOGRAPHY_SEED_SALT := 402_653
const PLACEMENT_SEED_SALT := 219_961
const DIG_FIND_SEED_SALT := 738_419 # ADR 026

const PRIORITY_COMMAND := 0
const PRIORITY_TICK := 100

## Static, not const (read from needs.json in _init()); kept for colonist_panel.gd.
static var NEED_FULL: int = 0

const REASON_NEED_UNMET_PREFIX := NeedsSystemType.REASON_NEED_UNMET_PREFIX
## F3: OrderHandler's assignee check and _resolve_refused_reservations()'s termination.
const REASON_NOT_ORDERED_BY_PLAYER := "not_ordered_by_player"
const REASON_FIGHTING := CombatSystemType.REASON_FIGHTING
const REASON_NO_RESCUER_AVAILABLE := RescueGiverType.REASON_NO_RESCUER_AVAILABLE
## Rescue jobs bypass scoring (committed proposals, colonist-ai.md 3.6); kept for any fallback.
const RESCUE_JOB_PRIORITY := 1

## Per-colonist labour table: priority 0 (off) .. 4 per labour kind.
const LABOUR_KINDS := ["mine", "chop", "farm", "haul", "build", "craft", "cook"]
const LABOUR_DEFAULT := 3
const LABOUR_MIN := 0
const LABOUR_MAX := 4

var _seed: int
## StateCodec.decode() overwrites its width/height with the saved map's exact size.
var _tile_grid: TileGridType
## The algorithm that produced the tiles; a loaded save keeps its own.
var _generator_version: int = WorldGeneratorType.GENERATOR_VERSION
var _clock: SeededClock
## The simulation stream; generation uses salted RNGs, so mapgen.json never perturbs it.
var _random: RandomNumberGenerator
## The clearing WorldGenerator.place_spawn() chose; {} on a decoded world.
var _spawn_clearing: Dictionary = {}
var _colonists: Array[Dictionary] = []
## Id and tile lookups over _colonists, trusted only inside tick() (actor_index.gd).
var _actor_index := ActorIndexType.new()
var _item_table: ItemTableType
## Read-through accessors kept for viewer/debug_scenario.gd's farm stock.
var _items: Dictionary:
	get:
		return _item_table.items
var _next_item_id: int:
	get:
		return _item_table.next_item_id
	set(value):
		_item_table.next_item_id = value
var _tool_store: ToolItemStoreType
var _item_definitions: Dictionary = {}
var _object_table: ObjectTableType
var _zone_table: ZoneTableType
var _passability: PassabilityType
## The single content bundle (F1), schema-validated and cross-checked at construction.
var _content: ContentRegistryType
var _object_definitions: Dictionary = {}
var _need_definitions: Dictionary = {}
var _tile_definitions: Dictionary = {}
var _work_ticks: Dictionary = {}
var _need_full: int = 0
var _mapgen: Dictionary = {}
var _scheduler: AssignmentType
var _toils: ToilExecutorType
var _toil_bindings: ToilBindingsType
## _toil_bindings.hooks, ToilExecutor.advance()'s hooks (StateCodec reads it too).
var _toil_hooks: Dictionary = {}
var _event_log: EventLogType
var _commands: CommandRouterType
var _tick_pipeline: TickPipelineType
var _area_orders: AreaOrders # pending area_order expansions (ADR 044)
## Live re-route searches by colonist id, shared by reference with _toils.
var _reroutes: Dictionary = {}
var _progress_table: WorkProgressType
## colonist_id -> true once its per-tick routing allowance is spent; shared by reference.
var _route_budget: Dictionary = {}
var _need_giver: NeedGiverType
var _rescue_giver: RescueGiverType
var _trench: TrenchSystemType
var _needs_system: NeedsSystemType
var _haul_giver: HaulGiverType
## The "calendar boost" term in the effective-priority formula (ADR 008).
var _calendar: CalendarServiceType
var _calendar_alert_giver: CalendarAlertGiverType
var _calendar_alerts_fired: Dictionary = {}
## Owns its own seeded RNG (ADR 017); state_codec.gd/state_hash() read its fields directly.
var _incidents: IncidentSchedulerType
var _relations: RelationsType
var _combat_giver: CombatGiverType
var _combat_system: CombatSystemType
var _approach_giver: ApproachGiverType
var _construction: ConstructionSystemType
var _construction_giver: ConstructionGiverType
## Trader offers; never persisted or hashed.
var _trade: TradeSystemType

## The start a world was built with (ADR 057); its calendar and incident list are saved ("scenarioStart").
var _setup: WorldSetupType

## content is the session's ContentRegistry (one per session); null builds the base bundle.
## setup is a scenario's start (world/world_setup.gd, ADR 057); null is the base start.
func _init(p_seed: int = 1337, tick_rate: int = 10, p_width: int = MAP_WIDTH, p_height: int = MAP_HEIGHT, incidents_enabled: bool = false,
		content: ContentRegistryType = null, setup: WorldSetupType = null) -> void:
	_setup = setup if setup != null else WorldSetupType.new()
	_seed = p_seed
	_clock = SeededClockType.new(tick_rate)
	_random = RandomNumberGenerator.new()
	_random.seed = p_seed
	# Dig's find_table stream (ADR 026), salted so it never perturbs _random.
	var dig_find_random := RandomNumberGenerator.new()
	dig_find_random.seed = p_seed + DIG_FIND_SEED_SALT
	_content = content if content != null else ContentRegistryType.new()
	if not _content.is_valid():
		_fail_startup("fatal ContentRegistry startup failure: %s" % _content.get_error())
		return
	_build_map(p_width, p_height)
	_build_scheduling(dig_find_random)
	_build_systems()
	_build_commands()
	var tables := WorldSetupType.startup_tables(_content)
	if not tables.error.is_empty():
		_fail_startup(tables.error)
		return
	_build_work_engine(tables.tool_requirements)
	_build_givers(tables.haul)
	_build_dimension_services(incidents_enabled)

func _build_map(p_width: int, p_height: int) -> void:
	_relations = RelationsType.new(_content)
	_object_definitions = ContentTablesType.index_by_field(_content.list("objects"), "kind")
	_need_definitions = ContentTablesType.index_by_field(_content.list("needs"), "kind")
	_item_definitions = ContentTablesType.index_by_field(_content.list("items"), "id") # "kind" is the category ("tool")
	_tile_definitions = ContentTablesType.index_by_field(_content.list("tiles"), "id")
	_mapgen = _content.document("mapgen").duplicate(true)
	var resolved_size := WorldGeneratorType.resolve_size(p_width, p_height, _mapgen)
	_zone_table = ZoneTableType.new()
	_tile_grid = TileGridType.new(resolved_size.x, resolved_size.y, get_object, _zone_table.is_in_any_zone)
	_object_table = ObjectTableType.new(_object_definitions, _tile_grid)
	_passability = PassabilityType.new(_content, _tile_grid, _object_table, _object_definitions, _tile_definitions,
		_actor_faction, _find_colonist)
	_need_full = int(ContentTablesType.need_config(_content)["full"]); NEED_FULL = _need_full # before seeding and NeedsSystem/NeedGiver
	var seeded := WorldSeedingType.seed_world(_seed + GEOGRAPHY_SEED_SALT, _seed + PLACEMENT_SEED_SALT, _tile_grid.width,
		_tile_grid.height, _setup.seeding_mapgen(_mapgen), _content, _object_table, _setup.colonists)
	_tile_grid.tiles = seeded["tiles"]
	_colonists = seeded["colonists"]
	_spawn_clearing = seeded["clearing"]
	CombatSystemType.ensure_combat(_colonists, _content)

func _build_scheduling(dig_find_random: RandomNumberGenerator) -> void:
	_tool_store = ToolItemStoreType.new(_find_colonist)
	_scheduler = AssignmentType.new(_random, _content)
	_event_log = EventLogType.new(_clock, _scheduler.queue, PRIORITY_COMMAND)
	_item_table = ItemTableType.new(_content, dig_find_random, func() -> Array[Dictionary]: return _colonists,
		passability, get_tile, _zone_table.is_in_any_zone, _scheduler.queue.get_reservation_table,
		_fail_haul_jobs_referencing_item, _cancel_haul_job_carrying_consumed_item)
	# F3: the faction gates read this world's actors, never a hardcoded "colony".
	_scheduler.set_order_eligibility(_passability.colonist_may_be_ordered)
	_scheduler.set_reservation_gate(_passability.colonist_may_reserve_colony_items)
	_scheduler.set_autonomous_reservation_gate(_actor_may_reserve_target)
	_scheduler.set_autonomous_passability(_passability.passable_for_worker)
	# Flee jobs (rule 4) submit autonomously through NeedGiver's interrupt/resume boundary (ADR 009).
	_combat_giver = CombatGiverType.new(_scheduler.submit_autonomous, _get_job, _scheduler.queue.get_jobs,
		_job_restricted_to, func(colonist: Dictionary) -> void: _needs_system.interrupt_current_job(colonist),
		func(colonist_id: String) -> void: _needs_system.resume_interrupted_job(colonist_id), _passability.passable_for_flee,
		_actor_may_reserve_target, _passability.region_reachable, Vector2i(_tile_grid.width - 1, _tile_grid.height - 1), _content, _relations,
		_flee_target_reserved, _cancel_autonomous_job)

func _build_systems() -> void:
	_calendar = CalendarServiceType.new("", _setup.calendar_document(_content))
	_work_ticks = ContentTablesType.work_ticks(_content)
	_progress_table = WorkProgressType.new(_scheduler.queue, _work_ticks, _tile_key, _work_target_for)
	_construction = ConstructionSystemType.new(_object_definitions, _tile_grid, _passability, _object_table, _zone_table,
		_item_table, _scheduler, _event_log, func() -> Array[Dictionary]: return _colonists, _colonist_at,
		_find_job_colonist, _finish_job, _drop_carried_haul_item, _route_cost)
	# Lambdas over the givers: _build_dimension_services() rebuilds NeedGiver/RescueGiver.
	_trench = TrenchSystemType.new(_content, _relations, _tile_grid, _passability, _scheduler, _progress_table, _clock,
		func() -> Array[Dictionary]: return _colonists, _find_colonist, _find_job_colonist, _finish_job,
		_drop_carried_haul_item, _resolve_giver_association, _set_work_progress,
		func() -> Array[String]: return _need_giver.searching_colonist_ids(),
		func() -> Dictionary: return _need_giver.get_pending_assignments(), _combat_giver.owns,
		func(job_id: String) -> String: return _rescue_giver.victim_for_job(job_id),
		func(job_id: String) -> void: _rescue_giver.resolve_job(job_id))
	_trade = TradeSystemType.new(_clock, _content, _item_table, _scheduler, _event_log, PRIORITY_TICK, is_tool_kind,
		_find_colonist, _find_job_colonist, _finish_job, _remove_colonist_by_id)
	_area_orders = AreaOrders.new(func(command: Dictionary) -> Dictionary: return _commands.apply(command), get_construction_site, _scheduler.queue.get_index, _scheduler.queue.get_next_id, _construction.site_table.get_next_id, _event_log, _clock)

func _build_commands() -> void:
	# Every CommandChecks rule takes the world; handlers get it only through this Callable.
	var check := func(rule: Callable, command: Dictionary) -> Dictionary: return rule.call(self, command)
	_commands = CommandRouterType.new(_clock, _event_log, _construction, check,
		OrderHandlerType.new(_clock, _event_log, _scheduler, _progress_table, _construction, _area_orders, _tile_grid,
			check, _drop_carried_haul_item, _finish_job, _resolve_giver_association, _resolve_refused_reservations),
		ConstructionHandlerType.new(_event_log, _construction, _object_table, check),
		ZoneHandlerType.new(_event_log, _scheduler, _zone_table, check, _terminate_haul_job_by_id),
		ActorHandlerType.new(_event_log, check, _find_colonist),
		IncidentHandlerType.new(_clock, _event_log, _trade, check,
			func(incident_id: String, tick: int) -> Array: return _incidents.force_spawn(incident_id, tick)))

func _build_work_engine(tool_requirements_by_kind: Dictionary) -> void:
	_toils = ToilExecutorType.new(int(_content.list("tiles")[0]["move_ticks_per_tile"]), _work_ticks, passability, _get_job,
		_content, _item_table.item_lookup, _item_table.remove_ground_item_units, _item_table.place_new_ground_item, _is_cell_occupied,
		func(job_id: String) -> bool: return _needs_system.consume_source_valid(job_id),
		_resume_work_progress, _set_work_progress, _progress_table.clear, _reroutes, _route_search_factory,
		get_tool_items, get_tool_item, get_tool_item_reservation, reserve_tool_item, release_tool_item_reservation,
		set_tool_item_held, set_tool_item_ground, _worker_view, _route_budget,
		get_zones, is_cell_free, set_tool_item_stockpile, _tool_store.release_all, get_tool_reservation_table,
		_scheduler.queue.set_active_item_marker, _scheduler.queue.get_active_item_marker, _find_colonist, get_assignments,
		_work_target_for, _construction.construction_site_exists, _construction.construction_site_deposit)
	_toils.on_actor_moved = _actor_index.moved; _trench.on_actor_moved = _actor_index.moved
	# Built after _toils; CombatGiver and ToilExecutor above reach it through lambdas.
	_needs_system = NeedsSystemType.new(_content, _need_definitions, _need_full, PRIORITY_TICK, _clock, _calendar, _scheduler,
		_toils, _progress_table, _tool_store, _item_table, _tile_grid, _object_table, _event_log, _trench,
		func() -> Array[Dictionary]: return _colonists, _find_colonist, _colonist_within_reach, _advance_go_to_or_resubmit,
		_combat_giver.owns, _route, _labour_table, _default_labour_table,
		func() -> void: CombatSystemType.ensure_health(_colonists, _content),
		func() -> void: CombatSystemType.ensure_combat(_colonists, _content))
	_needs_system.on_actor_replaced = _actor_index.replaced
	# After NeedsSystem (death detaches paused jobs); ApproachGiver by lambda, as it is rebuilt.
	_combat_system = CombatSystemType.new(_content, _relations, PRIORITY_TICK, _scheduler, _progress_table, _tool_store,
		_item_table, _object_table, _event_log, _needs_system, _combat_giver, func() -> Array[Dictionary]: return _colonists,
		func(actor_id: String) -> void: _approach_giver.forget(actor_id), _job_restricted_to, _finish_job,
		_resolve_giver_association, _remove_colonist_by_id, is_tool_kind, spawn_ground_tool_item)
	# Last of the modules: its hooks reach every system above.
	_toil_bindings = ToilBindingsType.new(_scheduler, _toils, _item_table, _tool_store, _tile_grid, _object_table, _passability,
		_construction, _trench, _needs_system, _reroutes, tool_requirements_by_kind, func() -> Array[Dictionary]: return _colonists,
		_find_colonist, _find_job_colonist, _finish_job, _resubmit_unreachable_job, _routable_to, _route_cost,
		func(job_id: String) -> void: _need_giver.resolve_job(job_id), func(job_id: String) -> void: _rescue_giver.resolve_job(job_id))

func _build_givers(haul_definition: Dictionary) -> void:
	_scheduler.set_route_budget(_route_budget)
	_scheduler.queue.set_tool_requirement(_toil_bindings.tool_requirement_for_kind, _toil_bindings.tool_exists)
	_toil_hooks = _toil_bindings.hooks
	_scheduler.queue.set_haul_backoff(int(haul_definition["retry_base_ticks"]), int(haul_definition["retry_cap_ticks"]))
	# Read-only queue views (A5): get_jobs()'s tool-handover overlay never touches haul/site_fetch/site_work.
	_haul_giver = HaulGiverType.new(int(haul_definition["priority"]), _scheduler.queue.view_jobs_of_kinds.bind(["haul"]), get_items, _zone_table.is_in_any_zone, _scheduler.submit,
		_scheduler.queue.attach_item, get_zones, is_cell_free, passability, _is_cell_occupied)
	_scheduler.queue.set_haul_destination_finder(_haul_giver.find_free_haul_cell)
	_construction_giver = ConstructionGiverType.new(_construction.site_table.list, _scheduler.queue.view_jobs_of_kinds.bind(["site_fetch", "site_work"]), _item_table.get_items,
		_zone_table.is_in_any_zone, _construction.construction_item_reservation_owner, _construction.submit_site_fetch,
		_construction.submit_site_work, _construction.site_table.materials_met, _construction.site_table.remaining)
	# Live tiles by reference: get_tiles() would copy 65536 Strings per tick.
	_calendar_alert_giver = CalendarAlertGiverType.new(_worker_view, func() -> Array[String]: return _tile_grid.tiles, _has_item_of_kind, _event_log.insert_event, _event_log.next_sequence, PRIORITY_TICK)

## Builds what is sized by the map (NeedGiver, RescueGiver, ApproachGiver, IncidentScheduler)
## and the TickPipeline over them. StateCodec.decode() calls it again after setting a saved
## map's exact size; _seed, already restored by then, salts IncidentScheduler's RNG.
func _build_dimension_services(incidents_enabled: bool) -> void:
	var bounds_max := Vector2i(_tile_grid.width - 1, _tile_grid.height - 1)
	var need_config := ContentTablesType.need_config(_content)
	_need_giver = NeedGiverType.new(_need_definitions, _need_full, int(need_config["retry_base_ticks"]), int(need_config["retry_cap_ticks"]),
		int(need_config["job_priority"]), bounds_max, _scheduler.queue.get_reservation_table(), _needs_system.need_job_targets,
		_needs_system.need_source_candidates, _tile_key, _routable_to, _scheduler.submit, _needs_system.set_need_reason,
		_needs_system.emit_need_unmet_event, _needs_system.interrupt_current_job, _needs_system.resume_interrupted_job, _content, _passability.region_reachable)
	_rescue_giver = RescueGiverType.new(RESCUE_JOB_PRIORITY, bounds_max, _scheduler.queue.get_reservation_table(),
		_tile_key, _routable_to, _trench.rescue_target_candidates, _scheduler.submit, _trench.set_rescue_reason,
		_needs_system.interrupt_current_job, _needs_system.resume_interrupted_job, _trench.is_trench_tile, _route_budget, _get_job, _trench.retire_rescue_job, _passability.region_reachable)
	# The "trapped:<victim_id>" key moves through JobQueue's activation boundary like any reservation.
	_scheduler.queue.set_extra_reservation_keys(_rescue_giver.extra_keys_for_job)
	# Shares CombatGiver's faction-aware wrappers and the same _route_budget ledger.
	_approach_giver = ApproachGiverType.new(_scheduler.submit_autonomous, _get_job, _scheduler.queue.get_jobs,
		_job_restricted_to, _passability.passable_for_flee, _actor_may_reserve_target, _passability.region_reachable,
		_flee_target_reserved, _routable_to, bounds_max, _content, _relations, _route_budget,
		_combat_giver.owns, get_objects, get_object, _object_table.object_health_at, get_object_faction_id,
		_cancel_autonomous_job)
	_incidents = IncidentSchedulerType.new(_seed, _content, _append_colonist, _remove_colonist_by_id,
		_tile_grid.width, _tile_grid.height, _passability.passable_for_faction, _is_bare_tile, _tile_grid.get_regions, _submit_incident_job,
		_get_job, _finish_job.bind("cancel_job"), _set_work_progress,
		_calendar.day_of_tick, _event_log.insert_event, _event_log.next_sequence, PRIORITY_TICK, incidents_enabled,
		_setup.enabled_incidents)
	_tick_pipeline = TickPipelineType.new(_clock, _area_orders, _needs_system, _need_giver, _haul_giver, _construction_giver,
		_combat_system, _combat_giver, _construction, _scheduler, _passability, _tile_grid, _toils, func() -> CalendarServiceType: return _calendar, _rescue_giver,
		_trench, _incidents, _approach_giver, _item_table, _event_log, _calendar_alert_giver, _progress_table, _reroutes,
		_toil_hooks, func() -> Array[Dictionary]: return _colonists, func() -> Dictionary: return _calendar_alerts_fired,
		_resolve_refused_reservations, _route, PRIORITY_TICK, _actor_index)

var command_observer: Callable # optional (command, result) listener after each apply() from outside the core (area-order expansion bypasses it); never mutates (A11)
## apply() and tick() are the only mutators; preview() is apply()'s read-only dry run.
func preview(command) -> Dictionary: return _commands.preview(command)
func apply(command) -> Dictionary:
	var result := _commands.apply(command); if command_observer.is_valid(): command_observer.call(command, result)
	return result
func tick() -> void: _tick_pipeline.run() # one tick, phases in world/tick_pipeline.gd

## The live route object through ActorTable's mover component (ADR 012).
func _route(colonist: Dictionary):
	var mover_component: Variant = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

## The worker component's labourTable through ActorTable (ADR 012): the live Dictionary.
func _labour_table(colonist: Dictionary) -> Dictionary:
	var worker_component: Variant = ActorTableType.get_component(colonist, "worker", _content)
	return worker_component.get("labourTable", {}) if worker_component != null else {}

func state_hash(include_incidents: bool = true) -> int:
	_needs_system.ensure_needs()
	_ensure_held_tool()
	CombatSystemType.ensure_health(_colonists, _content)
	# Giver associations use state_codec.gd's sorted encodings: restore order never changes the hash.
	var snapshot := {
		"seed": _seed,
		"tick": _clock.tick,
		"tool_items": _tool_store.items,
		"next_tool_item_id": _tool_store.next_id,
		"tool_reservations": _tool_store.reservations.snapshot(),
		"colonists": StateCodec._hash_colonists(_colonists, _reroutes),
		"jobs": get_jobs([], false),
		"scheduling": _scheduler.snapshot(),
		"calendar_alerts_fired": _calendar_alerts_fired,
		"tool_fetch_excluded": _toils.get_fetch_tool_excluded(),
		"combat_blocked_targets": StateCodec._encode_combat_blocked_targets(_combat_giver.get_blocked_targets()),
		"rescue_victim_assignments": StateCodec._encode_rescue_victim_assignments(_rescue_giver.get_job_victims()),
		"approach_job_targets": StateCodec._encode_approach_job_targets(_approach_giver.get_job_targets()),
	}
	if not _area_orders.is_idle(): snapshot["area_orders"] = _area_orders.encode() # pending expansion shapes the next ticks
	# Each module adds its own keys (JSON.stringify sorts keys, so insertion order is irrelevant).
	_tile_grid.hash_into(snapshot)
	_object_table.hash_into(snapshot)
	_zone_table.hash_into(snapshot)
	_item_table.hash_into(snapshot)
	_progress_table.hash_into(snapshot)
	_construction.hash_into(snapshot)
	if include_incidents: snapshot["incidents"] = {"cooldown_until_day": _incidents._cooldown_until_day, "last_processed_day": _incidents._last_processed_day, "rng_seed": _incidents._random.seed, "rng_state": _incidents._random.state}
	return hash(JSON.stringify(snapshot))

## Matches game-state.schema.json; no file I/O, callers own the bytes.
func to_save_state() -> Dictionary:
	_needs_system.ensure_needs()
	_ensure_held_tool()
	CombatSystemType.ensure_health(_colonists, _content)
	return StateCodec.encode(self)
## Reconstructs a WorldState from to_save_state(), resuming any in-flight search.
static func from_save_state(state: Dictionary) -> WorldState: return StateCodec.decode(state)

# Read-only getters (presentation and tests).
func get_seed() -> int: return _seed
func get_tick() -> int: return _clock.tick
func get_map_width() -> int: return _tile_grid.width
func get_map_height() -> int: return _tile_grid.height
func get_generator_version() -> int: return _generator_version
func get_move_ticks_per_tile() -> int: return int(_content.list("tiles")[0]["move_ticks_per_tile"])
func get_tile(x: int, y: int) -> String: return _tile_grid.get_tile(x, y)
func get_tiles() -> Array[String]: return _tile_grid.get_tiles()
func get_ground_wood(x: int, y: int) -> int: return _item_table.get_ground_wood(x, y)
func get_items() -> Array[Dictionary]: return _item_table.get_items()
func get_ground_berries(x: int, y: int) -> int: return _item_table.get_ground_berries(x, y)
func get_ground_berries_faction_id(x: int, y: int) -> String: return _item_table.get_ground_berries_faction_id(x, y)
func get_object(x: int, y: int) -> String: return _object_table.get_object(x, y)
func get_object_faction_id(x: int, y: int) -> String: return _object_table.get_object_faction_id(x, y)
func get_objects() -> Array[Dictionary]: return _object_table.get_objects()
func get_construction_sites() -> Array[Dictionary]: return _construction.get_construction_sites()
func get_construction_site(x: int, y: int) -> Dictionary: return _construction.get_construction_site(x, y)
func get_zones() -> Array[Dictionary]: return _zone_table.get_zones()
func get_zone(id: String) -> Dictionary: return _zone_table.get_zone(id)
func get_actors_with_health() -> Array[Dictionary]: return _combat_system.get_actors_with_health()
func get_pending_trade_offers() -> Array[Dictionary]: return _trade.get_pending_trade_offers()
func get_queued_job_summary() -> Dictionary: return _scheduler.queue.get_index().queued_summary()
func get_designation_changes(from: int) -> Dictionary: return _scheduler.queue.get_index().designation_changes(from)
func get_pending_job_ids_at(tile: Vector2i) -> Array[String]: return _scheduler.queue.get_index().pending_ids_at(tile)
func get_reservations() -> Dictionary: return _scheduler.queue.get_reservations()
func get_colonist_need_reason(colonist_id: String) -> String: return _needs_system.get_colonist_need_reason(colonist_id)
func get_active_need_job_id(colonist_id: String) -> String: return _need_giver.get_pending_job(colonist_id)
func get_colonist_rescue_reason(colonist_id: String) -> String: return _trench.get_colonist_rescue_reason(colonist_id)
func get_actor_combat_reason(actor_id: String) -> String: return _combat_system.get_actor_combat_reason(actor_id)
func get_active_calendar_boost(labour: String) -> int: return _calendar.active_boost(labour, _clock.tick)
func get_scheduling_metrics() -> Dictionary: return _scheduler.get_metrics()
func get_assignments() -> Dictionary: return _scheduler.get_assignments()
## Cursor stream of the cells whose tile kind or object changed (map/tile_grid.gd, A6).
func get_dirty_cells_since(cursor: int) -> Dictionary: return _tile_grid.get_dirty_cells_since(cursor)
func get_room_at(x: int, y: int) -> Dictionary: return _tile_grid.get_room_at(x, y)
func get_events(types: Array = []) -> Array[Dictionary]: return _event_log.get_events(types)
func get_events_since(sequence: int, types: Array = []) -> Dictionary: return _event_log.get_events_since(sequence, types)
func get_spawn_clearing() -> Dictionary: return _spawn_clearing.duplicate()
## The content bundle's read-only entries of `kind` (ContentRegistry.list()), for the viewer's menus.
func get_content_list(kind: String) -> Array: return _content.list(kind)
## Test-only: the simulation stream's seed/state, to compare with a pristine same-seed RNG.
func get_simulation_random_state() -> Dictionary: return {"seed": _random.seed, "state": _random.state}
## The one authoritative movement rule for a tile and its object; faction_id (F3) only matters for a door.
func passability(x: int, y: int, faction_id: String = "colony") -> Dictionary: return _passability.passability(x, y, faction_id)
## True when no job/haul reservation owns (x, y)'s "cell:" key.
func is_cell_free(x: int, y: int) -> bool: return not _scheduler.queue.get_reservation_table().is_reserved(_cell_key(x, y))

# Tool item CRUD and reservations, delegated to _tool_store (tool_item_store.gd).
func get_tool_items() -> Array[Dictionary]: return _tool_store.get_items()
func get_tool_item(item_id: String) -> Dictionary: return _tool_store.get_item(item_id)
func set_tool_item_ground(item_id: String, x: int, y: int) -> bool: return _tool_store.set_ground(item_id, x, y)
func set_tool_item_stockpile(item_id: String, x: int, y: int) -> bool: return _tool_store.set_stockpile(item_id, x, y)
func set_tool_item_held(item_id: String, colonist_id: String) -> bool: return _tool_store.set_held(item_id, colonist_id)
func reserve_tool_item(item_id: String, job_id: String) -> bool: return _tool_store.reserve(item_id, job_id)
func release_tool_item_reservation(item_id: String, job_id: String) -> bool: return _tool_store.release(item_id, job_id)
func get_tool_item_reservation(item_id: String) -> String: return _tool_store.reservation_of(item_id)
func is_tool_item_reserved(item_id: String) -> bool: return _tool_store.is_reserved(item_id)
## Shared by reference, like JobQueue.get_reservation_table().
func get_tool_reservation_table() -> ReservationTableType: return _tool_store.reservations
func is_tool_kind(kind: String) -> bool: return String(_item_definitions.get(kind, {}).get("kind", "")) == "tool"

## "" without allocating an id when kind is not a declared tool kind.
func spawn_ground_tool_item(kind: String, x: int, y: int) -> String:
	if not is_tool_kind(kind):
		return ""
	return _tool_store.spawn_ground(kind, x, y)

## The only path that finishes a scheduler job. Tool reservations are released only
## once the scheduler accepts the transition (a rejected one keeps them); an incident
## job also drops its actor, trade offer and stamped wait here.
func _finish_job(job_id: String, status: String) -> Dictionary:
	var job := _scheduler.queue.get_job(job_id)
	# Captured before finish() clears the assignment, so no trade offer outlives its trader.
	var incident_actor := _find_job_colonist(job_id) if String(job.get("kind", "")) == "incident" else {}
	var result := _scheduler.finish(job_id, status)
	if result.get("ok", false):
		_tool_store.release_all(job_id)
		_construction.site_fetch_source_retargeted.erase(job_id)
		_construction.site_fetch_picked_kind.erase(job_id)
		if String(job.get("kind", "")) == "incident":
			_incidents.on_job_finished(job_id)
			if not incident_actor.is_empty():
				_trade.pending_offers.erase(String(incident_actor["id"]))
			# An incident's wait has no job_id owner: cleared if active at finish.
			if String(job.get("status", "")) == "active":
				_progress_table.clear(job["target"])
		else:
			_progress_table.release_owned(job_id, job)
	return result

## Read-only view (A5) of the live actors get_colonists() copies, for core readers; never mutated.
func _worker_view() -> Array: return _colonists.filter(func(a: Dictionary) -> bool: return ActorTableType.has_component(a, "worker", _content))
## A thin filter over the actor table (ADR 012): copies (with the ADR 037 "carrying" view) of every worker actor.
func get_colonists() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for actor: Dictionary in _worker_view():
		copy.append(ViewSnapshotType.actor_copy(actor))
	return copy
## A9 (ADR 055): the viewer's one read-only snapshot per refresh (view_snapshot.gd), with the full
## record of only the `detail_ids` workers, in place of its several deep-copying getters.
func get_view_snapshot(detail_ids: Array = []) -> Dictionary:
	return ViewSnapshotType.build(_clock.tick, _colonists, _content, {"job_kinds": _scheduler.queue.get_job_kinds(),
		"need_status": _needs_system.need_status, "get_job": get_job, "need_job_id": get_active_need_job_id,
		"rescue_reason": get_colonist_rescue_reason}, {"assignments": get_assignments(), "queued_job_summary":
		get_queued_job_summary(), "tool_items": get_tool_items(), "items": get_items(), "construction_sites":
		get_construction_sites(), "zones": get_zones(), "pending_trade_offers": get_pending_trade_offers()}, detail_ids)

## The tool-handover overlay only mutates detached duplicates; a non-empty `kinds` keeps only those kinds, costing
## only the jobs returned (B1). Retained terminal jobs (A5) are listed unless `retired` is false (state_hash()).
func get_jobs(kinds: Array = [], retired: bool = true) -> Array[Dictionary]:
	var jobs := _scheduler.queue.get_jobs(retired) if kinds.is_empty() else _scheduler.queue.get_jobs_of_kinds(kinds, retired)
	var assignments := _scheduler.get_assignments()
	for job in jobs:
		ToolHandoverType.apply(job, assignments, _toils)
	return jobs

## One job as get_jobs() shows it ({} when unknown). A caller reading many jobs passes one get_assignments() copy.
func get_job(job_id: String, assignments: Dictionary = {}) -> Dictionary:
	var job := _scheduler.queue.get_job(job_id)
	ToolHandoverType.apply(job, assignments if not assignments.is_empty() else _scheduler.get_assignments(), _toils)
	return job

## CombatGiver's flee-destination check: true when (x, y) is already another job's "tile:" target.
func _flee_target_reserved(x: int, y: int) -> bool: return _scheduler.queue.get_reservation_table().is_reserved(_tile_key(x, y))
## CombatGiver retires a stuck queued flee job through the shared finish boundary.
func _cancel_autonomous_job(job_id: String) -> void: _finish_job(job_id, "cancel_job")

## The faction of a roster actor or a staged (not yet spawned) incident actor.
func _actor_faction(actor_id: String) -> String:
	var actor := _find_colonist(actor_id)
	if actor.is_empty():
		actor = _incidents.staged_actor(actor_id)
	return String(actor.get("factionId", "colony"))

## Autonomous reservation gate (ADR 014 Amendment). A trapped actor may reserve only its own
## tile; colony-item factions reserve anything; others their own tile or a bare one.
func _actor_may_reserve_target(actor_id: String, target: Vector2i) -> bool:
	var trapped_actor := _find_colonist(actor_id)
	if not trapped_actor.is_empty() and trapped_actor.get("trapped") != null:
		return Vector2i(int(trapped_actor["x"]), int(trapped_actor["y"])) == target
	if _passability.faction_may_reserve_colony_items(_actor_faction(actor_id)):
		return true
	if not trapped_actor.is_empty() and Vector2i(int(trapped_actor["x"]), int(trapped_actor["y"])) == target:
		return true
	return _is_bare_tile(target)

## No colony-owned thing on this tile; IncidentScheduler picks targets with it so the gate accepts them.
func _is_bare_tile(tile: Vector2i) -> bool:
	if not get_object(tile.x, tile.y).is_empty() or get_ground_berries(tile.x, tile.y) > 0 or _zone_table.is_in_any_zone(tile.x, tile.y):
		return false
	if _item_table.has_item_at(tile.x, tile.y):
		return false
	for tool_item in _tool_store.get_items():
		var location: Dictionary = tool_item.get("location", {})
		if int(location.get("x", -1)) == tile.x and int(location.get("y", -1)) == tile.y:
			return false
	return true

func _get_job(job_id: String) -> Dictionary: return _scheduler.queue.get_job(job_id)
## IncidentScheduler's submit_job (ADR 014 Amendment): autonomous, restricted to
## actor_id, activated only in the scheduler phase. "" when the queue rejected it.
func _submit_incident_job(actor_id: String, target: Vector2i) -> String:
	var result := _scheduler.submit_autonomous(target, 1, _clock.tick, "incident", actor_id)
	return String(result["job_id"]) if result.get("ok", false) else ""

## After a load (IncidentScheduler persists nothing): IncidentScheduler.reconcile_after_load().
func _reconcile_incident_jobs_after_load() -> void:
	_incidents.reconcile_after_load(_scheduler.queue.view_jobs_of_kinds(["incident"]), _scheduler.restrict_to_for,
		func(actor_id: String) -> bool: return not _find_colonist(actor_id).is_empty())

## Re-applies the viewer's incident configuration after a decode (always built
## disabled), and reserves actor ordinals past the restored roster.
func enable_incidents() -> void:
	_incidents.set_enabled(true)
	_incidents.reserve_actor_ordinal_above(_colonists)

## cell_occupied callable for _toils's place precondition.
func _is_cell_occupied(x: int, y: int, excluding_colonist_id: String) -> bool:
	return _actor_index.any_at(_colonists, x, y, excluding_colonist_id) or _item_table.has_item_at(x, y)

## command_checks.gd's sow precondition reads this name through the world.
func _has_item_of_kind(kind: String) -> bool: return _item_table.has_item_of_kind(kind)

## Fails any live haul job naming item_id once its last ground unit is gone (no endless retry).
func _fail_haul_jobs_referencing_item(item_id: String) -> void:
	for job in _scheduler.queue.view_jobs_of_kinds(["haul"]):
		if String(job["kind"]) != "haul" or String(job["status"]) not in ["queued", "active"]:
			continue
		if String(job["item_id"]) != item_id:
			continue
		_terminate_haul_job_by_id(String(job["id"]), "blocked_missing_input", "resubmit_order")

## Fails colonist_id's haul job once what it carried was consumed. A haul paused by a
## need only loses its pause entry: the route/work belong to the need job.
func _cancel_haul_job_carrying_consumed_item(colonist_id: String) -> void:
	var job_id: String = ""
	var was_paused := false
	if _needs_system.paused_jobs.has(colonist_id):
		job_id = String(_needs_system.paused_jobs[colonist_id])
		was_paused = true
	else:
		var assignment: Variant = _scheduler.get_assignments().get(colonist_id)
		if assignment != null:
			job_id = String(assignment["job_id"])
	if job_id.is_empty():
		return
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("kind", "")) != "haul":
		return
	if was_paused:
		_needs_system.paused_jobs.erase(colonist_id)
	else:
		var colonist := _find_colonist(colonist_id)
		if not colonist.is_empty():
			colonist["route"] = null
			colonist["work"] = null
			_reroutes.erase(colonist_id)
	_scheduler.queue.set_pending_fail_reason(job_id, "blocked_missing_input", "resubmit_order")
	_finish_job(job_id, "fail_job")

## start_work()'s resume lookup; a site_work job's duration always comes from its site.
func _resume_work_progress(target: Vector2i, job_id: String):
	var job := _get_job(job_id)
	if String(job.get("kind", "")) == "site_work":
		return _construction.site_work_ticks_remaining(job, target)
	return _progress_table.resume(target, job_id)

## Every work tick of every work-toil job; job_id, when set, owns the key. site_work counts on
## its site instead (one counter for N builders); a trader posts its offer on its first work tick.
func _set_work_progress(target: Vector2i, ticks_remaining: int, job_id: String = "") -> void:
	if not job_id.is_empty() and String(_scheduler.queue.get_job(job_id).get("kind", "")) == "site_work":
		var job := _get_job(job_id)
		_construction.add_site_work(job.get("site", target), "")
		return
	_progress_table.record(target, ticks_remaining, job_id)
	_trench.mirror_climb_ticks(target, ticks_remaining)
	if not job_id.is_empty() and String(_scheduler.queue.get_job(job_id).get("kind", "")) == "incident":
		_trade.maybe_post_trade_offer(job_id)

## F3: terminates every job the scheduler's faction gates refused. The refusal list is
## transient (never saved), so both tick() and OrderHandler.apply_job_command() drain
## it, looping because one resolution may cause another.
func _resolve_refused_reservations() -> void:
	var refused := _scheduler.take_refused_reservations()
	while not refused.is_empty():
		for entry in refused:
			var job_id: String = String(entry["job_id"])
			var worker: String = String(entry["worker"])
			var job := _scheduler.queue.get_job(job_id)
			if String(job.get("kind", "")) in ["haul", "site_fetch"]:
				var refused_colonist := _find_colonist(worker)
				if not refused_colonist.is_empty():
					_toil_bindings.drop_carried_item_from(refused_colonist)
			_scheduler.queue.set_pending_fail_reason(job_id, REASON_NOT_ORDERED_BY_PLAYER, "assign_an_orderable_actor")
			if _finish_job(job_id, "fail_job").get("ok", false):
				_progress_table.clear_terminated_job(job_id, job, false)
			_resolve_giver_association(job_id, String(job.get("kind", "")))
		refused = _scheduler.take_refused_reservations()

## NeedsSystem.resume_paused_job()'s first go_to leg; unreachable goes through
## ToilBindings.toil_on_unreachable(), never a plain resubmit.
func _advance_go_to_or_resubmit(colonist: Dictionary, job_id: String, job: Dictionary, target: Vector2i) -> void:
	var on_arrive := Callable(_toils, "start_work") if _toils.leads_into_work(String(job["kind"]), true) else Callable(_toil_bindings, "toil_no_op_arrive")
	if _toils.advance_go_to(colonist, job_id, target, _routable_to(target, String(colonist.get("factionId", "colony"))), "go_to", on_arrive) != "unreachable":
		return
	_toil_bindings.toil_on_unreachable(job_id, job, true)

## Resubmits an unreachable first leg (blocked_target_unreachable), keeping the need colonist
## or the player's assignee, read before _finish_job() erases it.
func _resubmit_unreachable_job(job_id: String, job: Dictionary) -> void:
	var priority: int = int(job["priority"])
	var kind: String = String(job["kind"])
	var target: Vector2i = job["target"]
	var need_colonist_id := _need_giver.colonist_for_job(job_id)
	var restrict_to := need_colonist_id if not need_colonist_id.is_empty() else _scheduler.restrict_to_for(job_id)
	_finish_job(job_id, "cancel_job")
	var result := _scheduler.submit(target, priority, _clock.tick, kind, restrict_to)
	if not need_colonist_id.is_empty():
		if result.get("ok", false): _need_giver.reassign_job(job_id, String(result["job_id"]))
		else: _need_giver.resolve_job(job_id)

## A fresh bounded re-route search within this map's bounds (injected into _toils).
func _route_search_factory(start: Vector2i, target: Vector2i, passable: Callable) -> RerouteType:
	var bounds_max := Vector2i(_tile_grid.width - 1, _tile_grid.height - 1)
	return RerouteType.new(start, target, passable, Vector2i.ZERO, bounds_max, _passability.region_reachable)

## Faction passability with the scheduler's target-tile exception: a route may end on
## its own impassable target (a chop job's tree).
func _routable_to(target: Vector2i, faction_id: String = "colony") -> Callable:
	return func(tile: Vector2i) -> float:
		var cost := _passability.passable_for_faction(tile, faction_id)
		if tile == target and cost <= 0.0:
			return 1.0
		return cost

## Chebyshev adjacency, matching pick_up()/place()'s "on or adjacent to".
func _colonist_within_reach(colonist: Dictionary, tile: Vector2i) -> bool:
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	return maxi(absi(colonist_tile.x - tile.x), absi(colonist_tile.y - tile.y)) <= 1

## The colonist currently assigned to job_id, or {} when none.
func _find_job_colonist(job_id: String) -> Dictionary:
	var assignments := _scheduler.get_assignments()
	for worker in assignments:
		if String(assignments[worker]["job_id"]) == job_id:
			for colonist in _colonists:
				if String(colonist["id"]) == worker:
					return colonist
	return {}

## Delegations to ToilBindings for modules built before it.
func _work_target_for(job: Dictionary) -> Vector2i: return _toil_bindings.work_target_for(job)
func _drop_carried_haul_item(job_id: String) -> void: _toil_bindings.drop_carried_haul_item(job_id)
func _terminate_haul_job_by_id(job_id: String, reason: String, remedy: String) -> void: _toil_bindings.terminate_haul_job_by_id(job_id, reason, remedy)
func _resolve_giver_association(job_id: String, kind: String) -> void: _toil_bindings.resolve_giver_association(job_id, kind)


## Backfills a missing "held_tool" with "" by plain append (never a rebuild), so
## state_hash()'s key order matches a decoded colonist's; workers only (F2).
func _ensure_held_tool() -> void:
	for colonist in _colonists:
		if not colonist.has("held_tool") and ActorTableType.has_component(colonist, "worker", _content):
			colonist["held_tool"] = ""

## restrict_to_for(), else the waiting entry's restriction, so a never-activated job
## restricted to a just-killed actor cannot survive CombatSystem.cleanup_actor_scheduling().
func _job_restricted_to(job_id: String) -> String:
	var restrict_to := _scheduler.restrict_to_for(job_id)
	if not restrict_to.is_empty():
		return restrict_to
	return _scheduler.waiting_restrict_to(job_id)

## JobQueue's "tile:" target keys and is_cell_free()'s distinct "cell:" keys (colonist-ai.md 3.4).
func _tile_key(x: int, y: int) -> String: return "tile:%d,%d" % [x, y]
func _cell_key(x: int, y: int) -> String: return "cell:%d,%d" % [x, y]

## ActorTable.spawn()'s default labourTable, also NeedsSystem.ensure_needs()'s backfill.
func _default_labour_table() -> Dictionary:
	var worker_tunables: Dictionary = _content.get_entry("actors", "colonist").get("tunables", {}).get("worker", {})
	return WorkerType.default_labour_table(worker_tunables)

## `return` alone can't stop `.new()` handing back an unusable WorldState.
func _fail_startup(message: String) -> void:
	push_error("WorldState: %s" % message)
	OS.kill(OS.get_process_id())

## Travel cost from `from` to `to` under the same rule the go_to toil moves by, run to
## completion (bounded by the map). -1 when unreachable.
func _route_cost(from: Vector2i, to: Vector2i, faction_id: String) -> int:
	if from == to: return 0
	var route := _route_search_factory(from, to, _routable_to(to, faction_id))
	while not route.is_terminal(): route.resume()
	if route.get_status() != RerouteType.STATUS_FOUND: return -1
	return route.get_path().size() - 1

func _colonist_at(x: int, y: int) -> bool:
	return _actor_index.any_at(_colonists, x, y)

## The live colonist Dictionary for colonist_id, or {} when unknown.
func _find_colonist(colonist_id: String) -> Dictionary:
	return _actor_index.find(_colonists, colonist_id)

func _append_colonist(actor: Dictionary) -> void: # IncidentScheduler append/remove callables
	if not actor.has("trapped"): actor["trapped"] = null
	_colonists.append(actor)
	_actor_index.added(actor)

## The one path that removes an actor from the roster (CombatSystem death, and every
## terminal incident-job transition); scheduling cleanup runs first. A death always
## removes; an incident despawn leaves a trapped actor in its trench.
func _remove_colonist_by_id(colonist_id: String, is_death: bool = false) -> void:
	_combat_system.cleanup_actor_scheduling(colonist_id)
	for i in _colonists.size():
		if String(_colonists[i]["id"]) == colonist_id:
			if not is_death and _colonists[i].get("trapped") != null: # trapped, not despawned
				return
			_actor_index.removed(_colonists[i])
			_colonists.remove_at(i)
			# A despawned actor gets no further advance_colonists pass to release its reroute.
			_reroutes.erase(colonist_id)
			return
