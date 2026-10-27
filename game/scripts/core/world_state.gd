class_name WorldState
extends RefCounted

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
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
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
const OrderHandlerType = preload("res://scripts/core/commands/handlers/order_handler.gd")
const ConstructionHandlerType = preload("res://scripts/core/commands/handlers/construction_handler.gd")
const ZoneHandlerType = preload("res://scripts/core/commands/handlers/zone_handler.gd")
const ActorHandlerType = preload("res://scripts/core/commands/handlers/actor_handler.gd")
const IncidentHandlerType = preload("res://scripts/core/commands/handlers/incident_handler.gd")
const ActorIndexType = preload("res://scripts/core/actors/actor_index.gd")

## Default/fixture map size: every existing test and the debug scenario
## construct WorldState with no explicit width/height and must keep getting
## this exact 48x48 map. The "normal UI" new-game size is content-driven
## instead (mapgen.json's default_new_game_width/height); boot.gd passes
## that explicitly rather than relying on these constants.
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
## Salts for _generate_map()/_spawn_colonists()'s own local RNGs, distinct
## from each other and from incident_scheduler.gd's SEED_SALT (914_827) so no
## two of this world's independent streams ever share a draw sequence.
const GEOGRAPHY_SEED_SALT := 402_653
const PLACEMENT_SEED_SALT := 219_961
## ADR 026: dig's find_table roll gets its own salted stream, distinct from
## every salt above and from world_generator.gd's OUTCROP_SEED_SALT (100_003).
const DIG_FIND_SEED_SALT := 738_419

const PRIORITY_COMMAND := 0
const PRIORITY_TICK := 100

## Static, not const (a const can't read needs.json at runtime); set in
## _init(). Kept only for colonist_panel.gd's NEED_FULL read.
static var NEED_FULL: int = 0

const REASON_NEED_UNMET_PREFIX := NeedsSystemType.REASON_NEED_UNMET_PREFIX
const REASON_BLOCKED_SOURCE_RESERVED := "blocked_source_reserved"
const REASON_BLOCKED_SOURCE_UNREACHABLE := "blocked_source_unreachable"
## F3: shared by OrderHandler.apply_job_command()'s assignee check and
## _resolve_refused_reservations()'s typed termination of a job
## GlobalAssignment's reservation gate refused (see set_reservation_gate()
## in _init() below).
const REASON_NOT_ORDERED_BY_PLAYER := "not_ordered_by_player"
## F5 combat: exposed by get_actor_combat_reason() (actors/combat_system.gd).
const REASON_FIGHTING := CombatSystemType.REASON_FIGHTING
## Trapped-actor rescue (docs/architecture/colonist-ai.md 3.6): exposed by
## get_colonist_rescue_reason() for a trapped colonist while RescueGiver's own
## search finds no reachable candidate rescuer at all -- including the
## degenerate case every other colonist is itself trapped.
const REASON_NO_RESCUER_AVAILABLE := RescueGiverType.REASON_NO_RESCUER_AVAILABLE
## rescue's own submit() priority (Priority.NORMAL, matching needs.json's
## job_priority for every need kind): committed-proposal placement bypasses
## ordinary scoring entirely (colonist-ai.md 3.1/3.6), so this only matters if
## a rescue job ever fell back to open competition, which it never does.
const RESCUE_JOB_PRIORITY := 1

## Per-colonist labour table: a priority 0 (off) .. 4 per
## labour kind, editable via set_labour, defaulted to 3.
const LABOUR_KINDS := ["mine", "chop", "farm", "haul", "build", "craft", "cook"]
const LABOUR_DEFAULT := 3
const LABOUR_MIN := 0
const LABOUR_MAX := 4

var _seed: int
## Map dimensions, tiles, water cache, dirty cells, regions and rooms
## (map/tile_grid.gd). Its width/height are resolved once in _init()
## (WorldGeneratorType.resolve_size()), or overwritten by StateCodec.decode()
## with a loaded save's exact size; loading a different save replaces the whole WorldState.
var _tile_grid: TileGridType
## The algorithm that actually produced _tile_grid.tiles: the running build's constant
## for a freshly generated world, or a loaded save's own map.generatorVersion
## (state_codec.gd's decode() overwrites this directly), so re-saving an
## older save keeps its true provenance instead of relabelling it.
var _generator_version: int = WorldGeneratorType.GENERATOR_VERSION
var _clock: SeededClock
## The simulation stream: AssignmentType's own scheduling draws. Seeded
## directly from _seed and never advanced by _generate_map()/
## _spawn_colonists() (each uses its own salted local RNG instead,
## GEOGRAPHY_SEED_SALT/PLACEMENT_SEED_SALT above), so mapgen.json tuning can
## never perturb this stream's continuation -- see
## test_river_generation.gd's _check_generation_does_not_perturb_simulation_stream().
var _random: RandomNumberGenerator
## Generation-time scratch: _generate_map() stashes WorldGenerator's river/berry-bush
## output so _spawn_colonists() (the next _init() call) can turn bushes into _object_table.objects and
## bias its clearing search toward the river. Emptied there; never read after, never persisted.
var _pending_water_tiles: Array[Vector2i] = []
var _pending_berry_bush_tiles: Array[Vector2i] = []
## The starting clearing WorldGenerator.place_spawn() chose: {x, y, width, height,
## water_steps, food_steps, tree_steps, fallback}. Read by debug_scenario.gd/boot.gd to place
## content relative to the real spawn and by the seed-suite tests asserting no fallback.
## Empty ({}) on a StateCodec.decode()d world, which never calls _spawn_colonists().
var _spawn_clearing: Dictionary = {}
var _colonists: Array[Dictionary] = []
## Id and tile lookups over _colonists, trusted only inside tick() (actor_index.gd).
var _actor_index := ActorIndexType.new()
## Ground items, ground berries, their factions and dig's find roll (ADR 026).
var _item_table: ItemTableType
## Read-through accessors kept for viewer/debug_scenario.gd, which seeds its
## starting farm stock through these two names (the viewer is outside R2).
var _items: Dictionary:
	get:
		return _item_table.items
var _next_item_id: int:
	get:
		return _item_table.next_item_id
	set(value):
		_item_table.next_item_id = value
## Identity-bearing tool items (axe/pick) and their reservations; see tool_item_store.gd.
var _tool_store: ToolItemStoreType
var _item_definitions: Dictionary = {}
## Placed objects, their footprints, factions, health and orientation (objects/object_table.gd).
var _object_table: ObjectTableType
## Stockpile zones and the zone id counter (objects/zone_table.gd).
var _zone_table: ZoneTableType
## The movement and faction rules over _tile_grid/_object_table (map/passability.gd).
var _passability: PassabilityType
## The single content bundle loader (F1), schema-validated and
## cross-reference-checked at construction.
var _content: ContentRegistryType
var _object_definitions: Dictionary = {}
var _need_definitions: Dictionary = {}
var _tile_definitions: Dictionary = {}
var _work_ticks: Dictionary = {} # see _load_work_ticks()
var _need_full: int = 0 # see _load_need_config()
var _mapgen: Dictionary = {}
var _scheduler: AssignmentType
var _toils: ToilExecutorType
## The per-kind toil callbacks and carried-item drops (jobs/toil_bindings.gd).
var _toil_bindings: ToilBindingsType
## _toil_bindings.hooks: ToilExecutor.advance()'s hooks (StateCodec reads it too).
var _toil_hooks: Dictionary = {}
## Events, their sequence counter and the command envelopes (world/event_log.gd).
var _event_log: EventLogType
var _commands: CommandRouterType # apply()/preview(): validation, dispatch, envelopes
var _area_orders: AreaOrders # pending area_order expansions, a budget per tick (commands/area_orders.gd, ADR 044)
## Live in-flight re-route searches, keyed by colonist id, shared by
## reference with _toils.
var _reroutes: Dictionary = {}

## Work-toil progress, its owners and suspended progress (jobs/work_progress.gd).
var _progress_table: WorkProgressType
## job kind -> its needs_tool item kind, from content/jobs.json.
var _needs_tool_by_kind: Dictionary = {}
## colonist_id -> true once its per-tick routing allowance is spent,
## shared by reference with ToilExecutor/GlobalAssignment.
var _route_budget: Dictionary = {}
## Decides when eat_food/drink_water/sleep jobs exist.
var _need_giver: NeedGiverType
## Decides when a rescue job exists for a trapped colonist.
var _rescue_giver: RescueGiverType
## Trapping, escape_trench climb-out, rescue pools and rescue reasons (actors/trench_system.gd).
var _trench: TrenchSystemType
## Needs decay, interrupt pause/resume, need reasons, sources and effects (actors/needs_system.gd).
var _needs_system: NeedsSystemType
## Decides when a haul job exists and where it delivers to.
var _haul_giver: HaulGiverType
## The "calendar boost" term in the effective-priority formula (ADR 008).
var _calendar: CalendarServiceType
var _calendar_alert_giver: CalendarAlertGiverType
var _calendar_alerts_fired: Dictionary = {}
## Incident draws (ADR 017): owns its own seeded RNG, distinct from _random, so it never perturbs the shared stream. Its cooldowns/last-drawn-day/RNG state are read/written directly by state_codec.gd/state_hash() (ADR 004), since incident_scheduler.gd has no accessor for them.
var _incidents: IncidentSchedulerType
## F5 combat (ADR 021): the faction-relation reader (F3, docs/decisions/
## 014-factions-and-relations.md) combat targeting reads for hostility, and
## the job-giver deciding when a `flee` job should exist (rule 4). Also the
## ADR 014 hostility check for trapped-actor auto-submission.
var _relations: RelationsType
var _combat_giver: CombatGiverType
## Per-tick combat, deaths and their scheduling cleanup, the combat reason and the
## health/combat backfills (actors/combat_system.gd).
var _combat_system: CombatSystemType
## Decides when an `approach` job should exist for a hostile actor not yet
## adjacent to a hostile target (ADR 033).
var _approach_giver: ApproachGiverType
## Construction sites, their fetch/work flow and the two site-fetch runtime
## caches (objects/construction_system.gd).
var _construction: ConstructionSystemType
## Decides when a site's next fetch/work job should exist (ADR 040).
var _construction_giver: ConstructionGiverType
## Trader offers and accept_trade (economy/trade_system.gd); offers are never persisted or hashed.
var _trade: TradeSystemType

