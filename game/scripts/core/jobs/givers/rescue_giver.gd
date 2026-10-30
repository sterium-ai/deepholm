class_name RescueGiver
extends RefCounted

## Job-giver for `rescue` (ADR 026): decides when a rescue job should exist for a trapped
## colonist, with NeedGiver's committed-job pattern (submit with restrict_to, budgeted multi-tick
## search). Rescuers are pre-sorted by Manhattan distance; each in turn ranks the victim's
## non-trench neighbours by real route length.
## Route safety: searches use the same unrestricted routable_to that go_to walks, and a pair is
## accepted only if that real path crosses no trench tile at all; after commit, TrenchSystem
## keeps re-routes and activation trench-safe.
## Route budget (ADR 004): at most one resume() per colonist per tick, shared through
## WorldState._route_budget with GlobalAssignment and ToilExecutor; advance() runs after
## GlobalAssignment.tick() (which clears it) and before TickPipeline._advance_colonists().
## Reservations: the "trapped:<victim_id>" key is acquired only through JobQueue activation
## (extra_keys_for_job()), never directly; dedup reads _job_victim, which also covers queued and
## suspended rescues that hold no key.
## Persistence: _job_victim is saved verbatim (target adjacency cannot identify a victim) and
## restored before JobQueue.restore(); _pending is rebuilt from restrict_to after
## restore_scheduling().

const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

const REASON_NO_RESCUER_AVAILABLE := "no_rescuer_available"

## A candidate that keeps moving restarts its sweep at most this many times, then is skipped,
## so a walking worker cannot starve later-ranked (idle) candidates.
const MAX_STALE_RETRIES := 3

var _priority: int
var _bounds_max: Vector3i
var _reservation_table
var _tile_key: Callable
var _routable_to: Callable
## Handed to every RouteSearch: a target in another region is refused before it expands.
var _region_reachable: Callable
var _rescue_target_candidates: Callable
var _submit_job: Callable
var _set_reason: Callable
var _interrupt_current_job: Callable
var _resume_interrupted_job: Callable
var _is_trench: Callable
## Shared by reference with GlobalAssignment and ToilExecutor: colonist_id -> true once its
## one resume() this tick is spent.
var _route_budget: Dictionary
## colonist_id -> resume() calls in the last advance(); telemetry only (ADR 004).
var _tick_route_resumes: Dictionary = {}
var _get_job: Callable
## TrenchSystem.retire_rescue_job: cancels a committed rescue and calls resolve_job().
var _retire_job: Callable

## victim_id -> {victim_tile, targets, candidates: [{id, pos}], cursor, target_cursor, search,
## found, stale_retries}: a search not yet committed.
var _searching: Dictionary = {}
## rescuer_id -> job_id; merged into TickPipeline._committed_jobs() like NeedGiver's.
var _pending: Dictionary = {}
## job_id -> victim_id. A retired rescue is never resubmitted under a new id, so no association
## moves between ids.
var _job_victim: Dictionary = {}

## reservation_table is only peeked, never acquired. route_budget must be the shared instance,
## never a copy. interrupt/resume are the same NeedsSystem wrappers NeedGiver gets.
## region_reachable is Passability.region_reachable (ADR 054); invalid means no region check.
func _init(priority: int, bounds_max: Vector3i, reservation_table, tile_key: Callable,
		routable_to: Callable, rescue_target_candidates: Callable, submit_job: Callable,
		set_reason: Callable, interrupt_current_job: Callable, resume_interrupted_job: Callable,
		is_trench: Callable, route_budget: Dictionary, get_job: Callable, retire_job: Callable,
		region_reachable: Callable = Callable()) -> void:
	_priority = priority
	_bounds_max = bounds_max
	_reservation_table = reservation_table
	_tile_key = tile_key
	_routable_to = routable_to
	_region_reachable = region_reachable
	_rescue_target_candidates = rescue_target_candidates
	_submit_job = submit_job
	_set_reason = set_reason
	_interrupt_current_job = interrupt_current_job
	_resume_interrupted_job = resume_interrupted_job
	_is_trench = is_trench
	_route_budget = route_budget
	_get_job = get_job
	_retire_job = retire_job

func _trapped_key(victim_id: String) -> String:
	return "trapped:%s" % victim_id

func get_pending_job(colonist_id: String) -> String:
	return String(_pending.get(colonist_id, ""))

## Fed to GlobalAssignment.tick() via TickPipeline._committed_jobs(), so a committed rescue wins
## over ordinary work for that worker.
func get_pending_assignments() -> Dictionary:
	return _pending.duplicate()

func colonist_for_job(job_id: String) -> String:
	for rescuer_id in _pending.keys():
		if String(_pending[rescuer_id]) == job_id:
			return String(rescuer_id)
	return ""

