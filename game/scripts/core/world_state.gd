class_name WorldState
extends RefCounted

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ToolHandoverType = preload("res://scripts/core/jobs/tool_handover.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")
const ToolItemStoreType = preload("res://scripts/core/jobs/tool_item_store.gd")
const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const NeedGiverType = preload("res://scripts/core/jobs/givers/need_giver.gd")
const RescueGiverType = preload("res://scripts/core/jobs/givers/rescue_giver.gd")
const HaulGiverType = preload("res://scripts/core/jobs/givers/haul_giver.gd")
const CalendarAlertGiverType = preload("res://scripts/core/jobs/givers/calendar_alert_giver.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const NeedsType = preload("res://scripts/core/actors/components/needs.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const RegionMapType = preload("res://scripts/core/map/regions.gd")
const RoomMapType = preload("res://scripts/core/map/rooms.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const IncidentSchedulerType = preload("res://scripts/core/incidents/incident_scheduler.gd")
const CombatType = preload("res://scripts/core/actors/components/combat.gd")
const RelationsType = preload("res://scripts/core/relations/relations.gd")
const CombatResolverType = preload("res://scripts/core/combat/combat_resolver.gd")
const CombatGiverType = preload("res://scripts/core/combat/combat_giver.gd")
const ApproachGiverType = preload("res://scripts/core/combat/approach_giver.gd")
const ConstructionSiteTableType = preload("res://scripts/core/objects/construction_site.gd")
const ConstructionGiverType = preload("res://scripts/core/jobs/givers/construction_giver.gd")

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
const DEFAULT_TRENCH_CLIMB_TICKS := 40 ## content/actors.json tunables.wild.trench_climb_ticks default
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

const REASON_NEED_UNMET_PREFIX := "need_unmet:"
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
## This world's actual dimensions: resolved once in _init() from the
## constructor's width/height arguments (clamped by
## WorldGeneratorType.resolve_size()), or overwritten by StateCodec.decode()
## with a loaded save's own exact map.width/map.height. Never mutated again
## afterward -- loading a different save replaces the whole WorldState.
var _width: int = MAP_WIDTH
var _height: int = MAP_HEIGHT
## The algorithm that actually produced _tiles: the running build's constant
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
## ADR 026 (docs/decisions/026-trench-trapped-actor-and-rescue.md): dig's own
## find_table stream, salted off the world seed like incident_scheduler.gd's
## _random so it never perturbs or is perturbed by _random's own sequence.
## Reseeded fresh by _init() on every construction, including
## StateCodec.decode()'s own WorldState.new() call; state_codec.gd then
## overwrites this fresh value with the save's own persisted continuation,
## the same way it already restores _random/_incidents._random,
## so a dig's find sequence keeps going from where the saved run left off
## instead of restarting -- see state_hash()'s own "dig_find_rng" entry, which
## is why this stream's continuation is part of the diagnostic hash too.
var _dig_find_random: RandomNumberGenerator
var _tiles: Array[String] = []
## Generation-time scratch: _generate_map() stashes WorldGenerator's river/berry-bush
## output so _spawn_colonists() (the next _init() call) can turn bushes into _objects and
## bias its clearing search toward the river. Emptied there; never read after, never persisted.
var _pending_water_tiles: Array[Vector2i] = []
var _pending_berry_bush_tiles: Array[Vector2i] = []
## The starting clearing WorldGenerator.place_spawn() chose: {x, y, width, height,
## water_steps, food_steps, tree_steps, fallback}. Read by debug_scenario.gd/boot.gd to place
## content relative to the real spawn and by the seed-suite tests asserting no fallback.
## Empty ({}) on a StateCodec.decode()d world, which never calls _spawn_colonists().
var _spawn_clearing: Dictionary = {}
var _colonists: Array[Dictionary] = []
var _items: Dictionary = {}
var _next_item_id: int = 1
## ADR 026: dig completions staged this tick by _toil_on_work_complete(),
## drained by _resolve_dig_finds() (called once from tick(), right after
## _advance_colonists()) in ascending job-id order so the find roll sequence
## never depends on _advance_colonists()'s own colonist-id iteration order.
## Always empty between tick() calls; not persisted.
var _pending_dig_finds: Array[Dictionary] = []
## Identity-bearing tool items (axe/pick) and their reservations; see tool_item_store.gd.
var _tool_store: ToolItemStoreType
var _item_definitions: Dictionary = {}
## Ground berries left by a completed forage job, keyed like _objects ("%d_%d").
var _ground_berries: Dictionary = {}
var _objects: Dictionary = {}
## faction_id (F3) per placed object/ground-berries cell/item id,
## keyed like _objects/_ground_berries/_items respectively. Parallel maps, not
## a nested value inside _objects/_ground_berries/_items: state_codec.gd's
## _encode_objects()/_encode_items() each assume a fixed value shape (a plain
## kind String for _objects, an exact {id,x,y,kind,count} for _items) that a
## faction_id key would either crash (String(Dictionary) has no constructor)
## or silently drop on the next save/load round trip -- either way diverging
## state_hash() before vs. after a save/load that changed nothing else, so
## these maps are deliberately left out of state_hash()'s own snapshot too
## (persisting faction_id is future work).
var _object_factions: Dictionary = {}
var _ground_berries_factions: Dictionary = {}
var _item_factions: Dictionary = {}
## Per-instance {"hp","maxHp"} for a placed object whose kind
## declares "max_health" (content/objects.json), keyed like _objects/
## _object_factions. A parallel map, not a nested value inside _objects (the
## same reason _object_factions is one, per its own comment above). Unlike
## _object_factions, this is included in state_hash()'s own snapshot (a
## wall's accumulated damage changes future combat outcomes, so two saves
## that otherwise match but differ in a wall's remaining hp must not hash
## equal) and is persisted by state_codec.gd's _encode_objects()/
## _decode_objects() as each entry's optional "health" field.
var _object_health: Dictionary = {}
## For a footprint tile other than a placed object's own origin
## tile, the origin's Vector2i -- lets _set_object() find and clear every
## footprint tile of a multi-tile object from any one of them (e.g. a
## remove_object command aimed at the object's second tile). Absent for a
## footprint [1,1] object (every existing kind today) and for an origin tile
## itself, both of which are their own origin by definition -- mirroring
## _object_factions/_object_origin's own "absent means the default" idiom.
## Not persisted or hashed: state_codec.gd re-derives it from the persisted
## origin record on decode() (_object_footprint_tiles()), the same way
## _object_health is rebuilt from content on a save that predates it.
var _object_origin: Dictionary = {}
## origin_key -> "horizontal"/"vertical" for a placed object whose
## kind declares rotatable true and was placed with a non-default orientation;
## absent (never "") means no rotation, matching game-state.schema.json's
## optional "orientation" field. Keyed by origin tile only, like
## _object_health, not duplicated to every footprint tile.
var _object_orientation: Dictionary = {}
## The single content bundle loader (F1), schema-validated and
## cross-reference-checked at construction.
var _content: ContentRegistryType
var _object_definitions: Dictionary = {}
var _need_definitions: Dictionary = {}
var _tile_definitions: Dictionary = {}
var _work_ticks: Dictionary = {} # see _load_work_ticks()
var _need_full: int = 0 # see _load_need_config()
var _mapgen: Dictionary = {}
var _zones: Dictionary = {}
var _next_zone_id: int = 1
## trader_id -> {"give_item", "want_item"}: a trader's own
## trade_offer, posted partway through its generic incident wait (see
## _maybe_post_trade_offer()). Not persisted, like IncidentScheduler's own
## _staged/_actor_by_job: an offer in flight across a save/load is
## simply lost, and the trader still leaves on schedule either way.
var _pending_trade_offers: Dictionary = {}
## F5 "Regions": connected-walkable partition, updated incrementally by the
## on_passability_changed() call sites below. Built lazily in _get_regions(),
## not _init(), so a save/load's direct _tiles/_objects overwrite (state_codec.gd)
## never leaves it stale.
var _regions: RegionMapType
## F5 "Rooms": lazily built alongside _regions, same reason.
var _rooms: RoomMapType
## Lazily built list of every TILE_WATER cell, same reasoning as _regions:
## built on first use so a save/load's direct _tiles overwrite is never
## stale. Kept in sync afterwards by _update_water_tile_cache() whenever a
## tile's water membership changes.
var _water_tile_cache: Array[Vector2i] = []
var _water_tile_cache_built := false
## Append-only log of every cell whose tile kind or object changed, never
## cleared -- see get_dirty_cells()' own doc comment for why this is a log,
## not a clear-on-read set. Lets a presentation layer with a large map update
## only the affected cells instead of rebuilding the whole map every tick.
## Colonist/item movement never appends here -- those are read fresh every
## frame by their own presentation layers, never cached against this log.
var _dirty_cells: Array[Vector2i] = []
var _scheduler: AssignmentType
var _toils: ToilExecutorType
## Callables ToilExecutor.advance() cannot resolve itself, keyed by hook name.
var _toil_hooks: Dictionary = {}
var _queue_event_sequence: int = -1
var _events: Array[Dictionary] = []
## Live in-flight re-route searches, keyed by colonist id, shared by
## reference with _toils.
var _reroutes: Dictionary = {}

## colonist_id -> the scheduler job_id a critical need paused mid-`work`.
var _paused_jobs: Dictionary = {}
## "%d_%d" -> ticks remaining on a `work` toil's timer, so pausing never loses progress.
var _work_progress: Dictionary = {}
## "%d_%d" -> the job_id that last wrote _work_progress at that key. A job
## suspended mid-work (status reverts to "queued", _pause_work_job()) still
## owns its stored progress until it resumes or is terminated, so job
## "status" alone cannot distinguish that from an abandoned key. Persisted as
## "workProgressOwners": a second job (e.g. a dig) can legitimately be queued
## targeting a tile a build already owns mid-haul -- the submission-time
## duplicate-target rejection only guards a single job kind's own target --
## so guessing the owner on load from "whichever job targets this tile"
## could hand a build's progress to that unrelated dig, or vice versa.
## StateCodec.decode() restores the exact persisted job_id instead (see
## _restore_work_progress_owners() below); a save taken before this field
## existed restores with no owners at all rather than guess one.
var _work_progress_owner: Dictionary = {}
## job_id -> ticks remaining on a `work` toil's timer, for a job suspended
## (status "queued", not terminated) while its own work-progress tile is
## still keyed live to it -- moved here at the moment colonist.work is
## cleared for any non-terminal reason (JobQueue's own
## activation/reactivation lifecycle can hand a suspended job's released
## site/tile to a different job's own `work` toil, which would otherwise
## read/overwrite the same "%d_%d" slot in _work_progress -- inheriting the
## suspended job's stale ticks on start, then clobbering them tick by tick,
## then erasing them at its own completion). _resume_work_progress() below is
## the only reader (consumes the entry back into _work_progress on resume);
## _release_owned_work_progress() is the only place that drops an entry whose
## job terminates while still suspended. Persisted as "suspendedWorkProgress".
var _suspended_work_progress: Dictionary = {}
## job kind -> its needs_tool item kind, from content/jobs.json.
var _needs_tool_by_kind: Dictionary = {}
## job kind -> {"kind","retry_base_ticks","retry_cap_ticks"} for JobQueue's
## own tool-availability activation gate.
var _tool_requirements_by_kind: Dictionary = {}
## colonist_id -> true once its per-tick routing allowance is spent,
## shared by reference with ToilExecutor/GlobalAssignment.
var _route_budget: Dictionary = {}
## colonist_id -> last exposed need reason ("" when none, colonist-ai.md 3.8).
var _need_status: Dictionary = {}
## Decides when eat_food/drink_water/sleep jobs exist.
var _need_giver: NeedGiverType
## Decides when a rescue job exists for a trapped colonist.
var _rescue_giver: RescueGiverType
## colonist_id -> last exposed rescue reason ("" when none, colonist-ai.md 3.8), get_colonist_rescue_reason()'s backing store.
var _rescue_status: Dictionary = {}
## Decides when a haul job exists and where it delivers to.
var _haul_giver: HaulGiverType
## The "calendar boost" term in the effective-priority formula (ADR 008).
var _calendar: CalendarServiceType
var _calendar_alert_giver: CalendarAlertGiverType
var _calendar_alerts_fired: Dictionary = {}
var _event_sequence: int = 0
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
## fresh every tick by _apply_combat(), mirroring _need_status.
var _combat_status: Dictionary = {}
## Decides when an `approach` job should exist for a hostile actor not yet
## adjacent to a hostile target (ADR 033).
var _approach_giver: ApproachGiverType
## The advancing colonist's tile at the start of its _toils.advance() call:
## scratch for _toil_on_work_complete()'s trap pre-check. Never saved.
var _trap_tile_before: Vector2i = Vector2i.ZERO
## job_id -> true, once a site_fetch job's own item_id/target has ever been
## retargeted away from GlobalAssignment's own precomputed assignment_path
## destination -- either by _resolve_freshly_activated_site_fetch_sources()'s
## own seed-swap or by an ordinary on-demand hop (_toil_on_pick_up_success()),
## both part of the hands-filling rules. Consulted by
## _toil_go_to_skip_assignment_path(): once true, assignment_path is
## permanently stale for the rest of this job's life (it only ever led to the
## submission-time seed's own tile, never any later hop's), so every further
## leg -- not only the tick of the retarget itself -- must run a fresh bounded
## search instead of blindly walking that now-irrelevant precomputed path.
## Erased on job termination (_finish_job()) so this never grows unbounded;
## never saved (a reloaded job's own item_id already reflects its real current
## source, and _toil_is_first_leg()'s "cell == null" already tells a resumed
## job it is still fetching -- this dict only decides which go_to mechanism to
## use, never job behaviour).
var _site_fetch_source_retargeted: Dictionary = {}
## job_id -> the item kind _toil_pick_up_count_for() resolved right before
## this job's most recent pick_up toil: a source
## item whose entire remaining count a pick_up exactly exhausts is removed
## from _items by that same pick_up (ToilExecutor.pick_up()'s own
## _remove_item call), so _toil_on_pick_up_success() -- which fires
## immediately afterward -- can no longer resolve the picked kind by looking
## job["item_id"] back up in _items; it would silently read "" instead and
## mistake "the site needs 0 more of nothing" for "hands already cover the
## site's own need," delivering a partial load after a single hop even when
## further eligible sources sit right next to the one just visited (test_
## multi_source_crate: a 1-unit-stack wood source several tiles from two more
## unvisited wood units and the site itself). Cached here -- the same
## "erased on job termination, never saved" discipline _site_fetch_source_
## retargeted's own doc comment establishes, since a resumed job's own
## "cell == null" already tells it whether it is still fetching -- and read
## by _toil_on_pick_up_success(); overwritten on every further hop the same
## way job["item_id"] itself is (retarget_site_fetch_source()).
var _site_fetch_picked_kind: Dictionary = {}
## One record per active construction site (ADR 040):
## replaces the single-worker `build` job's own submission-time item
## resolution. WorldState is the only mutator; ConstructionGiver decides when
## a site's next fetch/work job should exist, through the same job_queue.gd
## entry point any order-driven job uses.
var _sites := ConstructionSiteTableType.new()
var _construction_giver: ConstructionGiverType

## incidents_enabled defaults false so every pre-existing caller keeps ticking byte-identically.
func _init(p_seed: int = 1337, tick_rate: int = 10, p_width: int = MAP_WIDTH, p_height: int = MAP_HEIGHT, incidents_enabled: bool = false) -> void:
	_seed = p_seed
	_clock = SeededClockType.new(tick_rate)
	_random = RandomNumberGenerator.new()
	_random.seed = p_seed
	_dig_find_random = RandomNumberGenerator.new()
	_dig_find_random.seed = p_seed + DIG_FIND_SEED_SALT
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
	_width = resolved_size.x
	_height = resolved_size.y
	_need_full = int(_load_need_config()["full"]); NEED_FULL = _need_full # _spawn_colonists() below needs this via _full_needs()
	_tiles = _generate_map()
	_colonists = _spawn_colonists(_tiles)
	_ensure_combat()
	_tool_store = ToolItemStoreType.new(_find_colonist)
	_scheduler = AssignmentType.new(_random, _content)
	# F3: wires GlobalAssignment's two faction gates through this
	# WorldState's own colonist/registry lookups, never a hardcoded "colony"
	# string -- see _colonist_may_be_ordered()/_colonist_may_reserve_colony_items().
	_scheduler.set_order_eligibility(_colonist_may_be_ordered)
	_scheduler.set_reservation_gate(_colonist_may_reserve_colony_items)
	# F5 (ADR 014 Amendment): an autonomous (incident) entry's own
	# target-aware reservation gate and faction-aware route passability.
	_scheduler.set_autonomous_reservation_gate(_actor_may_reserve_target)
	_scheduler.set_autonomous_passability(_passable_for_worker)
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
		_job_restricted_to, _interrupt_current_job, _resume_interrupted_job, _passable_for_flee,
		_actor_may_reserve_target, _region_reachable, Vector2i(_width - 1, _height - 1), _content, _relations,
		_flee_target_reserved, _cancel_autonomous_job)
	_calendar = CalendarServiceType.new("", _content.document("calendar"))
	_work_ticks = _load_work_ticks()
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
		_content, _item_lookup, _remove_ground_item_units, _place_new_ground_item, _is_cell_occupied, _consume_source_valid,
		_resume_work_progress, _set_work_progress, _clear_work_progress, _reroutes, _route_search_factory,
		get_tool_items, get_tool_item, get_tool_item_reservation, reserve_tool_item, release_tool_item_reservation,
		set_tool_item_held, set_tool_item_ground, get_colonists, _route_budget,
		get_zones, is_cell_free, set_tool_item_stockpile, _tool_store.release_all, get_tool_reservation_table,
		_scheduler.queue.set_active_item_marker, _scheduler.queue.get_active_item_marker, _find_colonist, get_assignments,
		_work_target_for, _construction_site_exists, _construction_site_deposit)
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
	_haul_giver = HaulGiverType.new(int(haul_definition["priority"]), get_jobs, get_items, _is_in_any_zone, _scheduler.submit,
		_scheduler.queue.attach_item, get_zones, is_cell_free, passability, _is_cell_occupied)
	_scheduler.queue.set_haul_destination_finder(_haul_giver.find_free_haul_cell)
	_construction_giver = ConstructionGiverType.new(_sites.list, get_jobs, get_items, _is_in_any_zone,
		_construction_item_reservation_owner, _submit_site_fetch, _submit_site_work, _sites.materials_met, _sites.remaining)
	# Live _tiles by reference: the giver only scans it per tick, and get_tiles() would copy 65536 Strings.
	_calendar_alert_giver = CalendarAlertGiverType.new(get_colonists, func() -> Array[String]: return _tiles, _has_item_of_kind, _insert_event, _next_sequence, PRIORITY_TICK)
	_build_dimension_services(incidents_enabled)

## Builds NeedGiver and IncidentScheduler from this WorldState's current
## _width/_height: factored out of _init() so
## StateCodec.decode() can call it again after overwriting the constructor's
## resolve_size()-clamped _width/_height with a saved map's own exact
## dimensions. Without a rebuild, a saved map smaller than
## WorldGenerator's 16-tile new-game minimum (e.g. 8x8) left NeedGiver's
## source-candidate bounds and IncidentScheduler's edge-spawn bounds pointing
## at the constructor's clamped 16x16 box -- a trader incident would search
## for its east edge at x=15 on a map only 8 tiles wide and never spawn.
## _seed (not the constructor's p_seed parameter) so a call from decode()
## after StateCodec has already overwritten it still salts IncidentScheduler's
## own RNG with the saved world's real seed.
func _build_dimension_services(incidents_enabled: bool) -> void:
	var bounds_max := Vector2i(_width - 1, _height - 1)
	var need_config := _load_need_config()
	_need_giver = NeedGiverType.new(_need_definitions, _need_full, int(need_config["retry_base_ticks"]), int(need_config["retry_cap_ticks"]),
		int(need_config["job_priority"]), bounds_max, _scheduler.queue.get_reservation_table(), _need_job_targets,
		_need_source_candidates, _tile_key, _routable_to, _scheduler.submit, _set_need_reason,
		_emit_need_unmet_event, _interrupt_current_job, _resume_interrupted_job, _content)
	_rescue_giver = RescueGiverType.new(RESCUE_JOB_PRIORITY, bounds_max, _scheduler.queue.get_reservation_table(),
		_tile_key, _routable_to, _rescue_target_candidates, _scheduler.submit, _set_rescue_reason,
		_interrupt_current_job, _resume_interrupted_job, _is_trench_tile, _route_budget, _get_job, _retire_rescue_job)
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
		_job_restricted_to, _passable_for_flee, _actor_may_reserve_target, _region_reachable,
		_flee_target_reserved, _routable_to, bounds_max, _content, _relations, _route_budget,
		_combat_giver.owns, get_objects, get_object, _object_health_at, get_object_faction_id,
		_cancel_autonomous_job)
	_incidents = IncidentSchedulerType.new(_seed, _content, _append_colonist, _remove_colonist_by_id,
		_width, _height, _passable_for_faction, _is_bare_tile, _get_regions, _submit_incident_job,
		_get_job, _finish_job.bind("cancel_job"), _set_work_progress,
		_calendar.day_of_tick, _insert_event, _next_sequence, PRIORITY_TICK, incidents_enabled)

