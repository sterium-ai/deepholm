class_name IncidentScheduler
extends RefCounted

## F5 incidents (docs/architecture/foundation-for-breadth.md section F5, ADR
## 018, issue #294): day-gated, budgeted spawns of passive non-colony actors
## (content/incidents.json). A spawned actor's walk-then-wait is a real job
## (content/jobs.json's "incident" kind: labour "", toils
## [reserve, go_to, work, release_all]) driven through the same
## WorldState._advance_colonists()/_toils.advance() dispatch every other job
## uses -- this module only decides WHEN an incident draws and WHERE an actor
## spawns/targets, exactly like NeedGiver/HaulGiver decide when their own
## jobs exist, then hands the job to WorldState._submit_incident_job()
## (GlobalAssignment.submit_autonomous(), ADR 015 Amendment). No per-actor
## walk/wait state machine and no synchronous full-path search live here.
##
## Lifecycle (see docs/architecture/orders-and-movement.md, "Incident jobs"):
##   propose()  -> job submitted; the actor is STAGED (_staged), offered to
##                 GlobalAssignment.tick() as a worker but NOT yet in the world
##   activate_pending() (once per WorldState tick, after _scheduler.tick())
##              -> job "active": actor appended to the world, wait stamped
##              -> job blocked unreachable: retired (never spawned)
##              -> job terminal/unknown: forgotten (never spawned)
##   on_job_finished() (from WorldState._finish_job(), every terminal
##                 transition) -> staged entry dropped, or spawned actor
##                 removed -- UNLESS content's own spawn.lingers (issue #398)
##                 marked it to stay in the world instead, e.g. a hostile
##                 actor left for ApproachGiver/CombatGiver to keep driving
##                 once its own arrival routine ends.
##
## Owns its own RandomNumberGenerator, seeded from the world seed combined
## with SEED_SALT, so it never shares a single randi() call with WorldState's
## own _random (constructed once in WorldState._init() alongside it).

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

## Distinct from any other WorldState RNG stream (debug_scenario.gd's own
## DIG_ORDER_SEED_OFFSET/OBJECT_SEED_OFFSET constants are the same idea, one
## fixed offset per independent stream).
const SEED_SALT := 914_827
const DAILY_BUDGET_POINTS := 3
const EDGE_NORTH := "north"
const EDGE_SOUTH := "south"
const EDGE_EAST := "east"
const EDGE_WEST := "west"
const JOB_KIND := "incident"
const NO_TILE := Vector2i(-1, -1)
const ACTOR_ID_PREFIX := "incident_actor_"
## JobQueue.BLOCKED_TARGET_UNREACHABLE: a staged job the shared bounded search
## (run under the actor's own faction) could not route is retired, never spawned.
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"

var _content
var _random: RandomNumberGenerator
var _append_colonist: Callable
var _remove_colonist: Callable
var _map_width: int
var _map_height: int
## (tile: Vector2i, faction_id: String) -> float; WorldState's faction-aware
## passability() wrapper, never the colony-only _is_passable().
var _passable_for_faction: Callable
## (tile: Vector2i) -> bool; WorldState._is_bare_tile(): no object, item or
## zone cell -- the same predicate its autonomous reservation gate applies,
## so a proposed target is one the gate will accept.
var _is_bare_tile: Callable
var _get_regions: Callable
## (actor_id: String, target: Vector2i) -> String job_id ("" on rejection);
## WorldState._submit_incident_job().
var _submit_job: Callable
## (job_id: String) -> Dictionary; WorldState._get_job() (the live queue record).
var _get_job: Callable
## (job_id: String) -> void; WorldState._finish_job(job_id, "cancel_job") --
## the shared finish boundary, which calls back into on_job_finished().
var _retire_job: Callable
## (target: Vector2i, ticks: int) -> void; WorldState._set_work_progress().
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
## job_id -> {"actor": Dictionary, "wait_ticks": int}: proposed actors whose
## job has not activated yet. Not in the world; not persisted (t4).
var _staged: Dictionary = {}
## job_id -> actor_id for every actor actually in the world: an identity
## lookup, not execution state (the job itself lives in the shared queue).
var _actor_by_job: Dictionary = {}
## actor_id -> true for every spawned actor whose own incident row declared
## spawn.lingers (content extension point, issue #398): its arrival job's own
## normal completion (travel + wait) must not despawn it -- it stays in the
## world exactly like any other actor, left for whatever other generic
## per-tick system applies to it (ApproachGiver's own hostile search,
## CombatGiver's flee, CombatResolver's adjacent-attack) to keep driving.
## Populated in activate_pending() when the actor is appended; not persisted
## (this module persists nothing, t4) -- adopt() cannot recover it after a
## load, so a reloaded lingering actor's job despawns on finish exactly like
## before this change (see docs/decisions/ ADR for issue #398).
var _lingering_actors: Dictionary = {}

## append_colonist/remove_colonist are method-bound callables onto
## WorldState's own _colonists array, never a raw Array reference captured
## once: StateCodec.decode() reassigns world._colonists wholesale after
## WorldState._init() already ran, which would strand a captured reference.
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

## WorldState.enable_incidents() (recovery review round 3, issue #294): a
## restored world's own decode() always constructs this scheduler disabled
## (no save data names the flag), so the boot layer flips it on the same way
## for a restored world as for a fresh one.
func set_enabled(enabled: bool) -> void:
	_enabled = enabled

## Prevents a freshly spawned actor's id from colliding with one already in
## a restored roster (recovery review round 3): scans for the highest
## "incident_actor_<N>" id among existing_actors and continues numbering
## past it, never behind.
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