## Once per tick, after GlobalAssignment.tick() and before _advance_colonists() (shared route
## budget). Rescue ranks below needs, above work (colonist-ai.md 3.6): `candidates` from
## TrenchSystem.rescue_candidates() already excludes trapped and need-committed colonists.
func advance(candidates: Array[Dictionary], victims: Array[Dictionary], tick: int) -> void:
	_tick_route_resumes = {}
	# Retire a commitment the scheduler found unreachable, so the victim can pick anyone.
	for rescuer_id in _pending.keys().duplicate():
		var job_id: String = String(_pending[rescuer_id])
		var job: Dictionary = _get_job.call(job_id)
		if String(job.get("status", "")) == "queued" \
				and String(job.get("reason", "")) == JobQueueType.BLOCKED_TARGET_UNREACHABLE:
			_retire_job.call(job_id)
	# Dedup on _job_victim: a queued or suspended rescue holds no "trapped:" key.
	var claimed_victims: Dictionary = {}
	for victim_id in _job_victim.values():
		claimed_victims[String(victim_id)] = true
	for victim in victims:
		var victim_id: String = String(victim["id"])
		if claimed_victims.has(victim_id):
			continue
		if _searching.has(victim_id):
			_advance_search(victim_id, candidates, tick)
		else:
			_start_search(victim, candidates, tick)

## The Manhattan pre-sort (ties by id) is only a search order; the choice is by real route.
func _start_search(victim: Dictionary, candidates: Array[Dictionary], tick: int) -> void:
	var victim_id: String = String(victim["id"])
	var victim_tile := TileGrid.tile_of(victim)
	var targets: Array = []
	for target in (_rescue_target_candidates.call(victim_tile) as Array):
		if not _reservation_table.is_reserved(String(_tile_key.call(target))):
			targets.append(target)
	if targets.is_empty():
		_onset_failed(victim_id)
		return
	var pool: Array = []
	for candidate in candidates:
		var candidate_id: String = String(candidate["id"])
		if _pending.has(candidate_id):
			continue
		pool.append({"id": candidate_id, "pos": TileGrid.tile_of(candidate)})
	if pool.is_empty():
		_onset_failed(victim_id)
		return
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da: int = TileGrid.manhattan(a["pos"], victim_tile)
		var db: int = TileGrid.manhattan(b["pos"], victim_tile)
		if da != db:
			return da < db
		return String(a["id"]) < String(b["id"]))
	_searching[victim_id] = {"victim_tile": victim_tile, "targets": targets, "candidates": pool,
		"cursor": 0, "target_cursor": 0, "search": null, "found": [], "stale_retries": 0}
	_set_reason.call(victim_id, "")
	_advance_search(victim_id, candidates, tick)

## Candidates in ranked order; each sweeps every target from a fixed position, then commits to
## the shortest safe route. The live position is rechecked only after a full sweep: if it moved,
## the sweep is redone (up to MAX_STALE_RETRIES). No safe route skips to the next candidate.
func _advance_search(victim_id: String, candidates: Array[Dictionary], tick: int) -> void:
	var state: Dictionary = _searching[victim_id]
	var pool: Array = state["candidates"]
	var cursor: int = int(state["cursor"])
	if cursor >= pool.size():
		_searching.erase(victim_id)
		_onset_failed(victim_id)
		return
	var candidate: Dictionary = pool[cursor]
	var candidate_id: String = String(candidate["id"])
	if _pending.has(candidate_id):
		_advance_to_next_candidate(state)
		return
	var targets: Array = state["targets"]
	var target_cursor: int = int(state["target_cursor"])
	if target_cursor < targets.size():
		_advance_target_search(state, candidate, target_cursor)
		return
	var live := _find_candidate(candidate_id, candidates)
	if live.is_empty():
		_advance_to_next_candidate(state)
		return
	var live_pos := TileGrid.tile_of(live)
	if live_pos != candidate["pos"]:
		var stale_retries: int = int(state.get("stale_retries", 0)) + 1
		if stale_retries > MAX_STALE_RETRIES:
			_advance_to_next_candidate(state)
			return
		state["stale_retries"] = stale_retries
		pool[cursor] = {"id": candidate_id, "pos": live_pos}
		state["target_cursor"] = 0
		state["found"] = []
		return
	var found: Array = state["found"]
	if found.is_empty():
		_advance_to_next_candidate(state)
		return
	var best: Dictionary = _shortest_found(found)
	var target: Vector3i = best["target"]
	if _reservation_table.is_reserved(String(_tile_key.call(target))):
		_advance_to_next_candidate(state)
		return
	var rescuer := _find_candidate(candidate_id, candidates)
	if rescuer.is_empty():
		_advance_to_next_candidate(state)
		return
	_searching.erase(victim_id)
	_commit(victim_id, rescuer, target, tick)