## Read-only dry run of apply()'s own rules: validates the envelope, then runs the
## exact same pre-mutation check apply()'s own handler consults (CommandChecksType.check(), see
## game/scripts/core/commands/command_checks.gd) without touching state, so a hover/drag
## preview or Play-mode cursor can ask "would apply() accept this?" per tile without
## StateCodec.encode()/decode()'s whole-world round trip. Never mutates _tiles, _colonists,
## _jobs, _events or any other field -- state_hash() is unchanged before and after a call, and
## unlike apply() a rejected preview() never appends a command_rejected event or advances
## _event_sequence: _validate_command(command, false) and
## _pure_rejection() below build the same rejection Dictionary apply() would return without
## either side effect.
func preview(command) -> Dictionary:
	var validation := _validate_command(command, false)
	if not validation["ok"]:
		return validation
	# build keeps its read-only rules in _check_construction_command()
	# below -- the exact same function _apply_construction_submission() runs --
	# so a hover preview and apply() always agree; cancel_site mirrors it via
	# _check_cancel_site_command(). place_object calls _check_place_object_command()
	# directly for the same reason; CommandChecks.check_place_object_command()
	# delegates to this same function, so either path runs
	# identical, current rules.
	if command["type"] == "build_line":
		var classification := _classify_build_line_command(command["payload"])
		if classification.has("reason"):
			return _pure_rejection(command["command_id"], command["actor"], classification["reason"], classification["message"])
		return {"ok": true, "skipped": classification["skipped"]}
	var check: Dictionary
	if command["type"] == "build":
		check = _check_construction_command(command["payload"])
	elif command["type"] == "cancel_site":
		check = _check_cancel_site_command(command["payload"])
	elif command["type"] == "place_object":
		check = _check_place_object_command(command["payload"])
	else:
		check = CommandChecks.check(self, command)
	if not check.is_empty():
		return _pure_rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	return {"ok": true}

## Only mutator alongside tick(): validates and applies a command envelope.
func apply(command) -> Dictionary:
	var validation := _validate_command(command)
	if not validation["ok"]:
		return validation
	match command["type"]:
		"noop":
			return _apply_noop(command)
		"dig", "chop", "forage", "till", "sow", "mine", "complete_job", "fail_job", "invalidate_job":
			return _apply_job_command(command)
		"cancel_job":
			return _apply_cancel_job_command(command)
		"build":
			return _apply_construction_submission(command)
		"build_line":
			return _apply_build_line_command(command)
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
			return _apply_accept_trade_command(command)
		"zone_add":
			return _apply_zone_add_command(command)
		"zone_remove":
			return _apply_zone_remove_command(command)
		_:
			return _rejection(
				command["command_id"], command["actor"], "unknown_command_type",
				"No handler for command type '%s'." % command["type"]
			)

