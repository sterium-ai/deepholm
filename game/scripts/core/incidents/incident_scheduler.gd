class_name IncidentScheduler
extends RefCounted

## Incidents (foundation-for-breadth.md F5, ADR 017): day-gated, budgeted spawns of non-colony
## actors (content/incidents.json). The walk-then-wait is an ordinary "incident" job run by the
## toil executor; this module only decides when a draw happens and where an actor spawns/targets,
## then submits through WorldState._submit_incident_job() (submit_autonomous(), ADR 014).
## Lifecycle: propose() stages the actor (offered to the scheduler, not in the world);
## activate_pending() appends it once its job is active, or retires/forgets it; on_job_finished()
## removes it unless content's spawn.lingers keeps it (ADR 034).
## Owns its own RNG (world seed + SEED_SALT): never shares a draw with any other stream.

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

## One fixed offset per independent RNG stream.
const SEED_SALT := 914_827
const DAILY_BUDGET_POINTS := 3
const EDGE_NORTH := "north"
const EDGE_SOUTH := "south"
const EDGE_EAST := "east"
const EDGE_WEST := "west"
const JOB_KIND := "incident"
const NO_TILE := Vector2i(-1, -1)
const ACTOR_ID_PREFIX := "incident_actor_"
## A staged job its faction-aware bounded search could not route is retired, never spawned.
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"

var _content
var _random: RandomNumberGenerator
var _append_colonist: Callable
var _remove_colonist: Callable
var _map_width: int
var _map_height: int
## (tile, faction_id) -> float; faction-aware passability, never the colony-only one.
var _passable_for_faction: Callable
## (tile) -> bool; WorldState._is_bare_tile(), the same predicate the autonomous reservation gate uses.
var _is_bare_tile: Callable
var _get_regions: Callable
## (actor_id, target) -> job_id ("" on rejection); WorldState._submit_incident_job().
var _submit_job: Callable
## (job_id) -> Dictionary; the live queue record.
var _get_job: Callable
## (job_id) -> void; the shared finish boundary, which calls back into on_job_finished().
var _retire_job: Callable
## (target, ticks) -> void; WorkProgress, through WorldState._set_work_progress().
var _set_work_progress: Callable
var _day_of_tick: Callable
var _insert_event: Callable
var _next_sequence: Callable
var _priority: int
var _enabled: bool

var _last_processed_day: int = 0
var _next_actor_ordinal: int = 1
## incident id -> the day index a fresh draw may next consider it eligible.
var _cooldown_until_day: Dictionary = {}
## job_id -> {"actor", "wait_ticks"}: proposed actors not yet in the world. Not persisted.
var _staged: Dictionary = {}
## job_id -> actor_id for every spawned actor (identity lookup only).
var _actor_by_job: Dictionary = {}
## actor_id -> true for spawned actors whose row declared spawn.lingers. Not persisted (this module
## persists nothing), so after a load a lingering actor despawns on finish (ADR 034).
var _lingering_actors: Dictionary = {}

## append/remove_colonist are callables, never a captured Array: StateCodec.decode() reassigns
## world._colonists after construction.
func _init(world_seed: int, content_registry, append_colonist: Callable, remove_colonist: Callable,
		map_width: int, map_height: int, passable_for_faction: Callable, is_bare_tile: Callable,
		get_regions: Callable, submit_job: Callable, get_job: Callable, retire_job: Callable,
		set_work_progress: Callable, day_of_tick: Callable, insert_event: Callable, next_sequence: Callable,
		priority: int, enabled: bool = false) -> void:
	_content = content_registry
	_random = RandomNumberGenerator.new()
	_random.seed = world_seed + SEED_SALT
	_append_colonist = append_colonist
	_remove_colonist = remove_colonist
	_map_width = map_width
	_map_height = map_height
	_passable_for_faction = passable_for_faction
	_is_bare_tile = is_bare_tile
	_get_regions = get_regions
	_submit_job = submit_job
	_get_job = get_job
	_retire_job = retire_job
	_set_work_progress = set_work_progress
	_day_of_tick = day_of_tick
	_insert_event = insert_event
	_next_sequence = next_sequence
	_priority = priority
	_enabled = enabled

func is_enabled() -> bool:
	return _enabled

## A decoded world always builds this scheduler disabled; the boot layer enables it either way.
func set_enabled(enabled: bool) -> void:
	_enabled = enabled