func _advance_to_next_candidate(state: Dictionary) -> void:
	state["cursor"] = int(state["cursor"]) + 1
	state["target_cursor"] = 0
	state["found"] = []
	state["search"] = null
	state["stale_retries"] = 0

## Same routable_to as go_to, so the path found is the one walked; a path crossing any trench is
## rejected, never assumed avoidable. Skips the tick when the candidate's budget is spent.
func _advance_target_search(state: Dictionary, candidate: Dictionary, target_cursor: int) -> void:
	var targets: Array = state["targets"]
	var found: Array = state["found"]
	var target: Vector3i = targets[target_cursor]
	var candidate_id: String = String(candidate["id"])
	var search: RerouteType = state.get("search")
	if search == null:
		search = RerouteType.new(candidate["pos"], target, _routable_to.call(target), Vector3i.ZERO, _bounds_max, _region_reachable)
		state["search"] = search
	if not search.is_terminal():
		if bool(_route_budget.get(candidate_id, false)):
			return
		search.resume()
		_route_budget[candidate_id] = true
		_tick_route_resumes[candidate_id] = int(_tick_route_resumes.get(candidate_id, 0)) + 1
	if not search.is_terminal():
		return
	if search.get_status() == RerouteType.STATUS_FOUND and not _path_crosses_trench(search.get_path()):
		found.append({"target": target, "length": search.get_path().size() - 1})
	state["target_cursor"] = target_cursor + 1
	state["search"] = null

## Any trench, not just the victim's: ordinary routing treats a trench like floor.
func _path_crosses_trench(path: Array) -> bool:
	for step in path:
		if _is_trench.call(step):
			return true
	return false

## At most 1 per colonist, 0 for one the scheduler already routed this tick (ADR 004).
func get_route_telemetry() -> Dictionary:
	return _tick_route_resumes.duplicate()

func _shortest_found(found: Array) -> Dictionary:
	var best: Dictionary = found[0]
	for entry in found:
		if int(entry["length"]) < int(best["length"]):
			best = entry
	return best

func _find_candidate(colonist_id: String, candidates: Array[Dictionary]) -> Dictionary:
	for candidate in candidates:
		if String(candidate["id"]) == colonist_id:
			return candidate
	return {}

## Submit first so a lost race mutates nothing; then interrupt the rescuer and record the victim.
func _commit(victim_id: String, rescuer: Dictionary, target: Vector3i, tick: int) -> void:
	var rescuer_id: String = String(rescuer["id"])
	var result: Dictionary = _submit_job.call(target, _priority, tick, "rescue", rescuer_id)
	if not result.get("ok", false):
		return
	var job_id: String = String(result["job_id"])
	_interrupt_current_job.call(rescuer)
	_pending[rescuer_id] = job_id
	# The "trapped:" key is acquired at activation, through extra_keys_for_job().
	_job_victim[job_id] = victim_id
	_set_reason.call(victim_id, "")

## No interrupt was issued before commit, so nothing resumes (unlike NeedGiver).
func _onset_failed(victim_id: String) -> void:
	_set_reason.call(victim_id, REASON_NO_RESCUER_AVAILABLE)

## Called by ToilBindings, TrenchSystem and death cleanup when a rescue ends; the rescuer resumes
## its paused work the same tick.
func resolve_job(job_id: String) -> void:
	_job_victim.erase(job_id)
	var rescuer_id := colonist_for_job(job_id)
	if rescuer_id.is_empty():
		return
	_pending.erase(rescuer_id)
	_resume_interrupted_job.call(rescuer_id)

## JobQueue's extra-reservation callback: "trapped:<victim_id>" is held only while active;
## [] for any job without a victim.
func extra_keys_for_job(job_id: String) -> Array[String]:
	var victim_id: String = String(_job_victim.get(job_id, ""))
	if victim_id.is_empty():
		return []
	return [_trapped_key(victim_id)]

## TrenchSystem.complete_rescue() reads this: two victims can share a target tile.
func victim_for_job(job_id: String) -> String:
	return String(_job_victim.get(job_id, ""))

## StateCodec saves this verbatim ("rescueVictimAssignments"), never as a per-job field.
func get_job_victims() -> Dictionary:
	return _job_victim.duplicate()

## Must run before JobQueue.restore(), whose reservation rebuild calls extra_keys_for_job().
func restore_victim_assignments(assignments: Dictionary) -> void:
	_job_victim = assignments.duplicate()
	_searching = {}

## Built by StateCodec from each rescue job's restored restrict_to; called after
## restore_scheduling(), before any advance()/resolve_job().
func restore_pending_assignments(pending: Dictionary) -> void:
	_pending = pending.duplicate()

## JobQueue.restore() builds a new table; called right after it so peeks never read a stale one.
func set_reservation_table(reservation_table) -> void:
	_reservation_table = reservation_table