## Only mutator alongside apply(): advances exactly one tick.
func tick() -> void:
	_clock.advance(1)
	_decay_needs()
	_need_giver.advance(_colonists_not_combat_owned(), _clock.tick)
	_haul_giver.advance(_clock.tick)
	_construction_giver.advance(_clock.tick)
	_apply_combat(_clock.tick)
	var active_site_fetch_jobs_before := _active_site_fetch_job_ids()
	_scheduler.tick(_clock.tick, _scheduler_workers(), _is_passable, Vector2i.ZERO,
		Vector2i(_width - 1, _height - 1), _toils.get_labour, _calendar.active_boost, _colonists,
		_committed_jobs(), _get_regions().reachable)
	# Hands-filling rules: a site_fetch job's own submission-time seed
	# is a position-agnostic placeholder (no colonist is chosen yet at
	# submission); the instant one really (re)activates with a colonist
	# known, swap it for the true nearest-to-builder source before
	# _advance_colonists() ever drives it -- see
	# _resolve_freshly_activated_site_fetch_sources() below.
	_resolve_freshly_activated_site_fetch_sources(active_site_fetch_jobs_before)
	# RescueGiver's own route searches
	# share _route_budget (the per-colonist, per-tick ledger ADR 004 bounds)
	# with the scheduler's activation searches above and the toil executor's
	# re-routes below, so it runs between them -- after tick() clears that
	# ledger, before _advance_colonists() honours it. Its commitments reach
	# the scheduler's committed-proposal path next tick (rescue_giver.gd).
	_rescue_giver.advance(_rescue_candidates(), _trapped_rescue_victims(), _clock.tick)
	# F5: staged incident actors whose job just activated enter the world now,
	# before _advance_colonists() drives their first toil (ADR 014 Amendment).
	_incidents.activate_pending()
	# Same activation-gated timing as the incident line above (ADR 026).
	_activate_pending_escapes()
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
	_resolve_dig_finds()
	# F3: drained after _advance_colonists() -- a need
	# resolving there can itself trigger a second refusal via
	# resume_interrupted_job(), which must drain too before this returns.
	_resolve_refused_reservations()
	_collect_queue_events()
	_calendar_alert_giver.advance(_clock.tick, _calendar, _calendar_alerts_fired)
	_incidents.advance(_clock.tick)
	_insert_event({
		"type": "tick_advanced",
		"tick": _clock.tick,
		"system_priority": PRIORITY_TICK,
		"entity_id": "world",
		"sequence": _next_sequence(),
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
## shared _paused_jobs entry CombatGiver owns until the episode closes.
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

## rescue_giver.gd's own candidate pool: every colonist ("worker"
## component actor, never a wolf/trader) eligible to be proposed a rescue job
## this tick. Excludes a trapped colonist (obviously cannot rescue anyone),
## one mid need-search or already committed to a need job (rescue must never
## pre-empt a colonist's own need, colonist-ai.md 3.1/3.6), and one
## CombatGiver owns (an open flee episode) -- the same exclusions
## _colonists_not_combat_owned()/_colonists_not_searching_need() already apply
## for the analogous need-giver roster, reused here rather than a bespoke
## filter. A colonist already committed to (or mid-search for) a different
## rescue is not excluded here: rescue_giver.gd's own `_pending` map already
## refuses to pick a rescuer twice (see its _start_search()).
func _rescue_candidates() -> Array[Dictionary]:
	var searching := _need_giver.searching_colonist_ids()
	var need_committed: Dictionary = _need_giver.get_pending_assignments()
	var filtered: Array[Dictionary] = []
	for colonist in _colonists:
		var colonist_id: String = String(colonist["id"])
		if colonist.get("trapped") != null: continue
		if searching.has(colonist_id) or need_committed.has(colonist_id): continue
		if _combat_giver.owns(colonist_id): continue
		if not ActorTableType.has_component(colonist, "worker", _content): continue
		# F3's own gate, the same one need_giver.gd's _may_be_ordered()
		# and GlobalAssignment's order-eligibility check consult: a "colonist"-def
		# actor under a hostile/neutral faction (a raider, ADR 014) still has a
		# worker component but must never be offered to rescue a colony colonist.
		if not _colonist_may_be_ordered(colonist_id): continue
		filtered.append(colonist)
	return filtered

## rescue_giver.gd's own victim pool: every currently-trapped
## colonist eligible for rescue. A trapped hostile actor's own trapped dict
## always carries ticksRemaining/fromTile (_trap_actor()'s hostile branch) and
## already auto-escapes via escape_trench (ADR 026) -- only the bare
## {"tile"} shape _trap_actor() gives a non-hostile (colonist) actor ever
## needs a rescuer.
func _trapped_rescue_victims() -> Array[Dictionary]:
	var victims: Array[Dictionary] = []
	for colonist in _colonists:
		var trapped = colonist.get("trapped")
		if trapped == null or (trapped as Dictionary).has("ticksRemaining"): continue
		victims.append(colonist)
	return victims

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
	# reverse. _rescue_candidates() only excludes a need-committed colonist at
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

## Reads a colonist's "needs" component through ActorTable (ADR 012): the
## same live Dictionary colonist["needs"] holds (get_component() never
## duplicates it), so mutating a value on the return still mutates the
## colonist's real state.
func _needs(colonist: Dictionary) -> Dictionary:
	var needs_component = ActorTableType.get_component(colonist, "needs", _content)
	return needs_component if needs_component != null else {}

## Reads the "worker" component's labourTable through ActorTable (ADR 012):
## a freshly assembled wrapper Dictionary, but its "labourTable" value is the
## same live Dictionary colonist["labourTable"] holds, so mutating a value on
## the return still mutates the colonist's real state.
func _labour_table(colonist: Dictionary) -> Dictionary:
	var worker_component = ActorTableType.get_component(colonist, "worker", _content)
	return worker_component.get("labourTable", {}) if worker_component != null else {}

func state_hash(include_incidents: bool = true) -> int:
	_ensure_needs()
	_ensure_held_tool()
	_ensure_health()
	var snapshot := {
		"seed": _seed,
		"tick": _clock.tick,
		"width": _width,
		"height": _height,
		"tiles": _tiles,
		"items": _items,
		"next_item_id": _next_item_id,
		"tool_items": _tool_store.items,
		"next_tool_item_id": _tool_store.next_id,
		"tool_reservations": _tool_store.reservations.snapshot(),
		"objects": _objects,
		"object_health": _object_health,
		"zones": _zones,
		"next_zone_id": _next_zone_id,
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
		"dig_find_rng": {"seed": _dig_find_random.seed, "state": _dig_find_random.state},
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
		# A suspended job's own work-toil ticks
		# affect what happens the moment it resumes, so two states that differ
		# only here must not hash equal.
		"suspended_work_progress": StateCodec._encode_suspended_work_progress(_suspended_work_progress),
		# A site's own held_materials/progress/builder_ids affect
		# what happens next (a fetch/work job the giver submits, or what
		# cancel_site drops), so two states differing only here must not hash
		# equal. list() is already sorted by site id for determinism.
		"construction_sites": _sites.list(),
	}
	if include_incidents: snapshot["incidents"] = {"cooldown_until_day": _incidents._cooldown_until_day, "last_processed_day": _incidents._last_processed_day, "rng_seed": _incidents._random.seed, "rng_state": _incidents._random.state}
	return hash(JSON.stringify(snapshot))

## Matches game-state.schema.json: every field needed to keep ticking
## identically after from_save_state(). No file I/O: callers own the bytes.
func to_save_state() -> Dictionary:
	_ensure_needs()
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
	return _width

func get_map_height() -> int:
	return _height

## The generator algorithm version that actually produced this world's stored
## terrain (for reproducibility): _generator_version, above.
func get_generator_version() -> int:
	return _generator_version

## The already-loaded content/tiles.json value colonist_sprites.gd's
## advance() needs for a full tile-crossing's real tick duration.
func get_move_ticks_per_tile() -> int:
	return int(_content.list("tiles")[0]["move_ticks_per_tile"])

func get_tile(x: int, y: int) -> String:
	return _tiles[_tile_index(x, y)]

func get_tiles() -> Array[String]:
	return _tiles.duplicate()

## Derived sum over ground "wood" items at (x, y) (kept for existing tests).
func get_ground_wood(x: int, y: int) -> int:
	var total := 0
	for item in _items.values():
		if int(item["x"]) == x and int(item["y"]) == y and String(item["kind"]) == "wood":
			total += int(item["count"])
	return total

func get_items() -> Array[Dictionary]:
	var keys := _items.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		var item: Dictionary = (_items[key] as Dictionary).duplicate(true)
		item["faction_id"] = String(_item_factions.get(key, "colony"))
		copy.append(item)
	return copy

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
		_site_fetch_source_retargeted.erase(job_id)
		_site_fetch_picked_kind.erase(job_id)
		if String(job.get("kind", "")) == "incident":
			_incidents.on_job_finished(job_id)
			if not incident_actor.is_empty():
				_pending_trade_offers.erase(String(incident_actor["id"]))
			# Unlike every other work-ticked kind below, an incident's stamped
			# wait is written by IncidentSchedulerType.activate_pending()
			# (incident_scheduler.gd) through
			# the same injected set_work_progress callable but with no job_id
			# (a 2-arg call; job_id defaults to "" and is never recorded as an
			# owner) -- so it cannot participate in the job-id ownership
			# tracking below and keeps its own pre-existing "active at finish"
			# rule instead, unchanged.
			if String(job.get("status", "")) == "active":
				_clear_work_progress(job["target"])
		else:
			_release_owned_work_progress(job_id, job)
	return result

## The one place every terminal transition (complete/cancel/fail/invalidate,
## from any caller: a command, a trap, a death, an unreachable second leg, a
## refused reservation resolution) converges, so this is the one place a
## terminating job's own stored work-toil progress is cleared -- ownership
## tracked by job_id (_work_progress_owner), not by the job's "status" at
## termination time: a build/dig/etc. job interrupted mid-
## work by a critical need is suspended (status reverts to "queued",
## _pause_work_job()) without losing its progress, by design, so it can
## resume from where it left off; but if it is instead cancelled/failed while
## still suspended, the old "status == active" heuristic never fired, leaving
## the abandoned tick count behind for whatever gets built/dug there next.
## Job-id ownership fixes this for every terminal path uniformly, while still
## never erasing a genuinely different job's progress at a coincidentally
## shared target/site (the concern the old heuristic protected against).
## Never called for "incident" (see _finish_job()'s own branch above).
func _release_owned_work_progress(job_id: String, job: Dictionary) -> void:
	if job.is_empty() or not _work_ticks.has(String(job.get("kind", ""))):
		return
	# A job cancelled/failed while still suspended (_suspend_work_progress()
	# already moved its ticks out of the live tile cache) must not leak that
	# snapshot forever.
	_suspended_work_progress.erase(job_id)
	var target: Vector2i = _work_target_for(job)
	var key := _work_progress_key(target.x, target.y)
	if String(_work_progress_owner.get(key, "")) == job_id:
		_clear_work_progress(target)

func get_ground_berries(x: int, y: int) -> int:
	return int(_ground_berries.get(_ground_berries_key(x, y), 0))

## "" (like get_ground_berries()'s own absence) when no berries are on the ground here.
func get_ground_berries_faction_id(x: int, y: int) -> String:
	return String(_ground_berries_factions.get(_ground_berries_key(x, y), ""))

func get_object(x: int, y: int) -> String:
	return String(_objects.get(_object_key(x, y), ""))

## "" (like get_object()'s own "none") when no object is placed here.
func get_object_faction_id(x: int, y: int) -> String:
	return String(_object_factions.get(_object_key(x, y), ""))

## The one authoritative movement rule for a tile and its object: an
## impassable object blocks the tile; a passable one supplies its move cost.
## `faction_id` (F3) defaults to "colony" so every pre-existing
## single-arg call site (route search, movement stepping, dig/chop/forage
## target validation, reachability checks -- all colony-only until F5) keeps
## its old behaviour unchanged. It is only consulted for a door object: a
## non-door object or tile is unaffected by faction_id.
func passability(x: int, y: int, faction_id: String = "colony") -> Dictionary:
	if x < 0 or x >= _width or y < 0 or y >= _height:
		return {"passable": false, "cost": 0, "is_door": false}
	var object_kind := get_object(x, y)
	if not object_kind.is_empty():
		var object_definition: Dictionary = _object_definitions.get(object_kind, {})
		if object_definition.is_empty():
			return {"passable": false, "cost": 0, "is_door": false}
		var is_door := bool(object_definition.get("is_door", false))
		if is_door and not _faction_may_pass_doors(faction_id):
			return {"passable": false, "cost": 0, "is_door": true}
		var object_passable := bool(object_definition.get("passable", false))
		return {
			"passable": object_passable,
			"cost": int(object_definition.get("move_cost", 0)) if object_passable else 0,
			"is_door": is_door
		}
	var tile_kind := get_tile(x, y)
	var tile_definition: Dictionary = _tile_definitions.get(tile_kind, {})
	var tile_passable := bool(tile_definition.get("passable", false))
	return {"passable": tile_passable, "cost": int(tile_definition.get("move_cost", 0)) if tile_passable else 0, "is_door": false}

## rules.may_pass_doors consultation (ADR 014, F3) for a door object's
## passability. Defaults true for a faction_id absent from the factions
## registry (get_entry() returns {} for an unknown id) so a caller that never
## passes faction_id -- resolving to "colony", always declared -- and any
## other lookup miss fails open rather than silently blocking every door.
func _faction_may_pass_doors(faction_id: String) -> bool:
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_pass_doors", true))

## rules.may_be_ordered consultation (F3): whether faction_id may
## be named as a dig/chop/forage command's assignee, read through the
## registry rather than a hardcoded "colony" string. Fails open like
## _faction_may_pass_doors() above.
func _faction_may_be_ordered(faction_id: String) -> bool:
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_be_ordered", true))

## rules.may_reserve_colony_items consultation (F3): the single
## reusable check _enforce_faction_reservations() below consults for the
## assigned actor's faction before a job's reserve step is allowed to stand.
func _faction_may_reserve_colony_items(faction_id: String) -> bool:
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_reserve_colony_items", true))

## may_be_ordered callable for GlobalAssignment.set_order_eligibility() (F3): consulted for every worker before it may even be proposed for any job -- the gate that reaches haul, which has no actor pool of its own to filter (see haul_giver.gd). Also resolves a staged incident actor (F5); an unknown id fails open, matching _faction_may_be_ordered().
func _colonist_may_be_ordered(colonist_id: String) -> bool:
	if _find_colonist(colonist_id).get("trapped") != null: return false
	return _faction_may_be_ordered(_actor_faction(colonist_id))

## may_reserve callable for GlobalAssignment.set_reservation_gate() (F3):
## consulted immediately before a chosen job's reserve step, or
## a suspended job's reactivate() on resume -- never after -- so a refused
## actor's reservation is never even transiently acquired.
func _colonist_may_reserve_colony_items(colonist_id: String) -> bool:
	return _faction_may_reserve_colony_items(_actor_faction(colonist_id))

func get_objects() -> Array[Dictionary]:
	var keys := _objects.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		var coords := String(key).split("_")
		copy.append({"x": int(coords[0]), "y": int(coords[1]), "kind": String(_objects[key]),
			"faction_id": String(_object_factions.get(key, "colony"))})
	return copy

func get_zones() -> Array[Dictionary]:
	var keys := _zones.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		copy.append((_zones[key] as Dictionary).duplicate(true))
	return copy

func get_zone(id: String) -> Dictionary:
	if not _zones.has(id):
		return {}
	return (_zones[id] as Dictionary).duplicate(true)

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

## Every trader's own outstanding trade_offer, state only, for
## the presentation layer (colonist_panel.gd) to render and wire to accept_trade.
func get_pending_trade_offers() -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	for trader_id in _pending_trade_offers:
		var offer: Dictionary = _pending_trade_offers[trader_id]
		offers.append({"trader_id": trader_id, "give_item": String(offer["give_item"]), "want_item": String(offer["want_item"])})
	return offers

## The handover overlay only mutates this call's own detached duplicates, never JobQueue's state.
func get_jobs() -> Array[Dictionary]:
	var jobs := _scheduler.queue.get_jobs()
	var assignments := _scheduler.get_assignments()
	for job in jobs:
		ToolHandoverType.apply(job, assignments, _toils)
	return jobs

func get_reservations() -> Dictionary:
	return _scheduler.queue.get_reservations()

## "" when no exposed need reason (colonist-ai.md 3.8): need_unmet:<kind> once
## a search exhausts every source, blocked_source_reserved/unreachable
## transiently mid-search, "" again once committed or with no need at all.
func get_colonist_need_reason(colonist_id: String) -> String:
	return String(_need_status.get(colonist_id, ""))

## The need job id a colonist is currently committed to, or "" when none --
## the only way to observe the tick between route arrival and the instant
## `consume` toil, when route/work are both null but the job is still pending.
func get_active_need_job_id(colonist_id: String) -> String:
	return _need_giver.get_pending_job(colonist_id)

## Mirroring get_colonist_need_reason()'s own pattern: "" when a
## trapped colonist has no exposed rescue reason (a rescuer is already
## committed, or the search has not run yet), REASON_NO_RESCUER_AVAILABLE once
## a tick's search finds no reachable candidate at all -- the colonist panel's
## "trapped in a trench, no one can help" message.
func get_colonist_rescue_reason(colonist_id: String) -> String:
	return String(_rescue_status.get(colonist_id, ""))

## The active calendar boost (ADR 008) for labour at the current tick -- a
## read-only getter for presentation; the scheduler queries it directly.
func get_active_calendar_boost(labour: String) -> int:
	return _calendar.active_boost(labour, _clock.tick)

func get_scheduling_metrics() -> Dictionary:
	return _scheduler.get_metrics()

func get_assignments() -> Dictionary:
	return _scheduler.get_assignments()

## RouteSearch's cost callable. StateCodec forwards this method reference
## unchanged into GlobalAssignment.restore_scheduling().
func _is_passable(tile: Vector2i) -> float:
	return float(passability(tile.x, tile.y)["cost"])

## Faction-aware cost callable for IncidentScheduler's spawn-tile/target selection (F5): the colony-only _is_passable() above would let a wildlife actor spawn on/target a tile only reachable through a colony door.
func _passable_for_faction(tile: Vector2i, faction_id: String) -> float:
	return float(passability(tile.x, tile.y, faction_id)["cost"])

## GlobalAssignment's autonomous passability (F5): an incident
## actor's initial bounded route search runs under its own faction.
func _passable_for_worker(actor_id: String, tile: Vector2i) -> float:
	return _passable_for_faction(tile, _actor_faction(actor_id))

## CombatGiver's own faction-aware passability(x,y)->Dictionary check for a
## flee candidate tile: a hostile actor's own faction, not
## "colony", decides whether a door blocks it, mirroring
## _passable_for_worker() above but returning the full passability()
## Dictionary a flee candidate check needs rather than just its cost.
func _passable_for_flee(actor_id: String, x: int, y: int) -> Dictionary:
	return passability(x, y, _actor_faction(actor_id))

## CombatGiver's own region-reachability check for a flee candidate tile.
## A single-tile passability check alone would let it pick a
## candidate that is passable but disconnected from the fleeing actor's own
## region (an isolated pocket), leaving the actor permanently stuck pursuing
## an unreachable target.
func _region_reachable(from: Vector2i, target: Vector2i) -> bool:
	return _get_regions().reachable(from, target)

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
	if _faction_may_reserve_colony_items(_actor_faction(actor_id)):
		return true
	if not trapped_actor.is_empty() and Vector2i(int(trapped_actor["x"]), int(trapped_actor["y"])) == target:
		return true
	return _is_bare_tile(target)

## No colony-owned thing on this tile: shared by the gate above and by
## IncidentScheduler's target/spawn-tile selection, so a proposed target is
## one the gate accepts.
func _is_bare_tile(tile: Vector2i) -> bool:
	if not get_object(tile.x, tile.y).is_empty() or get_ground_berries(tile.x, tile.y) > 0 or _is_in_any_zone(tile.x, tile.y):
		return false
	for item in _items.values():
		if int(item["x"]) == tile.x and int(item["y"]) == tile.y:
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
## actor's active incident job back to "queued" via _pause_work_job()/
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
## through the same _paused_jobs entry StateCodec already restored.
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

## item_lookup callable for _toils's pick_up precondition: {} when gone.
func _item_lookup(item_id: String) -> Dictionary:
	if not _items.has(item_id):
		return {}
	return (_items[item_id] as Dictionary).duplicate(true)

## Whole-item removal, still used directly by callers that already know the
## entire item is leaving (e.g. sow's seed consumption via
## _remove_one_item_of_kind()).
func _remove_ground_item(item_id: String) -> void:
	_items.erase(item_id)
	_item_factions.erase(item_id)

## remove_item callable for _toils's pick_up: decrements the
## ground item's own count by count, removing it entirely at 0 -- exactly as
## pick_up already did for a whole stack before hands capped a pick_up below
## the ground item's own count.
func _remove_ground_item_units(item_id: String, count: int) -> void:
	if not _items.has(item_id):
		return
	var item: Dictionary = _items[item_id]
	var remaining := int(item["count"]) - count
	if remaining > 0:
		item["count"] = remaining
	else:
		_remove_ground_item(item_id)

## place_item callable for _toils's place: preserves id stability across a
## pick_up/place round trip. faction_id is always "colony": nothing today
## (set_faction never targets an item; hands has no faction
## field) can ever produce an item of any other faction, so there is no
## carried-faction to plumb through the toil executor's hands shape.
func _place_ground_item(item_id: String, kind: String, count: int, x: int, y: int) -> void:
	_items[item_id] = {"id": item_id, "x": x, "y": y, "kind": kind, "count": count}
	_item_factions[item_id] = "colony"

## place_item callable for _toils's place: place() now deposits
## one fresh ground item per distinct hands kind rather than reusing a single
## carried item's own id (hands entries have no id of their own -- a pick_up
## may have merged several ground items' units into one entry), so this mints
## the next id off the same _next_item_id counter every other ground-item
## spawn uses and returns it.
func _place_new_ground_item(kind: String, count: int, x: int, y: int) -> String:
	var item_id: String = "item_%d" % _next_item_id
	_next_item_id += 1
	_place_ground_item(item_id, kind, count, x, y)
	return item_id

## cell_occupied callable for _toils's place precondition.
func _is_cell_occupied(x: int, y: int, excluding_colonist_id: String) -> bool:
	for colonist in _colonists:
		if String(colonist["id"]) != excluding_colonist_id and int(colonist["x"]) == x and int(colonist["y"]) == y:
			return true
	for item in _items.values():
		if int(item["x"]) == x and int(item["y"]) == y:
			return true
	return false

func _spawn_wood_item(x: int, y: int) -> void:
	var item_id := "item_%d" % _next_item_id
	_next_item_id += 1
	_items[item_id] = {"id": item_id, "x": x, "y": y, "kind": "wood", "count": 1}
	_item_factions[item_id] = "colony"

## Generic ground-item spawn (ADR 026): the same shape _spawn_wood_item()
## above uses, generalized to an arbitrary content/items.json kind. Used by
## dig's guaranteed sand and any rolled find item.
func _spawn_item(kind: String, x: int, y: int) -> void:
	var item_id := "item_%d" % _next_item_id
	_next_item_id += 1
	_items[item_id] = {"id": item_id, "x": x, "y": y, "kind": kind, "count": 1}
	_item_factions[item_id] = "colony"

## ADR 026's item placement rule: the nearest adjacent passable, non-trench
## tile to (x, y), checked in row-major order (north, west, east, south --
## already row-major since these four orthogonal neighbours never tie in y),
## first qualifying tile wins. Falls back to (x, y) itself -- the trench tile
## -- only when no neighbour qualifies.
func _dig_item_placement(x: int, y: int) -> Vector2i:
	for neighbor in [Vector2i(x, y - 1), Vector2i(x - 1, y), Vector2i(x + 1, y), Vector2i(x, y + 1)]:
		if bool(passability(neighbor.x, neighbor.y)["passable"]) and get_tile(neighbor.x, neighbor.y) != TILE_TRENCH:
			return neighbor
	return Vector2i(x, y)

## rescue_giver.gd's target-tile candidates: every passable,
## non-trench tile adjacent to a trapped colonist's own tile, in the same
## row-major neighbour order _dig_item_placement() already uses (ADR 026's own
## "item placement" convention) -- but, unlike that helper, a rescue target
## must never be the trench tile itself: a rescue job must never target the
## trench a rescuer could then fall into. rescue_giver.gd ranks these by real
## route length from its own chosen rescuer (a route that must also never
## cross the victim's own trench tile -- see its own doc comment) rather than
## picking a single one here: an adjacent tile on the far side of a
## corridor-width trench can be much farther, by real route, than the map's
## row-major order alone would suggest.
func _rescue_target_candidates(victim_tile: Vector2i) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	for neighbor in [Vector2i(victim_tile.x, victim_tile.y - 1), Vector2i(victim_tile.x - 1, victim_tile.y),
			Vector2i(victim_tile.x + 1, victim_tile.y), Vector2i(victim_tile.x, victim_tile.y + 1)]:
		if bool(passability(neighbor.x, neighbor.y)["passable"]) and get_tile(neighbor.x, neighbor.y) != TILE_TRENCH:
			candidates.append(neighbor)
	return candidates

## escape_trench's exit rule: prefers from_tile (where the actor fell from)
## when passable for the actor's own faction, else _dig_item_placement()'s
## row-major order. Vector2i(-1, -1) means no exit (caller retries).
func _trench_exit_tile(tile: Vector2i, from_tile: Vector2i, faction_id: String) -> Vector2i:
	if from_tile != tile and bool(passability(from_tile.x, from_tile.y, faction_id)["passable"]) \
			and get_tile(from_tile.x, from_tile.y) != TILE_TRENCH:
		return from_tile
	for neighbor in [Vector2i(tile.x, tile.y - 1), Vector2i(tile.x - 1, tile.y), Vector2i(tile.x + 1, tile.y), Vector2i(tile.x, tile.y + 1)]:
		if bool(passability(neighbor.x, neighbor.y, faction_id)["passable"]) and get_tile(neighbor.x, neighbor.y) != TILE_TRENCH:
			return neighbor
	return Vector2i(-1, -1)

## Draws dig's find_table (ADR 026, content/jobs.json's "dig" entry) against
## _dig_find_random: the rolled item id, or "" for "no find" (a find_table
## row's item: null). Always consumes exactly one randi_range() draw, so the
## roll count stays reproducible from the world seed regardless of outcome.
func _roll_dig_find() -> String:
	var find_table: Array = _content.get_entry("jobs", "dig").get("yields", {}).get("find_table", [])
	var roll := _dig_find_random.randi_range(0, 99)
	var cumulative := 0
	for entry in find_table:
		cumulative += int(entry["weight"])
		if roll < cumulative:
			var item = entry.get("item")
			return String(item) if item != null else ""
	return ""

## Drains _pending_dig_finds (ADR 026) in ascending job-id order -- called
## once per tick, after _advance_colonists() -- so replaying the same seed
## against the same command stream always produces the same find sequence no
## matter which colonist's dig happened to finish first this tick.
func _resolve_dig_finds() -> void:
	if _pending_dig_finds.is_empty():
		return
	var pending := _pending_dig_finds
	_pending_dig_finds = []
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(String(a["job_id"]).trim_prefix("job_")) < int(String(b["job_id"]).trim_prefix("job_")))
	for entry in pending:
		var find_item := _roll_dig_find()
		if find_item.is_empty():
			continue
		var at := _dig_item_placement(int(entry["x"]), int(entry["y"]))
		_spawn_item(find_item, at.x, at.y)

func _spawn_stone_item(x: int, y: int) -> void:
	var item_id := "item_%d" % _next_item_id
	_next_item_id += 1
	_items[item_id] = {"id": item_id, "x": x, "y": y, "kind": "stone", "count": 1}
	_item_factions[item_id] = "colony"

func _spawn_berries_item(x: int, y: int) -> void:
	var key := _ground_berries_key(x, y)
	_ground_berries[key] = int(_ground_berries.get(key, 0)) + 1
	_ground_berries_factions[key] = "colony"

## sow's blocked_missing_input precondition: a seed counts whether it is on
## the ground/stockpile or mid-haul in a colonist's hands.
func _has_item_of_kind(kind: String) -> bool:
	for item in _items.values():
		if String(item["kind"]) == kind:
			return true
	for colonist in _colonists:
		if InventoryType.has_kind(colonist, kind):
			return true
	return false

## sow's on_work_complete effect: removes one item of `kind`, ground/stockpile
## first (by id order), else a carried one. Returns false if none exist
## anywhere, so the caller can fail the job blocked_missing_input instead.
func _remove_one_item_of_kind(kind: String) -> bool:
	var ids := _items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = _items[id]
		if String(item["kind"]) != kind:
			continue
		var count := int(item.get("count", 1))
		if count > 1:
			item["count"] = count - 1
		else:
			_items.erase(id)
			_item_factions.erase(id)
			_fail_haul_jobs_referencing_item(String(id))
		return true
	return _consume_carried_item_of_kind(kind)

## Fails any nonterminal haul job still naming item_id after
## _remove_one_item_of_kind() above erased its last ground unit, so it doesn't
## retry forever for an item that no longer exists.
func _fail_haul_jobs_referencing_item(item_id: String) -> void:
	for job in _scheduler.queue.get_jobs():
		if String(job["kind"]) != "haul" or String(job["status"]) not in ["queued", "active"]:
			continue
		if String(job["item_id"]) != item_id:
			continue
		_terminate_haul_job_by_id(String(job["id"]), "blocked_missing_input", "resubmit_order")

## Fallback for _remove_one_item_of_kind() above: consumes one unit of `kind`
## from whichever colonist (lowest id first, for determinism) carries it
## mid-haul, then fails that colonist's now-empty haul job once its last unit
## of `kind` is gone (whatever else its hands may still hold).
func _consume_carried_item_of_kind(kind: String) -> bool:
	var ordered: Array[Dictionary] = _colonists.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	for colonist in ordered:
		if not InventoryType.has_kind(colonist, kind):
			continue
		InventoryType.remove_from_hands(colonist, kind, 1)
		if not InventoryType.has_kind(colonist, kind):
			_cancel_haul_job_carrying_consumed_item(String(colonist["id"]))
		return true
	return false

## Fails colonist_id's haul job after _consume_carried_item_of_kind() above
## emptied what it was carrying, the way an unreachable destination already
## does. Checks _paused_jobs first: a need interrupt may have suspended this
## haul after pickup, in which case only the pause entry is cleared, not the
## colonist's route/work (owned by whatever need job is now driving it).
func _cancel_haul_job_carrying_consumed_item(colonist_id: String) -> void:
	var job_id: String = ""
	var was_paused := false
	if _paused_jobs.has(colonist_id):
		job_id = String(_paused_jobs[colonist_id])
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
		_paused_jobs.erase(colonist_id)
	else:
		var colonist := _find_colonist(colonist_id)
		if not colonist.is_empty():
			colonist["route"] = null
			colonist["work"] = null
			_reroutes.erase(colonist_id)
	_scheduler.queue.set_pending_fail_reason(job_id, "blocked_missing_input", "resubmit_order")
	_finish_job(job_id, "fail_job")

func _ground_berries_key(x: int, y: int) -> String:
	return "%d_%d" % [x, y]

## The _work_progress key a specific job's progress lives under: scoped by
## job id only when that job is a "rescue":
## a tile-only key would let two different rescue jobs sharing one target (two
## victims can share a target) read and clear each other's progress across a
## suspend/resume. Every other kind keeps the plain tile key every existing
## test/save already assumes, since an ordinary job's target changes kind (or
## is no longer valid) once it completes, so a same-kind job can never really
## reuse that exact tile. Takes the job's own explicit identity, never the
## tile's current reservation owner: every
## terminal boundary below clears progress after _finish_job() has already
## released that reservation, when an owner lookup would name nobody.
func _work_progress_key_for_job(job_id: String, job: Dictionary) -> String:
	var target: Vector2i = job["target"]
	if String(job.get("kind", "")) != "rescue":
		return "%d_%d" % [target.x, target.y]
	return "%s:%d_%d" % [job_id, target.x, target.y]

## The tile-addressed variant ToilExecutor's own get/set/clear hooks use mid-
## work, when the tile's reservation owner is the job being worked: resolves
## that owner and delegates to _work_progress_key_for_job() above.
func _work_progress_key(x: int, y: int) -> String:
	var owning_job_id: String = _scheduler.queue.get_reservation_table().owner(_tile_key(x, y))
	if owning_job_id.is_empty():
		return "%d_%d" % [x, y]
	# A construction site's own footprint reservation is owned by
	# "site:<id>", never a job id (ConstructionSiteTable.owner_key()) -- fall
	# back to the plain tile key exactly like the unreserved case above rather
	# than resolving a nonexistent job, which get_job() reports as {}.
	var owning_job := _scheduler.queue.get_job(owning_job_id)
	if owning_job.is_empty():
		return "%d_%d" % [x, y]
	return _work_progress_key_for_job(owning_job_id, owning_job)

## Progress cleanup for a job that just took a terminal transition, by its
## own explicit identity. A rescue job's progress
## key names that job alone, so it is dropped on every terminal transition --
## active or merely queued/suspended -- since no other job can ever own it;
## an ordinary job's plain tile key is shared with any paused job on the same
## tile, so it is dropped only when the terminating job was the active owner
## (a queued competitor or a repeated terminal command must never erase
## another job's paused progress).
func _clear_terminated_job_progress(job_id: String, job: Dictionary, was_active: bool) -> void:
	if not job.has("target"):
		return
	var kind := String(job.get("kind", ""))
	if kind == "rescue" or (was_active and _work_ticks.has(kind)):
		_work_progress.erase(_work_progress_key_for_job(job_id, job))

## null when the tile has no stored progress, otherwise the ticks remaining
## on its `work` toil the last time it was worked (colonist-ai.md 3.6). Any
## job's progress at the tile, regardless of owner -- escape_trench's own
## dedup check (_activate_pending_escapes()) is the only caller, and it only
## ever needs "has anything been stamped here yet", never whose.
func _get_work_progress(target: Vector2i):
	var key := _work_progress_key(target.x, target.y)
	if not _work_progress.has(key):
		return null
	return int(_work_progress[key])

## start_work()'s own resume/start lookup, job-id scoped:
## unlike _get_work_progress() above, a different job's stale value at the
## same tile (a still-suspended job's own entry, or simply nothing) must never
## be handed to job_id as its own starting point. Checks _suspended_work_progress
## first (a suspended job's own snapshot, moved there by _suspend_work_progress()
## below) and consumes it on read -- the resuming job's own next advance_work_step()
## tick immediately re-establishes it live in _work_progress via _set_work_progress()
## -- then falls back to _work_progress only when its recorded owner is job_id
## itself (the ordinary "already mid-work, tick advanced since" case). Returns
## null (use the job kind's own declared duration) for every other case,
## including a different job's still-live entry at the same tile.
func _resume_work_progress(target: Vector2i, job_id: String):
	# A site_work job's own duration is never a fixed
	# content/jobs.json constant (every object kind declares its own
	# build_ticks) nor a per-job private counter -- it is always exactly
	# "how many ticks does the site's own progress still need", re-derived
	# fresh on every start_work() call (a genuinely fresh activation and a
	# resumption after a critical-need interrupt look identical here, since
	# ConstructionSiteTable.progress -- not this job-id-scoped cache -- is the
	# one persisted, authoritative counter). Bypasses _suspended_work_progress
	# entirely: that cache exists to stop a different job inheriting a stale
	# tile-keyed value, a problem this kind cannot have since its own value is
	# always computed from the site record, never cached here at all.
	var job := _get_job(job_id)
	if String(job.get("kind", "")) == "site_work":
		var site_id := _sites.find_at_origin(job.get("site", target))
		if site_id.is_empty():
			return 0
		var site := _sites.get_site(site_id)
		return maxi(0, int(site["build_ticks"]) - int(site["progress"]))
	if _suspended_work_progress.has(job_id):
		var value := int(_suspended_work_progress[job_id])
		_suspended_work_progress.erase(job_id)
		return value
	var key := _work_progress_key(target.x, target.y)
	if not _work_progress.has(key):
		return null
	# An empty owner is "incident"'s own deliberate no-job_id stamp (see
	# _work_progress_owner's doc comment and _finish_job()'s "incident"
	# branch) -- IncidentSchedulerType.activate_pending() pre-stamps its wait
	# before the actor's own `work` toil ever starts, precisely so start_work()
	# picks it up here; only a non-empty owner naming a different job must be
	# refused.
	var owner := String(_work_progress_owner.get(key, ""))
	if not owner.is_empty() and owner != job_id:
		return null
	return int(_work_progress[key])

## Moves a still-queued (suspended, not terminated) job's in-progress `work`
## timer out of the shared per-tile cache into _suspended_work_progress before
## its colonist.work is cleared for any reason other than that job's own
## completion: JobQueue's own activation/reactivation
## lifecycle can hand the tile this job's site/target reservation just
## released to a completely different job's own `work` toil, which must never
## read, overwrite, or erase this job's own saved ticks at that same "%d_%d"
## key. No-op for a terminal job (_release_owned_work_progress() already owns
## that cleanup, keyed the same way) or a kind with no `work` toil at all.
func _suspend_work_progress(work) -> void:
	if work == null:
		return
	var job_id := String(work.get("job_id", ""))
	var job := _scheduler.queue.get_job(job_id)
	# "active" as well as "queued": _pause_work_job() calls this before
	# suspend_assignment() actually flips the job's own status to "queued",
	# so at that call site the job is still nominally "active" even though
	# colonist.work is about to be cleared for it right here. A genuinely
	# terminal status (already handled by _release_owned_work_progress(),
	# which always runs before this could ever see it) is the only case this
	# must not treat as a suspend.
	if job.is_empty() or String(job.get("status", "")) not in ["active", "queued"]:
		return
	var kind := String(job.get("kind", ""))
	# "incident" never participates in job-id-owned work progress at all (see
	# _finish_job()'s own "incident" branch and _work_progress_owner's doc
	# comment): its stamped wait is written job_id-less by
	# IncidentSchedulerType.activate_pending() and cleared directly by
	# _finish_job(), never through this suspend/resume path.
	if kind == "incident" or not _work_ticks.has(kind):
		return
	_suspended_work_progress[job_id] = int(work.get("ticks_remaining", 0))
	var target: Vector2i = _work_target_for(job)
	var key := _work_progress_key(target.x, target.y)
	if String(_work_progress_owner.get(key, "")) == job_id:
		_clear_work_progress(target)

## Called every tick for every work-toil job kind. For an active
## escape_trench job, also mirrors trapped.ticksRemaining from this same
## real work timer -- never a countdown of its own. job_id,
## when non-empty, records this key's owner in _work_progress_owner so
## _release_owned_work_progress() can later tell a genuinely abandoned key
## from one merely paused.
func _set_work_progress(target: Vector2i, ticks_remaining: int, job_id: String = "") -> void:
	# A site_work job never writes into the shared tile-keyed
	# cache below at all -- ConstructionSiteTable.progress is the one
	# persisted, authoritative counter (summed across every active builder).
	# Checked here too, not only in _toil_on_work_complete()'s final-tick
	# case: with more than one builder, combined contributions can cross
	# build_ticks before any single job's own locally-seeded countdown would,
	# so this non-final tick must finalize immediately for genuine N-builder
	# speedup -- "" matches no real job id, so _finalize_construction_site()
	# finishes every builder here, including this one (nothing else will).
	if not job_id.is_empty() and String(_scheduler.queue.get_job(job_id).get("kind", "")) == "site_work":
		var job := _get_job(job_id)
		var site_id := _sites.find_at_origin(job.get("site", target))
		if not site_id.is_empty():
			var progress := _sites.add_progress(site_id, 1)
			if progress >= int(_sites.get_site(site_id)["build_ticks"]):
				_finalize_construction_site(site_id, "")
		return
	var key := _work_progress_key(target.x, target.y)
	_work_progress[key] = ticks_remaining
	if not job_id.is_empty():
		_work_progress_owner[key] = job_id
	var escaping := _escaping_actor_at(target)
	if not escaping.is_empty() and escaping.get("trapped") != null:
		(escaping["trapped"] as Dictionary)["ticksRemaining"] = ticks_remaining
	# Posted on the trader's own first work-toil tick (this same
	# call, on arrival), not at the wait's end, so accept_trade has a window
	# before the trader's unchanged despawn (test_incidents.gd's own
	# exact-wait-timing checks still hold).
	if not job_id.is_empty() and String(_scheduler.queue.get_job(job_id).get("kind", "")) == "incident":
		_maybe_post_trade_offer(job_id)

## job_id's incident actor posts its trade_offer exactly once (guarded by
## _pending_trade_offers, not a separate flag); a no-op for a non-visitor
## incident actor (wolf, raider) or one that already posted.
func _maybe_post_trade_offer(job_id: String) -> void:
	var actor := _find_job_colonist(job_id)
	if actor.is_empty() or not ActorTableType.has_component(actor, "visitor", _content):
		return
	var trader_id: String = String(actor["id"])
	if _pending_trade_offers.has(trader_id):
		return
	_post_trade_offer(actor)

## Posts actor's own trade_offer: two distinct
## content/items.json kinds, deterministic from actor's own id (never
## global randomness, AGENTS.md; no new persisted RNG stream needed, since a
## lost offer across a save/load is simply never posted again). give_item is
## placed into the trader's "inventory" component items array (F2) so
## accept_trade has something concrete to move; want_item names what the
## colony must give up, taken only if accept_trade is actually called.
func _post_trade_offer(actor: Dictionary) -> void:
	var trader_id: String = String(actor["id"])
	var picks := _pick_trade_items(trader_id)
	var give_item: String = picks[0]
	var want_item: String = picks[1]
	_append_trader_inventory_item(actor, give_item)
	_pending_trade_offers[trader_id] = {"give_item": give_item, "want_item": want_item}
	_insert_event({
		"type": "trade_offer", "tick": _clock.tick, "system_priority": PRIORITY_TICK,
		"entity_id": trader_id, "sequence": _next_sequence(),
		"data": {"trader_id": trader_id, "give_item": give_item, "want_item": want_item},
	})

## Two distinct non-tool content/items.json kinds, keyed off trader_id's own
## hash so the pick is stable without a persisted RNG stream. Tool kinds
## (axe, pick) are excluded: trading one would need ToolItemStore's own
## reservation/handover machinery, out of scope for a plain ground-item swap.
func _pick_trade_items(trader_id: String) -> Array:
	var kinds: Array[String] = []
	for entry in _content.list("items"):
		var id := String(entry["id"])
		if not is_tool_kind(id):
			kinds.append(id)
	kinds.sort()
	var base := int(trader_id.hash()) % kinds.size()
	if base < 0:
		base += kinds.size()
	return [kinds[base], kinds[(base + 1) % kinds.size()]]

## accept_trade {trader_id}, modelled on
## _apply_set_faction_command()'s validate-then-mutate shape
## (orders-and-movement.md's typed-rejection pattern). Performs the full
## two-way swap: one want_item unit moves out of an eligible stockpiled item
## (_find_available_stockpiled_item(), the same zone/reservation invariant
## the superseded `build` job once resolved its own seed item through -- a
## trade must never rip an item out of a colonist's hands mid-haul) into the
## trader's own "inventory" component, and the trader's give_item moves out
## of that same inventory into the colony's stockpile, at the tile the
## want_item unit just vacated (still inside the same zone). Then cancels the
## trader's still-active incident job through the shared finish boundary --
## _finish_job()'s "incident" branch calls IncidentScheduler.on_job_finished(),
## which removes the trader exactly like its own unaccepted despawn would, and
## also clears this trader's own _pending_trade_offers entry.
## Refusing (never calling this) leaves the trader to that same despawn.
func _apply_accept_trade_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if not (payload.get("trader_id") is String) or String(payload.get("trader_id", "")).is_empty():
		return _rejection(command["command_id"], command["actor"], "invalid_payload",
			"accept_trade requires a non-empty string trader_id.")
	var trader_id: String = String(payload["trader_id"])
	if not _pending_trade_offers.has(trader_id):
		return _rejection(command["command_id"], command["actor"], "invalid_target",
			"No pending trade offer for trader_id '%s' (unknown or already departed)." % trader_id)
	var trader := _find_colonist(trader_id)
	if trader.is_empty():
		_pending_trade_offers.erase(trader_id)
		return _rejection(command["command_id"], command["actor"], "invalid_target",
			"Trader '%s' has already departed." % trader_id)
	var offer: Dictionary = _pending_trade_offers[trader_id]
	var want_item := String(offer["want_item"])
	var give_item := String(offer["give_item"])
	var stock_item_id := _find_available_stockpiled_item(want_item, 1)
	if stock_item_id.is_empty():
		return _rejection(command["command_id"], command["actor"], "blocked_missing_input",
			"stockpile_the_required_item")
	var stock_tile := _remove_stockpiled_item_unit(stock_item_id)
	_append_trader_inventory_item(trader, want_item)
	_remove_trader_offered_item(trader, give_item)
	_spawn_item(give_item, stock_tile.x, stock_tile.y)
	_pending_trade_offers.erase(trader_id)
	var assignment = _scheduler.get_assignments().get(trader_id)
	if assignment != null:
		_finish_job(String(assignment["job_id"]), "cancel_job")
	else:
		_remove_colonist_by_id(trader_id)
	return _applied(command)

## The lowest-id ground item of `item_kind` with at least `quantity` count,
## sitting inside a stockpile zone, and not reserved by any job on the shared
## ReservationTable -- or "" when none qualifies. Deterministic id order, like
## _remove_one_item_of_kind(). Used by accept_trade's own stockpile draw; the
## superseded single-worker `build` job once shared
## this exact search (as `_find_available_build_item()`) for its own seed
## item, before it was replaced by a persistent construction site that
## never resolves an item synchronously at all.
func _find_available_stockpiled_item(item_kind: String, quantity: int) -> String:
	var table := _scheduler.queue.get_reservation_table()
	var ids := _items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = _items[id]
		if String(item["kind"]) != item_kind or int(item.get("count", 1)) < quantity:
			continue
		if not _is_in_any_zone(int(item["x"]), int(item["y"])):
			continue
		if not table.owner(JobQueueType.ITEM_KEY_PREFIX + String(id)).is_empty():
			continue
		return String(id)
	return ""

## Removes one unit of the stockpiled item _find_available_stockpiled_item()
## resolved (same decrement/erase shape _remove_one_item_of_kind() uses for a
## kind-wide search, here applied to a single already-resolved id), and
## returns the tile it sat on so the give_item side of the swap can land in
## that same stockpile spot.
func _remove_stockpiled_item_unit(item_id: String) -> Vector2i:
	var item: Dictionary = _items[item_id]
	var tile := Vector2i(int(item["x"]), int(item["y"]))
	var count := int(item.get("count", 1))
	if count > 1:
		item["count"] = count - 1
	else:
		_items.erase(item_id)
		_item_factions.erase(item_id)
		_fail_haul_jobs_referencing_item(item_id)
	return tile

## Appends one unit of `kind` to actor's own "inventory" component items
## array (F2's per-instance shape, no "id" field), shared by _post_trade_offer()
## (the trader's initial give_item) and _apply_accept_trade_command() (the
## want_item moving into the trader on acceptance).
func _append_trader_inventory_item(actor: Dictionary, kind: String) -> void:
	var inventory = actor.get("inventory")
	if inventory is Dictionary:
		(inventory["items"] as Array).append({"kind": kind, "count": 1})

## Removes the one inventory-component entry _append_trader_inventory_item()
## added (mirroring how _drop_inventory_contents() already reads only
## "kind"/"count" off it).
func _remove_trader_offered_item(trader: Dictionary, kind: String) -> void:
	var inventory = trader.get("inventory")
	if not (inventory is Dictionary):
		return
	var items: Array = inventory["items"]
	for i in items.size():
		if String((items[i] as Dictionary).get("kind", "")) == kind:
			items.remove_at(i)
			return

## The colonist with an active escape_trench job targeting `target`, via the
## scheduler's own assignments (never trapped.tile alone, so two actors
## trapped on the same tile at different times are never confused).
func _escaping_actor_at(target: Vector2i) -> Dictionary:
	var assignments := _scheduler.get_assignments()
	for worker_id in assignments:
		var job_id: String = String(assignments[worker_id]["job_id"])
		var job := _scheduler.queue.get_job(job_id)
		if String(job.get("kind", "")) == "escape_trench" and String(job.get("status", "")) == "active" \
				and job.get("target") == target:
			return _find_colonist(worker_id)
	return {}

func _clear_work_progress(target: Vector2i) -> void:
	var key := _work_progress_key(target.x, target.y)
	_work_progress.erase(key)
	_work_progress_owner.erase(key)

## StateCodec.decode()'s own post-load restore of _work_progress_owner from
## the persisted "workProgressOwners" job_id (see its declaration above),
## rather than guessing an owner from whichever job currently targets a key
## (a dig queued at a build's site would make that guess pick the wrong
## job). Cross-checked against the just-restored job list -- exactly
## the same non-terminal/kind-has-work_ticks filter the old guess used -- so
## a hand-edited or corrupted save can never resurrect an owner pointing at a
## job that no longer exists, has gone terminal, or never ticks work.
## `persisted` is StateCodec's decoded key -> job_id map ({} for a save taken
## before this field existed, restoring with no owners at all). Must run
## once jobs are restored but before _reconcile_incident_jobs_after_load()
## may cancel one through the shared _finish_job() boundary, so that
## cancellation's own ownership-gated cleanup fires correctly immediately
## after a load exactly like it would have on a live, uninterrupted run.
func _restore_work_progress_owners(persisted: Dictionary) -> void:
	_work_progress_owner.clear()
	for key in persisted:
		var job_id := String(persisted[key])
		var job := _scheduler.queue.get_job(job_id)
		if job.is_empty() or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var kind := String(job.get("kind", ""))
		# "incident" never participates -- see _finish_job()'s own comment.
		if kind == "incident" or not _work_ticks.has(kind):
			continue
		if _work_progress.has(key):
			_work_progress_owner[key] = job_id
	# "workProgressOwners" is optional on the wire
	# (see StateCodec.encode()'s own comment), so a save taken before this
	# field existed decodes `persisted` as {} here even though _work_progress
	# itself (unconditional on the wire, restored above this call) may still
	# hold real in-flight progress -- an active dig/build's own timer, or one
	# a need interrupt suspended mid-work. Leaving those keys ownerless (the
	# old behaviour) let them survive forever: _release_owned_work_progress()
	# only clears a key its own job_id owns, so a cancel/fail of that exact
	# job could never match and a replacement job at the same tile silently
	# inherited the abandoned timer. Recover ownership from execution state
	# the save format has always carried -- never by guessing from which job
	# merely targets the key -- then drop whatever
	# still has no recovered owner so it cannot leak forward either.
	var reconstructed := _reconstruct_work_progress_owners()
	for key in reconstructed:
		if _work_progress_owner.has(key):
			continue
		var candidate = reconstructed[key]
		if candidate != null:
			_work_progress_owner[key] = String(candidate)
	# An active "incident" job's own stored wait never gets a job_id owner by
	# design (_finish_job()'s own comment -- IncidentSchedulerType.
	# activate_pending() writes it through a job_id-less call), so it must
	# never be swept up as "abandoned" here; exclude its keys before pruning.
	var incident_keys := _active_incident_work_progress_keys()
	for key in _work_progress.keys():
		if not _work_progress_owner.has(key) and not incident_keys.has(key):
			_work_progress.erase(key)

## Fallback ownership source for _restore_work_progress_owners() above, used
## for a work-progress key its `persisted` argument doesn't name (a legacy
## save predating "workProgressOwners", or a persisted entry that pointed at
## a job load itself rejected as stale). Built only from execution state the
## save format has always carried, unconditionally, so it is as trustworthy
## as a persisted job_id -- never a guess from which job happens to target a
## tile:
##  - a colonist's own "work" field: the job_id its currently-active `work`
##    toil belongs to (state_codec.gd's entity "work"/"jobId").
##  - _paused_jobs: the job_id a need interrupt suspended mid-work, restored
##    from "pausedJobs" before this runs (see decode()'s own ordering
##    comment) -- exactly the case where "status" alone can't
##    tell a merely-paused owner from an abandoned one.
## Two different candidates never legitimately name the same key: each only
## exists for a job that has genuinely started its own `work` toil (the only
## place a job_id is ever recorded against a key in the first place, in
## _set_work_progress()), and a target is claimed by at most one such job at
## a time. A collision is therefore corruption, not a real ownership
## question -- recorded as null so the caller drops the key rather than
## guessing which candidate is real.
func _reconstruct_work_progress_owners() -> Dictionary:
	var result: Dictionary = {}
	for colonist in _colonists:
		var work = colonist.get("work")
		if work != null:
			_claim_reconstructed_owner(result, String(work.get("job_id", "")))
	for colonist_id in _paused_jobs.keys():
		var job_id := String(_paused_jobs[colonist_id])
		var job := _scheduler.queue.get_job(job_id)
		if not job.is_empty() and String(job.get("status", "")) == "queued":
			_claim_reconstructed_owner(result, job_id)
	return result

## Every work-progress key an active "incident" job currently owns without a
## job_id (see _restore_work_progress_owners()'s own comment above), so the
## pruning step there can tell that deliberate absence from a genuinely
## abandoned key instead of erasing it.
func _active_incident_work_progress_keys() -> Dictionary:
	var keys: Dictionary = {}
	for job in _scheduler.queue.get_jobs():
		if String(job.get("kind", "")) == "incident" and String(job.get("status", "")) == "active":
			var target: Vector2i = _work_target_for(job)
			keys[_work_progress_key(target.x, target.y)] = true
	return keys

func _claim_reconstructed_owner(result: Dictionary, job_id: String) -> void:
	if job_id.is_empty():
		return
	var job := _scheduler.queue.get_job(job_id)
	var kind := String(job.get("kind", ""))
	# "incident" never owns a work-progress key by job_id -- see
	# _restore_work_progress_owners()'s own persisted-loop and
	# _finish_job()'s comment; excluded here too so reconstruction never
	# hands one an owner live play itself never records.
	if job.is_empty() or kind == "incident" or not _work_ticks.has(kind):
		return
	var target: Vector2i = _work_target_for(job)
	var key := _work_progress_key(target.x, target.y)
	if not _work_progress.has(key):
		return
	if result.has(key):
		if String(result[key]) != job_id:
			result[key] = null
	else:
		result[key] = job_id

## is_in_any_zone callable for _haul_giver and RoomMapType's has_stockpile.
func _is_in_any_zone(x: int, y: int) -> bool:
	for zone in _zones.values():
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		if x >= zx and x < zx + int(zone["width"]) and y >= zy and y < zy + int(zone["height"]):
			return true
	return false

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
				_clear_terminated_job_progress(job_id, job, false)
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
				_suspend_work_progress(colonist.get("work"))
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
				_suspend_work_progress(work)
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
				and not _rescue_activation_safe(colonist, job, assignment.get("path", [])):
			_retire_rescue_job(job_id, job)
			continue
		var tile_before := Vector2i(int(colonist["x"]), int(colonist["y"]))
		_trap_tile_before = tile_before
		_toils.advance(colonist, job_id, job, assignment.get("path", []), _toil_hooks)
		_check_trench_arrival(colonist, job_id, tile_before)

## True when a freshly activated rescue assignment may be driven as-is: its
## target is still a passable non-trench tile (an object placed there since
## commit would otherwise make the scheduler's route-trim start rescue work
## one tile off-target) and, when the scheduler's path starts where the
## rescuer stands (the only case ToilExecutor walks it verbatim; any other
## path is re-routed under _rescue_routable_to() anyway), that path ends on
## the target and crosses no trench tile anywhere along it.
func _rescue_activation_safe(colonist: Dictionary, job: Dictionary, path: Array) -> bool:
	var target: Vector2i = job["target"]
	if _is_trench_tile(target) or not bool(passability(target.x, target.y, String(colonist.get("factionId", "colony")))["passable"]):
		return false
	if path.is_empty() or path[0] != Vector2i(int(colonist["x"]), int(colonist["y"])):
		return true
	if path[path.size() - 1] != target:
		return false
	for step in path:
		if _is_trench_tile(step):
			return false
	return true

## Retires a committed rescue whose travel can no longer be completed safely:
## an unreachable or newly unsafe target, a route that would now cross a
## trench, or a target no longer passable. Cancelled through the shared
## finish boundary (never resubmitted under the same rescuer like
## _resubmit_unreachable_job() does for an ordinary order), its own progress
## key dropped, and RescueGiver told so the rescuer resumes its own
## interrupted work and the victim's next search is free to choose any
## available rescuer, not this one indefinitely.
func _retire_rescue_job(job_id: String, job: Dictionary = {}) -> void:
	if job.is_empty():
		job = _scheduler.queue.get_job(job_id)
	var was_active := String(job.get("status", "")) == "active"
	if _finish_job(job_id, "cancel_job").get("ok", false):
		_clear_terminated_job_progress(job_id, job, was_active)
	_rescue_giver.resolve_job(job_id)

## ADR 026: traps an actor whose route step lands it on trench (the
## "still routing" case; _toil_on_work_complete()'s own pre-check covers
## arrival+completion in the same tick, via the same _trap_actor()).
func _check_trench_arrival(colonist: Dictionary, job_id: String, tile_before: Vector2i) -> void:
	if colonist.get("trapped") != null: return
	var tile_after := Vector2i(int(colonist["x"]), int(colonist["y"]))
	if tile_after == tile_before or get_tile(tile_after.x, tile_after.y) != TILE_TRENCH: return
	if not _actor_traps_on_trench(colonist): return
	_trap_actor(colonist, job_id, tile_before)

## Scope: trap-on-entry/hostile climb-out applies only to a colonist (has
## a worker component, ActorTable/ADR 012) or an actor hostile to the colony
## (ADR 014 Relations.is_hostile) -- a non-hostile, non-colonist actor (a
## trader) crosses a trench unaffected, exactly like it always could.
func _actor_traps_on_trench(actor: Dictionary) -> bool:
	if ActorTableType.has_component(actor, "worker", _content):
		return true
	return _relations.is_hostile({"faction_id": String(actor.get("factionId", "colony"))}, {"faction_id": "colony"})

## Releases job_id exactly like cancel_job (reservations freed, owned
## work-progress cleared, NeedGiver resolved -- _apply_job_command()'s own
## path). Records `trapped`, and when hostile (ADR 014) submits escape_trench.
func _trap_actor(colonist: Dictionary, job_id: String, from_tile: Vector2i) -> void:
	var tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var hostile: bool = _relations.is_hostile({"faction_id": String(colonist.get("factionId", "colony"))}, {"faction_id": "colony"})
	# Key order matches StateCodec._decode_trapped_field(): state_hash()
	# hashes JSON.stringify(), which is insertion-order-sensitive.
	colonist["trapped"] = ({"tile": tile, "ticksRemaining": _trench_climb_ticks(colonist), "fromTile": from_tile}
		if hostile else {"tile": tile})
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("status", "")) == "active":
		var job_kind := String(job.get("kind", ""))
		if job_kind in ["haul", "site_fetch"]: _drop_carried_haul_item(job_id)
		if _finish_job(job_id, "cancel_job").get("ok", false):
			_clear_terminated_job_progress(job_id, job, true)
			_resolve_giver_association(job_id, job_kind)
	if not hostile: return
	_submit_trench_escape(colonist, tile)