## incidents_enabled defaults false so every pre-existing caller keeps ticking byte-identically.
func _init(p_seed: int = 1337, tick_rate: int = 10, p_width: int = MAP_WIDTH, p_height: int = MAP_HEIGHT, incidents_enabled: bool = false) -> void:
	_seed = p_seed
	_clock = SeededClockType.new(tick_rate)
	_random = RandomNumberGenerator.new()
	_random.seed = p_seed
	# Dig's find_table stream (ADR 026), salted so it never perturbs _random;
	# owned by _item_table, which StateCodec.decode() restores its continuation into.
	var dig_find_random := RandomNumberGenerator.new()
	dig_find_random.seed = p_seed + DIG_FIND_SEED_SALT
	_content = ContentRegistryType.new()
	if not _content.is_valid():
		_fail_startup("fatal ContentRegistry startup failure: %s" % _content.get_error())
		return
	_relations = RelationsType.new(_content)
	_object_definitions = _load_object_definitions()
	_need_definitions = _load_need_definitions()
	_item_definitions = _load_item_definitions()
	_tile_definitions = _index_by_field(_content.list("tiles"), "id")
	_mapgen = _content.document("mapgen").duplicate(true)
	var resolved_size := WorldGeneratorType.resolve_size(p_width, p_height, _mapgen)
	_zone_table = ZoneTableType.new()
	_tile_grid = TileGridType.new(resolved_size.x, resolved_size.y, passability, get_object, _zone_table.is_in_any_zone)
	_object_table = ObjectTableType.new(_object_definitions, _tile_grid)
	_passability = PassabilityType.new(_content, _tile_grid, _object_table, _object_definitions, _tile_definitions,
		_actor_faction, _find_colonist)
	_need_full = int(_load_need_config()["full"]); NEED_FULL = _need_full # set before _spawn_colonists() and the NeedsSystem/NeedGiver constructors
	_tile_grid.tiles = _generate_map()
	_colonists = _spawn_colonists(_tile_grid.tiles)
	CombatSystemType.ensure_combat(_colonists, _content)
	_tool_store = ToolItemStoreType.new(_find_colonist)
	_scheduler = AssignmentType.new(_random, _content)
	_event_log = EventLogType.new(_clock, _scheduler.queue, PRIORITY_COMMAND)
	_item_table = ItemTableType.new(_content, dig_find_random, func() -> Array[Dictionary]: return _colonists,
		passability, get_tile, _zone_table.is_in_any_zone, _scheduler.queue.get_reservation_table,
		_fail_haul_jobs_referencing_item, _cancel_haul_job_carrying_consumed_item)
	# F3: wires GlobalAssignment's two faction gates through this
	# WorldState's own colonist/registry lookups, never a hardcoded "colony"
	# string -- see _passability.colonist_may_be_ordered()/_passability.colonist_may_reserve_colony_items().
	_scheduler.set_order_eligibility(_passability.colonist_may_be_ordered)
	_scheduler.set_reservation_gate(_passability.colonist_may_reserve_colony_items)
	# F5 (ADR 014 Amendment): an autonomous (incident) entry's own
	# target-aware reservation gate and faction-aware route passability.
	_scheduler.set_autonomous_reservation_gate(_actor_may_reserve_target)
	_scheduler.set_autonomous_passability(_passability.passable_for_worker)
	# A flee job (rule 4) submits autonomously too, the same reason
	# an incident actor's own job does -- a non-colony actor's own job must
	# skip the ordinary may_be_ordered gate (ADR 014 Amendment). Wired through
	# the same interrupt/resume boundary NeedGiver uses (ADR 009) and the same
	# reservation-eligibility/faction-passability/region-reachability checks
	# submit_autonomous()'s own reserve step consults, so a candidate this
	# giver picks is never refused there for a reason it could have checked
	# itself.
	# GlobalAssignment.restrict_to_for() only reads
	# _activated_entries, "" by its own contract for a job that has never
	# activated (still queued or mid its own initial route search) -- exactly
	# the state a freshly submitted flee job is in for at least one tick.
	# _job_restricted_to() (below) also falls back to the raw waiting-queue
	# entry, so a save/load mid-flee (queued or still searching) still finds
	# its own actor's restriction and never submits a duplicate leg.
	_combat_giver = CombatGiverType.new(_scheduler.submit_autonomous, _get_job, _scheduler.queue.get_jobs,
		_job_restricted_to, func(colonist: Dictionary) -> void: _needs_system.interrupt_current_job(colonist),
		func(colonist_id: String) -> void: _needs_system.resume_interrupted_job(colonist_id), _passability.passable_for_flee,
		_actor_may_reserve_target, _passability.region_reachable, Vector2i(_tile_grid.width - 1, _tile_grid.height - 1), _content, _relations,
		_flee_target_reserved, _cancel_autonomous_job)
	_calendar = CalendarServiceType.new("", _content.document("calendar"))
	_work_ticks = _load_work_ticks()
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
	_area_orders = AreaOrders.new(apply, get_construction_site, _scheduler.queue.get_index, _scheduler.queue.get_next_id, _construction.site_table.get_next_id, _event_log, _clock)
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
	# job kind -> {"kind","retry_base_ticks","retry_cap_ticks"}: JobQueue's tool gate, through ToilBindings.
	var tool_requirements_by_kind: Dictionary = {}
	for job_def in _content.list("jobs"):
		var needs_tool := String(job_def.get("needs_tool", ""))
		if not needs_tool.is_empty():
			if not (job_def.has("retry_base_ticks") and job_def.has("retry_cap_ticks")):
				_fail_startup("jobs.json's '%s' entry declares needs_tool but is missing retry_base_ticks/retry_cap_ticks" % job_def["kind"])
				return
			_needs_tool_by_kind[String(job_def["kind"])] = needs_tool
			tool_requirements_by_kind[String(job_def["kind"])] = {
				"kind": needs_tool,
				"retry_base_ticks": int(job_def["retry_base_ticks"]),
				"retry_cap_ticks": int(job_def["retry_cap_ticks"]),
			}
	var haul_definition: Dictionary = _index_by_field(_content.list("jobs"), "kind").get("haul", {})
	if not (haul_definition.has("priority") and haul_definition.has("retry_base_ticks") and haul_definition.has("retry_cap_ticks")):
		_fail_startup("jobs.json's 'haul' entry is missing priority/retry_base_ticks/retry_cap_ticks")
		return
	_toils = ToilExecutorType.new(int(_content.list("tiles")[0]["move_ticks_per_tile"]), _work_ticks, passability, _get_job,
		_content, _item_table.item_lookup, _item_table.remove_ground_item_units, _item_table.place_new_ground_item, _is_cell_occupied,
		func(job_id: String) -> bool: return _needs_system.consume_source_valid(job_id),
		_resume_work_progress, _set_work_progress, _progress_table.clear, _reroutes, _route_search_factory,
		get_tool_items, get_tool_item, get_tool_item_reservation, reserve_tool_item, release_tool_item_reservation,
		set_tool_item_held, set_tool_item_ground, get_colonists, _route_budget,
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
	# After NeedsSystem (it detaches paused jobs on death); ApproachGiver through a lambda:
	# _build_dimension_services() rebuilds it.
	_combat_system = CombatSystemType.new(_content, _relations, PRIORITY_TICK, _scheduler, _progress_table, _tool_store,
		_item_table, _object_table, _event_log, _needs_system, _combat_giver, func() -> Array[Dictionary]: return _colonists,
		func(actor_id: String) -> void: _approach_giver.forget(actor_id), _job_restricted_to, _finish_job,
		_resolve_giver_association, _remove_colonist_by_id, is_tool_kind, spawn_ground_tool_item)
	# Last of the modules: its hooks reach every system above. The giver lambdas: _build_dimension_services()
	# rebuilds NeedGiver/RescueGiver.
	_toil_bindings = ToilBindingsType.new(_scheduler, _toils, _item_table, _tool_store, _tile_grid, _object_table, _passability,
		_construction, _trench, _needs_system, _reroutes, tool_requirements_by_kind, func() -> Array[Dictionary]: return _colonists,
		_find_colonist, _find_job_colonist, _finish_job, _resubmit_unreachable_job, _routable_to, _route_cost,
		func(job_id: String) -> void: _need_giver.resolve_job(job_id), func(job_id: String) -> void: _rescue_giver.resolve_job(job_id))
	_scheduler.set_route_budget(_route_budget)
	_scheduler.queue.set_tool_requirement(_toil_bindings.tool_requirement_for_kind, _toil_bindings.tool_exists)
	_toil_hooks = _toil_bindings.hooks
	_scheduler.queue.set_haul_backoff(int(haul_definition["retry_base_ticks"]), int(haul_definition["retry_cap_ticks"]))
	_haul_giver = HaulGiverType.new(int(haul_definition["priority"]), get_jobs.bind(["haul"]), get_items, _zone_table.is_in_any_zone, _scheduler.submit,
		_scheduler.queue.attach_item, get_zones, is_cell_free, passability, _is_cell_occupied)
	_scheduler.queue.set_haul_destination_finder(_haul_giver.find_free_haul_cell)
	# The queue's own kind-filtered read: get_jobs()'s tool-handover overlay never touches site_fetch/site_work (no tool).
	_construction_giver = ConstructionGiverType.new(_construction.site_table.list, _scheduler.queue.get_jobs_of_kinds.bind(["site_fetch", "site_work"]), _item_table.get_items,
		_zone_table.is_in_any_zone, _construction.construction_item_reservation_owner, _construction.submit_site_fetch,
		_construction.submit_site_work, _construction.site_table.materials_met, _construction.site_table.remaining)
	# Live _tile_grid.tiles by reference: the giver only scans it per tick, and get_tiles() would copy 65536 Strings.
	_calendar_alert_giver = CalendarAlertGiverType.new(get_colonists, func() -> Array[String]: return _tile_grid.tiles, _has_item_of_kind, _event_log.insert_event, _event_log.next_sequence, PRIORITY_TICK)
	_build_dimension_services(incidents_enabled)

## Builds NeedGiver and IncidentScheduler from this WorldState's current
## _tile_grid.width/_tile_grid.height: factored out of _init() so
## StateCodec.decode() can call it again after overwriting the constructor's
## resolve_size()-clamped _tile_grid.width/_tile_grid.height with a saved map's own exact
## dimensions. Without a rebuild, a saved map smaller than
## WorldGenerator's 16-tile new-game minimum (e.g. 8x8) left NeedGiver's
## source-candidate bounds and IncidentScheduler's edge-spawn bounds pointing
## at the constructor's clamped 16x16 box -- a trader incident would search
## for its east edge at x=15 on a map only 8 tiles wide and never spawn.
## _seed (not the constructor's p_seed parameter) so a call from decode()
## after StateCodec has already overwritten it still salts IncidentScheduler's
## own RNG with the saved world's real seed.
func _build_dimension_services(incidents_enabled: bool) -> void:
	var bounds_max := Vector2i(_tile_grid.width - 1, _tile_grid.height - 1)
	var need_config := _load_need_config()
	_need_giver = NeedGiverType.new(_need_definitions, _need_full, int(need_config["retry_base_ticks"]), int(need_config["retry_cap_ticks"]),
		int(need_config["job_priority"]), bounds_max, _scheduler.queue.get_reservation_table(), _needs_system.need_job_targets,
		_needs_system.need_source_candidates, _tile_key, _routable_to, _scheduler.submit, _needs_system.set_need_reason,
		_needs_system.emit_need_unmet_event, _needs_system.interrupt_current_job, _needs_system.resume_interrupted_job, _content)
	_rescue_giver = RescueGiverType.new(RESCUE_JOB_PRIORITY, bounds_max, _scheduler.queue.get_reservation_table(),
		_tile_key, _routable_to, _trench.rescue_target_candidates, _scheduler.submit, _trench.set_rescue_reason,
		_needs_system.interrupt_current_job, _needs_system.resume_interrupted_job, _trench.is_trench_tile, _route_budget, _get_job, _trench.retire_rescue_job)
	# The "trapped:<victim_id>" key now moves through
	# JobQueue's own activation/reactivation boundary like any other job's
	# reservation, instead of RescueGiver acquiring it directly -- see
	# rescue_giver.gd's own class doc comment and job_queue.gd's
	# set_extra_reservation_keys().
	_scheduler.queue.set_extra_reservation_keys(_rescue_giver.extra_keys_for_job)
	# Shares CombatGiver's own faction-aware passability/
	# reservation-eligibility/region-reachability/target-reservation wrappers
	# and the same _route_budget ledger RescueGiver/CombatGiver already share.
	_approach_giver = ApproachGiverType.new(_scheduler.submit_autonomous, _get_job, _scheduler.queue.get_jobs,
		_job_restricted_to, _passability.passable_for_flee, _actor_may_reserve_target, _passability.region_reachable,
		_flee_target_reserved, _routable_to, bounds_max, _content, _relations, _route_budget,
		_combat_giver.owns, get_objects, get_object, _object_table.object_health_at, get_object_faction_id,
		_cancel_autonomous_job)
	_incidents = IncidentSchedulerType.new(_seed, _content, _append_colonist, _remove_colonist_by_id,
		_tile_grid.width, _tile_grid.height, _passability.passable_for_faction, _is_bare_tile, _tile_grid.get_regions, _submit_incident_job,
		_get_job, _finish_job.bind("cancel_job"), _set_work_progress,
		_calendar.day_of_tick, _event_log.insert_event, _event_log.next_sequence, PRIORITY_TICK, incidents_enabled)

## Read-only dry run of apply()'s own rules (CommandRouter.preview()).
func preview(command) -> Dictionary:
	return _commands.preview(command)

## Only mutator alongside tick(): validates and applies a command envelope.
func apply(command) -> Dictionary:
	return _commands.apply(command)

## Only mutator alongside apply(): advances exactly one tick.
func tick() -> void:
	_actor_index.begin_tick(_colonists); _item_table.begin_tick()
	_area_orders.advance() # commands of tick T, applied before it advances
	_clock.advance(1)
	_needs_system.decay_needs()
	_need_giver.advance(_colonists_not_combat_owned(), _clock.tick)
	_haul_giver.advance(_clock.tick)
	_construction_giver.advance(_clock.tick)
	_combat_system.apply_combat(_clock.tick)
	var active_site_fetch_jobs_before := _construction.active_site_fetch_job_ids()
	_scheduler.tick(_clock.tick, _scheduler_workers(), _passability.is_passable, Vector2i.ZERO,
		Vector2i(_tile_grid.width - 1, _tile_grid.height - 1), _toils.get_labour, _calendar.active_boost, _colonists,
		_committed_jobs(), _tile_grid.get_regions().reachable)
	# Hands-filling rules: a site_fetch job's own submission-time seed
	# is a position-agnostic placeholder (no colonist is chosen yet at
	# submission); the instant one really (re)activates with a colonist
	# known, swap it for the true nearest-to-builder source before
	# _advance_colonists() ever drives it -- see
	# ConstructionSystem.resolve_freshly_activated_site_fetch_sources().
	_construction.resolve_freshly_activated_site_fetch_sources(active_site_fetch_jobs_before)
	# RescueGiver's own route searches
	# share _route_budget (the per-colonist, per-tick ledger ADR 004 bounds)
	# with the scheduler's activation searches above and the toil executor's
	# re-routes below, so it runs between them -- after tick() clears that
	# ledger, before _advance_colonists() honours it. Its commitments reach
	# the scheduler's committed-proposal path next tick (rescue_giver.gd).
	_rescue_giver.advance(_trench.rescue_candidates(), _trench.trapped_rescue_victims(), _clock.tick)
	# F5: staged incident actors whose job just activated enter the world now,
	# before _advance_colonists() drives their first toil (ADR 014 Amendment).
	_incidents.activate_pending()
	# Same activation-gated timing as the incident line above (ADR 026).
	_trench.activate_pending_escapes()
	_advance_colonists()
	# Runs after _advance_colonists(), not alongside
	# CombatGiver/RescueGiver above: its own "already adjacent" check (rule 1)
	# must see this tick's post-movement positions, the exact ones
	# CombatResolver.resolve_tick() will check first thing next tick (nothing
	# moves in between) -- checking pre-movement positions here would submit a
	# redundant approach job for an actor that just walked into range this
	# same tick. Running after _advance_colonists() also means an actor that
	# falls into a trench (and is submitted an escape_trench job) this tick is
	# already `trapped` by the time this giver ever looks at it, so it can
	# never win a same-tick race for that actor's own scheduler slot against
	# escape_trench (both submit at the same priority; the queue only tries
	# one candidate per worker per tick, so an approach job that got there
	# first would otherwise delay escape_trench's own first activation by a
	# tick). Still shares the shared _route_budget ledger correctly: cleared
	# once at the top of _scheduler.tick() above, so this giver's own resume()
	# calls (like the toil executor's re-routes just before it in this same
	# tick) draw from that same freshly-cleared budget.
	_approach_giver.advance(_colonists, _clock.tick)
	# ADR 026: every dig completion this tick is staged, never rolled inline,
	# so this drains in ascending job-id order regardless of the colonist-id
	# order _advance_colonists() just processed them in.
	_item_table.resolve_dig_finds()
	# F3: drained after _advance_colonists() -- a need
	# resolving there can itself trigger a second refusal via
	# resume_interrupted_job(), which must drain too before this returns.
	_resolve_refused_reservations()
	_event_log.collect_queue_events()
	_calendar_alert_giver.advance(_clock.tick, _calendar, _calendar_alerts_fired)
	_incidents.advance(_clock.tick)
	_event_log.insert_event({
		"type": "tick_advanced",
		"tick": _clock.tick,
		"system_priority": PRIORITY_TICK,
		"entity_id": "world",
		"sequence": _event_log.next_sequence(),
		"data": {}
	})
	_actor_index.end_tick(); _item_table.end_tick()

## Every colonist not currently mid-search for a need source (colonist-ai.md
## 3.1), except one CombatGiver already tracks as fleeing.
## Passed to GlobalAssignment.tick() in place of the full colonist list so it
## can never propose/activate a work job for a colonist NeedGiver has not yet
## finished deciding about. A colonist already pursuing a committed need job
## is deliberately not excluded either: its scheduler assignment already
## reflects that job, so GlobalAssignment.tick()'s own `_assignments.has()`
## check already skips it.
## Excludes colonists CombatGiver.owns() (an open flee
## episode) from NeedGiver.advance(), so a search or onset never touches the
## shared NeedsSystem.paused_jobs entry CombatGiver owns until the episode closes.
func _colonists_not_combat_owned() -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for colonist in _colonists:
		if _combat_giver.owns(String(colonist["id"])):
			continue
		filtered.append(colonist)
	return filtered

func _colonists_not_searching_need() -> Array[Dictionary]:
	var searching := _need_giver.searching_colonist_ids()
	var fleeing := _combat_giver.get_committed_jobs()
	var filtered: Array[Dictionary] = []
	for colonist in _colonists:
		var colonist_id: String = String(colonist["id"])
		# An actor mid need-search must still be proposed the
		# scheduler tick it is fleeing in -- otherwise CombatGiver's own flee
		# commitment (_committed_jobs() below) never even reaches GlobalAssignment.tick()
		# for it, and the flee job it just submitted sits forever unassigned.
		if searching.has(colonist_id) and not fleeing.has(colonist_id):
			continue
		filtered.append(colonist)
	return filtered

## GlobalAssignment.tick()'s `committed_needs` param (a historical name: it
## now carries more than needs): a worker id -> job id map that skips the ordinary scored candidate
## scan entirely and proposes only that job, so it always wins regardless of
## priority scoring. CombatGiver's own flee commitments are
## layered on top of NeedGiver's, and win any collision for the same worker --
## rule 4 pre-empts a critical need exactly like it pre-empts ordinary work,
## and without this a fleeing actor's interrupted work (suspend_assignment()
## returns it to the ordinary pool) or an existing need commitment could both
## still outscore/out-rank a merely-queued flee job every tick, so the actor
## never actually flees.
func _committed_jobs() -> Dictionary:
	# Rescue's commitments are merged first, need's
	# second, so a need overwrites a rescue for the same actor rather than the
	# reverse. TrenchSystem.rescue_candidates() only excludes a need-committed colonist at
	# the moment a rescue is first proposed -- it says nothing about a colonist
	# already mid-rescue who later develops a critical need of its own (NeedGiver
	# still considers it, since _colonists_not_combat_owned() does not exclude
	# a rescuer): once that happens, both givers name an entry for the same
	# actor on the same tick, and colonist-ai.md 3.1/3.6's own "below both need
	# layers" ordering requires the need to win, exactly like it already wins
	# over ordinary work.
	var committed: Dictionary = _rescue_giver.get_pending_assignments().duplicate()
	var needing := _need_giver.get_pending_assignments()
	for actor_id in needing:
		committed[actor_id] = needing[actor_id]
	var fleeing := _combat_giver.get_committed_jobs()
	for actor_id in fleeing:
		committed[actor_id] = fleeing[actor_id]
	return committed

## GlobalAssignment.tick()'s worker list: the roster above plus every staged
## incident actor (F5) -- proposed and routed by the shared
## scheduler like any worker, but in the world only once its job activates.
func _scheduler_workers() -> Array[Dictionary]:
	var workers := _colonists_not_searching_need()
	workers.append_array(_incidents.staged_actors())
	return workers

## Reads a colonist's "mover" component route through ActorTable (ADR 012)
## rather than indexing the colonist dict directly. The returned Dictionary
## (when non-null) is the same live route object the colonist dict holds --
## get_component() never duplicates a component's nested value -- so a
## wholesale replacement (colonist["route"] = ...) must still assign the
## colonist dict directly, since ActorTable has no setter.
func _route(colonist: Dictionary):
	var mover_component: Variant = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

## Reads the "worker" component's labourTable through ActorTable (ADR 012):
## a freshly assembled wrapper Dictionary, but its "labourTable" value is the
## same live Dictionary colonist["labourTable"] holds, so mutating a value on
## the return still mutates the colonist's real state.
func _labour_table(colonist: Dictionary) -> Dictionary:
	var worker_component: Variant = ActorTableType.get_component(colonist, "worker", _content)
	return worker_component.get("labourTable", {}) if worker_component != null else {}

func state_hash(include_incidents: bool = true) -> int:
	_needs_system.ensure_needs()
	_ensure_held_tool()
	CombatSystemType.ensure_health(_colonists, _content)
	var snapshot := {
		"seed": _seed,
		"tick": _clock.tick,
		"tool_items": _tool_store.items,
		"next_tool_item_id": _tool_store.next_id,
		"tool_reservations": _tool_store.reservations.snapshot(),
		"colonists": StateCodec._hash_colonists(_colonists, _reroutes),
		"jobs": get_jobs(),
		"scheduling": _scheduler.snapshot(),
		"calendar_alerts_fired": _calendar_alerts_fired,
		"tool_fetch_excluded": _toils.get_fetch_tool_excluded(),
		# CombatGiver's own excluded-flee-destination
		# set affects the very next _pick_flee_target() call, so two runs (or a
		# save/load round trip) that differ only in it must not hash equal.
		# JSON-safe-encoded the same way state_codec.gd persists it (Vector2i
		# cannot be a JSON.stringify() dictionary key directly).
		"combat_blocked_targets": StateCodec._encode_combat_blocked_targets(_combat_giver.get_blocked_targets()),
		# Two suspended-rescue states naming
		# different victims for the same job id must not hash equal. Hashed
		# in the same sorted-by-job-id encoding
		# state_codec.gd persists (never raw insertion order), so a save/load
		# that restores identical associations in a different Dictionary
		# order (job_9 inserted before job_10 live, sorted after it on disk)
		# hashes identically.
		"rescue_victim_assignments": StateCodec._encode_rescue_victim_assignments(_rescue_giver.get_job_victims()),
		# This giver's own job_id -> target association
		# affects the next commit/adjacency decision, so two states that
		# differ only here must not hash equal.
		"approach_job_targets": StateCodec._encode_approach_job_targets(_approach_giver.get_job_targets()),
	}
	if not _area_orders.is_idle(): snapshot["area_orders"] = _area_orders.encode() # pending expansion shapes the next ticks
	# Each module adds its own keys (JSON.stringify sorts keys, so insertion order is irrelevant):
	# "width"/"height"/"tiles", "objects"/"object_health", "zones"/"next_zone_id",
	# "items"/"next_item_id"/"dig_find_rng", "suspended_work_progress", "construction_sites".
	_tile_grid.hash_into(snapshot)
	_object_table.hash_into(snapshot)
	_zone_table.hash_into(snapshot)
	_item_table.hash_into(snapshot)
	_progress_table.hash_into(snapshot)
	_construction.hash_into(snapshot)
	if include_incidents: snapshot["incidents"] = {"cooldown_until_day": _incidents._cooldown_until_day, "last_processed_day": _incidents._last_processed_day, "rng_seed": _incidents._random.seed, "rng_state": _incidents._random.state}
	return hash(JSON.stringify(snapshot))

## Matches game-state.schema.json: every field needed to keep ticking
## identically after from_save_state(). No file I/O: callers own the bytes.
func to_save_state() -> Dictionary:
	_needs_system.ensure_needs()
	_ensure_held_tool()
	CombatSystemType.ensure_health(_colonists, _content)
	return StateCodec.encode(self)

## Reconstructs a WorldState from to_save_state(), resuming any in-flight search.
static func from_save_state(state: Dictionary) -> WorldState:
	return StateCodec.decode(state)

func get_seed() -> int:
	return _seed

func get_tick() -> int:
	return _clock.tick

## This live world's actual dimensions, for a presentation layer
## that must size/clip itself to whatever map is currently loaded rather than
## assume the 48x48 fixture default (WorldState.MAP_WIDTH/MAP_HEIGHT).
func get_map_width() -> int:
	return _tile_grid.width

func get_map_height() -> int:
	return _tile_grid.height

## The generator algorithm version that actually produced this world's stored
## terrain (for reproducibility): _generator_version, above.
func get_generator_version() -> int:
	return _generator_version

## The already-loaded content/tiles.json value colonist_sprites.gd's
## advance() needs for a full tile-crossing's real tick duration.
func get_move_ticks_per_tile() -> int:
	return int(_content.list("tiles")[0]["move_ticks_per_tile"])

func get_tile(x: int, y: int) -> String:
	return _tile_grid.get_tile(x, y)

func get_tiles() -> Array[String]:
	return _tile_grid.get_tiles()

## Derived sum over ground "wood" items at (x, y) (kept for existing tests).
func get_ground_wood(x: int, y: int) -> int:
	return _item_table.get_ground_wood(x, y)

func get_items() -> Array[Dictionary]:
	return _item_table.get_items()

## Tool item CRUD + reservations: thin delegators onto _tool_store (see
## tool_item_store.gd), kept as WorldState's own public surface since every
## other module (ToilExecutor, job-givers, tests) already depends on these names.
func get_tool_items() -> Array[Dictionary]:
	return _tool_store.get_items()

func get_tool_item(item_id: String) -> Dictionary:
	return _tool_store.get_item(item_id)

func is_tool_kind(kind: String) -> bool:
	return String(_item_definitions.get(kind, {}).get("kind", "")) == "tool"

## "" without allocating an id when kind is not a declared tool kind.
func spawn_ground_tool_item(kind: String, x: int, y: int) -> String:
	if not is_tool_kind(kind):
		return ""
	return _tool_store.spawn_ground(kind, x, y)

func set_tool_item_ground(item_id: String, x: int, y: int) -> bool:
	return _tool_store.set_ground(item_id, x, y)

func set_tool_item_stockpile(item_id: String, x: int, y: int) -> bool:
	return _tool_store.set_stockpile(item_id, x, y)

func set_tool_item_held(item_id: String, colonist_id: String) -> bool:
	return _tool_store.set_held(item_id, colonist_id)

func reserve_tool_item(item_id: String, job_id: String) -> bool:
	return _tool_store.reserve(item_id, job_id)

func release_tool_item_reservation(item_id: String, job_id: String) -> bool:
	return _tool_store.release(item_id, job_id)

func get_tool_item_reservation(item_id: String) -> String:
	return _tool_store.reservation_of(item_id)

func is_tool_item_reserved(item_id: String) -> bool:
	return _tool_store.is_reserved(item_id)

## Share-by-reference like JobQueue.get_reservation_table(), for
## ReservationInvariants reuse.
func get_tool_reservation_table() -> ReservationTableType:
	return _tool_store.reservations

## The only path that finishes a scheduler job: releases every tool
## reservation job_id owns, but only once the scheduler confirms the
## terminal transition actually took -- a rejected complete/cancel/fail
## against a parked order must leave its reservations intact.
## An incident job's own lifecycle cleanup (F5) lives here too: every terminal transition drops its staged/spawned actor and clears its stamped wait key.
func _finish_job(job_id: String, status: String) -> Dictionary:
	var job := _scheduler.queue.get_job(job_id)
	# Captured before _scheduler.finish() below clears the assignment. This is
	# the one place every incident actor's own departure
	# converges, accepted trade or not, so a still-pending trade_offer never
	# outlives the trader that posted it (get_pending_trade_offers() would
	# otherwise keep exposing an Accept prompt for a trader already gone).
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
			# Unlike every other work-ticked kind below, an incident's stamped
			# wait is written by IncidentSchedulerType.activate_pending()
			# (incident_scheduler.gd) through
			# the same injected set_work_progress callable but with no job_id
			# (a 2-arg call; job_id defaults to "" and is never recorded as an
			# owner) -- so it cannot participate in the job-id ownership
			# tracking below and keeps its own pre-existing "active at finish"
			# rule instead, unchanged.
			if String(job.get("status", "")) == "active":
				_progress_table.clear(job["target"])
		else:
			_progress_table.release_owned(job_id, job)
	return result

func get_ground_berries(x: int, y: int) -> int:
	return _item_table.get_ground_berries(x, y)

## "" (like get_ground_berries()'s own absence) when no berries are on the ground here.
func get_ground_berries_faction_id(x: int, y: int) -> String:
	return _item_table.get_ground_berries_faction_id(x, y)

func get_object(x: int, y: int) -> String:
	return _object_table.get_object(x, y)

## "" (like get_object()'s own "none") when no object is placed here.
func get_object_faction_id(x: int, y: int) -> String:
	return _object_table.get_object_faction_id(x, y)

## The one authoritative movement rule for a tile and its object (map/passability.gd).
## faction_id (F3) defaults to "colony" and only matters for a door.
func passability(x: int, y: int, faction_id: String = "colony") -> Dictionary:
	return _passability.passability(x, y, faction_id)

func get_objects() -> Array[Dictionary]:
	return _object_table.get_objects()

## Every active construction site, builder_ids as colonist ids (ConstructionSystem).
func get_construction_sites() -> Array[Dictionary]:
	return _construction.get_construction_sites()

## {} for a tile no site's footprint covers.
func get_construction_site(x: int, y: int) -> Dictionary:
	return _construction.get_construction_site(x, y)

func get_zones() -> Array[Dictionary]:
	return _zone_table.get_zones()

func get_zone(id: String) -> Dictionary:
	return _zone_table.get_zone(id)

## True when no job/haul reservation owns (x, y)'s "cell:" key; zone_add/
## zone_remove never acquire a cell reservation, only rectangle bookkeeping.
func is_cell_free(x: int, y: int) -> bool:
	return not _scheduler.queue.get_reservation_table().is_reserved(_cell_key(x, y))

## A thin filter over the actor table (ADR 012): every actor whose definition
## declares a worker component. _colonists holds only colonists today, so
## this returns the same Array[Dictionary] shape callers have always seen.
func get_colonists() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for actor in _colonists:
		if ActorTableType.has_component(actor, "worker", _content):
			var entry: Dictionary = actor.duplicate(true)
			entry["carrying"] = _carrying_view(actor)
			copy.append(entry)
	return copy

## ADR 037: a presentation-only mirror of the pre-hands-model single-slot
## "carrying" shape, derived from "hands" so the viewer layer
## (colonist_sprites.gd/colonist_panel.gd/map_view.gd) keeps rendering the
## carried item unchanged. "hands" on the actor dict itself remains the only field simulation code reads or
## writes (via InventoryType); this key exists solely on get_colonists()'s
## own detached copies and is never part of the persisted or hashed state.
func _carrying_view(actor: Dictionary) -> Variant:
	if not InventoryType.is_carrying(actor):
		return null
	var first: Dictionary = InventoryType.hands_snapshot(actor)[0]
	return {"kind": first["kind"], "count": first["count"]}

## Every actor with a `health` component, worker or not (colonist_sprites.gd's health bars).
func get_actors_with_health() -> Array[Dictionary]:
	return _combat_system.get_actors_with_health()

## Every trader's own outstanding trade_offer, for colonist_panel.gd.
func get_pending_trade_offers() -> Array[Dictionary]:
	return _trade.get_pending_trade_offers()

## The handover overlay only mutates this call's own detached duplicates, never JobQueue's state; a non-empty `kinds` keeps only those kinds, costing only the jobs returned (B1).
## get_job(): one job as get_jobs() shows it ({} when unknown); the reads below: JobIndex (B1); get_pending_job_ids_at(): a tile's pending non-site jobs (Cancel's candidates).
func get_jobs(kinds: Array = []) -> Array[Dictionary]:
	var jobs := _scheduler.queue.get_jobs() if kinds.is_empty() else _scheduler.queue.get_jobs_of_kinds(kinds)
	var assignments := _scheduler.get_assignments()
	for job in jobs:
		ToolHandoverType.apply(job, assignments, _toils)
	return jobs

func get_job(job_id: String) -> Dictionary:
	var job := _scheduler.queue.get_job(job_id)
	ToolHandoverType.apply(job, _scheduler.get_assignments(), _toils)
	return job

func get_queued_job_summary() -> Dictionary:
	return _scheduler.queue.get_index().queued_summary()

func get_designation_changes(from: int) -> Dictionary:
	return _scheduler.queue.get_index().designation_changes(from)

func get_pending_job_ids_at(tile: Vector2i) -> Array[String]:
	return _scheduler.queue.get_index().pending_ids_at(tile)

func get_reservations() -> Dictionary:
	return _scheduler.queue.get_reservations()

## "" when no exposed need reason (colonist-ai.md 3.8): need_unmet:<kind> once
## a search exhausts every source, blocked_source_reserved/unreachable
## transiently mid-search, "" again once committed or with no need at all.
func get_colonist_need_reason(colonist_id: String) -> String:
	return _needs_system.get_colonist_need_reason(colonist_id)

## The need job id a colonist is currently committed to, or "" when none --
## the only way to observe the tick between route arrival and the instant
## `consume` toil, when route/work are both null but the job is still pending.
func get_active_need_job_id(colonist_id: String) -> String:
	return _need_giver.get_pending_job(colonist_id)

## "" or REASON_NO_RESCUER_AVAILABLE for a trapped colonist (TrenchSystem).
func get_colonist_rescue_reason(colonist_id: String) -> String:
	return _trench.get_colonist_rescue_reason(colonist_id)

## The active calendar boost (ADR 008) for labour at the current tick -- a
## read-only getter for presentation; the scheduler queries it directly.
func get_active_calendar_boost(labour: String) -> int:
	return _calendar.active_boost(labour, _clock.tick)

func get_scheduling_metrics() -> Dictionary:
	return _scheduler.get_metrics()

func get_assignments() -> Dictionary:
	return _scheduler.get_assignments()

## CombatGiver's own destination-reservation check for a flee candidate tile:
## true when (x, y) is already the "tile:" target of
## another active (or backed-off) job, the same shared ReservationTable
## NeedGiver's own _start_search() already consults for a need source
## candidate (_tile_key() namespaces it identically) -- without this, a
## candidate ranked ahead of every other only failed _may_reserve_target()'s
## faction-eligibility gate, never an actual current reservation, so a flee
## job could be submitted straight at a tile another job already owns.
func _flee_target_reserved(x: int, y: int) -> bool:
	return _scheduler.queue.get_reservation_table().is_reserved(_tile_key(x, y))

## CombatGiver's own shared-finish-boundary cancel: lets it
## retire a `flee` job stuck "queued" and blocked (its own preferred
## destination reserved by another job the instant this actor tried to
## commit to it, or genuinely unreachable through a faction-forbidden door
## despite passing the coarser region-connectivity check) without waiting on
## ToilBindings.toil_on_unreachable(), which only ever fires once a job has actually
## activated and started its go_to leg.
func _cancel_autonomous_job(job_id: String) -> void:
	_finish_job(job_id, "cancel_job")

## The faction of a roster actor or a staged (not yet spawned) incident actor.
func _actor_faction(actor_id: String) -> String:
	var actor := _find_colonist(actor_id)
	if actor.is_empty():
		actor = _incidents.staged_actor(actor_id)
	return String(actor.get("factionId", "colony"))

## GlobalAssignment's autonomous reservation gate (ADR 014 Amendment): a faction that may reserve colony items may reserve any target; one that may not (wildlife, traders) may still reserve a bare tile, never one holding an object, ground item, berries, tool item or stockpile cell.
## Narrow exception: an autonomous actor may always reserve
## its own current tile, whatever it holds -- escape_trench always targets the
## trapped actor's own already-occupied tile. Every other autonomous target is
## unaffected; _find_colonist() returns {} for a still-staged incident actor.
##
## A trapped actor is checked first and exclusively, before
## the faction check -- this is the same activation/reactivation boundary
## GlobalAssignment consults both when a "ready" entry first activates and
## when resume_assignment() reactivates a suspended one (never anywhere
## else), so a trapped actor can never reserve any target except its own
## tile through either path. This is what stops CombatGiver's own `flee` job
## (submitted autonomously so a non-colony or low-health actor can flee its
## own job, see combat_giver.gd) from ever landing a reservation for a
## trapped actor: every flee candidate _pick_flee_target() considers is a
## tile other than the actor's own (its own tile is excluded outright, being
## `== start`), so this gate now refuses every one of them, and
## _pick_flee_target() returns null forever -- CombatGiver never calls
## _interrupt()/submits a replacement job, and escape_trench (the one
## autonomous job ever allowed to target a trapped actor's own tile) is
## unaffected. Applies without regard to faction, so a trapped colonist
## (still eligible to reserve colony items) is covered exactly like a
## trapped hostile.
func _actor_may_reserve_target(actor_id: String, target: Vector2i) -> bool:
	var trapped_actor := _find_colonist(actor_id)
	if not trapped_actor.is_empty() and trapped_actor.get("trapped") != null:
		return Vector2i(int(trapped_actor["x"]), int(trapped_actor["y"])) == target
	if _passability.faction_may_reserve_colony_items(_actor_faction(actor_id)):
		return true
	if not trapped_actor.is_empty() and Vector2i(int(trapped_actor["x"]), int(trapped_actor["y"])) == target:
		return true
	return _is_bare_tile(target)

## No colony-owned thing on this tile: shared by the gate above and by
## IncidentScheduler's target/spawn-tile selection, so a proposed target is
## one the gate accepts.
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

func _get_job(job_id: String) -> Dictionary:
	return _scheduler.queue.get_job(job_id)

## submit_job callable for IncidentScheduler (F5; ADR 014 Amendment): the actor's job goes through GlobalAssignment.submit_autonomous(), restricted to actor_id and flagged autonomous, activated only inside tick()'s own _scheduler.tick() pass so N submissions in one tick never tick the queue clock twice.
## "" when the queue rejected the target.
func _submit_incident_job(actor_id: String, target: Vector2i) -> String:
	var result := _scheduler.submit_autonomous(target, 1, _clock.tick, "incident", actor_id)
	return String(result["job_id"]) if result.get("ok", false) else ""

## After a load (StateCodec.decode()): IncidentScheduler persists nothing,
## so an active incident job is re-associated with its restored actor
## (despawn still works) and one whose actor is absent -- never activated, or
## its actor gone -- is retired through the shared finish boundary.
##
## A "queued" incident job is not automatically a never-activated proposal:
## CombatGiver's own flee interrupt suspends an incident
## actor's active incident job back to "queued" via NeedsSystem.pause_work_job()/
## suspend_assignment() exactly like a critical need would, so saving mid-flee
## persists a previously activated, now-paused incident job in "queued"
## status. GlobalAssignment.restrict_to_for() reads _activated_entries, which
## a job only ever enters the instant it is first activated and which
## suspend() never clears -- so a queued job with a non-empty restrict_to_for()
## was activated at least once (the paused-by-combat case); one
## with an empty restrict_to_for() was never activated at all (an ordinary,
## still-waiting proposal). Only the latter -- or either shape whose actor is
## now gone -- is retired; the former is re-associated exactly like an active
## job, so it despawns correctly and, once the actor stops fleeing, resumes
## through the same NeedsSystem.paused_jobs entry StateCodec already restored.
func _reconcile_incident_jobs_after_load() -> void:
	for job in _scheduler.queue.get_jobs():
		if String(job["kind"]) != "incident" or String(job["status"]) not in ["queued", "active"]:
			continue
		var job_id := String(job["id"])
		var actor_id := _scheduler.restrict_to_for(job_id)
		var previously_activated := String(job["status"]) == "active" or not actor_id.is_empty()
		if previously_activated and not _find_colonist(actor_id).is_empty():
			_incidents.adopt(job_id, actor_id)
		else:
			_finish_job(job_id, "cancel_job")

## Re-applies the live/debug viewer's own incident configuration to a world reconstructed by StateCodec.decode(), since decode() always builds incidents_enabled=false; boot.gd calls this once after every restore (startup autosave and manual Load).
## Also reserves incident actor ordinals past the restored roster so a freshly spawned actor can never collide with one still alive from before the save.
func enable_incidents() -> void:
	_incidents.set_enabled(true)
	_incidents.reserve_actor_ordinal_above(_colonists)

## cell_occupied callable for _toils's place precondition.
func _is_cell_occupied(x: int, y: int, excluding_colonist_id: String) -> bool:
	return _actor_index.any_at(_colonists, x, y, excluding_colonist_id) or _item_table.has_item_at(x, y)

## command_checks.gd's sow precondition reads this name through the world.
func _has_item_of_kind(kind: String) -> bool:
	return _item_table.has_item_of_kind(kind)

## Fails any nonterminal haul job still naming item_id after
## ItemTable.remove_one_item_of_kind()/remove_stockpiled_item_unit() erased its last ground unit, so it doesn't
## retry forever for an item that no longer exists.
func _fail_haul_jobs_referencing_item(item_id: String) -> void:
	for job in _scheduler.queue.get_jobs():
		if String(job["kind"]) != "haul" or String(job["status"]) not in ["queued", "active"]:
			continue
		if String(job["item_id"]) != item_id:
			continue
		_terminate_haul_job_by_id(String(job["id"]), "blocked_missing_input", "resubmit_order")

## Fails colonist_id's haul job after ItemTable._consume_carried_item_of_kind()
## emptied what it was carrying, the way an unreachable destination already
## does. Checks NeedsSystem.paused_jobs first: a need interrupt may have suspended this
## haul after pickup, in which case only the pause entry is cleared, not the
## colonist's route/work (owned by whatever need job is now driving it).
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

## start_work()'s resume/start lookup (WorkProgress.resume()). A site_work job's
## duration is always re-derived from its site (ConstructionSiteTable.progress is
## the one authoritative counter), so it bypasses the progress table entirely.
func _resume_work_progress(target: Vector2i, job_id: String):
	var job := _get_job(job_id)
	if String(job.get("kind", "")) == "site_work":
		return _construction.site_work_ticks_remaining(job, target)
	return _progress_table.resume(target, job_id)

## Called every tick for every work-toil job kind. For an active
## escape_trench job, also mirrors trapped.ticksRemaining from this same
## real work timer -- never a countdown of its own. job_id, when non-empty,
## becomes the key's owner (WorkProgress.record()).
func _set_work_progress(target: Vector2i, ticks_remaining: int, job_id: String = "") -> void:
	# A site_work job never writes into the shared tile-keyed
	# cache below at all -- ConstructionSiteTable.progress is the one
	# persisted, authoritative counter (summed across every active builder).
	# Checked here too, not only in ToilBindings' on_work_complete final-tick
	# case: with more than one builder, combined contributions can cross
	# build_ticks before any single job's own locally-seeded countdown would,
	# so this non-final tick must finalize immediately for genuine N-builder
	# speedup -- "" matches no real job id, so finalizing the site
	# finishes every builder here, including this one (nothing else will).
	if not job_id.is_empty() and String(_scheduler.queue.get_job(job_id).get("kind", "")) == "site_work":
		var job := _get_job(job_id)
		_construction.add_site_work(job.get("site", target), "")
		return
	_progress_table.record(target, ticks_remaining, job_id)
	_trench.mirror_climb_ticks(target, ticks_remaining)
	# Posted on the trader's own first work-toil tick (this same
	# call, on arrival), not at the wait's end, so accept_trade has a window
	# before the trader's unchanged despawn (test_incidents.gd's own
	# exact-wait-timing checks still hold).
	if not job_id.is_empty() and String(_scheduler.queue.get_job(job_id).get("kind", "")) == "incident":
		_trade.maybe_post_trade_offer(job_id)

## F3: terminally resolves every job GlobalAssignment's
## may_be_ordered/may_reserve_colony_items gates refused, with the same typed
## fail() path zone_remove's blocked_destination_gone already uses -- nothing
## was ever acquired, so this only owns termination, returning a suspended
## haul's carried item, and telling NeedGiver a need job resolved. Looped:
## resolving one refusal may trigger another. Called at the end of both
## tick() and OrderHandler.apply_job_command() (a command can resolve a need outside
## tick() too) since _refused_reservations is transient, never saved, so
## anything left undrained when either mutator returns would silently vanish
## across a save/load.
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

## Walks every colonist's route/work by exactly one tick, ascending colonist-id
## order. Every active job kind drives the same generic toil-sequence advance
## (_toils.advance()), dispatched purely off job["kind"]'s own declared toils
## array: WorldState never branches on kind here (AGENTS.md "one work engine").
func _advance_colonists() -> void:
	var assignments := _scheduler.get_assignments()
	var ordered: Array[Dictionary] = _colonists.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	for colonist in ordered:
		var colonist_id: String = colonist["id"]
		var assignment: Variant = assignments.get(colonist_id)
		if assignment == null:
			if _route(colonist) != null or colonist.get("work") != null:
				_progress_table.suspend(colonist.get("work"))
				colonist["route"] = null
				colonist["work"] = null
				_reroutes.erase(colonist["id"])
			continue
		var job_id: String = assignment["job_id"]
		var job := _scheduler.queue.get_job(job_id)
		if job.is_empty() or String(job.get("status", "")) != "active":
			continue
		# _scheduler.tick() (step 2, above) may reassign a colonist to a new job in
		# the very tick an external command frees it, before this loop gets a
		# chance to clear the old job's progress. Reconcile by job_id, not merely
		# null-ness: stale route/work naming a job other than the current
		# assignment is cleared here so the colonist starts the new job fresh
		# instead of continuing to walk or work the cancelled one.
		var route: Variant = _route(colonist)
		var work: Variant = colonist.get("work")
		if (route != null and route["job_id"] != job_id) or (work != null and work["job_id"] != job_id):
			if work != null and work["job_id"] != job_id:
				_progress_table.suspend(work)
			colonist["route"] = null
			colonist["work"] = null
			_reroutes.erase(colonist["id"])
		# A rescue's commit-time route
		# safety (rescue_giver.gd) says nothing about the map at activation
		# time. Before the first drive of a fresh rescue activation (no route,
		# no work yet) re-check the scheduler's own already-computed path and
		# target, and retire the commitment -- so the victim's next search may
		# pick another rescuer -- rather than walk a now-unsafe path.
		if String(job.get("kind", "")) == "rescue" and _route(colonist) == null and colonist.get("work") == null \
				and not _trench.rescue_activation_safe(colonist, job, assignment.get("path", [])):
			_trench.retire_rescue_job(job_id, job)
			continue
		var tile_before := Vector2i(int(colonist["x"]), int(colonist["y"]))
		_trench.trap_tile_before = tile_before
		_toils.advance(colonist, job_id, job, assignment.get("path", []), _toil_hooks)
		_trench.check_trench_arrival(colonist, job_id, tile_before)

## Steps the go_to toil toward target; on "unreachable", routes through the
## same kind-aware ToilBindings.toil_on_unreachable() boundary every other first-leg
## unreachable case uses rather than
## unconditionally resubmitting -- an incident or flee job recovering here
## must be cancelled-only, never resubmitted: _resubmit_unreachable_job()
## replaces a job through the ordinary, may_be_ordered-gated submit(),
## refused outright for a non-colony actor, producing a replacement job that
## can never run. Used only by NeedsSystem.resume_paused_job() re-deriving a fresh route
## after a need or combat interrupt releases a colonist.
## Always is_first=true (NeedsSystem.resume_paused_job() only ever calls this for a
## colonist not yet carrying anything), so the on_arrive callback must match
## whatever the ordinary tick-driven path would use for that same leg
## (ToilExecutor.leads_into_work()/_arrival_hook()): a haul/build leg whose own next toil is pick_up, not work, must
## never auto-start the work timer on arrival here either -- the same bug
## ADR 028 traced on the ordinary path.
func _advance_go_to_or_resubmit(colonist: Dictionary, job_id: String, job: Dictionary, target: Vector2i) -> void:
	var on_arrive := Callable(_toils, "start_work") if _toils.leads_into_work(String(job["kind"]), true) else Callable(_toil_bindings, "toil_no_op_arrive")
	if _toils.advance_go_to(colonist, job_id, target, _routable_to(target, String(colonist.get("factionId", "colony"))), "go_to", on_arrive) != "unreachable":
		return
	_toil_bindings.toil_on_unreachable(job_id, job, true)

## Shared "unreachable" consequence for a job's first go_to leg: cancels and
## resubmits the same target as a fresh job, letting the scheduler's own
## reachability check report blocked_target_unreachable. A need job's
## replacement stays restricted to the same colonist, and NeedGiver's
## ownership carries over via reassign_job() rather than dropping (which
## would let a different colonist claim the replacement while this one is
## told its need is already met); falls back to resolve_job() if the
## resubmission itself is rejected. A player-ordered dig/chop/forage job's
## own assignee restriction (F3) has no NeedGiver association at
## all, so it is instead read straight off the original job's activated
## entry (GlobalAssignment.restrict_to_for()) before _finish_job() below
## erases that entry -- without this, the documented "only the named actor
## may activate it" guarantee would be lost the instant the target briefly
## became unreachable.
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

## route_search_factory injected into _toils: a fresh bounded RerouteType
## search from the colonist's current tile within this WorldState's map
## bounds, reusing RouteSearch's own step budget rather than an unbounded
## recompute.
func _route_search_factory(start: Vector2i, target: Vector2i, passable: Callable) -> RerouteType:
	var bounds_max := Vector2i(_tile_grid.width - 1, _tile_grid.height - 1)
	return RerouteType.new(start, target, passable, Vector2i.ZERO, bounds_max)

## Wraps passability() with the same target-tile exception
## GlobalAssignment._routable() applies to the scheduler's own route search: a
## re-route search may terminate on its own job's target tile even when that
## tile's base kind is otherwise impassable (a chop job's tree). faction_id
## (F5) defaults "colony" so every pre-existing colony-only call
## site is unchanged; ToilBindings' go_to_passable hook passes the acting actor's
## own factionId instead.
func _routable_to(target: Vector2i, faction_id: String = "colony") -> Callable:
	return func(tile: Vector2i) -> float:
		var cost := _passability.passable_for_faction(tile, faction_id)
		if tile == target and cost <= 0.0:
			return 1.0
		return cost

## Chebyshev-adjacency check matching ToilExecutor.pick_up()/place()'s "on or
## adjacent to" precondition.
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

## Callables handed to modules built before _toil_bindings (and to the command paths
## below): one-line delegations to ToilBindings.
func _work_target_for(job: Dictionary) -> Vector2i: return _toil_bindings.work_target_for(job)
func _drop_carried_haul_item(job_id: String) -> void: _toil_bindings.drop_carried_haul_item(job_id)
func _terminate_haul_job_by_id(job_id: String, reason: String, remedy: String) -> void: _toil_bindings.terminate_haul_job_by_id(job_id, reason, remedy)
func _resolve_giver_association(job_id: String, kind: String) -> void: _toil_bindings.resolve_giver_association(job_id, kind)

## Append-only log of every cell whose tile kind or object changed (map/tile_grid.gd).
func get_dirty_cells() -> Array[Vector2i]:
	return _tile_grid.get_dirty_cells()

## {} for a tile with no recognised room; otherwise RoomMapType.get_room_at().
func get_room_at(x: int, y: int) -> Dictionary:
	return _tile_grid.get_room_at(x, y)

## Namespaces a tile into the shared ReservationTable's generic String key
## space (colonist-ai.md 3.4), distinct from JobQueue's own "tile:" target
## keys, for is_cell_free()'s per-cell free/reserved lookup.
func _cell_key(x: int, y: int) -> String:
	return "cell:%d,%d" % [x, y]

## A colonist dict missing "held_tool" (an older fixture) never held a
## tool: backfilled to "" in place, always a plain append (never a rebuild
## like NeedsSystem.ensure_needs()) so state_hash()'s key insertion order matches a
## decoded colonist's. Uses has()/index-assignment only (no read of the
## field's value), so no ActorTable accessor applies here. Only a worker
## (F2) has a tool slot: a wolf/trader is never given this colonist-only field.
func _ensure_held_tool() -> void:
	for colonist in _colonists:
		if not colonist.has("held_tool") and ActorTableType.has_component(colonist, "worker", _content):
			colonist["held_tool"] = ""

## "" when actor_id has no adjacent hostile target this tick (CombatSystem).
func get_actor_combat_reason(actor_id: String) -> String:
	return _combat_system.get_actor_combat_reason(actor_id)

## restrict_to_for(), else the waiting entry's restriction for a never-activated job, so a still-queued job restricted to a just-killed actor (a flee job submitted the same tick it died) cannot survive CombatSystem.cleanup_actor_scheduling().
func _job_restricted_to(job_id: String) -> String:
	var restrict_to := _scheduler.restrict_to_for(job_id)
	if not restrict_to.is_empty():
		return restrict_to
	return _scheduler.waiting_restrict_to(job_id)

## Matches JobQueue's own "tile:%d,%d" target-key format (colonist-ai.md 3.4).
func _tile_key(x: int, y: int) -> String:
	return "tile:%d,%d" % [x, y]

## ActorTable.spawn()'s own default labourTable, off the same content
## tunables -- also used by NeedsSystem.ensure_needs()'s backfill.
func _default_labour_table() -> Dictionary:
	var worker_tunables: Dictionary = _content.get_entry("actors", "colonist").get("tunables", {}).get("worker", {})
	return WorkerType.default_labour_table(worker_tunables)

func _load_need_definitions() -> Dictionary:
	return _index_by_field(_content.list("needs"), "kind")

func _load_object_definitions() -> Dictionary:
	return _index_by_field(_content.list("objects"), "kind")

## content/items.json declares item kinds by "id"; "kind" is the shared
## category ("tool"), so it cannot double as the lookup key.
func _load_item_definitions() -> Dictionary:
	return _index_by_field(_content.list("items"), "id")

## job kind -> work-toil ticks; only dig/chop/forage/till/sow/sleep declare one.
func _load_work_ticks() -> Dictionary:
	var ticks: Dictionary = {}
	for job in _content.list("jobs"):
		if job.has("work_ticks"):
			ticks[String(job["kind"])] = int(job["work_ticks"])
	return ticks

## needs.json repeats full/job_priority/retry_base_ticks/retry_cap_ticks on
## every entry rather than once at the root (content_registry.gd has no
## root-field accessor); any entry carries the same value.
func _load_need_config() -> Dictionary:
	return _content.list("needs")[0]

## `return` alone can't stop `.new()` handing back an unusable WorldState.
func _fail_startup(message: String) -> void:
	push_error("WorldState: %s" % message)
	OS.kill(OS.get_process_id())

## Re-indexes ContentRegistry.list()'s frozen entries by field, deep-duplicated
## so the registry's own bundle stays immutable while callers mutate copies.
func _index_by_field(entries: Array, field: String) -> Dictionary:
	var indexed: Dictionary = {}
	for entry in entries:
		var entry_dict: Dictionary = entry
		indexed[String(entry_dict[field])] = entry_dict.duplicate(true)
	return indexed

## Deterministic travel cost from `from` to `to` for `faction_id`, reusing the
## same bounded RouteSearch and _routable_to() target-tile exception the
## colonist's own go_to toil actually travels under (ToilBindings' go_to_passable hook),
## so a candidate ranked nearest is guaranteed reachable by the identical rule
## that later moves the colonist. Run to completion: safe since the search
## space is bounded by the map itself, same as GlobalAssignment._resolve_path().
## Returns -1 when `to` is unreachable from `from`.
func _route_cost(from: Vector2i, to: Vector2i, faction_id: String) -> int:
	if from == to: return 0
	var route := _route_search_factory(from, to, _routable_to(to, faction_id))
	while not route.is_terminal(): route.resume()
	if route.get_status() != RerouteType.STATUS_FOUND: return -1
	return route.get_path().size() - 1

func _colonist_at(x: int, y: int) -> bool:
	return _actor_index.any_at(_colonists, x, y)

## The live colonist Dictionary reference for colonist_id (mutating it mutates
## _colonists in place), or {} when unknown.
func _find_colonist(colonist_id: String) -> Dictionary:
	return _actor_index.find(_colonists, colonist_id)

func _append_colonist(actor: Dictionary) -> void: # IncidentScheduler append/remove callables
	if not actor.has("trapped"): actor["trapped"] = null
	_colonists.append(actor)
	_actor_index.added(actor)

## The one path that removes an actor from the roster, called by
## CombatSystem.apply_actor_death() (rule 2, is_death=true) and by
## IncidentScheduler.on_job_finished() (every terminal incident-job
## transition, including one cancelled while combat has it suspended for a
## flee episode; is_death defaults false there, bound with a single String
## arg at _init()). Runs CombatSystem.cleanup_actor_scheduling() first so both callers
## share the same scheduling/CombatGiver teardown.
##
## is_death distinguishes an actual combat death (always
## removed -- a killed actor must leave the roster and its scheduling/
## reservation cleanup regardless of trapped state) from an ordinary
## incident-lifecycle despawn (suppressed for a trapped actor -- a
## wolf whose incident wait job just finished must stay trapped in its
## trench, not vanish, until it escapes or dies).
func _remove_colonist_by_id(colonist_id: String, is_death: bool = false) -> void:
	_combat_system.cleanup_actor_scheduling(colonist_id)
	for i in _colonists.size():
		if String(_colonists[i]["id"]) == colonist_id:
			if not is_death and _colonists[i].get("trapped") != null: # trapped, not despawned
				return
			_actor_index.removed(_colonists[i])
			_colonists.remove_at(i)
			# A despawned actor gets no further _advance_colonists() pass to release its own in-flight reroute -- release it here instead.
			_reroutes.erase(colonist_id)
			return

func get_events(types: Array = []) -> Array[Dictionary]:
	return _event_log.get_events(types)

## Delegates to WorldGeneratorType, a pure, scene-independent module so
## world_state.gd's own core-budgets.json cap has room for width/height
## plumbing. Consumes a GEOGRAPHY_SEED_SALT-derived local RNG, not _random
## (terrain/decoration must never advance the simulation stream AssignmentType
## consumes -- see _random's own doc comment), in a fixed draw order (rock
## veins, hazards, tree groves, river, berry bush groves), so a request at the
## same size/seed/mapgen always reproduces the same terrain regardless of how
## much simulation randomness runs afterward. Stashes the river's water tiles
## and berry-bush positions for _spawn_colonists() -- see
## _pending_water_tiles' own doc comment.
func _generate_map() -> Array[String]:
	var geography_random := RandomNumberGenerator.new()
	geography_random.seed = _seed + GEOGRAPHY_SEED_SALT
	var result := WorldGeneratorType.generate_with_decorations(geography_random, _tile_grid.width, _tile_grid.height, _mapgen)
	_pending_water_tiles = result["water_tiles"]
	_pending_berry_bush_tiles = result["berry_bush_tiles"]
	return result["tiles"]

## Delegates the clearing search to WorldGeneratorType.place_spawn() (a
## river-aware, resource-validated search, not a fixed rectangle -- see
## ADR 020), consuming its own PLACEMENT_SEED_SALT local RNG for
## the same reason _generate_map() above does not touch _random; this
## method's own job is turning that module's pure output into real WorldState
## state: surviving berry bush tiles become _object_table.objects entries (WorldGenerator
## owns no object store), and the chosen positions become spawned colonists.
func _spawn_colonists(map: Array[String]) -> Array[Dictionary]:
	var placement_random := RandomNumberGenerator.new()
	placement_random.seed = _seed + PLACEMENT_SEED_SALT
	var placement: Dictionary = WorldGeneratorType.place_spawn(placement_random, map, _tile_grid.width, _tile_grid.height, _mapgen,
		_pending_water_tiles, _pending_berry_bush_tiles, int(_mapgen["colonist_count"]))
	_spawn_clearing = placement["clearing"]
	for pos in placement["berry_bush_tiles"]:
		_object_table.objects[_object_table.object_key(pos.x, pos.y)] = "berry_bush"
		_object_table.object_factions[_object_table.object_key(pos.x, pos.y)] = "colony"
	_pending_water_tiles = []
	_pending_berry_bush_tiles = []
	var spawned: Array[Dictionary] = []
	var positions: Array = placement["colonist_positions"]
	for i in positions.size():
		var position: Vector2i = positions[i]
		var colonist := ActorTableType.spawn("colonist", position.x, position.y, _content, "colonist_%d" % i)
		# ActorTable.spawn() still builds the legacy single-slot "carrying"
		# field (ADR 012's own frozen shape); it is replaced here with the
		# empty "hands" list ADR 037 defines. Key insertion order
		# does not affect state_hash() (JSON.stringify() sorts keys), so a
		# straight erase+assign is equivalent to inserting "hands" at
		# "carrying"'s original position.
		colonist.erase("carrying")
		colonist["hands"] = []
		colonist["trapped"] = null # unconditional like health/route
		spawned.append(colonist)
	return spawned

## The colonist starting clearing actually chosen for this world -- see
## _spawn_clearing's own doc comment.
func get_spawn_clearing() -> Dictionary:
	return _spawn_clearing.duplicate()

## Test-only observation point: the simulation stream's own seed/state right
## after construction, so a test can compare it against a pristine same-seed
## RandomNumberGenerator's state without depending on any mapgen.json tuning.
func get_simulation_random_state() -> Dictionary:
	return {"seed": _random.seed, "state": _random.state}
