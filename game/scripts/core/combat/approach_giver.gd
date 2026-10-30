class_name ApproachGiver
extends RefCounted

## Job-giver for `approach` (ADR 033): walks a hostile actor (a `combat` component and a `hostile`
## relation to `colony`, read with `Relations.relation()` on runtime `factionId`, never
## `Relations.is_hostile()`, ADR 021) toward the nearest hostile target it is not adjacent to.
## TickPipeline runs it after advance_colonists and after CombatSystem.apply_combat(), so adjacency
## is checked on post-movement positions and a just-trapped actor already carries `trapped`.
## advance() rules per actor, in this fixed order:
## 2. CombatGiver.owns(actor) (fleeing): release tracking, never submit; flee keeps priority.
## 2.5. A tracked job whose target died/was destroyed, or that is queued+BLOCKED_TARGET_UNREACHABLE,
##    is cancelled and dropped; checked before rule 1 so adjacency never skips the cleanup.
## 1. Adjacent to a hostile: do nothing; the attack rule has it.
## 3. A non-terminal approach job is still tracked: leave it running.
## 4. Otherwise rank reachable targets by real route length (one budgeted resume() per tick through
##    the shared `_route_budget`, ADR 004; ties: actor before object, then id / "%d_%d" tile key)
##    and submit one single-leg job through submit_autonomous().
## 5. No reachable target: do nothing; retried every tick, never latched. Incident jobs are never touched.

const TargetingType = preload("res://scripts/core/combat/combat_targeting.gd")
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")

const APPROACH_KIND := "approach"
const APPROACH_PRIORITY := 1

## JobQueue's reason for a queued job that can never progress (same constant as combat_giver.gd).
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"

## The 8 Chebyshev-adjacent offsets around a target tile, cardinal first
## (matching CombatTargeting.NEIGHBOR_OFFSETS' own scan order).
const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(0, -1, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(-1, -1, 0), Vector3i(1, -1, 0), Vector3i(-1, 1, 0), Vector3i(1, 1, 0),
]

var _submit_job: Callable
var _get_job: Callable
var _list_jobs: Callable
var _restrict_to_for: Callable
var _passable_for_actor: Callable
var _may_reserve_target: Callable
var _reachable: Callable
var _is_target_reserved: Callable
var _routable_to: Callable
var _bounds_max: Vector3i
var _content
var _relations
var _route_budget: Dictionary
var _combat_owns: Callable
var _list_objects: Callable
var _object_at: Callable
var _object_health_at: Callable
var _object_faction_at: Callable
## Must be WorldState._cancel_autonomous_job (the shared _finish_job() boundary), so a job can be
## retired before it activates.
var _cancel_job: Callable

## actor_id -> tracked approach job_id; never persisted, rebuilt by restore_job_targets().
var _tracking: Dictionary = {}
## actor_id -> in-progress multi-tick target search state (like need_giver.gd's `_searching`).
var _searching: Dictionary = {}
## job_id -> {"kind": "actor", "id"} or {"kind": "object", "tile"}: the job's target. Persisted
## verbatim by state_codec.gd (an object target cannot be rebuilt after a load).
var _job_targets: Dictionary = {}
## job_id -> actor_id for every live `_job_targets` entry, including jobs released from `_tracking`
## while CombatGiver owns the actor; forget() walks this map. Never persisted (rebuilt on restore).
var _job_actor: Dictionary = {}

## Every Callable is wired by WorldState (see its ApproachGiverType.new call); route_budget is the
## per-tick route ledger shared by reference with the scheduler and the other givers.
func _init(submit_job: Callable, get_job: Callable, list_jobs: Callable, restrict_to_for: Callable,
		passable_for_actor: Callable, may_reserve_target: Callable, reachable: Callable,
		is_target_reserved: Callable, routable_to: Callable, bounds_max: Vector3i, content, relations,
		route_budget: Dictionary, combat_owns: Callable, list_objects: Callable, object_at: Callable,
		object_health_at: Callable, object_faction_at: Callable, cancel_job: Callable) -> void:
	_submit_job = submit_job
	_get_job = get_job
	_list_jobs = list_jobs
	_restrict_to_for = restrict_to_for
	_passable_for_actor = passable_for_actor
	_may_reserve_target = may_reserve_target
	_reachable = reachable
	_is_target_reserved = is_target_reserved
	_routable_to = routable_to
	_bounds_max = bounds_max
	_content = content
	_relations = relations
	_route_budget = route_budget
	_combat_owns = combat_owns
	_list_objects = list_objects
	_object_at = object_at
	_object_health_at = object_health_at
	_object_faction_at = object_faction_at
	_cancel_job = cancel_job