## Submits (or re-submits, after a blocked climb-out) colonist's own
## escape_trench job targeting its own tile (self-tile reservation exception).
func _submit_trench_escape(colonist: Dictionary, tile: Vector2i) -> void:
	_scheduler.submit_autonomous(tile, 1, _clock.tick, "escape_trench", String(colonist["id"]))

## Once per tick, before _advance_colonists() (mirrors IncidentScheduler's
## activate_pending()): stamps each newly-active escape_trench job's duration
## onto its target's work-progress key. Reads the tunable fresh rather than
## staging it at submission, so a target with existing progress (mid-
## countdown, or another queued escaper) needs no persisted bookkeeping.
func _activate_pending_escapes() -> void:
	var assignments := _scheduler.get_assignments()
	for worker_id in assignments:
		var job_id: String = String(assignments[worker_id]["job_id"])
		var job := _scheduler.queue.get_job(job_id)
		if String(job.get("kind", "")) != "escape_trench" or String(job.get("status", "")) != "active": continue
		var target: Vector2i = job["target"]
		if _get_work_progress(target) != null: continue
		var actor := _find_colonist(worker_id)
		if actor.is_empty(): continue
		_set_work_progress(target, _trench_climb_ticks(actor), job_id)

func _trench_climb_ticks(colonist: Dictionary) -> int: # content/actors.json tunables.wild.trench_climb_ticks
	var definition: Dictionary = _content.get_entry("actors", String(colonist.get("kind", "")))
	var wild_tunables: Dictionary = (definition.get("tunables", {}) as Dictionary).get("wild", {})
	return int(wild_tunables.get("trench_climb_ticks", DEFAULT_TRENCH_CLIMB_TICKS))

## Steps the go_to toil toward target; on "unreachable", routes through the
## same kind-aware _toil_on_unreachable() boundary every other first-leg
## unreachable case uses rather than
## unconditionally resubmitting -- an incident or flee job recovering here
## must be cancelled-only, never resubmitted: _resubmit_unreachable_job()
## replaces a job through the ordinary, may_be_ordered-gated submit(),
## refused outright for a non-colony actor, producing a replacement job that
## can never run. Used only by _resume_paused_job() re-deriving a fresh route
## after a need or combat interrupt releases a colonist.
## Always is_first=true (_resume_paused_job() only ever calls this for a
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
	var bounds_max := Vector2i(_width - 1, _height - 1)
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
		var cost := _passable_for_faction(tile, faction_id)
		if tile == target and cost <= 0.0:
			return 1.0
		return cost

## A rescue job's own route cost: every
## trench tile is impassable (a rescuer must never be routed into the very
## hazard it is relieving, whichever trench it is), and the target gets none
## of _routable_to()'s impassable-target exception -- a rescue target is an
## ordinary passable tile the rescuer must actually stand on, so a target
## made impassable since commit must read as unreachable (and retire the
## commitment) rather than let the executor trim the last step and start
## work one tile off. Used by every re-route of an active rescue
## (_toil_go_to_passable()) and by a resume after an interrupt
## (_resume_paused_rescue()); the giver's own commit-time search stays on the
## unrestricted _routable_to() so it validates the exact path the
## scheduler's activation will compute. `target` is unused on purpose (kept
## for hook-signature symmetry with _routable_to()).
func _rescue_routable_to(_target: Vector2i, faction_id: String = "colony") -> Callable:
	return func(tile: Vector2i) -> float:
		return 0.0 if _is_trench_tile(tile) else _passable_for_faction(tile, faction_id)

## is_trench callable for RescueGiver.
func _is_trench_tile(tile: Vector2i) -> bool:
	return get_tile(tile.x, tile.y) == TILE_TRENCH

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
		_place_new_ground_item(String(entry["kind"]), int(entry["count"]), int(colonist["x"]), int(colonist["y"]))
	InventoryType.clear_hands(colonist)

## Drops a haul/build job's carried item at the shared terminal boundary
## (cancel/fail/invalidate commands, an unreachable second leg, a refused
## build completion): the live-assignment path first, where job_id still
## names a worker; otherwise the suspended-owner path --
## a job paused by a critical-need interrupt is only recorded in
## _paused_jobs, so its carrier is resolved there and deposits the cargo
## without touching its route/work, which now belong to the need job driving
## it. The pause entry is cleared too: the job is about to be terminal, so
## there is nothing left to resume.
func _drop_carried_haul_item(job_id: String) -> void:
	var colonist := _find_job_colonist(job_id)
	if not colonist.is_empty():
		_drop_carried_item_from(colonist)
		return
	for colonist_id in _paused_jobs.keys():
		if String(_paused_jobs[colonist_id]) != job_id:
			continue
		_paused_jobs.erase(colonist_id)
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
## work-in-progress-key reader (_trap_actor(), _apply_job_command()'s
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
		return func(tile: Vector2i) -> float: return _passable_for_faction(tile, faction_id)
	# A rescuer's every re-route (a
	# corridor blocked mid-travel, a resume after a need interrupt) runs under
	# rescue's own trench-excluding, no-target-exception passability, so it
	# can never be routed through a trench nor trimmed to start work off-target.
	if String(job["kind"]) == "rescue":
		return _rescue_routable_to(target, faction_id)
	return _routable_to(target, faction_id) if is_first or String(job["kind"]) != "haul" else _is_passable

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
## tick's or an earlier hop's _resolve_freshly_activated_site_fetch_sources()/
## _toil_on_pick_up_success() has ever retargeted away from
## GlobalAssignment's own precomputed path (_site_fetch_source_retargeted)
## must also run the same fresh bounded search every later hop already uses,
## rather than walking a path toward a target this leg no longer targets.
func _toil_go_to_skip_assignment_path(job: Dictionary) -> bool:
	var kind := String(job.get("kind", ""))
	if kind == "site_work":
		return true
	return kind == "site_fetch" and _site_fetch_source_retargeted.has(String(job.get("id", "")))

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
		_retire_rescue_job(job_id, job)
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
	return _sites.find_at_origin(job["site"])