## Continues "incident_actor_<N>" numbering past the highest id in a restored roster.
func reserve_actor_ordinal_above(existing_actors: Array) -> void:
	for actor in existing_actors:
		var actor_id := String((actor as Dictionary).get("id", ""))
		if not actor_id.begins_with(ACTOR_ID_PREFIX):
			continue
		var suffix := actor_id.substr(ACTOR_ID_PREFIX.length())
		if not suffix.is_valid_int():
			continue
		var ordinal := suffix.to_int()
		if ordinal >= _next_actor_ordinal:
			_next_actor_ordinal = ordinal + 1

## Once per tick; runs the budgeted draw once per calendar day. No-op when disabled.
func advance(tick: int) -> void:
	if not _enabled:
		return
	var day := int(_day_of_tick.call(tick))
	if day != _last_processed_day:
		_last_processed_day = day
		_run_daily_draw(day, tick)

## Debug spawn_incident: bypasses min_day/cooldown/budget but records the cooldown. Returns the
## proposed actor ids (each enters the world when its job activates).
func force_spawn(incident_id: String, tick: int) -> Array:
	if not _enabled:
		return []
	var entry: Dictionary = _content.get_entry("incidents", incident_id)
	if entry.is_empty():
		return []
	return _spawn(entry, int(_day_of_tick.call(tick)), tick)

## Staged actors in job-id order, offered to GlobalAssignment.tick() before they exist in the world.
func staged_actors() -> Array[Dictionary]:
	var actors: Array[Dictionary] = []
	for job_id in _staged_job_ids():
		actors.append(_staged[job_id]["actor"])
	return actors

## The staged actor with this id, or {}; faction lookups consult it alongside the roster.
func staged_actor(actor_id: String) -> Dictionary:
	for job_id in _staged:
		if String(_staged[job_id]["actor"]["id"]) == actor_id:
			return _staged[job_id]["actor"]
	return {}

## Submits the actor's walk/wait job and stages it; "" when the queue rejected it. Public so tests
## can drive staging with a chosen target. `lingers` carries spawn.lingers to activate_pending().
func propose(actor: Dictionary, target: Vector2i, wait_ticks: int, lingers: bool = false) -> String:
	var job_id: String = String(_submit_job.call(String(actor["id"]), target))
	if job_id.is_empty():
		return ""
	_staged[job_id] = {"actor": actor, "wait_ticks": wait_ticks, "lingers": lingers}
	return job_id

## Once per tick, after the scheduler and before advance_colonists (TickPipeline): spawns actors
## whose job activated (stamping the wait as work progress), retires unreachable ones through the
## finish boundary, forgets terminal ones. Still-queued jobs stay staged.
func activate_pending() -> void:
	for job_id in _staged_job_ids():
		var job: Dictionary = _get_job.call(job_id)
		var status := String(job.get("status", ""))
		if status == "active":
			var staged: Dictionary = _staged[job_id]
			var actor: Dictionary = staged["actor"]
			_staged.erase(job_id)
			if not _spawn_tile_still_valid(actor):
				# A door or wall landed on the spawn tile during the route search: retire, never spawn.
				_retire_job.call(job_id)
				continue
			_append_colonist.call(actor)
			_actor_by_job[job_id] = String(actor["id"])
			if bool(staged.get("lingers", false)):
				_lingering_actors[String(actor["id"])] = true
			_set_work_progress.call(job["target"], int(staged["wait_ticks"]))
		elif status == "queued":
			if String(job.get("reason", "")) == BLOCKED_TARGET_UNREACHABLE:
				_retire_job.call(job_id)
		else:
			_staged.erase(job_id)

## Finish-boundary hook for every terminal "incident" job: drops a staged actor, or removes a spawned
## one unless it lingers. No-op for jobs this scheduler never staged.
func on_job_finished(job_id: String) -> void:
	_staged.erase(job_id)
	var actor_id: String = String(_actor_by_job.get(job_id, ""))
	if actor_id.is_empty():
		return
	_actor_by_job.erase(job_id)
	if _lingering_actors.has(actor_id):
		_lingering_actors.erase(actor_id)
		return
	_remove_colonist.call(actor_id)

## Re-associates an active incident job with its actor after a load (nothing is persisted here).
func adopt(job_id: String, actor_id: String) -> void:
	_actor_by_job[job_id] = actor_id

## The spawn tile is still bare and passable for the actor's faction (rechecked before spawning).
func _spawn_tile_still_valid(actor: Dictionary) -> bool:
	var tile := Vector2i(int(actor["x"]), int(actor["y"]))
	return _cost_of(tile, String(actor.get("factionId", ""))) > 0.0 and bool(_is_bare_tile.call(tile))

