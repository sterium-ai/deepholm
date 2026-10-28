class_name TestAccess
extends RefCounted

## The single test-only seam into WorldState's internals (R15). Headless tests read module
## state and build scenarios through these named static functions instead of reaching into
## `world._field` themselves, so a field rename touches this file, not a hundred tests.
## Nothing under game/scripts/core or game/scripts/viewer may call it
## (test_architecture_rules checks this). Every function is one plain read or write; a setup
## write here bypasses validation, events and caches exactly as the direct access it replaced.

const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ToolItemStoreType = preload("res://scripts/core/items/tool_item_store.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const NeedGiverType = preload("res://scripts/core/jobs/givers/need_giver.gd")
const RescueGiverType = preload("res://scripts/core/jobs/givers/rescue_giver.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const IncidentSchedulerType = preload("res://scripts/core/incidents/incident_scheduler.gd")
const CombatGiverType = preload("res://scripts/core/combat/combat_giver.gd")
const ApproachGiverType = preload("res://scripts/core/combat/approach_giver.gd")
const ConstructionSystemType = preload("res://scripts/core/objects/construction_system.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const ZoneTableType = preload("res://scripts/core/objects/zone_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")
const TrenchSystemType = preload("res://scripts/core/actors/trench_system.gd")
const NeedsSystemType = preload("res://scripts/core/actors/needs_system.gd")
const CombatSystemType = preload("res://scripts/core/actors/combat_system.gd")
const TickPipelineType = preload("res://scripts/core/world/tick_pipeline.gd")
const ActorIndexType = preload("res://scripts/core/actors/actor_index.gd")
const JobEventLogType = preload("res://scripts/core/jobs/job_event_log.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const JobHistoryType = preload("res://scripts/core/jobs/job_history.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SchedulingCodecType = preload("res://scripts/core/persistence/scheduling_codec.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")

# --- Map ---------------------------------------------------------------------------------

## Writes one tile kind straight into the grid (no dirty mark, no cache invalidation).
static func set_tile(w: WorldState, x: int, y: int, kind: String) -> void:
	w._tile_grid.tiles[w._tile_grid.tile_index(x, y)] = kind

static func tile_at(w: WorldState, x: int, y: int) -> String:
	return w._tile_grid.tiles[w._tile_grid.tile_index(x, y)]

static func tile_grid(w: WorldState) -> TileGridType: return w._tile_grid
static func passability(w: WorldState) -> PassabilityType: return w._passability
static func object_table(w: WorldState) -> ObjectTableType: return w._object_table
static func zone_table(w: WorldState) -> ZoneTableType: return w._zone_table
static func construction(w: WorldState) -> ConstructionSystemType: return w._construction
static func area_orders(w: WorldState) -> AreaOrders: return w._area_orders
static func tile_key(w: WorldState, x: int, y: int) -> String: return w._tile_key(x, y)
static func cell_key(w: WorldState, x: int, y: int) -> String: return w._cell_key(x, y)
static func is_cell_occupied(w: WorldState, x: int, y: int, excluding_colonist_id: String) -> bool:
	return w._is_cell_occupied(x, y, excluding_colonist_id)

# --- Actors ------------------------------------------------------------------------------

## The live roster; appending to it skips the actor index, unlike append_colonist().
static func colonists(w: WorldState) -> Array[Dictionary]: return w._colonists
static func set_colonists(w: WorldState, value: Array[Dictionary]) -> void: w._colonists = value
static func find_colonist(w: WorldState, colonist_id: String) -> Dictionary: return w._find_colonist(colonist_id)
static func colonist_at(w: WorldState, x: int, y: int) -> bool: return w._colonist_at(x, y)
static func append_colonist(w: WorldState, actor: Dictionary) -> void: w._append_colonist(actor)
static func remove_colonist_by_id(w: WorldState, colonist_id: String, is_death: bool = false) -> void:
	w._remove_colonist_by_id(colonist_id, is_death)
static func actor_index(w: WorldState) -> ActorIndexType: return w._actor_index
static func default_labour_table(w: WorldState) -> Dictionary: return w._default_labour_table()
static func needs_system(w: WorldState) -> NeedsSystemType: return w._needs_system
static func need_definitions(w: WorldState) -> Dictionary: return w._need_definitions
static func need_full(w: WorldState) -> int: return w._need_full
static func combat_system(w: WorldState) -> CombatSystemType: return w._combat_system
static func trench(w: WorldState) -> TrenchSystemType: return w._trench
static func reroutes(w: WorldState) -> Dictionary: return w._reroutes
static func route_budget(w: WorldState) -> Dictionary: return w._route_budget

# --- Items and content -------------------------------------------------------------------

static func item_table(w: WorldState) -> ItemTableType: return w._item_table
static func item_ids_at_trusted(w: WorldState) -> bool: return w._item_table._ids_at_trusted
static func tool_store(w: WorldState) -> ToolItemStoreType: return w._tool_store
static func content(w: WorldState) -> ContentRegistryType: return w._content
static func object_definitions(w: WorldState) -> Dictionary: return w._object_definitions
static func work_ticks(w: WorldState) -> Dictionary: return w._work_ticks

# --- Jobs and scheduling -----------------------------------------------------------------

static func scheduler(w: WorldState) -> AssignmentType: return w._scheduler
static func get_job(w: WorldState, job_id: String) -> Dictionary: return w._get_job(job_id)
static func job_restricted_to(w: WorldState, job_id: String) -> String: return w._job_restricted_to(job_id)
static func queue_jobs(w: WorldState) -> Array[Dictionary]: return w._scheduler.queue._jobs
static func queue_events(w: WorldState) -> JobEventLogType: return w._scheduler.queue._events
static func queue_history(w: WorldState) -> JobHistoryType: return w._scheduler.queue._history
static func queue_haul_retry_base_ticks(w: WorldState) -> int: return w._scheduler.queue._haul_retry_base_ticks
static func queue_haul_retry_cap_ticks(w: WorldState) -> int: return w._scheduler.queue._haul_retry_cap_ticks
static func scheduler_find_waiting_entry(w: WorldState, job_id: String) -> Dictionary:
	return w._scheduler._find_waiting_entry(job_id)
static func toils(w: WorldState) -> ToilExecutorType: return w._toils
static func progress_table(w: WorldState) -> WorkProgressType: return w._progress_table
static func set_work_progress(w: WorldState, target: Vector2i, ticks_remaining: int, job_id: String = "") -> void:
	w._set_work_progress(target, ticks_remaining, job_id)
static func resolve_refused_reservations(w: WorldState) -> void: w._resolve_refused_reservations()
static func resubmit_unreachable_job(w: WorldState, job_id: String, job: Dictionary) -> void:
	w._resubmit_unreachable_job(job_id, job)
static func flee_target_reserved(w: WorldState, x: int, y: int) -> bool: return w._flee_target_reserved(x, y)
static func tick_pipeline(w: WorldState) -> TickPipelineType: return w._tick_pipeline
static func colonists_not_searching_need(w: WorldState) -> Array[Dictionary]:
	return w._tick_pipeline._colonists_not_searching_need()

# --- Job givers --------------------------------------------------------------------------

static func need_giver(w: WorldState) -> NeedGiverType: return w._need_giver
static func need_giver_pending(w: WorldState) -> Dictionary: return w._need_giver._pending
static func need_giver_searching(w: WorldState) -> Dictionary: return w._need_giver._searching
static func need_giver_bounds_max(w: WorldState) -> Vector2i: return w._need_giver._bounds_max
static func rescue_giver(w: WorldState) -> RescueGiverType: return w._rescue_giver
static func rescue_giver_searching(w: WorldState) -> Dictionary: return w._rescue_giver._searching
static func rescue_giver_job_victim(w: WorldState) -> Dictionary: return w._rescue_giver._job_victim
static func combat_giver(w: WorldState) -> CombatGiverType: return w._combat_giver
static func combat_giver_episodes(w: WorldState) -> Dictionary: return w._combat_giver._episodes
static func combat_giver_fleeing(w: WorldState) -> Dictionary: return w._combat_giver._fleeing
static func approach_giver(w: WorldState) -> ApproachGiverType: return w._approach_giver

# --- Incidents, calendar, clock, events --------------------------------------------------

static func incidents(w: WorldState) -> IncidentSchedulerType: return w._incidents
static func submit_incident_job(w: WorldState, actor_id: String, target: Vector2i) -> String:
	return w._submit_incident_job(actor_id, target)
static func incident_random(w: WorldState) -> RandomNumberGenerator: return w._incidents._random
static func incident_last_processed_day(w: WorldState) -> int: return w._incidents._last_processed_day
static func set_incident_last_processed_day(w: WorldState, day: int) -> void: w._incidents._last_processed_day = day
static func incident_cooldown_until_day(w: WorldState) -> Dictionary: return w._incidents._cooldown_until_day
static func set_incident_cooldown_until_day(w: WorldState, value: Dictionary) -> void:
	w._incidents._cooldown_until_day = value
static func incident_staged(w: WorldState) -> Dictionary: return w._incidents._staged
static func incident_map_width(w: WorldState) -> int: return w._incidents._map_width
static func incident_map_height(w: WorldState) -> int: return w._incidents._map_height
static func incident_actor_by_job(w: WorldState) -> Dictionary: return w._incidents._actor_by_job
static func incident_spawn(w: WorldState, entry: Dictionary, day: int, tick: int) -> Array:
	return w._incidents._spawn(entry, day, tick)
static func calendar(w: WorldState) -> CalendarServiceType: return w._calendar
static func set_calendar(w: WorldState, value: CalendarServiceType) -> void: w._calendar = value
static func clock(w: WorldState) -> SeededClock: return w._clock
static func random(w: WorldState) -> RandomNumberGenerator: return w._random
static func event_log(w: WorldState) -> EventLogType: return w._event_log
static func event_log_events(w: WorldState) -> Array[Dictionary]: return w._event_log._events
static func event_log_sequence(w: WorldState) -> int: return w._event_log._event_sequence

# --- Modules exercised on their own, without a WorldState --------------------------------

static func assignment_pending(s: AssignmentType) -> Dictionary: return s._pending
static func queue_emit(q: JobQueueType, event_type: String, job_id: String, data: Dictionary) -> void:
	q._emit(event_type, job_id, data)
## The queue's live (queued/active) list itself, not get_jobs()'s copy.
static func queue_live_jobs(q: JobQueueType) -> Array[Dictionary]: return q._jobs
static func scheduling_encode_jobs(jobs: Array[Dictionary]) -> Array: return SchedulingCodecType._encode_jobs(jobs)
static func save_validate_state(state: Dictionary) -> Dictionary: return SaveIOType._validate_state(state)
static func save_sha256(bytes: PackedByteArray) -> String: return SaveIOType._sha256(bytes)
static func generator_scatter_rock_outcrops(rng: RandomNumberGenerator, map: Array[String], width: int, height: int,
		mapgen: Dictionary, scale: float) -> void:
	WorldGeneratorType._scatter_rock_outcrops(rng, map, width, height, mapgen, scale)
static func generator_count_reachable_food_sources(map: Array[String], width: int, height: int,
		footprint: Array[Vector2i], bush_lookup: Dictionary, limit: int) -> int:
	return WorldGeneratorType._count_reachable_food_sources(map, width, height, footprint, bush_lookup, limit)