## pick_up_count_for hook (construction sites, extended for the hands-filling
## rules and chained delivery): clamps a site_fetch pick_up to what the
## current target site still needs of that source's own kind
## (ConstructionSiteTable.remaining()), plus every other reachable,
## still-short, not-already-at-capacity sibling site's own remaining need of
## the same kind (_reachable_short_sibling_sites(): sized so a hands-load can
## actually carry enough to chain onto more than one block, not just the site
## job["site"] currently names -- see _toil_on_deposit_success() below, the
## other half of this design; a sibling already holding its own max_builders
## worth of queued-or-active fetch-plus-work jobs, per _site_fetch_work_busy(),
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
	var item := _item_lookup(String(job.get("item_id", "")))
	if item.is_empty():
		return -1
	var kind := String(item.get("kind", ""))
	# Cached for _toil_on_pick_up_success(): the
	# pick_up this count gates for may exhaust and delete item's own entry
	# from _items entirely, so that hook cannot re-derive kind the same way
	# once it runs.
	_site_fetch_picked_kind[String(job.get("id", ""))] = kind
	var site := _sites.get_site(site_id)
	var need := _sites.remaining(site, kind)
	var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
	for sibling in _reachable_short_sibling_sites(colonist, kind, current, site_id):
		need += _sites.remaining(sibling, kind)
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
	var site := _sites.get_site(site_id)
	# Not _item_lookup(job["item_id"]): a pick_up that exactly
	# exhausts its source's remaining count deletes that item from _items
	# before this hook ever runs (ToilExecutor.pick_up()'s own _remove_item
	# call), which would silently resolve kind as "" here instead -- see
	# _site_fetch_picked_kind's own doc comment.
	var kind := String(_site_fetch_picked_kind.get(job_id, ""))
	var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
	if (InventoryType.count_of_kind(colonist, kind) >= _sites.remaining(site, kind)
			or InventoryType.free_capacity(colonist) <= 0):
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var next_id := _next_site_fetch_source(colonist, job, kind, current)
	if next_id.is_empty():
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var next_item := _item_lookup(next_id)
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
	_site_fetch_source_retargeted[job_id] = true

## on_toil_fail hook: pick_up/place/deposit are haul-shaped (haul, site_fetch),
## so a failed one always permanently fails the job. A failed consume belongs
## to a need job instead: no carried item to drop, and NeedGiver must hear
## about the resolution.
func _toil_on_toil_fail(job_id: String, reason: String) -> void:
	var job := _get_job(job_id)
	if _need_kind_for_job(String(job.get("kind", ""))).is_empty():
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
## sibling site exists (_next_site_fetch_site(), the same deterministic
## route-cost search _next_site_fetch_source() uses for sources, applied to
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
## `_site_fetch_picked_kind` cache is never saved and is empty right after a
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
		var next_site := _next_site_fetch_site(colonist, kind, current, delivered_site_id)
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
	# ADR 026: arrival and this work toil's completion can land in the same
	# tick (a wait_ticks=1 job targeting a trench); trapping must preempt the
	# completion effect/despawn below, so this runs first. _trap_tile_before
	# != target excludes an actor already standing on a target that merely
	# changed kind; requiring its actual position on target too rejects a
	# stale one (a paused job resumed adjacent). escape_trench falls through.
	if String(job.get("kind", "")) != "escape_trench" and _trap_tile_before != target and get_tile(target.x, target.y) == TILE_TRENCH:
		var arriving_actor := _find_job_colonist(job_id)
		if not arriving_actor.is_empty() and arriving_actor.get("trapped") == null \
				and Vector2i(int(arriving_actor["x"]), int(arriving_actor["y"])) == target \
				and _actor_traps_on_trench(arriving_actor):
			_trap_actor(arriving_actor, job_id, _trap_tile_before)
			return
	var tile_before: String = _tiles[_tile_index(target.x, target.y)]
	match job["kind"]:
		"dig":
			if get_tile(target.x, target.y) != TILE_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tiles[_tile_index(target.x, target.y)] = TILE_TRENCH
			var sand_at := _dig_item_placement(target.x, target.y)
			_spawn_item("sand", sand_at.x, sand_at.y)
			_pending_dig_finds.append({"job_id": job_id, "x": target.x, "y": target.y})
		"chop":
			_tiles[_tile_index(target.x, target.y)] = TILE_FLOOR
			_spawn_wood_item(target.x, target.y)
		"mine":
			if get_tile(target.x, target.y) != TILE_ROCK:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tiles[_tile_index(target.x, target.y)] = TILE_FLOOR
			_spawn_stone_item(target.x, target.y)
		"forage":
			_tiles[_tile_index(target.x, target.y)] = TILE_FLOOR
			_set_object(target.x, target.y, "")
			_spawn_berries_item(target.x, target.y)
		"till":
			if get_tile(target.x, target.y) != TILE_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tiles[_tile_index(target.x, target.y)] = TILE_PLOWED_SOIL
		"sow":
			if get_tile(target.x, target.y) != TILE_PLOWED_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			if not _remove_one_item_of_kind("seed"):
				# Seed was consumed by another sow/haul after this job committed.
				_scheduler.queue.set_pending_fail_reason(job_id, "blocked_missing_input", "resubmit_order")
				_finish_job(job_id, "fail_job")
				return
			_tiles[_tile_index(target.x, target.y)] = TILE_PLANTED
		"site_work":
			# Every builder's own site_work job adds one tick of
			# progress per tick it works (ConstructionSiteTable.add_progress(),
			# not a private per-job counter -- this final tick included, the
			# ones before it via _set_work_progress()'s own site_work branch),
			# so the mechanism already sums correctly for more than one
			# concurrent builder.
			# Once accumulated progress meets the site's own declared
			# build_ticks, _finalize_construction_site() places the declared
			# object, releases the site's footprint reservation, and removes
			# the site record.
			var site_id := _sites.find_at_origin(target)
			if not site_id.is_empty():
				var progress := _sites.add_progress(site_id, 1)
				var site := _sites.get_site(site_id)
				if progress >= int(site["build_ticks"]):
					_finalize_construction_site(site_id, job_id)
		"sleep":
			var colonist := _find_job_colonist(job_id)
			if not colonist.is_empty():
				_apply_need_effect(colonist, job)
		"escape_trench":
			var actor := _find_job_colonist(job_id)
			if not actor.is_empty():
				var trapped_state: Dictionary = actor.get("trapped", {})
				var from_tile: Vector2i = trapped_state.get("fromTile", target)
				var actor_faction := String(actor.get("factionId", "colony"))
				var exit_tile := _trench_exit_tile(target, from_tile, actor_faction)
				if exit_tile.x >= 0:
					actor["x"] = exit_tile.x
					actor["y"] = exit_tile.y
					actor["trapped"] = null
				else:
					# Recoverable blocked-exit outcome: stays trapped, retries.
					_submit_trench_escape(actor, target)
		"rescue":
			var rescuer := _find_job_colonist(job_id)
			var victim := _rescue_victim_for_job(job_id)
			if not rescuer.is_empty() and not victim.is_empty():
				victim["x"] = rescuer["x"]
				victim["y"] = rescuer["y"]
				victim["trapped"] = null
	if _tiles[_tile_index(target.x, target.y)] != tile_before:
		_update_water_tile_cache(target.x, target.y, tile_before == TILE_WATER, _tiles[_tile_index(target.x, target.y)] == TILE_WATER)
		_mark_dirty(target.x, target.y)
		_get_regions().on_passability_changed(target.x, target.y)
		_get_rooms().on_passability_changed(target.x, target.y)
	_finish_job(job_id, "complete_job")
	_resolve_giver_association(job_id, String(job["kind"]))

## rescue's on_work_complete effect: the trapped, rescuable
## colonist this specific job_id was actually committed to rescue, read from
## RescueGiver's own victim_for_job() -- never
## guessed by scanning for "the first trapped colonist adjacent to target,"
## which picks the wrong victim whenever two different trapped colonists are
## each cardinally adjacent to this same target tile. When the assigned
## victim no longer exists or is no longer trapped (it
## died, or something else already freed it), this returns {} rather than
## falling back to an arbitrary adjacent trapped colonist -- substituting one
## could steal a different victim's own, already-claimed rescue (that other
## victim's own job still holds its own "trapped:" key and RescueGiver
## association untouched). The caller's own unconditional _finish_job()/
## _resolve_giver_association() below still resolve this job through the
## ordinary cleanup boundary either way, releasing its reservations and
## freeing the rescuer to resume its own interrupted work -- an obsolete
## rescue is simply retired, never redirected onto a victim it was never
## committed to.
func _rescue_victim_for_job(job_id: String) -> Dictionary:
	var victim_id := _rescue_giver.victim_for_job(job_id)
	if victim_id.is_empty():
		return {}
	var victim := _find_colonist(victim_id)
	if victim.is_empty() or victim.get("trapped") == null:
		return {}
	return victim

## Tells whichever job-giver owns job_id (NeedGiver for a need job, RescueGiver
## for a rescue job) that it resolved -- shared by _toil_on_work_complete()'s
## own completion path, _trap_actor(), _cancel_job_for_death() and
## _resolve_refused_reservations(), everywhere a job terminates outside its
## giver's own advance()/resolve_job() call.
func _resolve_giver_association(job_id: String, kind: String) -> void:
	if not _need_kind_for_job(kind).is_empty():
		_need_giver.resolve_job(job_id)
	elif kind == "rescue":
		_rescue_giver.resolve_job(job_id)
	elif kind == "site_work":
		_release_site_builder(job_id)

## on_consume_success hook (eat_food/drink_water): restores the need,
## finishes the job, and tells NeedGiver this resolved so a paused colonist
## resumes.
func _toil_on_consume_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var colonist := _find_job_colonist(job_id)
	if not colonist.is_empty():
		_apply_need_effect(colonist, job)
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

## (x, y)'s own footprint origin -- (x, y) itself unless it is a
## non-origin tile of a multi-tile object (_object_origin), letting any
## footprint tile find the whole object's origin.
func _object_origin_at(x: int, y: int) -> Vector2i:
	return _object_origin.get(_object_key(x, y), Vector2i(x, y))

## Kind's own [w, h] footprint size (content/objects.json's
## "footprint", default [1, 1] for a defensive lookup miss -- real content
## always declares it, per objects.schema.json's required field), with width
## and height swapped when orientation is "vertical" and kind declares
## "rotatable" true. A non-rotatable kind or an empty/"horizontal"
## orientation always keeps the declared [w, h] as-is.
func _object_footprint_size(kind: String, orientation: String) -> Vector2i:
	var definition: Dictionary = _object_definitions.get(kind, {})
	var footprint: Array = definition.get("footprint", [1, 1])
	var width := int(footprint[0])
	var height := int(footprint[1])
	if orientation == "vertical" and bool(definition.get("rotatable", false)):
		return Vector2i(height, width)
	return Vector2i(width, height)

## Every tile kind occupies starting at origin under orientation,
## in row-major order (origin itself always first) -- the one place both
## _set_object() and place_object's footprint validation compute this, so
## they can never disagree about which tiles a placement touches.
func _object_footprint_tiles(kind: String, origin: Vector2i, orientation: String) -> Array[Vector2i]:
	var size := _object_footprint_size(kind, orientation)
	var tiles: Array[Vector2i] = []
	for dy in size.y:
		for dx in size.x:
			tiles.append(Vector2i(origin.x + dx, origin.y + dy))
	return tiles

## Internal mutator: not exposed publicly. Called by
## _apply_place_object_command()/_apply_remove_object_command() (and directly
## by tests). A tile holds at most one *logical* object, now possibly
## spanning kind's whole footprint (ADR 039): every
## occupied tile carries the same kind/faction_id/health, and orientation is
## recorded once at origin (x, y) (meaningful only when kind declares
## "rotatable" true). Clearing at (x, y) (kind "") erases the *whole*
## existing object there, found via _object_origin_at() so this works from
## any of its footprint tiles, not just its origin -- and a bare/no-object
## (x, y) still marks/invalidates exactly that one tile, matching this
## function's single-tile behaviour byte-for-byte for every existing footprint
## [1,1] kind. faction_id/orientation default to "colony"/"" so every
## existing 3-arg caller keeps placing colony-owned, unrotated objects.
func _set_object(x: int, y: int, kind: String, faction_id: String = "colony", orientation: String = "") -> void:
	var origin := Vector2i(x, y)
	var origin_key := _object_key(x, y)
	var existing_origin := _object_origin_at(x, y)
	var existing_origin_key := _object_key(existing_origin.x, existing_origin.y)
	var existing_kind := String(_objects.get(existing_origin_key, ""))
	var clear_tiles: Array[Vector2i] = [origin]
	if not existing_kind.is_empty():
		clear_tiles = _object_footprint_tiles(existing_kind, existing_origin, String(_object_orientation.get(existing_origin_key, "")))
		_object_orientation.erase(existing_origin_key)
	for tile in clear_tiles:
		var clear_key := _object_key(tile.x, tile.y)
		_objects.erase(clear_key)
		_object_factions.erase(clear_key)
		_object_health.erase(clear_key)
		_object_origin.erase(clear_key)
		_mark_dirty(tile.x, tile.y)
		_get_regions().on_passability_changed(tile.x, tile.y)
		_get_rooms().on_passability_changed(tile.x, tile.y)
	if kind.is_empty():
		return
	var definition: Dictionary = _object_definitions.get(kind, {})
	for tile in _object_footprint_tiles(kind, origin, orientation):
		var key := _object_key(tile.x, tile.y)
		_objects[key] = kind
		_object_factions[key] = faction_id
		if key != origin_key:
			_object_origin[key] = origin
		_mark_dirty(tile.x, tile.y)
		_get_regions().on_passability_changed(tile.x, tile.y)
		_get_rooms().on_passability_changed(tile.x, tile.y)
	if definition.has("max_health"):
		_object_health[origin_key] = {"hp": int(definition.get("health", definition["max_health"])), "maxHp": int(definition["max_health"])}
	else:
		_object_health.erase(origin_key)
	if not orientation.is_empty():
		_object_orientation[origin_key] = orientation

## {} for a bare tile, a tile whose object declares no
## health/max_health (content/objects.json), or a not-yet-placed one --
## CombatTargeting's own "does this object have health" check. Resolved
## through _object_origin_at() so every footprint tile of a
## multi-tile object reports the same, single canonical health pool (health
## is stored once, at the object's origin tile).
func _object_health_at(x: int, y: int) -> Dictionary:
	var origin := _object_origin_at(x, y)
	return (_object_health.get(_object_key(origin.x, origin.y), {}) as Dictionary).duplicate()

## Applies `amount` damage to the object occupying (x, y), clearing
## it (a wall becomes floor, rule 3) once its hp reaches 0 -- through the same
## _set_object() every other object mutation uses, so regions/rooms/dirty-cell
## bookkeeping stays correct. A no-op for a tile with no health-bearing object.
## Resolved through _object_origin_at() so damage landing on any
## footprint tile of a multi-tile object updates the one shared health pool
## and, at zero, clears the whole footprint via _set_object() at the origin.
func _damage_object(x: int, y: int, amount: int) -> void:
	var origin := _object_origin_at(x, y)
	var key := _object_key(origin.x, origin.y)
	if not _object_health.has(key):
		return
	var health: Dictionary = _object_health[key]
	health["hp"] = maxi(0, int(health["hp"]) - amount)
	if int(health["hp"]) <= 0:
		_set_object(origin.x, origin.y, "")

## Appends to the dirty-cell log -- see _dirty_cells' own doc
## comment above. Duplicates are left in (a tile dug then immediately built
## on is two real changes); get_dirty_cells() callers key their own consumed
## index by Array size, exactly like get_events(), so a duplicate costs one
## harmless extra touch, never a missed one.
func _mark_dirty(x: int, y: int) -> void:
	_dirty_cells.append(Vector2i(x, y))

## Every cell whose tile kind or object changed, in the order it changed,
## since this world was created -- an append-only log, never cleared, for a
## presentation layer's incremental refresh. Mirrors get_events()'s own
## append-only/never-drained contract (a viewer-purity rule permits only
## get_*/apply/tick/get_events from game/scripts/viewer/*.gd, so this
## cannot be a clear-on-read "drain"): a caller tracks how much of this
## Array it has already consumed, exactly as map_view.gd does.
func get_dirty_cells() -> Array[Vector2i]:
	return _dirty_cells.duplicate()

func _get_regions() -> RegionMapType:
	if _regions == null:
		_regions = RegionMapType.new(_width, _height, func(x, y): return passability(x, y)["passable"])
	return _regions

func _get_water_tiles() -> Array[Vector2i]:
	if not _water_tile_cache_built:
		for y in _height:
			for x in _width:
				if _tiles[_tile_index(x, y)] == TILE_WATER:
					_water_tile_cache.append(Vector2i(x, y))
		_water_tile_cache_built = true
	return _water_tile_cache

## Keeps _water_tile_cache in sync with any authoritative tile mutation that
## changes a tile's water membership (forage can legally clear
## a berry_bush placed on a TILE_WATER tile via a supported place_object
## command, converting that water tile to TILE_FLOOR in _toil_on_work_complete()
## above -- an unrefreshed cache would keep offering that former water tile as
## a "water" need candidate forever after). Hooked into the same "tile
## actually changed kind" boundary that already drives the dirty-cell/region/
## room updates, not a special case for forage: any future tile-mutating toil
## gets this for free. A no-op while the cache has never been built (the next
## _get_water_tiles() call will scan current _tiles and see the change itself).
func _update_water_tile_cache(x: int, y: int, was_water: bool, is_water: bool) -> void:
	if not _water_tile_cache_built or was_water == is_water:
		return
	if is_water:
		_water_tile_cache.append(Vector2i(x, y))
	else:
		var index := _water_tile_cache.find(Vector2i(x, y))
		if index != -1:
			_water_tile_cache.remove_at(index)

func _get_rooms() -> RoomMapType:
	if _rooms == null:
		_rooms = RoomMapType.new(_width, _height, func(x, y): return passability(x, y)["passable"],
			func(x, y): return bool(passability(x, y)["is_door"]), func(x, y): return get_object(x, y) == "bed",
			_is_in_any_zone)
	return _rooms

## {} for a tile with no recognised room; otherwise RoomMapType.get_room_at().
func get_room_at(x: int, y: int) -> Dictionary:
	return _get_rooms().get_room_at(x, y)

## JSON-safe key for _objects, mirroring _ground_item_key.
func _object_key(x: int, y: int) -> String:
	return "%d_%d" % [x, y]

## Namespaces a tile into the shared ReservationTable's generic String key
## space (colonist-ai.md 3.4), distinct from JobQueue's own "tile:" target
## keys, for is_cell_free()'s per-cell free/reserved lookup.
func _cell_key(x: int, y: int) -> String:
	return "cell:%d,%d" % [x, y]

## Backfills every declared need kind to full and every declared labour kind
## to its default on any colonist missing either (a hand-built test fixture
## that skips _spawn_colonists()). Idempotent. A colonist missing needs
## and/or labourTable is rebuilt key-by-key in _spawn_colonists()'s own field
## order, not appended, since state_hash() hashes JSON.stringify(_colonists),
## sensitive to key insertion order. Missingness is checked with has()
## alongside the ActorTable accessor (ADR 012) because get_component()'s
## "worker" wrapper defaults an absent labourTable to {}, masking absence as
## presence; the rebuild carries "factionId" forward too.
func _ensure_needs() -> void:
	for i in _colonists.size():
		var colonist: Dictionary = _colonists[i]
		# A generic actor (wolf/trader) never declares "worker" (F5), so labour_table_missing would read permanently true and rebuild it into this colonist-only shape every tick, dropping its own fields -- skip any actor without a worker component.
		if not ActorTableType.has_component(colonist, "worker", _content):
			continue
		var needs_component = ActorTableType.get_component(colonist, "needs", _content)
		var worker_component = ActorTableType.get_component(colonist, "worker", _content)
		var health_component = ActorTableType.get_component(colonist, "health", _content)
		var accumulator_component = colonist.get("needsAccumulator")
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
				"route": _route(colonist),
				"work": colonist.get("work"),
				"hands": colonist.get("hands", []),
				"trapped": colonist.get("trapped"), # unconditional, never dropped by this repair
				"held_tool": worker_component["held_tool"] if worker_component is Dictionary else "",
				"factionId": String(colonist.get("factionId", "colony")) }
			if not health_missing:
				colonist["health"] = health_component
			_colonists[i] = colonist
		var needs: Dictionary = _needs(colonist)
		for kind in _need_definitions.keys():
			if not needs.has(kind):
				needs[kind] = _need_full
		var accumulator: Dictionary = colonist.get("needsAccumulator", {})
		for kind in _need_definitions.keys():
			if not accumulator.has(kind):
				accumulator[kind] = 0
		var labour_table: Dictionary = _labour_table(colonist)
		var defaults := _default_labour_table()
		for kind in defaults.keys():
			if not labour_table.has(kind):
				labour_table[kind] = defaults[kind]

## A colonist dict missing "held_tool" (an older fixture) never held a
## tool: backfilled to "" in place, always a plain append (never a rebuild
## like _ensure_needs()) so state_hash()'s key insertion order matches a
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
## _ensure_needs() already backfill a component ActorTable's own special-cased
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