## Drops every association for actor_id, including the persisted target; called on death/removal or
## when the actor stops being hostile. Walks `_job_actor` so a job paused while CombatGiver owned the
## actor is dropped too.
func forget(actor_id: String) -> void:
	_tracking.erase(actor_id)
	_searching.erase(actor_id)
	for job_id in _job_actor.keys().duplicate():
		if String(_job_actor[job_id]) == actor_id:
			_job_targets.erase(job_id)
			_job_actor.erase(job_id)

## Clears only `_tracking`/`_searching`, never `_job_targets`: a flee-paused job resumes later and must
## still be recognised as this giver's.
func _release_tracking(actor_id: String) -> void:
	_tracking.erase(actor_id)
	_searching.erase(actor_id)

## Adopts a non-terminal approach job already restricted to actor_id (after a flee episode or a load).
func _adopt_existing_job(actor_id: String) -> bool:
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != APPROACH_KIND or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if _restrict_to_for.call(String(job["id"])) != actor_id:
			continue
		_tracking[actor_id] = String(job["id"])
		return true
	return false

## For state_codec.gd's encode().
func get_job_targets() -> Dictionary:
	return _job_targets.duplicate(true)

## state_codec.gd's decode() counterpart; must run after the scheduler queue is restored, since it
## re-adopts every non-terminal approach job for the actor it is restricted to.
func restore_job_targets(data: Dictionary) -> void:
	_job_targets = data.duplicate(true)
	_tracking.clear()
	_searching.clear()
	_job_actor.clear()
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != APPROACH_KIND or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var actor_id := String(_restrict_to_for.call(String(job["id"])))
		if actor_id.is_empty():
			continue
		_tracking[actor_id] = String(job["id"])
		_job_actor[String(job["id"])] = actor_id

## Once per tick (see class doc for the rule order). Nothing here moves or removes an actor, so one
## actors_by_tile() map serves the whole pass.
func advance(actors: Array[Dictionary], tick: int) -> void:
	var by_tile := TargetingType.actors_by_tile(actors)
	for actor in actors:
		if not (actor.get("combat") is Dictionary):
			continue
		var actor_id: String = String(actor["id"])
		if bool((actor.get("health", {}) as Dictionary).get("dead", false)):
			forget(actor_id)
			continue
		var own_faction := TargetingType.actor_faction(actor)
		if _relations.relation(own_faction, "colony") != "hostile":
			forget(actor_id)
			continue
		# Rule 2 before rule 1: release even on the tick adjacency becomes true.
		if _combat_owns.call(actor_id):
			_release_tracking(actor_id) # rule 2: never keep tracking while CombatGiver owns this actor
			continue
		if not _tracking.has(actor_id):
			_adopt_existing_job(actor_id) # a job CombatGiver's own interrupt paused, not cancelled, survives its episode
		if _tracking.has(actor_id):
			var job_id: String = String(_tracking[actor_id])
			var job: Dictionary = _get_job.call(job_id)
			var status := String(job.get("status", ""))
			# Rule 2.5, before rule 1's early return: a stale job's target can die while the actor stands
			# next to a different hostile, and the stale job (and its reservation) must still be cancelled.
			var lost := _target_lost(job_id, actors)
			var blocked_unreachable := status == "queued" and String(job.get("reason", "")) == BLOCKED_TARGET_UNREACHABLE
			if lost or blocked_unreachable:
				_cancel_job.call(job_id)
				_tracking.erase(actor_id)
				_job_targets.erase(job_id)
				_job_actor.erase(job_id)
			elif status in ["active", "queued"]:
				continue # rule 3: still a live, valid target -- leave it running regardless of adjacency
			else:
				# Completed, or cancelled elsewhere (unreachable mid-walk): fall through to a fresh search.
				_tracking.erase(actor_id)
				_job_targets.erase(job_id)
				_job_actor.erase(job_id)
		if not TargetingType.nearest_adjacent_hostile(actor, by_tile, _relations,
				_object_at, _object_health_at, _object_faction_at).is_empty():
			continue # rule 1: the attack rule already covers whichever hostile this actor now stands adjacent to
		if _searching.has(actor_id):
			_advance_search(actor, actor_id, tick)
			continue
		_start_search(actor, actor_id, actors, tick)

