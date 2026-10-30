class_name CombatGiver
extends RefCounted

## Job-giver for the flee decision: decides when a `flee` job should exist (one work engine, no
## state machine of its own; movement is the ordinary `go_to` toil). Submits through
## submit_autonomous() (ADR 014 amendment) so a non-colony actor's flee job is never refused by
## the `may_be_ordered` gate.

const TargetingType = preload("res://scripts/core/combat/combat_targeting.gd")
const FLEE_KIND := "flee"
const FLEE_PRIORITY := 1
const FLEE_DISTANCE := 6

## JobQueue's blocked reasons for a queued job that can never progress on its own (local copies).
const BLOCKED_TARGET_RESERVED := "blocked_target_reserved"
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"

## Away from the threat's dominant axis first; the fixed order backs _ranked_directions()' tie-break.
const CANDIDATE_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var _submit_job: Callable
var _get_job: Callable
var _list_jobs: Callable
var _restrict_to_for: Callable
var _interrupt: Callable
var _resume: Callable
var _passable_for_actor: Callable
var _may_reserve_target: Callable
var _reachable: Callable
var _bounds_max: Vector2i
var _content
var _relations
var _is_target_reserved: Callable
var _cancel_job: Callable

## actor_id -> current flee job_id. Never persisted: rebuilt from the scheduler's queue on load;
## `_episodes`, not this map, says whether an actor is mid-flee.
var _fleeing: Dictionary = {}

## actor_id -> Dictionary[Vector2i, true]: the open flee episode and its excluded destinations.
## Opened when `_interrupt` is called for the first leg; survives blocked legs, destination
## exhaustion and save/load (persisted as `combatBlockedTargets`, hashed); closed only by recovery
## or forget(). Exclusions accumulate for the whole episode.
var _episodes: Dictionary = {}

## Every Callable is wired by WorldState (see its CombatGiverType.new call). restrict_to_for must
## also know queued jobs (a reload mid-flee would otherwise submit a duplicate leg); interrupt/resume
## are NeedsSystem's critical-interrupt boundary (ADR 009); cancel_job is the shared _finish_job()
## boundary, a no-op for a job already terminal.
func _init(submit_job: Callable, get_job: Callable, list_jobs: Callable, restrict_to_for: Callable,
		interrupt: Callable, resume: Callable, passable_for_actor: Callable, may_reserve_target: Callable,
		reachable: Callable, bounds_max: Vector2i, content, relations,
		is_target_reserved: Callable, cancel_job: Callable) -> void:
	_submit_job = submit_job
	_get_job = get_job
	_list_jobs = list_jobs
	_restrict_to_for = restrict_to_for
	_interrupt = interrupt
	_resume = resume
	_passable_for_actor = passable_for_actor
	_may_reserve_target = may_reserve_target
	_reachable = reachable
	_bounds_max = bounds_max
	_content = content
	_relations = relations
	_is_target_reserved = is_target_reserved
	_cancel_job = cancel_job

static func _flee_hp_fraction(actor: Dictionary, content) -> float:
	var definition: Dictionary = content.get_entry("actors", String(actor.get("kind", "")))
	var combat_tunables: Dictionary = (definition.get("tunables", {}) as Dictionary).get("combat", {})
	return float(combat_tunables.get("flee_hp_fraction", 0.0))

static func _hp_fraction(actor: Dictionary) -> float:
	var health: Dictionary = actor.get("health", {})
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	return float(int(health.get("hp", 0))) / float(max_hp)

## Drops this giver's associations for a dead actor (its job is cancelled separately).
func forget(actor_id: String) -> void:
	_fleeing.erase(actor_id)
	_episodes.erase(actor_id)

## actor_id -> flee job_id, layered over NeedGiver's committed jobs before GlobalAssignment.tick()
## so a flee job is never outscored by the work it just interrupted.
func get_committed_jobs() -> Dictionary:
	return _fleeing.duplicate()