## Backfills a missing `_object_health` entry for any placed object
## whose kind declares `max_health` (content/objects.json). StateCodec.decode()
## now restores a save's own persisted per-object hp/maxHp directly (its
## "health" field, optional so an older save that predates it simply
## omits it) -- this backfill only ever fires for such an older save, or a
## hand-built fixture that calls `_objects[key] = kind` directly instead of
## through `_set_object()`, mirroring `_ensure_health()`/`_ensure_combat()`'s
## own backfill idiom for a component a restore path does not build. Resets to
## the object's own full/default health, the only truthful value for a save
## that never tracked per-instance damage in the first place.
func _ensure_object_health() -> void:
	for key in _objects.keys():
		if _object_origin.has(key):
			continue
		if _object_health.has(key):
			continue
		var kind := String(_objects[key])
		var definition: Dictionary = _object_definitions.get(kind, {})
		if not definition.has("max_health"):
			continue
		_object_health[key] = {"hp": int(definition.get("health", definition["max_health"])), "maxHp": int(definition["max_health"])}

## F5 combat (ADR 021): run once per tick before the fair scheduler sees any colonist. Resolves attacks
## (rule 1) via CombatResolver, applies its reported deaths (rule 2) against
## this WorldState's own owned state (job/reservation cleanup, dropping
## inventory, removal from scheduling), then lets CombatGiver decide whether
## any actor now below its own flee_hp_fraction should start a `flee` job
## (rule 4) -- per ADR 011, WorldState calls both, implements neither.
func _apply_combat(tick: int) -> void:
	var result := CombatResolverType.resolve_tick(_colonists, _content, _relations, tick, PRIORITY_TICK,
		get_object, _object_health_at, get_object_faction_id, _damage_object, _insert_event, _next_sequence)
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
## The paused job (if any) is captured and detached from _paused_jobs before
## the active assignment is cancelled: cancelling an active
## need job below calls NeedGiver.resolve_job() -> _resume_interrupted_job(),
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
	if _paused_jobs.has(colonist_id):
		paused_job_id = String(_paused_jobs[colonist_id])
		_paused_jobs.erase(colonist_id)
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
		_clear_terminated_job_progress(job_id, job, false)
	_resolve_giver_association(job_id, String(job.get("kind", "")))

## restrict_to_for()'s own restriction, falling back to the raw waiting-queue
## entry (GlobalAssignment.get_waiting()) for a job that has never yet been
## activated: restrict_to_for() only reads _activated_entries, "" by its own
## documented contract for a not-yet-activated job_id, which would otherwise
## let a freshly submitted, still-queued job restricted to a just-killed
## actor (a flee job submitted the same tick it died, say) survive
## _apply_actor_death()'s cleanup below.
func _job_restricted_to(job_id: String) -> String:
	var restrict_to := _scheduler.restrict_to_for(job_id)
	if not restrict_to.is_empty():
		return restrict_to
	for entry in _scheduler.get_waiting():
		if String(entry.get("id", "")) == job_id:
			return String(entry.get("restrict_to", ""))
	return ""

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
		_place_new_ground_item(String(entry["kind"]), int(entry["count"]), x, y)
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
## _place_ground_item() as an ordinary stack, same as before. Tools carry
## identity, never a count, so a tool entry of `count` N spawns N separate
## ground tools (one spawn per entry would silently lose N-1).
func _drop_inventory_item(kind: String, count: int, x: int, y: int) -> void:
	if is_tool_kind(kind):
		for _unit in count:
			spawn_ground_tool_item(kind, x, y)
		return
	var item_id: String = "item_%d" % _next_item_id
	_next_item_id += 1
	_place_ground_item(item_id, kind, count, x, y)

## Decays needs (ActorNeeds.apply_tick(), ADR 012/024) by _need_definitions'
## rate_per_day (content/needs.json -- the mutable source _isolate_need()
## relies on, not actors.json's own copy) applied through a per-colonist,
## per-need integer accumulator against the calendar's day_length_ticks, and
## re-clamps health (ActorHealth.apply_tick(), a no-op on hp today).
func _decay_needs() -> void:
	_ensure_needs()
	_ensure_health()
	_ensure_combat()
	_ensure_object_health()
	var rates: Dictionary = {}
	for kind in _need_definitions.keys():
		rates[kind] = int(_need_definitions[kind].get("rate_per_day", 0))
	var needs_tunables := {"rates": rates, "day_length_ticks": _calendar.day_length_ticks()}
	for colonist in _colonists:
		NeedsType.apply_tick(colonist, needs_tunables)
		HealthType.apply_tick(colonist)

## --- Needs decision layer (colonist-ai.md 3.1) -----------------------------
## When a need job exists is decided entirely by NeedGiver, called once per
## tick before the fair scheduler sees any colonist. What remains here is need
## *state* (decay, above) and the WorldState-only concerns NeedGiver cannot
## resolve: pausing/resuming a colonist's `work` toil around a critical
## interrupt, kind-aware source lookups/effects, and the "tile:" reservation key.

## Interrupts a colonist's in-progress `work` toil for a critical need
## (colonist-ai.md 3.6): clears colonist.work and remembers the job to resume
## later. When work is already null (a toil boundary, e.g. haul idling
## between pick_up/place), the job is read off the scheduler assignment
## instead. A no-op when the colonist holds no assignment.
func _pause_work_job(colonist: Dictionary) -> void:
	var colonist_id: String = colonist["id"]
	var work = colonist.get("work")
	if work != null:
		_paused_jobs[colonist_id] = String(work["job_id"])
		_suspend_work_progress(work)
		colonist["work"] = null
		return
	var assignment = _scheduler.get_assignments().get(colonist_id)
	if assignment != null:
		_paused_jobs[colonist_id] = String(assignment["job_id"])

## Sends a colonist back to the job _pause_work_job() paused for it. Returns
## the job_id to resume the scheduler assignment for, or "" when nothing is
## left to resume. While still on the first go_to leg (carrying null), this
## re-derives a fresh route rather than reusing start_assignment()'s
## short-path shortcut, which would wrongly treat a colonist that walked away
## and back as arrived. A no-op if the paused job no longer exists or reached
## a terminal status.
func _resume_paused_job(colonist: Dictionary) -> String:
	var colonist_id: String = colonist["id"]
	if not _paused_jobs.has(colonist_id):
		return ""
	var job_id: String = String(_paused_jobs[colonist_id])
	_paused_jobs.erase(colonist_id)
	var job := _scheduler.queue.get_job(job_id)
	if job.is_empty() or String(job.get("status", "")) not in ["active", "queued"]:
		return ""
	if String(job.get("kind", "")) == "rescue":
		return _resume_paused_rescue(colonist, job_id, job)
	# A needs_tool job whose tool is no longer satisfied (released on
	# interrupt, then reserved or physically taken by someone else while
	# paused) must defer entirely to ToilExecutor's own
	# fetch_tool -> go_to -> work sequence: starting a route toward the job
	# target (or the work timer) here first would leave stale route/work
	# state for _advance_fetch_tool() to wrongly reuse as its own travel leg
	# once advance() runs this same colonist. Route/work stay null (already
	# cleared by _pause_work_job()); the next advance() call re-derives
	# everything through _tool_satisfied()/_advance_fetch_tool().
	if _toils.needs_fetch_tool(colonist, job, job_id):
		colonist["route"] = null
		return job_id
	if InventoryType.is_carrying(colonist):
		return job_id
	var target: Vector2i = job["target"]
	if _colonist_within_reach(colonist, target):
		# is_first=true (guaranteed by the not-carrying check above): only
		# start the work timer when this leg genuinely leads into it
		# (ToilExecutor.leads_into_work()) -- a haul/build leg whose own next
		# toil is pick_up must defer to the ordinary advance() dispatch on the
		# next tick instead (checking for "work" in toils alone would wrongly
		# start build's work timer here too, before pick_up ever ran).
		if _toils.leads_into_work(String(job["kind"]), true):
			_toils.start_work(colonist, job_id)
		return job_id
	colonist["route"] = null
	_advance_go_to_or_resubmit(colonist, job_id, job, target)
	if String(_scheduler.queue.get_job(job_id).get("status", "")) not in ["active", "queued"]:
		return ""
	return job_id

## Rescue-specific resume, budgeted like every other re-route: a need interrupt can walk the rescuer across
## the victim's own trench, or leave it one tile off the exact adjacent tile
## RescueGiver's own commit-time search verified safe. Re-derives the route
## from the colonist's current position through the toil executor's own
## bounded, multi-tick re-route (ToilExecutor.advance_go_to(), honouring the
## shared per-colonist _route_budget like every other job -- never a
## synchronous search run to completion) under rescue's own trench-excluding,
## no-target-exception _rescue_routable_to(): the rescuer can therefore never
## be sent through a trench, and must reach exactly the target -- never a
## merely Chebyshev-adjacent tile like the generic path above -- before work
## can start. Never starts the work toil directly here (unlike the generic
## path): rescue's own target can be shared by another rescue job, so its
## reservation may not be reacquired yet at this point in the resume sequence
## (_resume_interrupted_job() calls this before resume_assignment()
## reactivates it) -- deferring to the ordinary tick path is what keeps
## _work_progress_key()'s own reservation-owner scoping correct here. An
## unreachable commitment (no trench-free route at all) is retired through
## _retire_rescue_job() -- immediately when the executor proves it so in
## its first budgeted step, or later through the ordinary on_unreachable
## hook once the retained search finishes -- rather than blindly resubmitted,
## letting a fresh search propose any rescuer/target for the same victim.
func _resume_paused_rescue(colonist: Dictionary, job_id: String, job: Dictionary) -> String:
	var target: Vector2i = job["target"]
	colonist["route"] = null
	if Vector2i(int(colonist["x"]), int(colonist["y"])) == target:
		return job_id
	var passable := _rescue_routable_to(target, String(colonist.get("factionId", "colony")))
	if _toils.advance_go_to(colonist, job_id, target, passable) == "unreachable":
		_retire_rescue_job(job_id, job)
		return ""
	return job_id

## interrupt_current_job callable for NeedGiver (ADR 009): pauses via
## _pause_work_job(), then suspends the scheduler assignment so the fair
## scheduler may offer the now-idle colonist the need job about to be
## searched for. Also releases any tool reservation the paused job holds
## (suspend_assignment() only knows JobQueue's ReservationTable,
## not _tool_store's) so the tool stays usable while the interrupt lasts. A
## no-op when nothing was paused.
func _interrupt_current_job(colonist: Dictionary) -> void:
	var colonist_id: String = colonist["id"]
	_pause_work_job(colonist)
	if not _paused_jobs.has(colonist_id):
		return
	var job_id: String = String(_paused_jobs[colonist_id])
	_tool_store.release_all(job_id)
	_scheduler.suspend_assignment(colonist_id, job_id)

## resume_interrupted_job callable for NeedGiver and CombatGiver's own
## `_resume`: resumes via _resume_paused_job(),
## then restores whatever assignment _interrupt_current_job() suspended via
## resume_assignment() (ADR 009). When something else claimed the target
## while away, that call is a no-op and the job falls to the ordinary
## fair-queue path instead.
##
## Guarded by CombatGiver.owns() first: a need job resolving mid-flee must not
## resume the work _paused_jobs still names (paused by the need interrupt,
## not the combat one -- CombatGiver's own interrupt found nothing new to
## pause) or it would overwrite the actor's current flee assignment,
## orphaning it. Deferring leaves _paused_jobs intact for CombatGiver's own
## recovery branch, which erases its episode before calling this function --
## owns() already false by then, so the deferred resume proceeds normally.
##
## resume_assignment() can fail to
## reactivate (JobQueue.reactivate()/_reactivate_build() returns false when a
## different job claimed the build's site while this one was suspended). A
## haul/build job whose colonist is still physically carrying its cargo must
## stay findable through _paused_jobs afterward -- the same suspended-owner
## path _drop_carried_haul_item() already reads -- or a later
## cancel/fail/invalidate on the now-queued-but-unassigned job would find no
## carrier and strand the cargo in inventory forever. A non-carrying job needs
## no such restoration: it is meant to fall to the ordinary fair-queue path.
func _resume_interrupted_job(colonist_id: String) -> void:
	if _combat_giver.owns(colonist_id):
		return
	var colonist := _find_colonist(colonist_id)
	if colonist.is_empty() or not _paused_jobs.has(colonist_id):
		return
	var job_id := _resume_paused_job(colonist)
	if job_id.is_empty():
		return
	_scheduler.resume_assignment(colonist_id, job_id)
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("status", "")) == "active":
		return
	if String(job.get("kind", "")) in ["haul", "site_fetch"] and InventoryType.is_carrying(colonist):
		_paused_jobs[colonist_id] = job_id

## set_reason callable for NeedGiver: writes WorldState's own exposed reason
## cache so get_colonist_need_reason() (and any test/panel that pokes
## _need_status directly) keeps working unchanged.
func _set_need_reason(colonist_id: String, reason: String) -> void:
	_need_status[colonist_id] = reason

## set_reason callable for RescueGiver: writes WorldState's own
## exposed rescue-reason cache, keyed by the trapped victim's colonist_id
## (never the rescuer's), mirroring _set_need_reason() above.
func _set_rescue_reason(colonist_id: String, reason: String) -> void:
	_rescue_status[colonist_id] = reason

## emit_need_unmet callable for NeedGiver (colonist-ai.md 3.1: "the player
## sees it in the panel and the alert list").
func _emit_need_unmet_event(colonist_id: String, kind: String) -> void:
	var reason := "%s%s" % [REASON_NEED_UNMET_PREFIX, kind]
	_insert_event({
		"type": "need_unmet", "tick": _clock.tick, "system_priority": PRIORITY_TICK,
		"entity_id": colonist_id, "sequence": _next_sequence(), "data": {"kind": kind, "reason": reason},
	})

## Matches JobQueue's own "tile:%d,%d" target-key format (colonist-ai.md 3.4).
func _tile_key(x: int, y: int) -> String:
	return "tile:%d,%d" % [x, y]

## Kind-aware lookups (a ground-berries tile for food, TILE_WATER for water, a
## bed object for rest), never in toil_executor.gd or NeedGiver.
func _need_source_candidates(kind: String) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	match kind:
		"food":
			for key in _ground_berries.keys():
				if int(_ground_berries[key]) <= 0:
					continue
				var coords := String(key).split("_")
				candidates.append(Vector2i(int(coords[0]), int(coords[1])))
		"water":
			candidates = _get_water_tiles()
		"rest":
			for key in _objects.keys():
				if String(_objects[key]) == "bed":
					var coords := String(key).split("_")
					candidates.append(Vector2i(int(coords[0]), int(coords[1])))
	return _reachable_candidates_only(candidates)

## Drops candidates NeedGiver's own search could never
## reach: with no early "impossible" signal it flood-fills the whole component
## before giving up, and a far-shore/inaccessible source does not count as a
## guaranteed resource. RegionMap lookup, O(1) each.
func _reachable_candidates_only(candidates: Array[Vector2i]) -> Array[Vector2i]:
	if _colonists.is_empty():
		return candidates
	var regions := _get_regions()
	return candidates.filter(func(candidate):
		return _colonists.any(func(colonist):
			return regions.reachable(Vector2i(int(colonist["x"]), int(colonist["y"])), candidate)))

## claimed_targets callable for NeedGiver, mirroring HaulGiver's own "claimed"
## de-duplication -- without this, two concurrent searches could target the
## same not-yet-reserved candidate (colonist-ai.md 3.4).
func _need_job_targets() -> Dictionary:
	var claimed: Dictionary = {}
	for job in _scheduler.queue.get_jobs():
		if not _need_kind_for_job(String(job["kind"])).is_empty() and job["status"] in ["queued", "active"]:
			claimed[job["target"]] = true
	return claimed

## Reverse of NeedGiver.JOB_KIND_BY_NEED, kept here since only WorldState's own hooks need "which need does this job kind restore".
func _need_kind_for_job(job_kind: String) -> String:
	match job_kind:
		"eat_food": return "food"
		"drink_water": return "water"
		"sleep": return "rest"
		_: return ""

## source_valid callable for _toils's consume() precondition: water never
## runs out; food requires a ground berry still at the target; rest requires
## the bed object still there.
func _consume_source_valid(job_id: String) -> bool:
	var job := _get_job(job_id)
	if job.is_empty():
		return false
	var target: Vector2i = job["target"]
	match String(job["kind"]):
		"eat_food":
			return get_ground_berries(target.x, target.y) > 0
		"drink_water":
			return get_tile(target.x, target.y) == TILE_WATER
		"sleep":
			return get_object(target.x, target.y) == "bed"
		_:
			return false

## Applies a completed need job's kind-specific effect: restoring the need
## (sleep's restore scaled by bedroom_rest_multiplier when the bed sits in a
## recognised bedroom) is common to every kind; decrementing the
## ground-berries counter (dropping the key once it reaches zero) is eat_food-only.
func _apply_need_effect(colonist: Dictionary, job: Dictionary) -> void:
	var need_kind := _need_kind_for_job(String(job["kind"]))
	if need_kind.is_empty():
		return
	var need_def: Dictionary = _need_definitions.get(need_kind, {})
	var restore := float(need_def.get("restore", _need_full))
	if String(job["kind"]) == "sleep":
		var target: Vector2i = job["target"]
		if bool(get_room_at(target.x, target.y).get("has_bed", false)):
			restore *= float(need_def.get("bedroom_rest_multiplier", 1.0))
	var needs: Dictionary = _needs(colonist)
	needs[need_kind] = mini(_need_full, int(restore))
	if String(job["kind"]) == "eat_food":
		var target: Vector2i = job["target"]
		var key := _ground_berries_key(target.x, target.y)
		var remaining := maxi(0, int(_ground_berries.get(key, 0)) - 1)
		if remaining == 0:
			_ground_berries.erase(key)
			_ground_berries_factions.erase(key)
		else:
			_ground_berries[key] = remaining

## Used for a freshly spawned colonist and (via SaveMigrations) a pre-needs
## save's backfill.
func _full_needs() -> Dictionary:
	var needs: Dictionary = {}
	for kind in _need_definitions.keys():
		needs[kind] = _need_full
	return needs

## ActorTable.spawn()'s own default labourTable, off the same content
## tunables -- also used by _ensure_needs()'s backfill above.
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
			return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
		var target := Vector2i(payload["x"], payload["y"])
		# assignee (F3), dig/chop/forage/mine only: carried through
		# submit()'s existing restrict_to (already used by need_giver.gd).
		var assignee := String(payload.get("assignee", "")) if command["type"] in ["dig", "chop", "forage", "mine"] else ""
		result = _scheduler.submit(target, payload.get("priority", 1), _clock.tick, command["type"], assignee)
	else:
		if typeof(payload.get("job_id")) != TYPE_STRING or String(payload["job_id"]).is_empty():
			return _rejection(command["command_id"], command["actor"], "invalid_payload", "A non-empty job_id is required.")
		# Cancelling/failing/invalidating a haul or site_fetch job mid-carry
		# drops the carried item (colonist-ai.md 3.3); "complete_job"
		# already went through the job's own completion effect. A site_work job
		# never carries anything.
		if command["type"] in ["cancel_job", "fail_job", "invalidate_job"]:
			var target_job := _scheduler.queue.get_job(String(payload["job_id"]))
			if String(target_job.get("kind", "")) in ["haul", "site_fetch"]:
				_drop_carried_haul_item(String(payload["job_id"]))
		# Clear work_progress only once the transition succeeds, by the terminating job's own identity (_clear_terminated_job_progress(): an ordinary job's plain tile key only when it was "active" before -- a queued competitor or a rejected/repeated terminal command must never erase another job's progress -- a rescue's own job-scoped key in every status).
		var terminal_job := _scheduler.queue.get_job(String(payload["job_id"]))
		var terminal_was_active: bool = String(terminal_job.get("status", "")) == "active"
		result = _finish_job(payload["job_id"], command["type"])
		if result["ok"] and command["type"] in ["complete_job", "cancel_job", "fail_job", "invalidate_job"]:
			_clear_terminated_job_progress(String(payload["job_id"]), terminal_job, terminal_was_active)
		# Shares _resolve_giver_association() with
		# _toil_on_work_complete()/_trap_actor()/_cancel_job_for_death()/
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
	_collect_queue_events()
	if not result["ok"]:
		return _rejection(command["command_id"], command["actor"], result["rejection"]["reason"], result["rejection"]["remedy"])
	var applied := _applied(command)
	applied["job_id"] = result["job_id"]
	return applied