## True when job_id's recorded target is gone: an actor removed or dead, or an object whose health
## and placed-object records have both cleared. No recorded target is never "lost".
func _target_lost(job_id: String, actors: Array[Dictionary]) -> bool:
	var target: Dictionary = _job_targets.get(job_id, {})
	if target.is_empty():
		return false
	if String(target["kind"]) == "actor":
		var target_id := String(target["id"])
		for other in actors:
			if String(other["id"]) == target_id:
				return bool((other.get("health", {}) as Dictionary).get("dead", false))
		return true
	var tile: Vector3i = target["tile"]
	return _object_health_at.call(tile).is_empty() or String(_object_at.call(tile)).is_empty()

## Every living actor and placed object with health that `actor`'s faction is hostile to.
func _hostile_targets(actor: Dictionary, actors: Array[Dictionary]) -> Array[Dictionary]:
	var own_faction := TargetingType.actor_faction(actor)
	var targets: Array[Dictionary] = []
	for other in actors:
		if other == actor or not other.has("health"):
			continue
		if bool((other["health"] as Dictionary).get("dead", false)):
			continue
		if _relations.relation(own_faction, TargetingType.actor_faction(other)) != "hostile":
			continue
		targets.append({"kind": "actor", "id": String(other["id"]), "tile": TileGrid.tile_of(other)})
	for placed_object in (_list_objects.call() as Array):
		var tile := TileGrid.tile_of(placed_object)
		var health: Dictionary = _object_health_at.call(tile)
		if health.is_empty():
			continue
		if _relations.relation(own_faction, String(_object_faction_at.call(tile))) != "hostile":
			continue
		targets.append({"kind": "object", "tile_key": TileGrid.coord_key(tile), "tile": tile})
	return targets

## The Chebyshev-adjacent tile of target_tile nearest `start` that is in bounds, passable, reservable,
## unreserved and region-reachable; null when none qualifies.
func _best_adjacent_tile(actor_id: String, start: Vector3i, target_tile: Vector3i):
	var best: Variant = null
	var best_distance := -1
	for offset in NEIGHBOR_OFFSETS:
		var candidate := target_tile + offset
		if candidate.x < 0 or candidate.y < 0 or candidate.x > _bounds_max.x or candidate.y > _bounds_max.y:
			continue
		if not bool((_passable_for_actor.call(actor_id, candidate) as Dictionary).get("passable", false)):
			continue
		if not bool(_may_reserve_target.call(actor_id, candidate)):
			continue
		if bool(_is_target_reserved.call(candidate)):
			continue
		if not bool(_reachable.call(start, candidate)):
			continue
		var distance := TileGrid.manhattan(candidate, start)
		if best == null or distance < best_distance:
			best = candidate
			best_distance = distance
	return best

## Tie-break at equal route length: actor before object, then ascending id / tile key.
static func _target_precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_is_actor := String(a["kind"]) == "actor"
	var b_is_actor := String(b["kind"]) == "actor"
	if a_is_actor != b_is_actor:
		return a_is_actor
	if a_is_actor:
		return String(a["id"]) < String(b["id"])
	return String(a["tile_key"]) < String(b["tile_key"])

## One candidate tile per hostile target, sorted by Chebyshev distance: an admissible lower bound
## with diagonal moves (Manhattan is not), so _search_can_stop() never prunes a nearer target.
func _start_search(actor: Dictionary, actor_id: String, actors: Array[Dictionary], tick: int) -> void:
	var start := TileGrid.tile_of(actor)
	var candidates: Array = []
	for target in _hostile_targets(actor, actors):
		var tile: Variant = _best_adjacent_tile(actor_id, start, target["tile"])
		if tile == null:
			continue
		var distance: int = TileGrid.chebyshev(tile, start)
		candidates.append({"tile": tile, "target": target, "distance": distance})
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return _target_precedes(a["target"], b["target"]))
	_searching[actor_id] = {"candidates": candidates, "cursor": 0, "search": null, "found": []}
	_advance_search(actor, actor_id, tick)