## Called once per WorldState.tick(), once per in-game calendar day: runs the
## budgeted draw. A disabled scheduler is a true no-op.
func advance(tick: int) -> void:
	if not _enabled:
		return
	var day := int(_day_of_tick.call(tick))
	if day != _last_processed_day:
		_last_processed_day = day
		_run_daily_draw(day, tick)

## Debug command entry point (spawn_incident {id}, WorldState.apply()):
## bypasses min_day/cooldown/budget gating entirely, but still records the
## same cooldown a natural draw would. Returns the PROPOSED actor ids: each
## enters the world only once its job activates (activate_pending()).
func force_spawn(incident_id: String, tick: int) -> Array:
	if not _enabled:
		return []
	var entry: Dictionary = _content.get_entry("incidents", incident_id)
	if entry.is_empty():
		return []
	return _spawn(entry, int(_day_of_tick.call(tick)), tick)

## The staged (proposed, unspawned) actors, in job-id order, for
## GlobalAssignment.tick()'s worker list: the scheduler must be able to
## propose/route them before they exist in the world.
func staged_actors() -> Array[Dictionary]:
	var actors: Array[Dictionary] = []
	for job_id in _staged_job_ids():
		actors.append(_staged[job_id]["actor"])
	return actors

## The staged actor with this id, or {} -- WorldState's faction lookups
## (reservation gate, autonomous passability) consult it alongside the roster.
func staged_actor(actor_id: String) -> Dictionary:
	for job_id in _staged:
		if String(_staged[job_id]["actor"]["id"]) == actor_id:
			return _staged[job_id]["actor"]
	return {}

## Submits actor's own walk/wait job for target and stages the actor. The
## actor enters the world only once activate_pending() sees the job active.
## Returns the job id, or "" when the queue rejected the submission (nothing
## staged). Public so a test can drive the real staging path with a chosen
## target; _spawn_one() is the only production caller. `lingers` (default
## false, preserving every existing 3-arg caller's behaviour unchanged)
## carries content's own spawn.lingers through to activate_pending(), which
## records it against the actor id for on_job_finished() to consult.
func propose(actor: Dictionary, target: Vector2i, wait_ticks: int, lingers: bool = false) -> String:
	var job_id: String = String(_submit_job.call(String(actor["id"]), target))
	if job_id.is_empty():
		return ""
	_staged[job_id] = {"actor": actor, "wait_ticks": wait_ticks, "lingers": lingers}
	return job_id

## Once per WorldState tick, right after _scheduler.tick() and before
## _advance_colonists(): commits every staged job the shared scheduler has
## actually activated (actor appended to the world, its content-declared wait
## stamped onto the target's work-progress key so ToilExecutor.start_work()
## reads it), retires one the actor's own faction-aware bounded search proved
## unreachable (through the shared finish boundary, never spawned), and
## forgets one already terminal (refused by the reservation gate, cancelled
## by a command). A job still queued for any other reason (its target held by
## another job) simply stays staged, exactly like a colonist's queued job.
func activate_pending() -> void:
	for job_id in _staged_job_ids():
		var job: Dictionary = _get_job.call(job_id)
		var status := String(job.get("status", ""))
		if status == "active":
			var staged: Dictionary = _staged[job_id]
			var actor: Dictionary = staged["actor"]
			_staged.erase(job_id)
			if not _spawn_tile_still_valid(actor):
				# The spawn tile's own multi-tick route search began before a
				# door or wall landed on it (recovery review round 3): that
				# already-checked start is now forbidden under the actor's
				# faction, so the proposal is retired, never appended to the
				# world, through the same finish boundary an unreachable
				# target uses.
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

## The shared finish boundary's hook (WorldState._finish_job(), every
## successful terminal transition of an "incident" job: work completion,
## unreachable travel, gate refusal, complete/cancel/fail/invalidate_job
## commands): drops a staged actor that never spawned, or removes a spawned
## one from the world -- UNLESS content's own spawn.lingers marked it to stay
## (_lingering_actors), in which case the actor remains, left for whatever
## other generic system (ApproachGiver, CombatGiver) already has a job
## association pending against this same worker. A no-op for a job this
## scheduler never staged.
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

## Re-associates an active incident job with its actor after a save/load
## (this module persists nothing, t4), so on_job_finished() still despawns it.
func adopt(job_id: String, actor_id: String) -> void:
	_actor_by_job[job_id] = actor_id

## True while actor's own spawn tile is still bare and passable for its own
## faction (the same test _pick_edge_tile() applied when it was chosen):
## revalidated immediately before activate_pending() appends the actor, since
## a door or wall may have landed on it while the job's route search ran.
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

## Builds the actor at a bare, passable edge tile and proposes its job for a
## random bare tile in the same region; "" (nothing staged) when no spawn
## tile or no candidate target exists.
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

## One uniformly random candidate among every bare tile (other than the
## spawn tile) passable for this faction and in the spawn tile's region --
## same_region() (physical, colony-oriented connectivity) filters before any
## route search, per F5 "Regions". It is a pre-filter, not the authority: a
## door that blocks this faction may still leave a tile "same region", and
## the job's own bounded search, run under the actor's faction
## (GlobalAssignment's autonomous passability), then reports it unreachable
## and activate_pending() retires the job before the actor ever spawns.
func _pick_reachable_target(from: Vector2i, faction_id: String) -> Vector2i:
	var regions = _get_regions.call()
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