## build {kind, x, y, orientation} submission (ADR 040, superseding ADR
## 028/038's single-worker `build` job): validates against
## _check_construction_command() -- no stock check at all, unlike the
## superseded job model, since a site is a standing commitment that waits for
## materials rather than a one-shot order requiring them up front (ordering a
## workbench creates its site immediately, before any material arrives)
## -- then creates the site record and reserves every footprint tile
## directly on the shared ReservationTable, owner "site:<id>" (never a job
## id), the instant the order is accepted. No job is submitted here at all:
## ConstructionGiver (world_state.gd's _construction_giver) decides on its own
## per-tick schedule when the site's next fetch/work job should exist.
func _apply_construction_submission(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check := _check_construction_command(payload)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var kind: String = payload["kind"]
	var orientation := String(payload.get("orientation", ""))
	var origin := Vector2i(int(payload["x"]), int(payload["y"]))
	var definition: Dictionary = _object_definitions[kind]
	var site := _sites.create(kind, origin, orientation, definition["build_cost"] as Array,
		int(definition["build_ticks"]), int(definition["max_builders"]))
	var owner := _sites.owner_key(String(site["id"]))
	var table := _scheduler.queue.get_reservation_table()
	for tile in _object_footprint_tiles(kind, origin, orientation):
		table.acquire(_build_site_key(tile), owner)
	var applied := _applied(command)
	applied["site_id"] = site["id"]
	# job_id mirrors site_id (test_order_input.gd): boot.gd's
	# Cancel tool still names a pending order by "job_id" (there is no job to
	# rewire it to yet; see ADR 040), so a site's own
	# id doubles as the value that identifier carries until then. See
	# _apply_cancel_job_command()'s matching fallback below.
	applied["job_id"] = site["id"]
	return applied

## build's complete read-only rule, shared verbatim by apply() (via
## _apply_construction_submission()) and preview(): a non-empty string kind,
## integer x/y and an optional string orientation ("horizontal"/"vertical"),
## no other payload field (invalid_payload); every footprint tile in-bounds,
## passable, empty, non-colonist, non-tree, and not already claimed by another
## site's own footprint reservation (invalid_target -- a site's footprint is
## reserved the instant it is created, so unlike the superseded per-job model
## there is no separate "queued but not yet reserved" commitment to check);
## for a kind whose object definition is itself impassable (a wall or a
## workbench), the existing blocked_target_unreachable reason
## (docs/architecture/orders-and-movement.md) when placing it would strand a
## currently-reachable tile -- never a new reason string. No stock check: a
## site is created regardless of what materials are currently on hand.
func _check_construction_command(payload: Dictionary) -> Dictionary:
	for key in payload.keys():
		if not (key == "kind" or key == "x" or key == "y" or key == "orientation"):
			return {"reason": "invalid_payload", "message": "build accepts only kind, x, y and orientation."}
	if (typeof(payload.get("kind")) != TYPE_STRING or String(payload.get("kind")).is_empty()
			or typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("orientation", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "message": "build requires a non-empty string kind, integer x, y and an optional string orientation."}
	var kind: String = payload["kind"]
	if not _object_definitions.has(kind) or (_object_definitions[kind].get("build_cost", []) as Array).is_empty():
		return {"reason": "invalid_payload", "message": "Unknown or non-buildable object kind '%s'." % kind}
	var orientation := String(payload.get("orientation", ""))
	if not orientation.is_empty() and orientation != "horizontal" and orientation != "vertical":
		return {"reason": "invalid_payload", "message": "orientation must be 'horizontal' or 'vertical'."}
	var origin := Vector2i(int(payload["x"]), int(payload["y"]))
	var footprint_tiles := _object_footprint_tiles(kind, origin, orientation)
	var occupancy_check := _construction_footprint_check(footprint_tiles)
	if not occupancy_check.is_empty():
		return occupancy_check
	if not bool(_object_definitions[kind].get("passable", true)) and _would_enclose_tiles(footprint_tiles):
		return {"reason": "blocked_target_unreachable", "message": "Building here would seal off part of the colony."}
	return {}

## Shared footprint/occupancy rule for one candidate placement's footprint
## tiles -- in-bounds, passable-for-kind, no colonist, no tree, not already an
## object, not already claimed by another order's own footprint reservation.
## Excludes the enclosure check, which a single `build` runs immediately after
## (above) and `build_line` runs once across a whole surviving
## batch instead (_classify_build_line_command()) -- both callers share this
## function so a wall placed one tile at a time and dragged as a line always
## agree on which tiles are occupancy-valid, and on the exact reason string
## returned for one that is not.
func _construction_footprint_check(footprint_tiles: Array[Vector2i]) -> Dictionary:
	var table := _scheduler.queue.get_reservation_table()
	for tile in footprint_tiles:
		if (_colonist_at(tile.x, tile.y) or not get_object(tile.x, tile.y).is_empty()
				or not _build_site_terrain_valid(tile)):
			return {"reason": "invalid_target", "message": "Choose an empty, passable, in-bounds tile with no colonist or tree."}
		if not table.owner(_build_site_key(tile)).is_empty():
			return {"reason": "invalid_target", "message": "Another order already claims this tile."}
	return {}

## build_line's complete read-only classification (ADR 042): shared verbatim
## by apply() (via _apply_build_line_command()) and
## preview() so a drag preview and the actually-applied command always agree
## on which tiles will be skipped and whether the whole batch is rejected.
## Returns {"reason", "message"} to reject the whole command (invalid_payload,
## or blocked_target_unreachable once the enclosure check below runs), or
## {"kind", "orientation", "surviving", "skipped"} otherwise. `tiles` is
## canonicalized into row-major order (lowest y, then lowest x) here --
## never trusting caller order -- and de-duplicated, since two entries naming
## the same tile could otherwise both "survive" (neither one's own footprint
## reservation exists yet during classification) and go on to create two
## overlapping sites in step 5. Each canonical tile is then classified with
## the exact single-tile _construction_footprint_check() rule above (step 3),
## plus a provisional-occupancy check against every earlier surviving tile's
## own footprint in this same batch (`claimed_footprint` below): a kind wider
## than one tile (e.g. workbench's [2,1]) can otherwise have two candidate
## origins whose footprints overlap -- (10,10) and (11,10) both individually
## pass _construction_footprint_check() since neither one's reservation
## exists in the table yet, and without this check both would "survive" and
## _apply_build_line_command() would create two sites sharing tile (11,10)
## with only one of them able to actually acquire it. A later candidate whose
## footprint touches an earlier survivor's claimed footprint is skipped
## invalid_target instead, the same reason a real reservation conflict would
## give. Once every tile is classified, _would_enclose_tiles() runs once
## across the whole surviving set (step 4, only meaningful for an impassable
## kind) -- a hit there discards "skipped" and rejects the entire command.
func _classify_build_line_command(payload: Dictionary) -> Dictionary:
	if typeof(payload.get("kind")) != TYPE_STRING or String(payload.get("kind")).is_empty():
		return {"reason": "invalid_payload", "message": "build_line requires a non-empty string kind."}
	var kind: String = payload["kind"]
	if not _object_definitions.has(kind) or (_object_definitions[kind].get("build_cost", []) as Array).is_empty():
		return {"reason": "invalid_payload", "message": "Unknown or non-buildable object kind '%s'." % kind}
	if typeof(payload.get("orientation", "")) != TYPE_STRING:
		return {"reason": "invalid_payload", "message": "orientation must be 'horizontal' or 'vertical'."}
	var orientation := String(payload.get("orientation", ""))
	if not orientation.is_empty() and orientation != "horizontal" and orientation != "vertical":
		return {"reason": "invalid_payload", "message": "orientation must be 'horizontal' or 'vertical'."}
	if typeof(payload.get("tiles")) != TYPE_ARRAY or (payload["tiles"] as Array).is_empty():
		return {"reason": "invalid_payload", "message": "build_line requires a non-empty array of tiles."}
	var seen := {}
	var canonical: Array[Vector2i] = []
	for entry in (payload["tiles"] as Array):
		if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("x")) != TYPE_INT or typeof(entry.get("y")) != TYPE_INT:
			return {"reason": "invalid_payload", "message": "Every build_line tile requires integer x and y."}
		var tile := Vector2i(int(entry["x"]), int(entry["y"]))
		if not seen.has(tile):
			seen[tile] = true
			canonical.append(tile)
	canonical.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	var surviving: Array[Vector2i] = []
	var skipped: Array[Dictionary] = []
	var claimed_footprint := {}
	for tile in canonical:
		var footprint := _object_footprint_tiles(kind, tile, orientation)
		var occupancy_check := _construction_footprint_check(footprint)
		if not occupancy_check.is_empty():
			skipped.append({"x": tile.x, "y": tile.y, "reason": occupancy_check["reason"]})
			continue
		var overlaps_earlier_survivor := false
		for footprint_tile in footprint:
			if claimed_footprint.has(footprint_tile):
				overlaps_earlier_survivor = true
				break
		if overlaps_earlier_survivor:
			skipped.append({"x": tile.x, "y": tile.y, "reason": "invalid_target"})
			continue
		for footprint_tile in footprint:
			claimed_footprint[footprint_tile] = true
		surviving.append(tile)
	if not surviving.is_empty() and not bool(_object_definitions[kind].get("passable", true)):
		var combined_footprint: Array[Vector2i] = []
		for tile in surviving:
			combined_footprint.append_array(_object_footprint_tiles(kind, tile, orientation))
		if _would_enclose_tiles(combined_footprint):
			return {"reason": "blocked_target_unreachable", "message": "Building this line would seal off part of the colony."}
	return {"kind": kind, "orientation": orientation, "surviving": surviving, "skipped": skipped}

## Applies build_line (ADR 042): creates one
## construction site per _classify_build_line_command()'s surviving tile, in
## the same row-major order, exactly as _apply_construction_submission() does
## for a single tile (footprint reservation, ConstructionSiteTable.create()) --
## atomic at the whole-batch level, since classification (including the one
## enclosure check across the whole surviving set) already ran to completion
## before this loop takes a single reservation.
func _apply_build_line_command(command: Dictionary) -> Dictionary:
	var classification := _classify_build_line_command(command["payload"])
	if classification.has("reason"):
		return _rejection(command["command_id"], command["actor"], classification["reason"], classification["message"])
	var kind: String = classification["kind"]
	var orientation: String = classification["orientation"]
	var definition: Dictionary = _object_definitions[kind]
	var table := _scheduler.queue.get_reservation_table()
	var sites: Array[Dictionary] = []
	for tile in (classification["surviving"] as Array[Vector2i]):
		var site := _sites.create(kind, tile, orientation, definition["build_cost"] as Array,
			int(definition["build_ticks"]), int(definition["max_builders"]))
		var owner := _sites.owner_key(String(site["id"]))
		for footprint_tile in _object_footprint_tiles(kind, tile, orientation):
			table.acquire(_build_site_key(footprint_tile), owner)
		sites.append({"id": site["id"], "x": tile.x, "y": tile.y})
	var applied := _applied(command)
	applied["sites"] = sites
	applied["skipped"] = classification["skipped"]
	return applied

## place_object's complete read-only rule, shared verbatim by
## apply() (via _apply_place_object_command()), preview() and
## CommandChecks.check_place_object_command() (which delegates here rather
## than keeping its own copy) -- mirrors _check_construction_command()'s
## shape above. x/y/kind are exactly as strict as the old CommandChecks.
## check_place_object_command(): integer x, y, a non-empty string kind naming
## a declared object kind. orientation is new and optional: when present it
## must be "horizontal" or "vertical" (invalid_payload otherwise); it is
## otherwise unconsulted here, since _object_footprint_size() already ignores
## it for a non-rotatable kind. Every tile of kind's footprint (default [1,1]
## -- every existing kind today) is checked in bounds, no colonist, no
## existing object, and neither TILE_TREE nor TILE_WATER (the strict,
## build-only _build_site_terrain_valid() would also reject
## TILE_ROCK/TILE_TRENCH/TILE_HAZARD, breaking test_debug_scenario_
## objects.gd, test_faction_doors.gd, test_tool_items.gd and existing
## test_water_cache_invalidation.gd fixtures that all place objects on rock
## through this exact command -- this remains the permissive debug/map-gen
## path _apply_place_object_command()'s own doc comment always described;
## `build` keeps its own separate, stricter _build_site_terrain_valid() call
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
	for tile in _object_footprint_tiles(kind, origin, orientation):
		if (tile.x < 0 or tile.x >= _width or tile.y < 0 or tile.y >= _height
				or _colonist_at(tile.x, tile.y)
				or not get_object(tile.x, tile.y).is_empty()
				or get_tile(tile.x, tile.y) == TILE_TREE
				or get_tile(tile.x, tile.y) == TILE_WATER):
			return {"reason": "invalid_target", "message": "Choose an empty, in-bounds tile with no colonist or tree."}
	return {}

## Terrain a construction site may occupy, checked per footprint tile by
## _construction_footprint_check() (shared by build and build_line):
## in-bounds, passable, and neither TILE_TREE nor TILE_TRENCH. Trench is
## passable=true (ADR 026's own trap-on-entry mechanic needs a colonist able
## to walk onto one), but a freshly dug pit is not valid ground for a
## foundation. place_object deliberately keeps its own, more permissive rule
## (see _check_place_object_command()).
func _build_site_terrain_valid(site: Vector2i) -> bool:
	if site.x < 0 or site.x >= _width or site.y < 0 or site.y >= _height:
		return false
	var tile_kind := get_tile(site.x, site.y)
	if tile_kind == TILE_TREE or tile_kind == TILE_TRENCH:
		return false
	return bool(passability(site.x, site.y)["passable"])

## Namespaces build_target on the same shared ReservationTable a dig/chop/mine/
## till/sow job's own target already uses (JobQueue.TARGET_KEY_PREFIX, "tile:"),
## so a build order and any other job kind correctly contend for the same tile
## through the one existing reservation ledger instead of a second one.
func _build_site_key(build_target: Vector2i) -> String:
	return "%s%d,%d" % [JobQueueType.TARGET_KEY_PREFIX, build_target.x, build_target.y]

## get_construction_sites()/get_construction_site(): every
## currently active site, mirroring get_objects()/get_object() -- detached
## copies, "builder_ids" translated from the internal job-id bookkeeping
## (ConstructionSiteTable.add_builder()/remove_builder() key sites on the
## contributing job's own id, resolvable at every terminal transition even
## after the colonist's own assignment is gone) to the live colonist id
## currently driving each job, for a caller that only cares who is building,
## not which job. A job whose colonist can no longer be found (mid-termination)
## is simply omitted from the translated list.
func _public_site_view(site: Dictionary) -> Dictionary:
	var view := site.duplicate(true)
	var colonist_ids: Array[String] = []
	for job_id in (site["builder_ids"] as Array):
		var colonist := _find_job_colonist(String(job_id))
		if not colonist.is_empty():
			colonist_ids.append(String(colonist["id"]))
	view["builder_ids"] = colonist_ids
	return view

func get_construction_sites() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for site in _sites.list():
		out.append(_public_site_view(site))
	return out

## {} for a tile no site's footprint covers; the whole site record otherwise
## (any of its footprint tiles resolves to the same site, mirroring
## get_object()'s own origin-agnostic per-tile lookup).
func get_construction_site(x: int, y: int) -> Dictionary:
	var id := _construction_site_id_at(x, y)
	if id.is_empty():
		return {}
	return _public_site_view(_sites.get_site(id))

func _construction_site_id_at(x: int, y: int) -> String:
	var tile := Vector2i(x, y)
	for site in _sites.list():
		if _object_footprint_tiles(String(site["kind"]), site["origin"], String(site["orientation"])).has(tile):
			return String(site["id"])
	return ""

## site_exists callable for _toils's deposit toil.
func _construction_site_exists(site_id: String) -> bool:
	return _sites.has(site_id)

## site_deposit callable for _toils's deposit toil: forwards straight to
## ConstructionSiteTable.deposit(), which already clamps to what the site
## still needs and returns the amount actually accepted.
func _construction_site_deposit(site_id: String, item_kind: String, count: int) -> int:
	return _sites.deposit(site_id, item_kind, count)

## reservation_owner callable for ConstructionGiver's own source-selection
## (mirrors the superseded _find_available_build_item()'s reservation check).
func _construction_item_reservation_owner(item_id: String) -> String:
	return _scheduler.queue.get_reservation_table().owner(JobQueueType.ITEM_KEY_PREFIX + item_id)

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

## Every queued/active site_fetch job except `exclude_job_id` (hands-filling
## rules): the orders whose source item is committed but, while
## still queued, not yet reserved -- a still-queued site_fetch job holds no
## live reservation yet (_tick_site_fetch() only acquires one on activation),
## so without this exclusion an already-active job's own on-demand search
## could freely retarget onto the exact item a queued sibling submitted
## against.
func _pending_site_fetch_jobs(exclude_job_id: String = "") -> Array[Dictionary]:
	var pending: Array[Dictionary] = []
	for job in _scheduler.queue.get_jobs():
		if String(job.get("kind", "")) != "site_fetch" or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if String(job["id"]) != exclude_job_id:
			pending.append(job)
	return pending

## The next unclaimed ground-item source of `kind` a site_fetch job should
## visit from colonist's current position `from` (hands-filling
## rules): among every zone-stockpiled item of that kind, either unreserved
## or already reserved to job itself, and not another still-queued/active
## site_fetch job's own committed item (_pending_site_fetch_jobs(), excluding
## job itself), the one with the lowest deterministic route cost from `from`
## via _route_cost() (not open-field Chebyshev -- a close source behind a
## wall must lose to a farther-but-reachable one), unreachable candidates
## skipped, ties broken by lowest item id -- "" when nothing qualifies. A
## pure query: never reserves anything itself (the caller does, once it
## commits to the id returned).
func _next_site_fetch_source(colonist: Dictionary, job: Dictionary, kind: String, from: Vector2i) -> String:
	var table := _scheduler.queue.get_reservation_table()
	var job_id := String(job["id"])
	var faction_id := String(colonist.get("factionId", "colony"))
	var committed := {}
	for other in _pending_site_fetch_jobs(job_id):
		committed[String(other.get("item_id", ""))] = true
	var best_id := ""
	var best_cost := 0
	var ids := _items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = _items[id]
		if String(item["kind"]) != kind:
			continue
		if not _is_in_any_zone(int(item["x"]), int(item["y"])):
			continue
		if committed.has(String(id)):
			continue
		var owner := table.owner(JobQueueType.ITEM_KEY_PREFIX + String(id))
		if not owner.is_empty() and owner != job_id:
			continue
		var tile := Vector2i(int(item["x"]), int(item["y"]))
		var cost := _route_cost(from, tile, faction_id)
		if cost < 0:
			continue
		if not best_id.is_empty():
			if cost > best_cost:
				continue
			if cost == best_cost and String(id) >= best_id:
				continue
		best_id = String(id)
		best_cost = cost
	return best_id

## Every other active construction site still short of `kind`, reachable from
## `from`, and not already holding its own max_builders' worth of committed
## fetch+work jobs (chained delivery: a colonist whose hands still hold units of
## `kind` after delivering to `exclude_site_id` may chain onward to a further
## block instead of completing) -- mirrors _next_site_fetch_source()'s own
## deterministic route-cost ranking (_route_cost(), not open-field Chebyshev),
## applied to sibling sites instead of ground-item sources: sorted by
## ascending cost, ties by lowest site id, unreachable candidates dropped.
## Has no separate item-level exclusion for a site already named by another
## pending (merely-queued) site_fetch job the way _next_site_fetch_source()
## excludes a committed item: eligibility here is already capacity-gated
## below, and that gate is the one that matters. For a max_builders 1 site
## (every wall block), a single queued-or-active job already saturates
## _site_fetch_work_busy() and gets excluded below with no extra rule needed;
## for a max_builders > 1 site, an existing job leaves real spare capacity a
## retarget can legitimately use. (A single stockpile stack backing a whole
## build_line row does not routinely leave every sibling holding a job of its
## own either -- ConstructionGiver._choose_source() commits that stack's item
## id to only the first site whose submission claims it, so most siblings are
## typically job-less, not merely-queued.) ConstructionSiteTable.deposit()'s
## own clamp to remaining() makes two jobs reaching the same site safe either
## way. It does exclude a site already at its own busy cap (a
## retarget bypasses ConstructionGiver.advance()'s own submission-time count
## entirely, so without this check a retarget could push an already-full site
## over max_builders) via _site_fetch_work_busy(), the same fetch-plus-work
## count the giver itself uses.
func _reachable_short_sibling_sites(colonist: Dictionary, kind: String, from: Vector2i, exclude_site_id: String) -> Array[Dictionary]:
	var faction_id := String(colonist.get("factionId", "colony"))
	var scored: Array = []
	for site in _sites.list():
		var site_id := String(site["id"])
		if site_id == exclude_site_id or _sites.remaining(site, kind) <= 0:
			continue
		if _site_fetch_work_busy(site["origin"]) >= int(site["max_builders"]):
			continue
		var cost := _route_cost(from, site["origin"], faction_id)
		if cost < 0:
			continue
		scored.append({"site": site, "cost": cost})
	scored.sort_custom(func(a, b):
		if int(a["cost"]) != int(b["cost"]): return int(a["cost"]) < int(b["cost"])
		return String(a["site"]["id"]) < String(b["site"]["id"]))
	var out: Array[Dictionary] = []
	for entry in scored:
		out.append(entry["site"])
	return out

## Every currently queued/active site_fetch or site_work job already
## committed to `origin`: the identical
## fetch-plus-work "busy" count ConstructionGiver.advance() sums per site
## before topping it up, mirrored here since a chain-onward retarget never
## goes through the giver's own submission path and so is never checked
## against it otherwise.
func _site_fetch_work_busy(origin: Vector2i) -> int:
	var busy := 0
	for job in _scheduler.queue.get_jobs():
		var kind := String(job.get("kind", ""))
		if kind != "site_fetch" and kind != "site_work":
			continue
		if String(job.get("status", "")) in ["queued", "active"] and job.get("site") == origin:
			busy += 1
	return busy

## The single nearest candidate _reachable_short_sibling_sites() returns, or
## {} when none qualifies -- _toil_on_deposit_success()'s own chain-onward
## query.
func _next_site_fetch_site(colonist: Dictionary, kind: String, from: Vector2i, exclude_site_id: String) -> Dictionary:
	var candidates := _reachable_short_sibling_sites(colonist, kind, from, exclude_site_id)
	return candidates[0] if not candidates.is_empty() else {}

## Every currently-active site_fetch job's id (hands-filling rules):
## tick()'s own before/after snapshot around _scheduler.tick(), so
## _resolve_freshly_activated_site_fetch_sources() below can tell which
## site_fetch jobs just (re)activated this tick from the ones that were
## already active and mid-route -- an already-active job is never touched by
## _tick_site_fetch() again (JobQueue.tick() only advances "queued" jobs), so
## this diff is exact.
func _active_site_fetch_job_ids() -> Dictionary:
	var ids: Dictionary = {}
	for job in _scheduler.queue.get_jobs():
		if String(job.get("kind", "")) == "site_fetch" and String(job.get("status", "")) == "active":
			ids[String(job["id"])] = true
	return ids

## Hands-filling rules: ConstructionGiver's own submission-time source
## choice (ConstructionGiver._choose_source()) is a position-agnostic
## placeholder -- no colonist is chosen yet at submission, so it cannot be
## "nearest to the builder" itself; it exists only so GlobalAssignment has a
## concrete tile to score/route idle colonists against. The instant a
## site_fetch job actually (re)activates with a real colonist known --
## caught by `before` naming every site_fetch job already active before this
## tick's _scheduler.tick() call, so only a job that just (re)activated this
## tick is considered -- this re-runs the exact nearest-source search every
## later hop already uses (_next_site_fetch_source()) from the colonist's
## real, current position, and swaps away from the placeholder when a
## genuinely nearer source exists: releases its reservation and reserves the
## replacement before the colonist ever takes a step toward it. Restricted to
## job.get("cell") == null (still fetching): once delivering, item_id no
## longer drives movement (_toil_go_to_target() already redirects a
## delivering leg at the site), so re-checking it would be inert. Never
## re-evaluated for a job that was already active before this tick (mid-route
## toward its current source): `before`'s membership test excludes it,
## matching _toil_on_pick_up_success()'s own "decide once, act until the next
## discrete boundary" discipline -- a (re)activation is one such boundary, an
## ordinary continuing tick never is.
func _resolve_freshly_activated_site_fetch_sources(before: Dictionary) -> void:
	for job in _scheduler.queue.get_jobs():
		if (String(job.get("kind", "")) != "site_fetch" or String(job.get("status", "")) != "active"
				or job.get("cell") != null):
			continue
		var job_id := String(job["id"])
		if before.has(job_id):
			continue
		var colonist := _find_job_colonist(job_id)
		if colonist.is_empty():
			continue
		var current_item_id := String(job.get("item_id", ""))
		var kind := String(_item_lookup(current_item_id).get("kind", ""))
		if kind.is_empty():
			continue
		var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var best_id := _next_site_fetch_source(colonist, job, kind, current)
		if best_id.is_empty() or best_id == current_item_id:
			continue
		var table := _scheduler.queue.get_reservation_table()
		table.release(JobQueueType.ITEM_KEY_PREFIX + current_item_id, job_id)
		table.acquire(JobQueueType.ITEM_KEY_PREFIX + best_id, job_id)
		var best_item := _item_lookup(best_id)
		_scheduler.queue.retarget_site_fetch_source(job_id, best_id, Vector2i(int(best_item["x"]), int(best_item["y"])))
		_site_fetch_source_retargeted[job_id] = true

## submit_fetch callable for ConstructionGiver: submits a site_fetch job
## targeting item_tile (leg one), then attaches item_id and the site's own
## origin (leg two's destination, read by _toil_go_to_target()).
func _submit_site_fetch(origin: Vector2i, item_id: String, item_tile: Vector2i, tick: int) -> Dictionary:
	var result := _scheduler.submit(item_tile, JobQueueType.Priority.NORMAL, tick, "site_fetch", "")
	if result.get("ok", false):
		var job_id: String = result["job_id"]
		_scheduler.queue.attach_item(job_id, item_id)
		_scheduler.queue.attach_site(job_id, origin)
	return result

## submit_work callable for ConstructionGiver: submits a site_work job
## targeting the site's own origin tile directly (its only leg), and records
## the contributing job on the site record itself (ConstructionSiteTable.
## add_builder(), capped at the site's own max_builders -- ConstructionGiver
## never calls this past that cap, but the table enforces it defensively too).
func _submit_site_work(origin: Vector2i, tick: int) -> Dictionary:
	var result := _scheduler.submit(origin, JobQueueType.Priority.NORMAL, tick, "site_work", "")
	if result.get("ok", false):
		var job_id: String = result["job_id"]
		_scheduler.queue.attach_site(job_id, origin)
		_sites.add_builder(_sites.find_at_origin(origin), job_id)
	return result

## The first passable, non-trench tile adjacent to any of `tiles` (a site's own
## footprint) and not itself one of `tiles` or already in `exclude` -- checked
## in the same north/west/east/south-per-tile order _dig_item_placement()
## already uses for a single tile (cancel_site's "nearest free tiles
## adjacent to the site" rule). Falls back to tiles[0] when nothing
## qualifies, mirroring _dig_item_placement()'s own "no adjacent tile
## qualifies" fallback.
func _nearest_free_adjacent_to_footprint(tiles: Array[Vector2i], exclude: Dictionary = {}) -> Vector2i:
	var footprint := {}
	for tile in tiles:
		footprint[tile] = true
	for tile in tiles:
		for neighbor in [Vector2i(tile.x, tile.y - 1), Vector2i(tile.x - 1, tile.y),
				Vector2i(tile.x + 1, tile.y), Vector2i(tile.x, tile.y + 1)]:
			if footprint.has(neighbor) or exclude.has(neighbor):
				continue
			if bool(passability(neighbor.x, neighbor.y)["passable"]) and get_tile(neighbor.x, neighbor.y) != TILE_TRENCH:
				return neighbor
	return tiles[0]

## cancel_site {x, y}: terminates every in-flight site_fetch/
## site_work job on the site (dropping a mid-fetch builder's own carried hands
## through the existing _drop_carried_haul_item() terminal path),
## drops every held material on the nearest free tile adjacent to the site
## (one distinct tile per kind where possible), releases the site's own
## footprint reservation, and removes the site record -- there is no separate
## "ghost" to erase: it is whatever a future presentation layer draws from
## get_construction_sites(), which this call already empties.
func _cancel_construction_site(site_id: String) -> void:
	var site := _sites.get_site(site_id)
	if site.is_empty():
		return
	var origin: Vector2i = site["origin"]
	for job in _scheduler.queue.get_jobs():
		if job.get("site") != origin or not (String(job.get("status", "")) in ["queued", "active"]):
			continue
		var kind := String(job.get("kind", ""))
		if kind != "site_fetch" and kind != "site_work":
			continue
		var job_id := String(job["id"])
		if kind == "site_fetch":
			_drop_carried_haul_item(job_id)
		_finish_job(job_id, "cancel_job")
	var footprint := _object_footprint_tiles(String(site["kind"]), origin, String(site["orientation"]))
	var used := {}
	for entry in (site["held_materials"] as Array):
		var quantity := int(entry["quantity"])
		if quantity <= 0:
			continue
		var drop_at := _nearest_free_adjacent_to_footprint(footprint, used)
		used[drop_at] = true
		_place_new_ground_item(String(entry["item"]), quantity, drop_at.x, drop_at.y)
	_scheduler.queue.get_reservation_table().release_all(_sites.owner_key(site_id))
	_sites.remove(site_id)

func _check_cancel_site_command(payload: Dictionary) -> Dictionary:
	for key in payload.keys():
		if key != "x" and key != "y":
			return {"reason": "invalid_payload", "message": "cancel_site accepts only x and y."}
	if typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT:
		return {"reason": "invalid_payload", "message": "cancel_site requires integer x and y."}
	if _construction_site_id_at(int(payload["x"]), int(payload["y"])).is_empty():
		return {"reason": "invalid_target", "message": "No construction site occupies this tile."}
	return {}

## cancel_job {job_id}: boot.gd's Cancel tool still
## resolves a pending build order by "job_id" (test_order_input.gd; the
## toolbar has not yet been rewired onto the dedicated cancel_site {x,y}
## command). A site has no job at order time
## (ADR 040), so _apply_construction_submission() hands its own id back as
## both site_id and job_id; recognising that id here and tearing the site
## down through the exact same _cancel_construction_site() cancel_site
## {x,y} uses keeps the two entry points equivalent rather than adding a
## second cancellation path. Any id that does not name a live site is an
## ordinary job id and goes to _apply_job_command() unchanged.
func _apply_cancel_job_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command.get("payload", {})
	var site_id := String(payload.get("job_id", ""))
	if not site_id.is_empty() and _sites.has(site_id):
		_cancel_construction_site(site_id)
		_collect_queue_events()
		var applied := _applied(command)
		applied["site_id"] = site_id
		applied["job_id"] = site_id
		return applied
	return _apply_job_command(command)

func _apply_cancel_site_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check := _check_cancel_site_command(payload)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var site_id := _construction_site_id_at(int(payload["x"]), int(payload["y"]))
	_cancel_construction_site(site_id)
	_collect_queue_events()
	var applied := _applied(command)
	applied["site_id"] = site_id
	return applied

## Placement/completion effect once a site's own accumulated progress meets
## its declared build_ticks: places the declared object via
## the footprint-aware _set_object() (clears/re-marks every footprint tile,
## invalidates regions/rooms, stamps health when the kind declares one),
## releases the site's own footprint reservation (the placed object's own
## passability governs the tiles from here on, not a placeholder reservation),
## completes any other still-active builder job on the site (best-effort: the
## mechanism must not strand a second builder mid-work once the structure
## already exists), and removes the
## site record -- which also discards held_materials, already fully spent by
## definition (ConstructionGiver never submits a site_work job before
## materials_met()).
func _finalize_construction_site(site_id: String, completing_job_id: String) -> void:
	var site := _sites.get_site(site_id)
	if site.is_empty():
		return
	for other_job_id in (site["builder_ids"] as Array):
		if String(other_job_id) != completing_job_id:
			_finish_job(String(other_job_id), "complete_job")
	_scheduler.queue.get_reservation_table().release_all(_sites.owner_key(site_id))
	var origin: Vector2i = site["origin"]
	_set_object(origin.x, origin.y, String(site["kind"]), "colony", String(site["orientation"]))
	_sites.remove(site_id)

## _resolve_giver_association()'s site_work branch: releases
## job_id's own builder slot on whichever site it belongs to, on every
## terminal transition that is not the site's own completion (that path
## already removes the whole record via _finalize_construction_site()).
## job.site names the site's origin tile, resolvable even after termination
## since JobQueue never deletes a terminal job from its own list.
func _release_site_builder(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	if job.is_empty() or job.get("site") == null:
		return
	var site_id := _sites.find_at_origin(job["site"])
	if not site_id.is_empty():
		_sites.remove_builder(site_id, job_id)

## True when treating every one of `tiles` (a candidate site's own footprint)
## as impassable simultaneously would strand a tile that is currently
## reachable by some colony actor (docs/architecture/orders-and-movement.md's
## blocked_target_unreachable) -- the only object-placement rule construction
## adds beyond dig/chop's own target validation, generalized from the
## superseded single-tile _would_enclose() to a whole footprint.
## Every existing impassable site's own footprint (except `exclude_site_id`'s
## own) already counts as blocked, so the second of two walls ordered into a
## room's two remaining openings is refused. Each colony actor's own reachable
## component is checked once (a 4-connected flood fill of passable("colony")
## tiles, with and without every tile in `tiles`; actors sharing an
## already-visited component are skipped, and one standing on an impassable
## tile anchors nothing), so a trapped or disconnected first actor never hides
## an enclosure elsewhere. Every tile in `tiles` always drops out of its own
## "after" set and is never mistaken for a stranded neighbour; the "how many
## disappeared besides the candidate itself" baseline is tiles.size() instead
## of the single-tile version's literal 1 -- but counted per reachable
## component (`candidates_in_before` below), not over the whole of `tiles`:
## build_line can submit candidate tiles spanning components that
## were never connected to begin with (e.g. a wall tile beside one colonist
## and an isolated one-tile pocket nobody can reach), and a candidate tile
## that this component's flood fill never reached is not "lost" by blocking
## it, so it must not be subtracted from this component's own baseline.
func _would_enclose_tiles(tiles: Array[Vector2i], exclude_site_id: String = "") -> bool:
	var blocked := {}
	for site in _sites.list():
		if String(site["id"]) == exclude_site_id:
			continue
		if bool(_object_definitions.get(String(site["kind"]), {}).get("passable", true)):
			continue
		for tile in _object_footprint_tiles(String(site["kind"]), site["origin"], String(site["orientation"])):
			blocked[tile] = true
	var seen := {}
	for colonist in _colonists:
		if String(colonist.get("factionId", "colony")) != "colony":
			continue
		var reference := Vector2i(int(colonist["x"]), int(colonist["y"]))
		if tiles.has(reference) or seen.has(reference) or blocked.has(reference):
			continue
		var before := _flood_fill_passable(reference, blocked)
		seen.merge(before)
		var touches_candidate := false
		for tile in tiles:
			if before.has(tile):
				touches_candidate = true
				break
		if not touches_candidate:
			continue
		for tile in tiles:
			blocked[tile] = true
		var after := _flood_fill_passable(reference, blocked)
		for tile in tiles:
			blocked.erase(tile)
		var candidates_in_before := 0
		for tile in tiles:
			if before.has(tile):
				candidates_in_before += 1
		if after.size() < before.size() - candidates_in_before:
			return true
	return false

## 4-connected BFS over passable(faction "colony") tiles reachable from `start`,
## treating every key of `blocked` as impassable regardless of its own real
## passability -- _would_enclose_tiles()'s only use, so kept private and
## untyped-simple rather than a general pathfinder.
func _flood_fill_passable(start: Vector2i, blocked: Dictionary) -> Dictionary:
	var visited := {}
	if blocked.has(start) or not bool(passability(start.x, start.y)["passable"]):
		return visited
	visited[start] = true
	var frontier: Array[Vector2i] = [start]
	while not frontier.is_empty():
		var current: Vector2i = frontier.pop_back()
		for offset in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var next: Vector2i = current + offset
			if blocked.has(next) or visited.has(next):
				continue
			if next.x < 0 or next.x >= _width or next.y < 0 or next.y >= _height:
				continue
			if not bool(passability(next.x, next.y)["passable"]):
				continue
			visited[next] = true
			frontier.append(next)
	return visited

## Applies immediately, no job queue involved. Rejected invalid_target for an
## out-of-bounds/occupied/tree/water tile on any footprint tile;
## rejected invalid_payload for an unknown kind or a malformed orientation.
## This is the debug/map-gen placement path only (ADR 039) -- the
## player-facing `build` order flow is _apply_construction_submission() above.
func _apply_place_object_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check := _check_place_object_command(payload)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	_set_object(int(payload["x"]), int(payload["y"]), String(payload["kind"]), "colony", String(payload.get("orientation", "")))
	return _applied(command)

## Rejected invalid_target for an out-of-bounds tile or one holding no object.
func _apply_remove_object_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_remove_object_command(self, command)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	_set_object(int(payload["x"]), int(payload["y"]), "")
	return _applied(command)

## Mutates one colonist's labour table (colonist-ai.md 3.2).
func _apply_set_labour_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_set_labour_command(self, command)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var colonist := _find_colonist(String(payload["colonist"]))
	WorkerType.set_labour_level(colonist, String(payload["kind"]), int(payload["level"]))
	return _applied(command)

## Debug command (F3): mutates one actor's existing "factionId"
## field, mirroring _apply_set_labour_command()'s validation shape. target is
## looked up against the actor table (_colonists, per ADR 012 -- every
## spawned actor lives there today, not just worker-component colonists), so
## an actor without a worker component is still a valid target. Never
## touches an object's or item's faction_id.
func _apply_set_faction_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_set_faction_command(self, command)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var actor := _find_colonist(String(payload["target"]))
	actor["factionId"] = String(payload["faction_id"])
	return _applied(command)

## Proposes incident_id's actors now, bypassing min_day/cooldown/budget gating (tests, the viewer's
## debug buttons); "actor_ids" lists the proposals, each spawned only once its job activates.
func _apply_spawn_incident_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_spawn_incident_command(self, command)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var applied := _applied(command)
	applied["actor_ids"] = _incidents.force_spawn(String(payload["id"]), _clock.tick)
	return applied

## Draws a rectangular stockpile zone.
func _apply_zone_add_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_zone_add_command(self, command)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var zone_id := "zone_%d" % _next_zone_id
	_next_zone_id += 1
	_zones[zone_id] = {"id": zone_id, "x": int(payload["x"]), "y": int(payload["y"]),
		"width": int(payload["width"]), "height": int(payload["height"])}
	var applied := _applied(command)
	applied["zone_id"] = zone_id
	return applied

## Removes a stockpile zone by id.
func _apply_zone_remove_command(command: Dictionary) -> Dictionary:
	var check := CommandChecks.check_zone_remove_command(self, command)
	if not check.is_empty():
		return _rejection(command["command_id"], command["actor"], check["reason"], check["message"])
	var payload: Dictionary = command["payload"]
	var zone_id: String = payload["id"]
	var removed: Dictionary = _zones[zone_id]
	_zones.erase(zone_id)
	_fail_haul_jobs_targeting_removed_zone(int(removed["x"]), int(removed["y"]), int(removed["width"]), int(removed["height"]))
	_collect_queue_events()
	return _applied(command)

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

## Half-open interval overlap test on both axes.
func _zone_overlaps(x: int, y: int, width: int, height: int) -> bool:
	for zone in _zones.values():
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		var zw: int = zone["width"]
		var zh: int = zone["height"]
		if x < zx + zw and zx < x + width and y < zy + zh and zy < y + height:
			return true
	return false

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

func _collect_queue_events() -> void:
	# JobQueue.get_events() deep-copies its whole log: skip ticks whose counter shows nothing new.
	if _scheduler.queue.get_sequence() <= _queue_event_sequence + 1:
		return
	var highest := _queue_event_sequence
	for event in _scheduler.queue.get_events():
		var queue_sequence: int = event["sequence"]
		if queue_sequence <= _queue_event_sequence:
			continue
		highest = maxi(highest, queue_sequence)
		event["sequence"] = _next_sequence()
		_insert_event(event)
	_queue_event_sequence = highest

func get_events() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for event in _events:
		copy.append(event.duplicate(true))
	return copy

## record=false (preview() only) builds every rejection through _pure_rejection() instead of
## _rejection(), so an invalid envelope, a malformed payload or a tick mismatch previewed on an
## otherwise-valid actor never appends a command_rejected event or advances _event_sequence
## -- apply() always passes record=true (the default), unchanged.
func _validate_command(command, record: bool = true) -> Dictionary:
	if typeof(command) != TYPE_DICTIONARY:
		return _reject(null, null, "invalid_envelope", "Command must be a Dictionary.", record)
	if not (command.has("actor") and typeof(command["actor"]) == TYPE_STRING and command["actor"] != ""):
		return _reject(command.get("command_id"), command.get("actor"), "invalid_envelope",
			"Command must include a non-empty string actor.", record)
	if not (command.has("command_id") and typeof(command["command_id"]) == TYPE_STRING and command["command_id"] != ""):
		return _reject(null, command["actor"], "invalid_envelope",
			"Command must include a non-empty string command_id.", record)
	if not (command.has("tick") and typeof(command["tick"]) == TYPE_INT):
		return _reject(command["command_id"], command["actor"], "invalid_envelope",
			"Command must include an integer tick.", record)
	if not (command.has("type") and typeof(command["type"]) == TYPE_STRING and command["type"] != ""):
		return _reject(command["command_id"], command["actor"], "invalid_envelope",
			"Command must include a non-empty string type.", record)
	if not (command.has("payload") and typeof(command["payload"]) == TYPE_DICTIONARY):
		return _reject(command["command_id"], command["actor"], "invalid_envelope",
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
			return _reject(command["command_id"], command["actor"], "invalid_payload",
				"Payload values must be String or int.", record)
	if command["tick"] != _clock.tick:
		return _reject(command["command_id"], command["actor"], "tick_mismatch",
			"Command tick %d does not match current tick %d." % [command["tick"], _clock.tick], record)
	return {"ok": true}

func _reject(command_id, actor, reason: String, message: String, record: bool) -> Dictionary:
	if record:
		return _rejection(command_id, actor, reason, message)
	return _pure_rejection(command_id, actor, reason, message)

func _apply_noop(command: Dictionary) -> Dictionary:
	var actor: String = command["actor"]
	var command_id: String = command["command_id"]
	var payload: Dictionary = command["payload"]
	_insert_event({
		"type": "command_applied",
		"tick": _clock.tick,
		"system_priority": PRIORITY_COMMAND,
		"entity_id": actor,
		"sequence": _next_sequence(),
		"command_id": command_id,
		"data": payload.duplicate(true)
	})
	return {"ok": true, "applied": {"command_id": command_id, "actor": actor, "type": "noop", "tick": _clock.tick}}

## _apply_noop(), with "applied".type overwritten from "noop" to the command's
## own type; shared tail for every immediate-apply command handler below.
func _applied(command: Dictionary) -> Dictionary:
	var result := _apply_noop(command)
	result["applied"]["type"] = command["type"]
	return result

func _rejection(command_id, actor, reason: String, message: String) -> Dictionary:
	var result := _pure_rejection(command_id, actor, reason, message)
	if typeof(actor) == TYPE_STRING and actor != "":
		_insert_event({
			"type": "command_rejected",
			"tick": _clock.tick,
			"system_priority": PRIORITY_COMMAND,
			"entity_id": actor,
			"sequence": _next_sequence(),
			"command_id": command_id if typeof(command_id) == TYPE_STRING else "",
			"data": {"reason": reason}
		})
	return result

## Pure counterpart of _rejection(): builds the exact same rejection
## Dictionary apply() would return, without appending a command_rejected event or advancing
## _event_sequence -- the only rejection path preview() may ever call.
func _pure_rejection(command_id, actor, reason: String, message: String) -> Dictionary:
	return {"ok": false, "rejection": {
		"command_id": command_id,
		"actor": actor,
		"reason": reason,
		"message": message,
		"tick": _clock.tick
	}}

func _next_sequence() -> int:
	var sequence := _event_sequence
	_event_sequence += 1
	return sequence

func _insert_event(event: Dictionary) -> void:
	var index := _events.size()
	while index > 0 and _event_less(event, _events[index - 1]):
		index -= 1
	_events.insert(index, event)

func _event_less(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]

func _tile_index(x: int, y: int) -> int:
	return y * _width + x

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
	var result := WorldGeneratorType.generate_with_decorations(geography_random, _width, _height, _mapgen)
	_pending_water_tiles = result["water_tiles"]
	_pending_berry_bush_tiles = result["berry_bush_tiles"]
	return result["tiles"]

## Delegates the clearing search to WorldGeneratorType.place_spawn() (a
## river-aware, resource-validated search, not a fixed rectangle -- see
## ADR 020), consuming its own PLACEMENT_SEED_SALT local RNG for
## the same reason _generate_map() above does not touch _random; this
## method's own job is turning that module's pure output into real WorldState
## state: surviving berry bush tiles become _objects entries (WorldGenerator
## owns no object store), and the chosen positions become spawned colonists.
func _spawn_colonists(map: Array[String]) -> Array[Dictionary]:
	var placement_random := RandomNumberGenerator.new()
	placement_random.seed = _seed + PLACEMENT_SEED_SALT
	var placement: Dictionary = WorldGeneratorType.place_spawn(placement_random, map, _width, _height, _mapgen,
		_pending_water_tiles, _pending_berry_bush_tiles, int(_mapgen["colonist_count"]))
	_spawn_clearing = placement["clearing"]
	for pos in placement["berry_bush_tiles"]:
		_objects[_object_key(pos.x, pos.y)] = "berry_bush"
		_object_factions[_object_key(pos.x, pos.y)] = "colony"
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