## Search phase: one bounded resume() per tick, recording reachable candidates and stopping once the
## next one's Chebyshev distance exceeds the best route. Commit phase: recheck one ranked candidate
## per tick for a reservation race.
func _advance_search(actor: Dictionary, actor_id: String, tick: int) -> void:
	var state: Dictionary = _searching[actor_id]
	if not state.has("ranked"):
		var candidates: Array = state["candidates"]
		var found: Array = state["found"]
		var cursor: int = int(state["cursor"])
		if cursor < candidates.size() and not _search_can_stop(candidates, cursor, found):
			_advance_candidate_search(actor, state, cursor)
			return
		state["ranked"] = _rank_found(found)
		state["commit_cursor"] = 0
		return
	_advance_commit(actor_id, state, tick)

func _advance_candidate_search(actor: Dictionary, state: Dictionary, cursor: int) -> void:
	var candidates: Array = state["candidates"]
	var found: Array = state["found"]
	var entry: Dictionary = candidates[cursor]
	var tile: Vector3i = entry["tile"]
	var actor_id: String = String(actor["id"])
	var actor_faction := TargetingType.actor_faction(actor)
	var search: RerouteType = state.get("search")
	if search == null:
		var start := TileGrid.tile_of(actor)
		search = RerouteType.new(start, tile, _routable_to.call(tile, actor_faction), Vector3i.ZERO, _bounds_max, _reachable)
		state["search"] = search
	if not search.is_terminal():
		if bool(_route_budget.get(actor_id, false)):
			return
		search.resume()
		_route_budget[actor_id] = true
	if not search.is_terminal():
		return
	if search.get_status() == RerouteType.STATUS_FOUND:
		found.append({"tile": tile, "target": entry["target"], "length": search.get_path().size() - 1})
	state["cursor"] = cursor + 1
	state["search"] = null

func _search_can_stop(candidates: Array, cursor: int, found: Array) -> bool:
	if found.is_empty():
		return false
	return int(candidates[cursor]["distance"]) > _shortest_found_length(found)

func _shortest_found_length(found: Array) -> int:
	var best := -1
	for entry in found:
		var length := int(entry["length"])
		if best < 0 or length < best:
			best = length
	return best

func _rank_found(found: Array) -> Array:
	var ranked: Array = found.duplicate()
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["length"]) != int(b["length"]):
			return int(a["length"]) < int(b["length"])
		return _target_precedes(a["target"], b["target"]))
	return ranked

func _advance_commit(actor_id: String, state: Dictionary, tick: int) -> void:
	var ranked: Array = state["ranked"]
	var commit_cursor: int = int(state["commit_cursor"])
	if commit_cursor >= ranked.size():
		_searching.erase(actor_id) # rule 5: nothing reachable, retried fresh next tick
		return
	var entry: Dictionary = ranked[commit_cursor]
	var tile: Vector3i = entry["tile"]
	if _is_target_reserved.call(tile):
		state["commit_cursor"] = commit_cursor + 1
		return
	_searching.erase(actor_id)
	_commit(actor_id, entry["target"], tile, tick)

## Submits through submit_autonomous() (never refused by may_be_ordered) and records the target.
func _commit(actor_id: String, target: Dictionary, tile: Vector3i, tick: int) -> void:
	var result: Dictionary = _submit_job.call(tile, APPROACH_PRIORITY, tick, APPROACH_KIND, actor_id)
	if not result.get("ok", false):
		return
	var job_id: String = String(result["job_id"])
	_tracking[actor_id] = job_id
	_job_actor[job_id] = actor_id
	if String(target["kind"]) == "actor":
		_job_targets[job_id] = {"kind": "actor", "id": String(target["id"])}
	else:
		_job_targets[job_id] = {"kind": "object", "tile": target["tile"]}