func _staged_job_ids() -> Array:
	var ids := _staged.keys()
	ids.sort()
	return ids

func _run_daily_draw(day: int, tick: int) -> void:
	var remaining_budget := DAILY_BUDGET_POINTS
	for entry in _content.list("incidents"):
		var incident_id := String(entry["id"])
		if int(entry.get("min_day", 0)) > day:
			continue
		if int(_cooldown_until_day.get(incident_id, 0)) > day:
			continue
		var weight := int(entry.get("weight", 1))
		if weight > remaining_budget:
			continue
		remaining_budget -= weight
		_spawn(entry, day, tick)

func _spawn(entry: Dictionary, day: int, tick: int) -> Array:
	var incident_id := String(entry["id"])
	var faction_id := String(entry["faction"])
	var spawn_def: Dictionary = entry.get("spawn", {})
	var actor_def := String(spawn_def.get("actor_def", ""))
	var count := int(spawn_def.get("count", 1))
	var edge := String(spawn_def.get("edge", EDGE_NORTH))
	var wait_ticks := int(spawn_def.get("wait_ticks", 1))
	var lingers := bool(spawn_def.get("lingers", false))
	_cooldown_until_day[incident_id] = day + int(entry.get("cooldown_days", 0))
	var proposed_ids: Array = []
	for i in count:
		var actor_id := _spawn_one(actor_def, faction_id, edge, wait_ticks, lingers)
		if not actor_id.is_empty():
			proposed_ids.append(actor_id)
	_insert_event.call({
		"type": "incident_started", "tick": tick, "system_priority": _priority,
		"entity_id": incident_id, "sequence": _next_sequence.call(),
		"data": {"incident_id": incident_id, "faction": faction_id, "actor_ids": proposed_ids},
	})
	return proposed_ids

## Spawns at a bare passable edge tile and proposes a job to a random bare tile in its region; ""
## when none exists.
func _spawn_one(actor_def: String, faction_id: String, edge: String, wait_ticks: int, lingers: bool) -> String:
	var spawn_tile := _pick_edge_tile(edge, faction_id)
	if spawn_tile == NO_TILE:
		return ""
	var target := _pick_reachable_target(spawn_tile, faction_id)
	if target == NO_TILE:
		return ""
	var actor_id := "%s%d" % [ACTOR_ID_PREFIX, _next_actor_ordinal]
	var actor := ActorTableType.spawn(actor_def, spawn_tile.x, spawn_tile.y, _content, actor_id)
	actor["factionId"] = faction_id
	var job_id := propose(actor, target, wait_ticks, lingers)
	if job_id.is_empty():
		return ""
	_next_actor_ordinal += 1
	return actor_id

## One uniformly random bare tile in the spawn tile's region, passable for the faction. Region is
## only a pre-filter: the job's faction-aware search may still prove it unreachable (then retired).
func _pick_reachable_target(from: Vector2i, faction_id: String) -> Vector2i:
	var regions: Variant = _get_regions.call()
	var candidates: Array[Vector2i] = []
	for y in _map_height:
		for x in _map_width:
			var candidate := Vector2i(x, y)
			if candidate == from:
				continue
			if _cost_of(candidate, faction_id) > 0.0 and bool(_is_bare_tile.call(candidate)) and regions.same_region(from, candidate):
				candidates.append(candidate)
	if candidates.is_empty():
		return NO_TILE
	return candidates[_random.randi_range(0, candidates.size() - 1)]

func _cost_of(tile: Vector2i, faction_id: String) -> float:
	return float(_passable_for_faction.call(tile, faction_id))

func _pick_edge_tile(edge: String, faction_id: String) -> Vector2i:
	var candidates := _edge_line(edge)
	if candidates.is_empty():
		return NO_TILE
	var start_index := _random.randi_range(0, candidates.size() - 1)
	for offset in candidates.size():
		var candidate: Vector2i = candidates[(start_index + offset) % candidates.size()]
		if _cost_of(candidate, faction_id) > 0.0 and bool(_is_bare_tile.call(candidate)):
			return candidate
	return NO_TILE

func _edge_line(edge: String) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	match edge:
		EDGE_NORTH:
			for x in _map_width: tiles.append(Vector2i(x, 0))
		EDGE_SOUTH:
			for x in _map_width: tiles.append(Vector2i(x, _map_height - 1))
		EDGE_WEST:
			for y in _map_height: tiles.append(Vector2i(0, y))
		EDGE_EAST:
			for y in _map_height: tiles.append(Vector2i(_map_width - 1, y))
		_:
			pass
	return tiles