## True while an episode is open for actor_id (broader than `_fleeing`); keeps NeedGiver off an
## actor whose interrupt/resume this giver owns.
func owns(actor_id: String) -> bool:
	return _episodes.has(actor_id)

## Every open episode with its excluded destinations, detached. Cannot be rebuilt from the queue,
## so state_codec.gd persists it as `combatBlockedTargets`.
func get_blocked_targets() -> Dictionary:
	var copy: Dictionary = {}
	for actor_id in _episodes:
		copy[actor_id] = (_episodes[actor_id] as Dictionary).duplicate()
	return copy

## state_codec.gd's decode() counterpart: replaces the episodes, then re-adopts every non-terminal
## flee job (opening its episode if missing). Must run after the scheduler queue is restored.
func restore_blocked_targets(data: Dictionary) -> void:
	_episodes = data
	_fleeing.clear()
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != FLEE_KIND or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var actor_id := String(_restrict_to_for.call(String(job["id"])))
		if actor_id.is_empty():
			continue
		_fleeing[actor_id] = String(job["id"])
		if not _episodes.has(actor_id):
			_episodes[actor_id] = {}

## Once per tick: an actor below its flee_hp_fraction with no tracked flee job is interrupted and
## gets one leg away from its nearest hostile; one back above the threshold resumes its interrupted
## work. "flee" completes one tick after arrival, so repeated legs make the "keep moving" reaction.
func advance(actors: Array[Dictionary], tick: int) -> void:
	for actor in actors:
		if not (actor.get("combat") is Dictionary):
			continue
		var actor_id: String = String(actor["id"])
		var health: Dictionary = actor.get("health", {})
		if bool(health.get("dead", false)):
			forget(actor_id)
			continue
		# Adopt an untracked non-terminal flee job before deciding, never duplicate it.
		if _episodes.has(actor_id) and not _fleeing.has(actor_id):
			_adopt_existing_flee_job(actor_id)
		var should_flee := _hp_fraction(actor) < _flee_hp_fraction(actor, _content)
		if not should_flee:
			# Recovery belongs to the episode, not to a current job. Cancel any outstanding leg first
			# (no-op if terminal), or its reservation is orphaned when _resume overwrites the assignment.
			if _fleeing.has(actor_id) or _episodes.has(actor_id):
				if _fleeing.has(actor_id):
					_cancel_job.call(String(_fleeing[actor_id]))
					_fleeing.erase(actor_id)
				_episodes.erase(actor_id)
				_resume.call(actor_id)
			continue
		if not _fleeing.has(actor_id):
			# Adopted after a load: fall through so a blocked leg is handled this same tick.
			_adopt_existing_flee_job(actor_id)
		if _fleeing.has(actor_id):
			var job: Dictionary = _get_job.call(_fleeing[actor_id])
			var status := String(job.get("status", ""))
			if status == "active":
				continue
			if status == "queued":
				# A blocked leg never resolves itself (JobQueue retries the same target forever): cancel it,
				# exclude its destination and pick a different one this same tick.
				if String(job.get("reason", "")) not in [BLOCKED_TARGET_RESERVED, BLOCKED_TARGET_UNREACHABLE]:
					continue
				var blocked: Dictionary = _episodes.get(actor_id, {})
				blocked[job["target"]] = true
				_episodes[actor_id] = blocked
				_cancel_job.call(String(_fleeing[actor_id]))
			_fleeing.erase(actor_id)
		var threat := TargetingType.nearest_hostile_actor(actor, actors, _relations)
		if threat.is_empty():
			continue
		var target: Variant = _pick_flee_target(actor, actors, threat, _episodes.get(actor_id, {}))
		if target == null:
			# Destination exhaustion: the episode (and its owed recovery) stays open.
			continue
		# The episode opens at the interrupt, independent of whether the leg is accepted.
		if not _episodes.has(actor_id):
			_episodes[actor_id] = {}
		_interrupt.call(actor)
		var result: Dictionary = _submit_job.call(target, FLEE_PRIORITY, tick, FLEE_KIND, actor_id)
		if result.get("ok", false):
			_fleeing[actor_id] = String(result["job_id"])

