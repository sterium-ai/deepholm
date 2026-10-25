class_name WorldState
extends RefCounted

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ToolHandoverType = preload("res://scripts/core/jobs/tool_handover.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")
const ToolItemStoreType = preload("res://scripts/core/items/tool_item_store.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const NeedGiverType = preload("res://scripts/core/jobs/givers/need_giver.gd")
const RescueGiverType = preload("res://scripts/core/jobs/givers/rescue_giver.gd")
const HaulGiverType = preload("res://scripts/core/jobs/givers/haul_giver.gd")
const CalendarAlertGiverType = preload("res://scripts/core/jobs/givers/calendar_alert_giver.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const IncidentSchedulerType = preload("res://scripts/core/incidents/incident_scheduler.gd")
const CombatType = preload("res://scripts/core/actors/components/combat.gd")
const RelationsType = preload("res://scripts/core/relations/relations.gd")
const CombatResolverType = preload("res://scripts/core/combat/combat_resolver.gd")
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
## F3: shared by _apply_job_command()'s assignee check and
## _resolve_refused_reservations()'s typed termination of a job
## GlobalAssignment's reservation gate refused (see set_reservation_gate()
## in _init() below).
const REASON_NOT_ORDERED_BY_PLAYER := "not_ordered_by_player"
## F5 combat (docs/architecture/orders-and-movement.md's typed reason
## vocabulary): exposed by get_actor_combat_reason() while an
## actor has an adjacent hostile target this tick, mirroring
## get_colonist_need_reason()'s "need_unmet:"/"rerouting" pattern.
const REASON_FIGHTING := "fighting"
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
## Callables ToilExecutor.advance() cannot resolve itself, keyed by hook name.
var _toil_hooks: Dictionary = {}
## Events, their sequence counter and the command envelopes (world/event_log.gd).
var _event_log: EventLogType
## Live in-flight re-route searches, keyed by colonist id, shared by
## reference with _toils.
var _reroutes: Dictionary = {}

## Work-toil progress, its owners and suspended progress (jobs/work_progress.gd).
var _progress_table: WorkProgressType
## job kind -> its needs_tool item kind, from content/jobs.json.
var _needs_tool_by_kind: Dictionary = {}
## job kind -> {"kind","retry_base_ticks","retry_cap_ticks"} for JobQueue's
## own tool-availability activation gate.
var _tool_requirements_by_kind: Dictionary = {}
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
## actor_id -> REASON_FIGHTING while it has an adjacent hostile target this
## tick, "" otherwise -- get_actor_combat_reason()'s backing store, rebuilt
## fresh every tick by _apply_combat(), mirroring NeedsSystem.need_status.
var _combat_status: Dictionary = {}
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
	_ensure_combat()
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
	for job_def in _content.list("jobs"):
		var needs_tool := String(job_def.get("needs_tool", ""))
		if not needs_tool.is_empty():
			if not (job_def.has("retry_base_ticks") and job_def.has("retry_cap_ticks")):
				_fail_startup("jobs.json's '%s' entry declares needs_tool but is missing retry_base_ticks/retry_cap_ticks" % job_def["kind"])
				return
			_needs_tool_by_kind[String(job_def["kind"])] = needs_tool
			_tool_requirements_by_kind[String(job_def["kind"])] = {
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
	# Built after _toils; CombatGiver and ToilExecutor above reach it through lambdas.
	_needs_system = NeedsSystemType.new(_content, _need_definitions, _need_full, PRIORITY_TICK, _clock, _calendar, _scheduler,
		_toils, _progress_table, _tool_store, _item_table, _tile_grid, _object_table, _event_log, _trench,
		func() -> Array[Dictionary]: return _colonists, _find_colonist, _colonist_within_reach, _advance_go_to_or_resubmit,
		_combat_giver.owns, _route, _labour_table, _default_labour_table, _ensure_health, _ensure_combat)
	_scheduler.set_route_budget(_route_budget)
	_scheduler.queue.set_tool_requirement(_tool_requirement_for_kind, _tool_exists)
	_toil_hooks = {
		"go_to_target": _toil_go_to_target,
		"go_to_passable": _toil_go_to_passable,
		"go_to_force_trim_last": _toil_go_to_force_trim_last,
		"on_unreachable": _toil_on_unreachable,
		"item_id_for": _toil_item_id_for,
		"cell_for": _toil_cell_for,
		"on_toil_fail": _toil_on_toil_fail,
		"on_place_success": _toil_on_place_success,
		"on_work_complete": _toil_on_work_complete,
		"on_consume_success": _toil_on_consume_success,
		"on_no_tool_found": _toil_on_no_tool_found,
		# site_fetch's own deposit-toil destination and success
		# hook; pick_up_count_for clamps a site_fetch pick_up to what the
		# site still needs of that source's own kind. Every other kind's
		# hooks ignore these (unset, "site_fetch"-only checks inside each).
		"pick_up_count_for": _toil_pick_up_count_for,
		"site_id_for": _toil_site_id_for,
		"on_deposit_success": _toil_on_deposit_success,
		"go_to_skip_assignment_path": _toil_go_to_skip_assignment_path,
		# Hands-filling rules: a site_fetch job's own
		# "still fetching vs. now delivering" state (_toil_is_first_leg()) and
		# its per-hop nearest-source/partial-load decision
		# (_toil_on_pick_up_success()). Every other kind's hooks ignore these.
		"is_first_leg": _toil_is_first_leg,
		"on_pick_up_success": _toil_on_pick_up_success,
	}
	_scheduler.queue.set_haul_backoff(int(haul_definition["retry_base_ticks"]), int(haul_definition["retry_cap_ticks"]))
	_haul_giver = HaulGiverType.new(int(haul_definition["priority"]), get_jobs.bind(["haul"]), get_items, _zone_table.is_in_any_zone, _scheduler.submit,
		_scheduler.queue.attach_item, get_zones, is_cell_free, passability, _is_cell_occupied)
	_scheduler.queue.set_haul_destination_finder(_haul_giver.find_free_haul_cell)
	# The queue's own kind-filtered read: get_jobs()'s tool-handover overlay never touches a
	# site_fetch/site_work job (neither kind needs a tool), the only kinds the giver reads.
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

## Read-only dry run of apply()'s own rules: validates the envelope, then runs the
## exact same pre-mutation check apply()'s own handler consults (CommandChecksType.check(), see
## game/scripts/core/commands/command_checks.gd) without touching state, so a hover/drag
## preview or Play-mode cursor can ask "would apply() accept this?" per tile without
## StateCodec.encode()/decode()'s whole-world round trip. Never mutates _tile_grid.tiles, _colonists,
## _jobs, the event log or any other field -- state_hash() is unchanged before and after a call, and
## unlike apply() a rejected preview() never appends a command_rejected event or advances
## the event sequence: _validate_command(command, false) and
## _event_log.pure_rejection() build the same rejection Dictionary apply() would return without
## either side effect.
func preview(command) -> Dictionary:
	var validation := _validate_command(command, false)
	if not validation["ok"]:
		return validation
	# build keeps its read-only rules in ConstructionSystem.check_construction_command()
	# -- the exact same function apply_construction_submission() runs --
	# so a hover preview and apply() always agree; cancel_site mirrors it via
	# _check_cancel_site_command(). place_object calls _check_place_object_command()
	# directly for the same reason; CommandChecks.check_place_object_command()
	# delegates to this same function, so either path runs
	# identical, current rules.
	if command["type"] == "build_line":
		var classification := _construction.classify_build_line_command(command["payload"])
		if classification.has("reason"):
			return _event_log.pure_rejection(command["command_id"], command["actor"], classification["reason"], classification["message"])
		return {"ok": true, "skipped": classification["skipped"]}
	var check: Dictionary
	if command["type"] == "build":
		check = _construction.check_construction_command(command["payload"])
	elif command["type"] == "cancel_site":
		check = _check_cancel_site_command(command["payload"])
	elif command["type"] == "place_object":
		check = _check_place_object_command(command["payload"])
	else:
		check = CommandChecks.check(self, command)
	if not check.is_empty():
		return _event_log.pure_rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	return {"ok": true}

## Only mutator alongside tick(): validates and applies a command envelope.
func apply(command) -> Dictionary:
	var validation := _validate_command(command)
	if not validation["ok"]:
		return validation
	match command["type"]:
		"noop":
			return _event_log.apply_noop(command)
		"dig", "chop", "forage", "till", "sow", "mine", "complete_job", "fail_job", "invalidate_job":
			return _apply_job_command(command)
		"cancel_job":
			return _apply_cancel_job_command(command)
		"build":
			return _construction.apply_construction_submission(command)
		"build_line":
			return _construction.apply_build_line_command(command)
		"cancel_site":
			return _apply_cancel_site_command(command)
		"place_object":
			return _apply_place_object_command(command)
		"remove_object":
			return _apply_remove_object_command(command)
		"set_labour":
			return _apply_set_labour_command(command)
		"set_faction":
			return _apply_set_faction_command(command)
		"spawn_incident":
			return _apply_spawn_incident_command(command)
		"accept_trade":
			return _trade.apply_accept_trade_command(command)
		"zone_add":
			return _apply_zone_add_command(command)
		"zone_remove":
			return _apply_zone_remove_command(command)
		_:
			return _event_log.rejection(
				command["command_id"], command["actor"], "unknown_command_type",
				"No handler for command type '%s'." % command["type"]
			)

## Only mutator alongside apply(): advances exactly one tick.
func tick() -> void:
	_clock.advance(1)
	_needs_system.decay_needs()
	_need_giver.advance(_colonists_not_combat_owned(), _clock.tick)
	_haul_giver.advance(_clock.tick)
	_construction_giver.advance(_clock.tick)
	_apply_combat(_clock.tick)
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
	var mover_component = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

## Reads the "worker" component's labourTable through ActorTable (ADR 012):
## a freshly assembled wrapper Dictionary, but its "labourTable" value is the
## same live Dictionary colonist["labourTable"] holds, so mutating a value on
## the return still mutates the colonist's real state.
func _labour_table(colonist: Dictionary) -> Dictionary:
	var worker_component = ActorTableType.get_component(colonist, "worker", _content)
	return worker_component.get("labourTable", {}) if worker_component != null else {}

func state_hash(include_incidents: bool = true) -> int:
	_needs_system.ensure_needs()
	_ensure_held_tool()
	_ensure_health()
	var snapshot := {
		"seed": _seed,
		"tick": _clock.tick,
		"tool_items": _tool_store.items,
		"next_tool_item_id": _tool_store.next_id,
		"tool_reservations": _tool_store.reservations.snapshot(),
		"colonists": _colonists,
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
	_ensure_health()
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

## Every actor with a `health` component, worker or not -- unlike
## get_colonists() above, this is not filtered to worker actors, so a
## presentation layer can render a health bar for any combat-eligible actor
## (a wolf, a trader) even before it has its own dedicated sprite
## (get_colonists()'s worker-only filter would hide every non-worker actor
## from colonist_sprites.gd's health bars).
func get_actors_with_health() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for actor in _colonists:
		if actor.get("health") is Dictionary:
			copy.append(actor.duplicate(true))
	return copy

## Every trader's own outstanding trade_offer, for colonist_panel.gd.
func get_pending_trade_offers() -> Array[Dictionary]:
	return _trade.get_pending_trade_offers()

## The handover overlay only mutates this call's own detached duplicates, never JobQueue's state; a non-empty `kinds` keeps only those kinds, costing only the jobs returned (B1).
## get_job(): one job as get_jobs() shows it, {} when unknown. The two summaries below: see JobIndex (B1).
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
	return _scheduler.queue.get_queued_summary()

func get_designation_changes(from: int) -> Dictionary:
	return _scheduler.queue.get_designation_changes(from)

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
## _toil_on_unreachable(), which only ever fires once a job has actually
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
	for colonist in _colonists:
		if String(colonist["id"]) != excluding_colonist_id and int(colonist["x"]) == x and int(colonist["y"]) == y:
			return true
	if _item_table.has_item_at(x, y):
		return true
	return false

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
		var assignment = _scheduler.get_assignments().get(colonist_id)
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
	# Checked here too, not only in _toil_on_work_complete()'s final-tick
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
## tick() and _apply_job_command() (a command can resolve a need outside
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
					_drop_carried_item_from(refused_colonist)
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
		var assignment = assignments.get(colonist_id)
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
		var route = _route(colonist)
		var work = colonist.get("work")
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
## same kind-aware _toil_on_unreachable() boundary every other first-leg
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
	var on_arrive := Callable(_toils, "start_work") if _toils.leads_into_work(String(job["kind"]), true) else Callable(self, "_toil_no_op_arrive")
	if _toils.advance_go_to(colonist, job_id, target, _routable_to(target, String(colonist.get("factionId", "colony"))), "go_to", on_arrive) != "unreachable":
		return
	_toil_on_unreachable(job_id, job, true)

## on_arrive no-op for a resumed go_to leg that must not auto-start work (see
## _advance_go_to_or_resubmit() above): arrival simply clears route, same as
## ToilExecutor's own internal _no_op_arrive(), leaving the next toil
## (pick_up, for a haul/build leg one) to the ordinary advance() dispatch.
func _toil_no_op_arrive(_colonist: Dictionary, _job_id: String) -> void:
	pass

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
## site is unchanged; _toil_go_to_passable() below passes the acting actor's
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

## Shared by the two callers below: places any carried item on colonist's own
## tile (colonist-ai.md 3.3) and clears route/work/reroute state. _toils.place()
## re-validates the destination (passability, occupancy) same as any ordinary
## drop; when another actor or ground item happens to occupy the colonist's
## own tile at the exact tick a refusal terminates the job, that re-validation
## fails and _force_drop_carried_item() below deposits the item unconditionally
## instead of leaving it stranded in "carrying" -- the same terminal-drop
## guarantee ToolDropToil's _drop_tool_ground already gives a tool item that
## has nowhere valid to go.
func _drop_carried_item_from(colonist: Dictionary) -> void:
	_deposit_carried_item(colonist)
	colonist["route"] = null
	colonist["work"] = null
	_reroutes.erase(colonist["id"])

## The deposit half of _drop_carried_item_from() alone -- ordinary place()
## onto the colonist's own tile, unconditional fallback when that is refused
## -- with no route/work reset, for a carrier whose route/work currently
## belong to a different (need) job than the one being terminated
## (_drop_carried_haul_item()'s suspended-owner branch below).
func _deposit_carried_item(colonist: Dictionary) -> void:
	if not InventoryType.is_carrying(colonist):
		return
	var result := _toils.place(colonist, Vector2i(int(colonist["x"]), int(colonist["y"])))
	if not bool(result.get("ok", false)):
		_force_drop_carried_item(colonist)

## Unconditional terminal drop for a refused/terminated job whose ordinary
## place() was refused (occupied or impassable current tile): writes every
## hands entry straight to the ground at the colonist's own tile (one fresh
## item per distinct kind, same as place() itself), bypassing its occupancy/
## passability re-validation. Mirrors tool_drop_toil.gd's own
## _drop_tool_ground fallback, which already accepts landing a tool on top of
## whatever is there rather than losing it -- conservation of the item across
## a forced termination matters more than the destination cell staying tidy.
func _force_drop_carried_item(colonist: Dictionary) -> void:
	for entry in InventoryType.hands_snapshot(colonist):
		_item_table.place_new_ground_item(String(entry["kind"]), int(entry["count"]), int(colonist["x"]), int(colonist["y"]))
	InventoryType.clear_hands(colonist)

## Drops a haul/build job's carried item at the shared terminal boundary
## (cancel/fail/invalidate commands, an unreachable second leg, a refused
## build completion): the live-assignment path first, where job_id still
## names a worker; otherwise the suspended-owner path --
## a job paused by a critical-need interrupt is only recorded in
## NeedsSystem.paused_jobs, so its carrier is resolved there and deposits the cargo
## without touching its route/work, which now belong to the need job driving
## it. The pause entry is cleared too: the job is about to be terminal, so
## there is nothing left to resume.
func _drop_carried_haul_item(job_id: String) -> void:
	var colonist := _find_job_colonist(job_id)
	if not colonist.is_empty():
		_drop_carried_item_from(colonist)
		return
	for colonist_id in _needs_system.paused_jobs.keys():
		if String(_needs_system.paused_jobs[colonist_id]) != job_id:
			continue
		_needs_system.paused_jobs.erase(colonist_id)
		var carrier := _find_colonist(String(colonist_id))
		if not carrier.is_empty():
			_deposit_carried_item(carrier)
		return

## Terminal haul failure with a specific typed reason: not retried, since its
## own failure is permanent; HaulGiver.advance() submits a fresh job next tick
## if the item is still on the ground.
func _terminate_haul_job_by_id(job_id: String, reason: String, remedy: String) -> void:
	_drop_carried_haul_item(job_id)
	_scheduler.queue.set_pending_fail_reason(job_id, reason, remedy)
	_finish_job(job_id, "fail_job")

## work_target_for callable injected into _toils (ToilExecutor's own
## start_work()/advance_work_step()): the tile a job's `work` toil actually
## operates on/completes at. Every kind's own job["target"] already names it
## directly -- a site_work job's "target" is the site's own origin tile (its
## only leg, attach_site()) -- so this is a plain passthrough today; kept as
## its own function since _toil_on_work_complete() and every other
## work-in-progress-key reader (TrenchSystem._trap_actor(), _apply_job_command()'s
## terminal-command cleanup) call it rather than reading job["target"]
## themselves, so a future kind needing a second destination has one place to
## redirect from.
func _work_target_for(job: Dictionary) -> Vector2i:
	return job["target"]

## go_to_target hook for _toils: the item's tile for a haul/site_fetch job's
## first leg, or job["cell"]/job["site"] for its second leg (site_fetch's
## second leg mirrors haul's own "target"/"cell" split, but through
## job_queue.gd's own "site" field). A site_work job has only one
## leg, straight to its own origin tile (already job["target"]). Any other
## kind always uses its own single target.
func _toil_go_to_target(job: Dictionary, is_first: bool) -> Vector2i:
	var kind := String(job["kind"])
	if kind == "haul":
		return job["target"] if is_first else job["cell"]
	if kind == "site_fetch" and not is_first:
		return job["site"]
	return job["target"]

## is_first_leg hook (hands-filling rules): every kind
## but site_fetch keeps ToilExecutor's original is_carrying()-based default
## unchanged. A site_fetch job's own "cell" field -- always null for
## site_fetch otherwise, since it never drives a `place` toil (it ends in
## `deposit`) -- doubles as the "done fetching, now delivering"
## flag: null while _toil_on_pick_up_success() still finds more worth
## visiting, stamped with the site's origin the moment it decides otherwise
## (JobQueue.mark_site_fetch_delivering()). This is what lets a single
## site_fetch job's [go_to, pick_up] pair revisit more than one source before
## its later [go_to, deposit] pair ever runs.
func _toil_is_first_leg(job: Dictionary, colonist: Dictionary) -> bool:
	if String(job.get("kind", "")) != "site_fetch":
		return not InventoryType.is_carrying(colonist)
	return job.get("cell") == null

## go_to_passable hook: haul's first leg reuses _routable_to() so an
## impassable target still terminates the search; its second leg uses plain
## passability (HaulGiver.find_free_haul_cell() already guarantees it passable).
## site_fetch's second leg and site_work's only leg also reuse _routable_to()
## (the branch below already applies it to every non-haul kind): the
## target-tile exception lets the search walk right up to/onto the site even
## though the declared object isn't placed yet, and
## _toil_go_to_force_trim_last() below then decides whether the final tile is
## kept (site_fetch's deposit, staying passable) or trimmed to land the
## colonist adjacent instead (site_work, about to sit next to what may become
## an impassable object).
## faction_id (F5) is ToilExecutor's own acting-colonist factionId, threaded through so a non-colony actor's route search is gated by its own faction's door permissions; every pre-existing (colony) caller still gets "colony" by default.
func _toil_go_to_passable(job: Dictionary, is_first: bool, target: Vector2i, faction_id: String = "colony") -> Callable:
	# An incident's destination needs actual arrival on a faction-passable tile, never _routable_to()'s dig/chop/forage impassable-target exception -- a door or wall must make it genuinely unreachable.
	if String(job["kind"]) == "incident":
		return func(tile: Vector2i) -> float: return _passability.passable_for_faction(tile, faction_id)
	# A rescuer's every re-route (a
	# corridor blocked mid-travel, a resume after a need interrupt) runs under
	# rescue's own trench-excluding, no-target-exception passability, so it
	# can never be routed through a trench nor trimmed to start work off-target.
	if String(job["kind"]) == "rescue":
		return _trench.rescue_routable_to(target, faction_id)
	return _routable_to(target, faction_id) if is_first or String(job["kind"]) != "haul" else _passability.is_passable

## go_to_force_trim_last hook: a site_work job's only leg, and a
## site_fetch job's own second (delivery) leg, both target the site's own
## origin tile, which is still genuinely passable at travel time -- nothing is
## placed there until progress reaches build_ticks -- so the ordinary "trim
## only a target that's impassable right now" rule
## (ToilExecutor._resume_go_to_reroute()) never fires for it, and a builder
## would otherwise walk onto and stand on the exact tile that may become an
## impassable object. Forcing the trim for both (a builder already standing
## on the site is stepped off by ToilExecutor.advance_go_to()'s own step-off
## rule) lands every builder adjacent instead, exactly like chop/forage's own
## already-impassable target -- and, critically, keeps a site_fetch delivery
## from ever parking a colonist exactly on the origin tile, which would
## otherwise let start_assignment()'s own "already at target" shortcut skip
## the trim entirely for the very next site_work leg and let the colonist
## wall itself in the instant that site completes.
func _toil_go_to_force_trim_last(job: Dictionary, is_first: bool) -> bool:
	var kind := String(job["kind"])
	return kind == "site_work" or (kind == "site_fetch" and not is_first)

## go_to_skip_assignment_path hook: a site_work job's single leg
## is always "is_first" (_is_first_leg() short-circuits true for any kind
## whose toils have no pick_up, before ever consulting a hook), so
## _start_current_toil() would otherwise walk GlobalAssignmentScheduler's own
## precomputed path via start_assignment() -- which knows nothing about
## go_to_force_trim_last above and, unlike chop/forage's target, never trims a
## site's own origin tile itself (still genuinely passable at scheduling time).
## Forcing every site_work go_to through the fresh bounded search
## (_continue_go_to()/advance_go_to()) instead is what actually applies the
## trim, so a builder's work leg lands adjacent to the site exactly like its
## own delivery leg already does, never on the tile about to become an object.
## A site_fetch job's own fetch leg may visit more than one source before
## delivering (the hands-filling rules), so a job this
## tick's or an earlier hop's resolve_freshly_activated_site_fetch_sources()/
## _toil_on_pick_up_success() has ever retargeted away from
## GlobalAssignment's own precomputed path (site_fetch_source_retargeted)
## must also run the same fresh bounded search every later hop already uses,
## rather than walking a path toward a target this leg no longer targets.
func _toil_go_to_skip_assignment_path(job: Dictionary) -> bool:
	var kind := String(job.get("kind", ""))
	if kind == "site_work":
		return true
	return kind == "site_fetch" and _construction.site_fetch_source_retargeted.has(String(job.get("id", "")))

## on_unreachable hook: a first-leg target may still be reachable elsewhere, so
## it is cancelled and resubmitted; a second-leg haul destination fails outright.
## An incident actor's target is never resubmitted (F5): the
## job is cancelled through the shared finish boundary, whose incident
## cleanup despawns the actor. A flee target is likewise never resubmitted
## here: _resubmit_unreachable_job() replaces a job
## through the ordinary, may_be_ordered-gated submit() -- refused outright for
## a hostile actor, and stripped of the autonomous flag even when accepted,
## leaving CombatGiver's own `_fleeing` association pointing at a cancelled
## id while a second, ungoverned job exists. Cancelling only and leaving it
## alone lets CombatGiver's own advance() -- which already treats any
## non-active/queued tracked job as free -- pick a fresh, freshly-reachable
## candidate through the one submit_autonomous() path the very next tick.
func _toil_on_unreachable(job_id: String, job: Dictionary, is_first: bool) -> void:
	if String(job["kind"]) in ["incident", CombatGiverType.FLEE_KIND, ApproachGiverType.APPROACH_KIND]:
		_finish_job(job_id, "cancel_job")
	elif String(job["kind"]) == "rescue":
		# Never resubmitted under the same
		# rescuer -- retired, so another available rescuer may be chosen.
		_trench.retire_rescue_job(job_id, job)
	elif String(job["kind"]) == "site_fetch":
		# Never resubmitted (unlike dig/chop/mine's first leg): a fresh fetch
		# job would need its own source resolution, which
		# _resubmit_unreachable_job() knows nothing about; ConstructionGiver's
		# own per-tick scan submits a replacement once this one terminates.
		# Fails outright instead, exactly like haul's own second leg --
		# dropping any carried item and releasing the item reservation through
		# the existing terminal path.
		_terminate_haul_job_by_id(job_id, "blocked_target_unreachable", "restore_target_access")
	elif String(job["kind"]) == "site_work":
		# No cargo, no reservation of its own to release; ConstructionGiver
		# tops the site back up to max_builders on a later tick once this
		# job's own terminal transition frees its builder slot.
		_finish_job(job_id, "cancel_job")
	elif is_first or String(job["kind"]) != "haul":
		_resubmit_unreachable_job(job_id, job)
	else:
		_terminate_haul_job_by_id(job_id, "blocked_destination_gone", "choose_reachable_destination")

## item_id_for hook for _toils's pick_up toil.
func _toil_item_id_for(job: Dictionary) -> String:
	return String(job["item_id"])

## cell_for hook for _toils's place toil: haul's own destination cell.
## site_fetch never drives a `place` toil at all (it ends in `deposit`
## instead), so this hook is never called for it.
func _toil_cell_for(job: Dictionary) -> Vector2i:
	return job["cell"]

## site_id_for hook for _toils's deposit toil: the construction site
## site_fetch's second leg is delivering to, resolved from job["site"] (the
## origin tile attach_site() recorded) via ConstructionSiteTable.
## find_at_origin(). "" for any other kind (deposit is never their toil).
func _toil_site_id_for(job: Dictionary) -> String:
	if job.get("site") == null:
		return ""
	return _construction.site_table.find_at_origin(job["site"])

## pick_up_count_for hook (construction sites, extended for the hands-filling
## rules and chained delivery): clamps a site_fetch pick_up to what the
## current target site still needs of that source's own kind
## (ConstructionSiteTable.remaining()), plus every other reachable,
## still-short, not-already-at-capacity sibling site's own remaining need of
## the same kind (reachable_short_sibling_sites(): sized so a hands-load can
## actually carry enough to chain onto more than one block, not just the site
## job["site"] currently names -- see _toil_on_deposit_success() below, the
## other half of this design; a sibling already holding its own max_builders
## worth of queued-or-active fetch-plus-work jobs, per ConstructionSystem._site_fetch_work_busy(),
## is excluded from this sum too, since it could never actually accept a
## chained delivery), minus whatever of that same kind colonist's
## hands already hold from an earlier hop this same job -- taking a generous
## source's whole remaining-need could otherwise, on a second or later hop,
## request more than every reachable site combined actually still needs,
## over-filling hands with units no site the colonist could plausibly chain
## onto will ever accept (deposit() only transfers up to what a site still
## needs, leaving any unaccepted remainder stuck in hands with no drop path of
## its own). -1 (pick_up()'s own "take the whole reachable stack" default) for
## any other kind, or when the site is already gone.
func _toil_pick_up_count_for(job: Dictionary, colonist: Dictionary) -> int:
	if String(job.get("kind", "")) != "site_fetch":
		return -1
	var site_id := _toil_site_id_for(job)
	if site_id.is_empty():
		return -1
	var item := _item_table.item_lookup(String(job.get("item_id", "")))
	if item.is_empty():
		return -1
	var kind := String(item.get("kind", ""))
	# Cached for _toil_on_pick_up_success(): the
	# pick_up this count gates for may exhaust and delete item's own entry
	# from the item table entirely, so that hook cannot re-derive kind the same way
	# once it runs.
	_construction.site_fetch_picked_kind[String(job.get("id", ""))] = kind
	var site := _construction.site_table.get_site(site_id)
	var need := _construction.site_table.remaining(site, kind)
	var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
	for sibling in _construction.reachable_short_sibling_sites(colonist, kind, current, site_id):
		need += _construction.site_table.remaining(sibling, kind)
	need -= InventoryType.count_of_kind(colonist, kind)
	return need if need > 0 else -1

## on_pick_up_success hook (hands-filling rules): a
## site_fetch job's own per-hop decision, made once right after each pick_up
## completes (never re-evaluated mid-travel, so a colonist walking toward an
## already-chosen source never flip-flops): deliver now
## (JobQueue.mark_site_fetch_delivering(), flips _toil_is_first_leg() to
## false) once hands already cover the site's own remaining need of that
## kind, hands are full, no further eligible unclaimed source of the same
## kind exists, or -- the "very close" rule, this design's one behavioural
## branch point -- the site's own deterministic route cost (_route_cost(),
## not open-field Chebyshev) from the colonist's current tile is no farther
## than the next unreserved source's; otherwise reserve that next source
## directly on the shared ReservationTable and retarget the job at it
## (retarget_site_fetch_source()), continuing to fill hands rather than ever
## delivering a partial load while a nearer top-up is still available. A
## no-op for any other job kind, a colonist no longer findable (job already
## terminating), or a site already gone (delivers with whatever hands hold;
## on_deposit_success/deposit() tolerate a since-vanished site as a no-op).
func _toil_on_pick_up_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("kind", "")) != "site_fetch":
		return
	var colonist := _find_job_colonist(job_id)
	if colonist.is_empty():
		return
	var site_id := _toil_site_id_for(job)
	if site_id.is_empty():
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var site := _construction.site_table.get_site(site_id)
	# Not _item_table.item_lookup(job["item_id"]): a pick_up that exactly
	# exhausts its source's remaining count deletes that item from the item table
	# before this hook ever runs (ToilExecutor.pick_up()'s own _remove_item
	# call), which would silently resolve kind as "" here instead -- see
	# ConstructionSystem.site_fetch_picked_kind's own doc comment.
	var kind := String(_construction.site_fetch_picked_kind.get(job_id, ""))
	var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
	if (InventoryType.count_of_kind(colonist, kind) >= _construction.site_table.remaining(site, kind)
			or InventoryType.free_capacity(colonist) <= 0):
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var next_id := _construction.next_site_fetch_source(colonist, job, kind, current)
	if next_id.is_empty():
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var next_item := _item_table.item_lookup(next_id)
	var next_tile := Vector2i(int(next_item["x"]), int(next_item["y"]))
	var faction_id := String(colonist.get("factionId", "colony"))
	var site_cost := _route_cost(current, site["origin"], faction_id)
	if site_cost < 0: site_cost = _UNREACHABLE_ROUTE_COST
	var next_cost := _route_cost(current, next_tile, faction_id)
	if next_cost < 0: next_cost = _UNREACHABLE_ROUTE_COST
	if site_cost <= next_cost:
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	_scheduler.queue.get_reservation_table().acquire(JobQueueType.ITEM_KEY_PREFIX + next_id, job_id)
	_scheduler.queue.retarget_site_fetch_source(job_id, next_id, next_tile)
	_construction.site_fetch_source_retargeted[job_id] = true

## on_toil_fail hook: pick_up/place/deposit are haul-shaped (haul, site_fetch),
## so a failed one always permanently fails the job. A failed consume belongs
## to a need job instead: no carried item to drop, and NeedGiver must hear
## about the resolution.
func _toil_on_toil_fail(job_id: String, reason: String) -> void:
	var job := _get_job(job_id)
	if _needs_system.need_kind_for_job(String(job.get("kind", ""))).is_empty():
		_terminate_haul_job_by_id(job_id, reason, "resubmit_order")
		return
	_scheduler.queue.set_pending_fail_reason(job_id, reason, "resubmit_need")
	_finish_job(job_id, "fail_job")
	_need_giver.resolve_job(job_id)

## on_place_success hook: an ordinary haul job simply completes once its item
## lands in its stockpile cell. site_fetch never drives a `place` toil at all
## (it ends in `deposit` instead), so this hook is never called
## for it.
func _toil_on_place_success(job_id: String) -> void:
	_finish_job(job_id, "complete_job")

## on_deposit_success hook (construction sites, extended for chained
## delivery): a site_fetch job completes once its hands are transferred into
## the site's held_materials -- unless hands still hold units of the job's own
## kind (the deposit toil itself already clamped to what the just-delivered
## site still needed, so any leftover means that site is now fully served for
## this kind) and a reachable, still-short, same-kind, not-already-at-capacity
## sibling site exists (next_site_fetch_site(), the same deterministic
## route-cost search next_site_fetch_source() uses for sources, applied to
## sites): retarget the same job onto it (JobQueue.retarget_site_fetch_site())
## and let the ordinary per-tick advance() drive a fresh go_to/deposit pair
## there instead of completing, rather than ending the job and forcing a fresh
## trip back to a stockpile for every further block a hands-load could still
## serve. job["site"] always names whichever site the job is currently
## delivering to either way -- no new persisted field, so a mid-chain
## save/load round-trips exactly like a single-site delivery already did.
## `kind` is read straight off the colonist's own (persisted) hands rather
## than a runtime cache: a source item a pick_up exhausted and deleted, or a
## save/load between hops, can never leave it unresolved (the
## `site_fetch_picked_kind` cache is never saved and is empty right after a
## load, which would silently end a chain early). When leftover exists but no
## sibling qualifies, it is dropped through the same live-assignment
## terminal-drop path cancel_job/cancel_site already use
## (_drop_carried_item_from()) before completing, so no material is ever
## stranded in hands past the job's own end. A colonist no longer findable
## (job already terminating) falls through to the ordinary completion,
## mirroring on_place_success's own "the toil already did the work" shape.
func _toil_on_deposit_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var colonist := _find_job_colonist(job_id)
	if not colonist.is_empty() and InventoryType.is_carrying(colonist):
		var kind := String((InventoryType.hands_snapshot(colonist)[0] as Dictionary)["kind"])
		var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var delivered_site_id := _toil_site_id_for(job)
		var next_site := _construction.next_site_fetch_site(colonist, kind, current, delivered_site_id)
		if not next_site.is_empty():
			_scheduler.queue.retarget_site_fetch_site(job_id, next_site["origin"])
			return
		_drop_carried_item_from(colonist)
	_finish_job(job_id, "complete_job")

## on_work_complete hook: applies this job kind's completion effect -- what
## "work" produces for dig/chop/forage/mine/till/sow, or the need sleep restores --
## then finishes the job. till/sow/mine re-check their own target tile kind here
## even though submission already checked it, since a paused job's released
## tile reservation can let another order complete on the same target first
## (e.g. two mine orders on one rock tile: the second's target is TILE_FLOOR
## by the time it would spawn a second stone).
## Dirty-cell/region/room hooks fire only when the target tile actually changed kind:
## sleep/incident transform nothing, and RoomMap re-floods the outdoors (~200 ms at 256x256).
func _toil_on_work_complete(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var target: Vector2i = _work_target_for(job)
	# ADR 026: trapping on a same-tick arrival pre-empts the completion effect below.
	if _trench.trap_on_work_complete(job_id, job, target):
		return
	var tile_before: String = _tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)]
	match job["kind"]:
		"dig":
			if get_tile(target.x, target.y) != TILE_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_TRENCH
			var sand_at := _item_table.dig_item_placement(target.x, target.y)
			_item_table.spawn_item("sand", sand_at.x, sand_at.y)
			_item_table.stage_dig_find(job_id, target.x, target.y)
		"chop":
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_SOIL  # trees only grow on soil
			_item_table.spawn_wood_item(target.x, target.y)
		"mine":
			if get_tile(target.x, target.y) != TILE_ROCK:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_FLOOR
			_item_table.spawn_stone_item(target.x, target.y)
		"forage":
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_FLOOR
			_object_table.set_object(target.x, target.y, "")
			_item_table.spawn_berries_item(target.x, target.y)
		"till":
			if get_tile(target.x, target.y) != TILE_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_PLOWED_SOIL
		"sow":
			if get_tile(target.x, target.y) != TILE_PLOWED_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			if not _item_table.remove_one_item_of_kind("seed"):
				# Seed was consumed by another sow/haul after this job committed.
				_scheduler.queue.set_pending_fail_reason(job_id, "blocked_missing_input", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_PLANTED
		"site_work":
			# Every builder's own site_work job adds one tick of
			# progress per tick it works (ConstructionSiteTable.add_progress(),
			# not a private per-job counter -- this final tick included, the
			# ones before it via _set_work_progress()'s own site_work branch),
			# so the mechanism already sums correctly for more than one
			# concurrent builder.
			# Once accumulated progress meets the site's own declared
			# build_ticks, ConstructionSystem finalizes the site: places the
			# declared object, releases the site's footprint reservation, and
			# removes the site record.
			_construction.add_site_work(target, job_id)
		"sleep":
			var colonist := _find_job_colonist(job_id)
			if not colonist.is_empty():
				_needs_system.apply_need_effect(colonist, job)
		"escape_trench":
			_trench.complete_escape(job_id, target)
		"rescue":
			_trench.complete_rescue(job_id)
	if _tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] != tile_before:
		_tile_grid.update_water_tile_cache(target.x, target.y, tile_before == TILE_WATER, _tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] == TILE_WATER)
		_tile_grid.mark_dirty(target.x, target.y)
		_tile_grid.get_regions().on_passability_changed(target.x, target.y)
		_tile_grid.get_rooms().on_passability_changed(target.x, target.y)
	_finish_job(job_id, "complete_job")
	_resolve_giver_association(job_id, String(job["kind"]))

## Tells whichever job-giver owns job_id (NeedGiver for a need job, RescueGiver
## for a rescue job) that it resolved -- shared by _toil_on_work_complete()'s
## own completion path, TrenchSystem._trap_actor(), _cancel_job_for_death() and
## _resolve_refused_reservations(), everywhere a job terminates outside its
## giver's own advance()/resolve_job() call.
func _resolve_giver_association(job_id: String, kind: String) -> void:
	if not _needs_system.need_kind_for_job(kind).is_empty():
		_need_giver.resolve_job(job_id)
	elif kind == "rescue":
		_rescue_giver.resolve_job(job_id)
	elif kind == "site_work":
		_construction.release_site_builder(job_id)

## on_consume_success hook (eat_food/drink_water): restores the need,
## finishes the job, and tells NeedGiver this resolved so a paused colonist
## resumes.
func _toil_on_consume_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var colonist := _find_job_colonist(job_id)
	if not colonist.is_empty():
		_needs_system.apply_need_effect(colonist, job)
	_finish_job(job_id, "complete_job")
	_need_giver.resolve_job(job_id)

## on_no_tool_found hook: requeue_assignment(), not
## suspend_assignment(), so the job keeps its original restrict_to (empty for
## an ordinary order) instead of getting pinned to a colonist whose own fetch
## just failed -- letting any still-eligible colonist pick it back up.
## JobQueue.block_no_tool() then applies this kind's own backoff/reason.
func _toil_on_no_tool_found(job_id: String, colonist_id: String, kind: String) -> void:
	_scheduler.requeue_assignment(colonist_id, job_id)
	_scheduler.queue.block_no_tool(job_id)

## tool_available callable for JobQueue.set_tool_requirement(): true when a
## matching tool is free, or already reserved by
## job_id itself -- a still-queued job normally holds no tool reservation
## yet (fetch_tool only ever reserves one once its job is active, and
## _toil_on_no_tool_found()'s callers already release any reservation before
## suspending), but the public reserve_tool_item() surface lets a caller
## reserve one ahead of activation, and this gate must not then treat the
## job's own reservation as proof no tool exists.
func _tool_exists(job_id: String, kind: String) -> bool:
	return bool(ToolMatchingType.find_nearest_free_tool(kind, Vector2i.ZERO, job_id,
		get_tool_items(), get_tool_item_reservation, ToolMatchingType.colonist_position_map(_colonists)).get("found", false))

## tool_requirement_of callable for JobQueue.set_tool_requirement(): {} for a job kind with no needs_tool requirement, else
## {"kind","retry_base_ticks","retry_cap_ticks"} straight from the
## content-loaded table _init() built alongside _needs_tool_by_kind.
func _tool_requirement_for_kind(kind: String) -> Dictionary:
	return _tool_requirements_by_kind.get(kind, {})

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

## Backfills a missing "health" (ActorTable.spawn()'s default) and
## "factionId" (only one faction exists) with "colony", like
## _ensure_held_tool(). Also "trapped" to null (no component builds it), so
## state_hash() never diverges from a freshly decoded StateCodec entity.
func _ensure_health() -> void:
	for colonist in _colonists:
		if not colonist.has("factionId"): colonist["factionId"] = "colony"
		if not colonist.has("trapped"): colonist["trapped"] = null
		if ActorTableType.get_component(colonist, "health", _content) is Dictionary:
			continue
		var definition: Dictionary = _content.get_entry("actors", String(colonist.get("kind", "colonist")))
		colonist["health"] = HealthType.build_full(definition.get("tunables", {}).get("health", {}))

## Backfills a missing "combat" component onto a colonist whose own
## definition now declares one (content/actors.json's colonist entry) --
## ActorTable._spawn_colonist() (ADR 012) keeps colonist's exact legacy field
## set and never adds a "combat" key itself, mirroring how _ensure_health()/
## NeedsSystem.ensure_needs() already backfill a component ActorTable's own special-cased
## spawn path does not build. A plain append (never a rebuild): every
## colonist, fresh-spawned or loaded from a save that predates combat, is
## uniformly missing "combat" at this point, so appending it last is the same
## key order every time -- state_hash()'s JSON.stringify(_colonists) stays
## deterministic across two runs of the same seed. A generic actor (wolf/
## trader) never reaches this: ActorTable._spawn_generic_actor() already
## builds its "combat" key directly from its own declared component.
func _ensure_combat() -> void:
	for colonist in _colonists:
		if not ActorTableType.has_component(colonist, "worker", _content):
			continue
		if colonist.has("combat") or not ActorTableType.has_component(colonist, "combat", _content):
			continue
		var definition: Dictionary = _content.get_entry("actors", String(colonist.get("kind", "colonist")))
		colonist["combat"] = CombatType.build(definition.get("tunables", {}).get("combat", {}))

## F5 combat (ADR 021): run once per tick before the fair scheduler sees any colonist. Resolves attacks
## (rule 1) via CombatResolver, applies its reported deaths (rule 2) against
## this WorldState's own owned state (job/reservation cleanup, dropping
## inventory, removal from scheduling), then lets CombatGiver decide whether
## any actor now below its own flee_hp_fraction should start a `flee` job
## (rule 4) -- per ADR 011, WorldState calls both, implements neither.
func _apply_combat(tick: int) -> void:
	var result := CombatResolverType.resolve_tick(_colonists, _content, _relations, tick, PRIORITY_TICK,
		get_object, _object_table.object_health_at, get_object_faction_id, _object_table.damage_object, _event_log.insert_event, _event_log.next_sequence)
	_combat_status.clear()
	for actor_id in (result["fighting"] as Array):
		_combat_status[String(actor_id)] = REASON_FIGHTING
	for dead_actor in (result["dead_actors"] as Array):
		_apply_actor_death(dead_actor)
	_combat_giver.advance(_colonists, tick)

## "" (no combat this tick) when actor_id names no known actor or has no
## adjacent hostile target -- REASON_FIGHTING otherwise, mirroring
## get_colonist_need_reason()'s own absent-key default.
func get_actor_combat_reason(actor_id: String) -> String:
	return String(_combat_status.get(actor_id, ""))

## F5 combat rule 2: a dead actor is removed from scheduling. Drops its
## inventory contents as loose items on its own tile -- death-specific, kept
## out of the shared _cleanup_actor_scheduling()/_remove_colonist_by_id() an
## ordinary (non-death) incident despawn also goes through -- then removes it
## through _remove_colonist_by_id(), which owns the scheduling/giver cleanup
## shared with that despawn path.
func _apply_actor_death(actor: Dictionary) -> void:
	var colonist_id: String = String(actor["id"])
	_drop_inventory_contents(actor)
	_remove_colonist_by_id(colonist_id, true)

## Every nonterminal job restricted to colonist_id -- its own active
## assignment, a paused one, and any still-queued or otherwise-routing one --
## cancelled through the shared finish boundary, releasing every reservation
## it held and telling NeedGiver/CombatGiver so neither keeps an association
## pointing at a removed actor.
##
## Shared by _apply_actor_death() and _remove_colonist_by_id(): an incident
## job cancelled while combat has it suspended for a flee episode would
## otherwise leave that flee job's own assignment, search, reservation and
## CombatGiver association orphaned once IncidentScheduler.on_job_finished()
## removed the actor directly.
##
## The paused job (if any) is captured and detached from NeedsSystem.paused_jobs before
## the active assignment is cancelled: cancelling an active
## need job below calls NeedGiver.resolve_job() -> NeedsSystem.resume_interrupted_job(),
## reactivating whatever was paused for an actor about to be removed.
## Detaching first makes that resume a no-op.
##
## Cancelling the same job this runs on top of (an incident job mid-
## _finish_job()) is not a hazard: _scheduler.finish() rejects an
## already-terminal job as a no-op, and the get_jobs() loop below skips it
## once its status reads terminal, before the restriction check runs.
func _cleanup_actor_scheduling(colonist_id: String) -> void:
	# Retires the actor's own in-flight scheduler route-search batch, if any,
	# so an unrestricted candidate job it was still mid-searching does not
	# stay marked claimed forever, starving every other worker of it.
	_scheduler.retire_worker(colonist_id)
	var paused_job_id := ""
	if _needs_system.paused_jobs.has(colonist_id):
		paused_job_id = String(_needs_system.paused_jobs[colonist_id])
		_needs_system.paused_jobs.erase(colonist_id)
	var assignment = _scheduler.get_assignments().get(colonist_id)
	if assignment != null:
		_cancel_job_for_death(String(assignment["job_id"]))
	if not paused_job_id.is_empty():
		_cancel_job_for_death(paused_job_id)
	for job in _scheduler.queue.get_jobs():
		if String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var job_id: String = String(job["id"])
		if _job_restricted_to(job_id) != colonist_id:
			continue
		_cancel_job_for_death(job_id)
	_combat_giver.forget(colonist_id)
	_approach_giver.forget(colonist_id)

## Cancels job_id through the shared finish boundary and, when it was a need
## job, tells NeedGiver the resolution too -- the same pairing
## _resolve_refused_reservations()/_toil_on_toil_fail() already use, needed
## here as well since a dead actor's need job would otherwise leave
## NeedGiver's own `_pending` map pointing at a removed actor.
func _cancel_job_for_death(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	# Only a rescue's own job-scoped key is dropped here; an ordinary job's tile progress outlives its actor's death
	# exactly as before, so a successor order on that tile inherits it.
	if _finish_job(job_id, "cancel_job").get("ok", false):
		_progress_table.clear_terminated_job(job_id, job, false)
	_resolve_giver_association(job_id, String(job.get("kind", "")))

## restrict_to_for(), else the waiting entry's restriction for a never-activated job, so a still-queued job
## restricted to a just-killed actor (a flee job submitted the same tick it died) cannot survive _apply_actor_death()'s cleanup below.
func _job_restricted_to(job_id: String) -> String:
	var restrict_to := _scheduler.restrict_to_for(job_id)
	if not restrict_to.is_empty():
		return restrict_to
	return _scheduler.waiting_restrict_to(job_id)

## Drops whatever `actor` is holding as loose ground items at its own tile:
## a colonist's hands contents (one fresh item per distinct kind held), a
## colonist's held tool item (ToolItemStore, moved rather than duplicated so
## its identity/reservation state is preserved; otherwise a dead colonist's
## axe/pick would point at a deleted colonist and be permanently
## unreachable), and/or a generic actor's "inventory" component items array
## and single "tool" slot, each dispatched by content item kind through
## _drop_inventory_item() below.
func _drop_inventory_contents(actor: Dictionary) -> void:
	var x := int(actor["x"])
	var y := int(actor["y"])
	for entry in InventoryType.hands_snapshot(actor):
		_item_table.place_new_ground_item(String(entry["kind"]), int(entry["count"]), x, y)
	var held_tool_id := WorkerType.get_held_tool(actor)
	if not held_tool_id.is_empty():
		_tool_store.set_ground(held_tool_id, x, y)
	var inventory = actor.get("inventory")
	if inventory is Dictionary:
		for raw_item in (inventory.get("items", []) as Array):
			var item: Dictionary = raw_item
			_drop_inventory_item(String(item.get("kind", "")), int(item.get("count", 1)), x, y)
		var carried_tool_kind := String(inventory.get("tool", ""))
		if not carried_tool_kind.is_empty():
			_drop_inventory_item(carried_tool_kind, 1, x, y)

## Drops one "inventory" component item of `kind`/`count` at (x, y): a
## declared tool kind (is_tool_kind(), content/items.json) goes
## through spawn_ground_tool_item() -- ToolItemStore, the same store a
## worker's tool-match search (ToilExecutor's fetch_tool precondition) only
## ever looks in -- so a surviving colonist can actually find and reserve a
## dead actor's dropped axe/pick; any other kind goes through
## ItemTable.place_new_ground_item() as an ordinary stack, same as before. Tools carry
## identity, never a count, so a tool entry of `count` N spawns N separate
## ground tools (one spawn per entry would silently lose N-1).
func _drop_inventory_item(kind: String, count: int, x: int, y: int) -> void:
	if is_tool_kind(kind):
		for _unit in count:
			spawn_ground_tool_item(kind, x, y)
		return
	_item_table.place_new_ground_item(kind, count, x, y)

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

func _apply_job_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var result: Dictionary
	if command["type"] in ["dig", "chop", "forage", "till", "sow", "mine"]:
		var check := CommandChecks.check_target_job_command(self, command)
		if not check.is_empty():
			return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
		var target := Vector2i(payload["x"], payload["y"])
		# assignee (F3), dig/chop/forage/mine only: carried through
		# submit()'s existing restrict_to (already used by need_giver.gd).
		var assignee := String(payload.get("assignee", "")) if command["type"] in ["dig", "chop", "forage", "mine"] else ""
		result = _scheduler.submit(target, payload.get("priority", 1), _clock.tick, command["type"], assignee)
	else:
		if typeof(payload.get("job_id")) != TYPE_STRING or String(payload["job_id"]).is_empty():
			return _event_log.rejection(command["command_id"], command["actor"], "invalid_payload", "A non-empty job_id is required.")
		# Cancelling/failing/invalidating a haul or site_fetch job mid-carry
		# drops the carried item (colonist-ai.md 3.3); "complete_job"
		# already went through the job's own completion effect. A site_work job
		# never carries anything.
		if command["type"] in ["cancel_job", "fail_job", "invalidate_job"]:
			var target_job := _scheduler.queue.get_job(String(payload["job_id"]))
			if String(target_job.get("kind", "")) in ["haul", "site_fetch"]:
				_drop_carried_haul_item(String(payload["job_id"]))
		# Clear work_progress only once the transition succeeds, by the terminating job's own identity (WorkProgress.clear_terminated_job(): an ordinary job's plain tile key only when it was "active" before -- a queued competitor or a rejected/repeated terminal command must never erase another job's progress -- a rescue's own job-scoped key in every status).
		var terminal_job := _scheduler.queue.get_job(String(payload["job_id"]))
		var terminal_was_active: bool = String(terminal_job.get("status", "")) == "active"
		result = _finish_job(payload["job_id"], command["type"])
		if result["ok"] and command["type"] in ["complete_job", "cancel_job", "fail_job", "invalidate_job"]:
			_progress_table.clear_terminated_job(String(payload["job_id"]), terminal_job, terminal_was_active)
		# Shares _resolve_giver_association() with
		# _toil_on_work_complete()/TrenchSystem._trap_actor()/_cancel_job_for_death()/
		# _resolve_refused_reservations() rather than only ever telling
		# NeedGiver -- a command that cancels/fails/invalidates/completes a
		# rescue job must tell RescueGiver too, or its own _pending/_job_victim
		# association keeps naming a job that is no longer queued or active,
		# and the rescuer can never take ordinary work or another rescue.
		if result["ok"]:
			_resolve_giver_association(String(payload["job_id"]), String(terminal_job.get("kind", "")))
	# F3: a cancel/fail/invalidate_job command above can
	# resolve a need and get a resume refused, entirely outside tick(); drain
	# it now rather than leaving it for the next tick(). Harmless otherwise.
	_resolve_refused_reservations()
	_event_log.collect_queue_events()
	if not result["ok"]:
		return _event_log.rejection(command["command_id"], command["actor"], result["rejection"]["reason"], result["rejection"]["remedy"])
	var applied := _event_log.applied(command)
	applied["job_id"] = result["job_id"]
	return applied

## place_object's complete read-only rule, shared verbatim by
## apply() (via _apply_place_object_command()), preview() and
## CommandChecks.check_place_object_command() (which delegates here rather
## than keeping its own copy) -- mirrors check_construction_command()'s
## shape above. x/y/kind are exactly as strict as the old CommandChecks.
## check_place_object_command(): integer x, y, a non-empty string kind naming
## a declared object kind. orientation is new and optional: when present it
## must be "horizontal" or "vertical" (invalid_payload otherwise); it is
## otherwise unconsulted here, since ObjectTable.object_footprint_size() already ignores
## it for a non-rotatable kind. Every tile of kind's footprint (default [1,1]
## -- every existing kind today) is checked in bounds, no colonist, no
## existing object, and neither TILE_TREE nor TILE_WATER (the strict,
## build-only ConstructionSystem._build_site_terrain_valid() would also reject
## TILE_ROCK/TILE_TRENCH/TILE_HAZARD, breaking test_debug_scenario_
## objects.gd, test_faction_doors.gd, test_tool_items.gd and existing
## test_water_cache_invalidation.gd fixtures that all place objects on rock
## through this exact command -- this remains the permissive debug/map-gen
## path _apply_place_object_command()'s own doc comment always described;
## `build` keeps its own separate, stricter ConstructionSystem._build_site_terrain_valid() call
## untouched) -- so a footprint >1 kind is rejected the instant any one of
## its tiles would have been.
func _check_place_object_command(payload: Dictionary) -> Dictionary:
	if (typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("kind")) != TYPE_STRING or String(payload.get("kind")).is_empty()
			or typeof(payload.get("orientation", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "message": "place_object requires integer x, y, a non-empty string kind and an optional string orientation."}
	var kind: String = payload["kind"]
	if not _object_definitions.has(kind):
		return {"reason": "invalid_payload", "message": "Unknown object kind '%s'." % kind}
	var orientation := String(payload.get("orientation", ""))
	if not orientation.is_empty() and orientation != "horizontal" and orientation != "vertical":
		return {"reason": "invalid_payload", "message": "orientation must be 'horizontal' or 'vertical'."}
	var origin := Vector2i(int(payload["x"]), int(payload["y"]))
	for tile in _object_table.object_footprint_tiles(kind, origin, orientation):
		if (tile.x < 0 or tile.x >= _tile_grid.width or tile.y < 0 or tile.y >= _tile_grid.height
				or _colonist_at(tile.x, tile.y)
				or not get_object(tile.x, tile.y).is_empty()
				or get_tile(tile.x, tile.y) == TILE_TREE
				or get_tile(tile.x, tile.y) == TILE_WATER):
			return {"reason": "invalid_target", "message": "Choose an empty, in-bounds tile with no colonist or tree."}
	return {}

## Comparison-only stand-in for "unreachable" (hands-filling rules):
## _route_cost() itself returns -1; call sites substitute this instead where
## they need a total order against a real cost.
const _UNREACHABLE_ROUTE_COST := 1 << 30

## Deterministic travel cost from `from` to `to` for `faction_id`, reusing the
## same bounded RouteSearch and _routable_to() target-tile exception the
## colonist's own go_to toil actually travels under (_toil_go_to_passable()),
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

func _check_cancel_site_command(payload: Dictionary) -> Dictionary:
	for key in payload.keys():
		if key != "x" and key != "y":
			return {"reason": "invalid_payload", "message": "cancel_site accepts only x and y."}
	if typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT:
		return {"reason": "invalid_payload", "message": "cancel_site requires integer x and y."}
	if _construction.construction_site_id_at(int(payload["x"]), int(payload["y"])).is_empty():
		return {"reason": "invalid_target", "message": "No construction site occupies this tile."}
	return {}

## cancel_job {job_id}: boot.gd's Cancel tool still
## resolves a pending build order by "job_id" (test_order_input.gd; the
## toolbar has not yet been rewired onto the dedicated cancel_site {x,y}
## command). A site has no job at order time
## (ADR 040), so apply_construction_submission() hands its own id back as
## both site_id and job_id; recognising that id here and tearing the site
## down through the exact same cancel_construction_site() cancel_site
## {x,y} uses keeps the two entry points equivalent rather than adding a
## second cancellation path. Any id that does not name a live site is an
## ordinary job id and goes to _apply_job_command() unchanged.
func _apply_cancel_job_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command.get("payload", {})
	var site_id := String(payload.get("job_id", ""))
	if not site_id.is_empty() and _construction.site_table.has(site_id):
		_construction.cancel_construction_site(site_id)
		_event_log.collect_queue_events()
		var applied := _event_log.applied(command)
		applied["site_id"] = site_id
		applied["job_id"] = site_id
		return applied
	return _apply_job_command(command)

func _apply_cancel_site_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check := _check_cancel_site_command(payload)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var site_id := _construction.construction_site_id_at(int(payload["x"]), int(payload["y"]))
	_construction.cancel_construction_site(site_id)
	_event_log.collect_queue_events()
	var applied := _event_log.applied(command)
	applied["site_id"] = site_id
	return applied

## Applies immediately, no job queue involved. Rejected invalid_target for an
## out-of-bounds/occupied/tree/water tile on any footprint tile;
## rejected invalid_payload for an unknown kind or a malformed orientation.
## This is the debug/map-gen placement path only (ADR 039) -- the
## player-facing `build` order flow is ConstructionSystem.apply_construction_submission().
func _apply_place_object_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check := _check_place_object_command(payload)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	_object_table.set_object(int(payload["x"]), int(payload["y"]), String(payload["kind"]), "colony", String(payload.get("orientation", "")))
	return _event_log.applied(command)

## Rejected invalid_target for an out-of-bounds tile or one holding no object.
func _apply_remove_object_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_remove_object_command(self, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	_object_table.set_object(int(payload["x"]), int(payload["y"]), "")
	return _event_log.applied(command)

## Mutates one colonist's labour table (colonist-ai.md 3.2).
func _apply_set_labour_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_set_labour_command(self, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var colonist := _find_colonist(String(payload["colonist"]))
	WorkerType.set_labour_level(colonist, String(payload["kind"]), int(payload["level"]))
	return _event_log.applied(command)

## Debug command (F3): mutates one actor's existing "factionId"
## field, mirroring _apply_set_labour_command()'s validation shape. target is
## looked up against the actor table (_colonists, per ADR 012 -- every
## spawned actor lives there today, not just worker-component colonists), so
## an actor without a worker component is still a valid target. Never
## touches an object's or item's faction_id.
func _apply_set_faction_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_set_faction_command(self, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var actor := _find_colonist(String(payload["target"]))
	actor["factionId"] = String(payload["faction_id"])
	return _event_log.applied(command)

## Proposes incident_id's actors now, bypassing min_day/cooldown/budget gating (tests, the viewer's
## debug buttons); "actor_ids" lists the proposals, each spawned only once its job activates.
func _apply_spawn_incident_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_spawn_incident_command(self, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var applied := _event_log.applied(command)
	applied["actor_ids"] = _incidents.force_spawn(String(payload["id"]), _clock.tick)
	return applied

## Draws a rectangular stockpile zone.
func _apply_zone_add_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_zone_add_command(self, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var zone_id := _zone_table.add(int(payload["x"]), int(payload["y"]), int(payload["width"]), int(payload["height"]))
	var applied := _event_log.applied(command)
	applied["zone_id"] = zone_id
	return applied

## Removes a stockpile zone by id.
func _apply_zone_remove_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_zone_remove_command(self, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var zone_id: String = payload["id"]
	var removed := _zone_table.remove(zone_id)
	_fail_haul_jobs_targeting_removed_zone(int(removed["x"]), int(removed["y"]), int(removed["width"]), int(removed["height"]))
	_event_log.collect_queue_events()
	return _event_log.applied(command)

## Removing a zone mid-walk to one of its cells must fail the haul job that
## reserved that cell with a typed reason and no leaked reservation. Scans
## every active haul job since a zone is rarely removed.
func _fail_haul_jobs_targeting_removed_zone(x: int, y: int, width: int, height: int) -> void:
	for job in _scheduler.queue.get_jobs():
		if String(job["kind"]) != "haul" or job["status"] != "active":
			continue
		var cell = job.get("cell")
		if cell == null:
			continue
		var cx: int = cell.x
		var cy: int = cell.y
		if cx >= x and cx < x + width and cy >= y and cy < y + height:
			_terminate_haul_job_by_id(job["id"], "blocked_destination_gone", "choose_reachable_destination")

func _colonist_at(x: int, y: int) -> bool:
	for colonist in _colonists:
		if int(colonist["x"]) == x and int(colonist["y"]) == y:
			return true
	return false

## The live colonist Dictionary reference for colonist_id (mutating it mutates
## _colonists in place), or {} when unknown.
func _find_colonist(colonist_id: String) -> Dictionary:
	for colonist in _colonists:
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

func _append_colonist(actor: Dictionary) -> void: # IncidentScheduler append/remove callables
	if not actor.has("trapped"): actor["trapped"] = null
	_colonists.append(actor)

## The one path that removes an actor from the roster, called by
## _apply_actor_death() (rule 2, is_death=true) and by
## IncidentScheduler.on_job_finished() (every terminal incident-job
## transition, including one cancelled while combat has it suspended for a
## flee episode; is_death defaults false there, bound with a single String
## arg at _init()). Runs _cleanup_actor_scheduling() first so both callers
## share the same scheduling/CombatGiver teardown.
##
## is_death distinguishes an actual combat death (always
## removed -- a killed actor must leave the roster and its scheduling/
## reservation cleanup regardless of trapped state) from an ordinary
## incident-lifecycle despawn (suppressed for a trapped actor -- a
## wolf whose incident wait job just finished must stay trapped in its
## trench, not vanish, until it escapes or dies).
func _remove_colonist_by_id(colonist_id: String, is_death: bool = false) -> void:
	_cleanup_actor_scheduling(colonist_id)
	for i in _colonists.size():
		if String(_colonists[i]["id"]) == colonist_id:
			if not is_death and _colonists[i].get("trapped") != null: # trapped, not despawned
				return
			_colonists.remove_at(i)
			# A despawned actor gets no further _advance_colonists() pass to release its own in-flight reroute -- release it here instead.
			_reroutes.erase(colonist_id)
			return

func get_events(types: Array = []) -> Array[Dictionary]:
	return _event_log.get_events(types)

## record=false (preview() only) builds every rejection through _event_log.pure_rejection() instead of
## _event_log.rejection(), so an invalid envelope, a malformed payload or a tick mismatch previewed on an
## otherwise-valid actor never appends a command_rejected event or advances the event sequence
## -- apply() always passes record=true (the default), unchanged.
func _validate_command(command, record: bool = true) -> Dictionary:
	if typeof(command) != TYPE_DICTIONARY:
		return _event_log.reject(null, null, "invalid_envelope", "Command must be a Dictionary.", record)
	if not (command.has("actor") and typeof(command["actor"]) == TYPE_STRING and command["actor"] != ""):
		return _event_log.reject(command.get("command_id"), command.get("actor"), "invalid_envelope",
			"Command must include a non-empty string actor.", record)
	if not (command.has("command_id") and typeof(command["command_id"]) == TYPE_STRING and command["command_id"] != ""):
		return _event_log.reject(null, command["actor"], "invalid_envelope",
			"Command must include a non-empty string command_id.", record)
	if not (command.has("tick") and typeof(command["tick"]) == TYPE_INT):
		return _event_log.reject(command["command_id"], command["actor"], "invalid_envelope",
			"Command must include an integer tick.", record)
	if not (command.has("type") and typeof(command["type"]) == TYPE_STRING and command["type"] != ""):
		return _event_log.reject(command["command_id"], command["actor"], "invalid_envelope",
			"Command must include a non-empty string type.", record)
	if not (command.has("payload") and typeof(command["payload"]) == TYPE_DICTIONARY):
		return _event_log.reject(command["command_id"], command["actor"], "invalid_envelope",
			"Command must include a Dictionary payload.", record)
	# build_line's own "tiles" payload field is an Array of {x, y} Dictionaries
	# -- the one deliberate exception to every other command's
	# flat String/int payload shape, scoped by both type and key so no other
	# command gains the exception by accident.
	for key in command["payload"].keys():
		if command["type"] == "build_line" and key == "tiles":
			continue
		var value = command["payload"][key]
		if typeof(value) != TYPE_STRING and typeof(value) != TYPE_INT:
			return _event_log.reject(command["command_id"], command["actor"], "invalid_payload",
				"Payload values must be String or int.", record)
	if command["tick"] != _clock.tick:
		return _event_log.reject(command["command_id"], command["actor"], "tick_mismatch",
			"Command tick %d does not match current tick %d." % [command["tick"], _clock.tick], record)
	return {"ok": true}

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