## Adopts a non-terminal flee job already restricted to actor_id (after a load, `_fleeing` is empty).
func _adopt_existing_flee_job(actor_id: String) -> bool:
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != FLEE_KIND:
			continue
		if String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if _restrict_to_for.call(String(job["id"])) != actor_id:
			continue
		_fleeing[actor_id] = String(job["id"])
		return true
	return false

## A deterministic, reachable, reservable flee tile: directions ranked by how directly they point
## away from `threat`, the farthest distance first within each direction (direction is the outer
## loop). A candidate must strictly increase the distance from `threat` and must not be impassable,
## unreachable, unreservable, hostile-occupied, already reserved or in `excluded`. null when none.
func _pick_flee_target(actor: Dictionary, actors: Array[Dictionary], threat: Dictionary, excluded: Dictionary = {}):
	var ax := int(actor["x"])
	var ay := int(actor["y"])
	var actor_id: String = String(actor["id"])
	var start := Vector2i(ax, ay)
	var threat_pos := Vector2i(int(threat["x"]), int(threat["y"]))
	var away := Vector2i(signi(ax - threat_pos.x), signi(ay - threat_pos.y))
	if away == Vector2i.ZERO:
		away = Vector2i(1, 1)
	var hostile_tiles := _hostile_occupied_tiles(actor, actors)
	var start_distance := TileGrid.distance_sq(start, threat_pos)
	for direction in _ranked_directions(away):
		for distance in range(FLEE_DISTANCE, 0, -1):
			var candidate := Vector2i(clampi(ax + direction.x * distance, 0, _bounds_max.x), clampi(ay + direction.y * distance, 0, _bounds_max.y))
			if candidate == start or hostile_tiles.has(candidate) or excluded.has(candidate):
				continue
			if TileGrid.distance_sq(candidate, threat_pos) <= start_distance:
				continue
			if not bool((_passable_for_actor.call(actor_id, candidate.x, candidate.y) as Dictionary)["passable"]):
				continue
			if not bool(_may_reserve_target.call(actor_id, candidate)):
				continue
			if bool(_is_target_reserved.call(candidate.x, candidate.y)):
				continue
			if not bool(_reachable.call(start, candidate)):
				continue
			return candidate
	return null

## Tiles occupied by living actors hostile to `actor` (never a flee destination).
func _hostile_occupied_tiles(actor: Dictionary, actors: Array[Dictionary]) -> Dictionary:
	var own_faction := TargetingType.actor_faction(actor)
	var occupied: Dictionary = {}
	for other in actors:
		if other == actor:
			continue
		if bool((other.get("health", {}) as Dictionary).get("dead", false)):
			continue
		if _relations.relation(own_faction, TargetingType.actor_faction(other)) != "hostile":
			continue
		occupied[Vector2i(int(other["x"]), int(other["y"]))] = true
	return occupied

## CANDIDATE_DIRECTIONS by descending dot product with `away`, ties by fixed index (no floats).
static func _ranked_directions(away: Vector2i) -> Array[Vector2i]:
	var scored: Array = []
	for i in CANDIDATE_DIRECTIONS.size():
		var direction: Vector2i = CANDIDATE_DIRECTIONS[i]
		scored.append({"direction": direction, "dot": direction.x * away.x + direction.y * away.y, "index": i})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["dot"]) != int(b["dot"]):
			return int(a["dot"]) > int(b["dot"])
		return int(a["index"]) < int(b["index"]))
	var ranked: Array[Vector2i] = []
	for entry in scored:
		ranked.append(entry["direction"])
	return ranked
