class_name TrenchSystem
extends RefCounted

## Trenches and rescue (ADR 026, colonist-ai.md 3.6): trapping, a hostile's escape_trench
## climb-out, and the rescue bookkeeping RescueGiver reads. RescueGiver decides when a rescue exists.
## Invariants:
## - Only a colonist (worker component) or an actor hostile to the colony is trapped.
## - Non-hostile `trapped` is exactly {"tile"} and needs a rescuer; hostile is {"tile",
##   "ticksRemaining", "fromTile"} in this key order (state_hash() hashes JSON.stringify()).
## - trapped.ticksRemaining mirrors the escape_trench job's work timer; it never counts on its own.
## - A rescue job never targets, nor is routed through, a trench tile.
## - Owns no persisted state; rescue_status and trap_tile_before are never saved or hashed.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")
const RelationsType = preload("res://scripts/core/relations/relations.gd")

const TILE_TRENCH := ContentRegistryType.TILE_TRENCH
const DEFAULT_TRENCH_CLIMB_TICKS := 40 ## content/actors.json tunables.wild.trench_climb_ticks default

## victim colonist_id -> last exposed rescue reason ("" when none, colonist-ai.md 3.8).
var rescue_status: Dictionary = {}
## The advancing colonist's tile before its ToilExecutor.advance(); scratch, never saved.
var trap_tile_before: Vector3i = Vector3i.ZERO
## (actor) -> void after a rescue or escape writes x/y: WorldState's ActorIndex.moved (A4).
var on_actor_moved: Callable = func(_actor: Dictionary) -> void: pass

var _content: ContentRegistryType
var _relations: RelationsType
var _tile_grid: TileGridType
var _passability: PassabilityType
var _scheduler: AssignmentType
var _progress_table: WorkProgressType
var _clock: SeededClock
var _get_colonists: Callable
var _find_colonist: Callable
var _find_job_colonist: Callable
var _finish_job: Callable
var _drop_carried_haul_item: Callable
var _resolve_giver_association: Callable
var _set_work_progress: Callable
var _need_searching_ids: Callable
var _need_pending_assignments: Callable
var _combat_owns: Callable
var _rescue_victim_id_for_job: Callable
var _resolve_rescue_job: Callable

## The giver callables are lambdas over WorldState's current givers: StateCodec.decode()
## rebuilds NeedGiver/RescueGiver (_build_dimension_services()) after this module exists.
func _init(content: ContentRegistryType, relations: RelationsType, tile_grid: TileGridType, p_passability: PassabilityType,
		scheduler: AssignmentType, progress_table: WorkProgressType, clock: SeededClock, get_colonists: Callable,
		find_colonist: Callable, find_job_colonist: Callable, finish_job: Callable, drop_carried_haul_item: Callable,
		resolve_giver_association: Callable, set_work_progress: Callable, need_searching_ids: Callable,
		need_pending_assignments: Callable, combat_owns: Callable, rescue_victim_id_for_job: Callable,
		resolve_rescue_job: Callable) -> void:
	_content = content
	_relations = relations
	_tile_grid = tile_grid
	_passability = p_passability
	_scheduler = scheduler
	_progress_table = progress_table
	_clock = clock
	_get_colonists = get_colonists
	_find_colonist = find_colonist
	_find_job_colonist = find_job_colonist
	_finish_job = finish_job
	_drop_carried_haul_item = drop_carried_haul_item
	_resolve_giver_association = resolve_giver_association
	_set_work_progress = set_work_progress
	_need_searching_ids = need_searching_ids
	_need_pending_assignments = need_pending_assignments
	_combat_owns = combat_owns
	_rescue_victim_id_for_job = rescue_victim_id_for_job
	_resolve_rescue_job = resolve_rescue_job

# --- rescue pools and reasons (RescueGiver's inputs) ---------------------------

## Workers eligible for a rescue this tick: not trapped, not need-searching or need-committed
## (rescue never pre-empts a need), not combat-owned, and orderable (F3). One already on a rescue
## stays in; RescueGiver's _pending refuses it.
func rescue_candidates() -> Array[Dictionary]:
	var searching: Array[String] = _need_searching_ids.call()
	var need_committed: Dictionary = _need_pending_assignments.call()
	var filtered: Array[Dictionary] = []
	for colonist in _get_colonists.call():
		var colonist_id: String = String(colonist["id"])
		if colonist.get("trapped") != null: continue
		if searching.has(colonist_id) or need_committed.has(colonist_id): continue
		if _combat_owns.call(colonist_id): continue
		if not ActorTableType.has_component(colonist, "worker", _content): continue
		# F3's order gate: a raider (ADR 014) has a worker component but never rescues a colonist.
		if not _passability.colonist_may_be_ordered(colonist_id): continue
		filtered.append(colonist)
	return filtered

## RescueGiver's victim pool: every trapped actor whose `trapped` is the bare {"tile"}
## shape; a hostile one (with ticksRemaining) escapes on its own via escape_trench.
func trapped_rescue_victims() -> Array[Dictionary]:
	var victims: Array[Dictionary] = []
	for colonist in _get_colonists.call():
		var trapped: Variant = colonist.get("trapped")
		if trapped == null or (trapped as Dictionary).has("ticksRemaining"): continue
		victims.append(colonist)
	return victims

## "" when a trapped colonist has no exposed reason (a rescuer is committed, or no search
## ran yet); REASON_NO_RESCUER_AVAILABLE once a search found no reachable rescuer.
func get_colonist_rescue_reason(colonist_id: String) -> String:
	return String(rescue_status.get(colonist_id, ""))

## set_reason callable for RescueGiver, keyed by the victim's id (never the rescuer's).
func set_rescue_reason(colonist_id: String, reason: String) -> void:
	rescue_status[colonist_id] = reason

## RescueGiver's target candidates: every passable, non-trench tile cardinally adjacent to
## the victim, in ADR 026's row-major order. RescueGiver ranks them by real route length.
func rescue_target_candidates(victim_tile: Vector3i) -> Array[Vector3i]:
	var candidates: Array[Vector3i] = []
	for neighbor in [Vector3i(victim_tile.x, victim_tile.y - 1, victim_tile.z), Vector3i(victim_tile.x - 1, victim_tile.y, victim_tile.z),
			Vector3i(victim_tile.x + 1, victim_tile.y, victim_tile.z), Vector3i(victim_tile.x, victim_tile.y + 1, victim_tile.z)]:
		if bool(_passability.passability(neighbor)["passable"]) and _tile_grid.tile_at(neighbor) != TILE_TRENCH:
			candidates.append(neighbor)
	return candidates

## The trapped colonist this job was committed to (never another adjacent trapped one), or {}.
func _rescue_victim_for_job(job_id: String) -> Dictionary:
	var victim_id: String = _rescue_victim_id_for_job.call(job_id)
	if victim_id.is_empty():
		return {}
	var victim: Dictionary = _find_colonist.call(victim_id)
	if victim.is_empty() or victim.get("trapped") == null:
		return {}
	return victim

# --- rescue travel --------------------------------------------------------------

## A freshly activated rescue may be driven as-is: target still passable and non-trench, and a
## path starting at the rescuer ends on the target and avoids trenches.
func rescue_activation_safe(colonist: Dictionary, job: Dictionary, path: Array) -> bool:
	var target: Vector3i = job["target"]
	if is_trench_tile(target) or not bool(_passability.passability(target, String(colonist.get("factionId", "colony")))["passable"]):
		return false
	if path.is_empty() or path[0] != TileGrid.tile_of(colonist):
		return true
	if path[path.size() - 1] != target:
		return false
	for step in path:
		if is_trench_tile(step):
			return false
	return true

## Cancels a rescue whose travel can no longer be completed safely (never resubmitted under the
## same rescuer), drops its job-scoped progress and tells RescueGiver.
func retire_rescue_job(job_id: String, job: Dictionary = {}) -> void:
	if job.is_empty():
		job = _scheduler.queue.get_job(job_id)
	var was_active := String(job.get("status", "")) == "active"
	if _finish_job.call(job_id, "cancel_job").get("ok", false):
		_progress_table.clear_terminated_job(job_id, job, was_active)
	_resolve_rescue_job.call(job_id)

## Trench tiles impassable and no impassable-target exception, so a blocked target reads as
## unreachable. `_target` is unused (hook-signature symmetry).
func rescue_routable_to(_target: Vector3i, faction_id: String = "colony") -> Callable:
	return func(tile: Vector3i) -> float:
		return 0.0 if is_trench_tile(tile) else _passability.passable_for_faction(tile, faction_id)

## is_trench callable for RescueGiver.
func is_trench_tile(tile: Vector3i) -> bool:
	return _tile_grid.tile_at(tile) == TILE_TRENCH

## The rescue arm of the work-complete hook: the rescuer lifts its own committed victim
## onto the rescuer's tile.
func complete_rescue(job_id: String) -> void:
	var rescuer: Dictionary = _find_job_colonist.call(job_id)
	var victim := _rescue_victim_for_job(job_id)
	if not rescuer.is_empty() and not victim.is_empty():
		TileGrid.write_tile(victim, TileGrid.tile_of(rescuer))
		on_actor_moved.call(victim)
		victim["trapped"] = null

# --- trapping -------------------------------------------------------------------

## ADR 026: traps an actor whose route step lands it on a trench (the "still routing"
## case; trap_on_work_complete() covers arrival and completion in the same tick).
func check_trench_arrival(colonist: Dictionary, job_id: String, tile_before: Vector3i) -> void:
	if colonist.get("trapped") != null: return
	var tile_after := TileGrid.tile_of(colonist)
	if tile_after == tile_before or _tile_grid.tile_at(tile_after) != TILE_TRENCH: return
	if not _actor_traps_on_trench(colonist): return
	_trap_actor(colonist, job_id, tile_before)

## Arrival and work completion can land in the same tick, so trapping pre-empts the completion
## effect; true when it trapped. trap_tile_before != target excludes an actor already on a target
## that changed kind; the position check rejects a stale one. escape_trench falls through.
func trap_on_work_complete(job_id: String, job: Dictionary, target: Vector3i) -> bool:
	if String(job.get("kind", "")) != "escape_trench" and trap_tile_before != target and _tile_grid.tile_at(target) == TILE_TRENCH:
		var arriving_actor: Dictionary = _find_job_colonist.call(job_id)
		if not arriving_actor.is_empty() and arriving_actor.get("trapped") == null \
				and TileGrid.tile_of(arriving_actor) == target \
				and _actor_traps_on_trench(arriving_actor):
			_trap_actor(arriving_actor, job_id, trap_tile_before)
			return true
	return false

## Only a colonist (worker component, ADR 012) or an actor hostile to the colony (ADR 014)
## is trapped; a trader crosses a trench unaffected.
func _actor_traps_on_trench(actor: Dictionary) -> bool:
	if ActorTableType.has_component(actor, "worker", _content):
		return true
	return _relations.is_hostile({"faction_id": String(actor.get("factionId", "colony"))}, {"faction_id": "colony"})

## Releases job_id like cancel_job, records `trapped`, and submits escape_trench when hostile.
func _trap_actor(colonist: Dictionary, job_id: String, from_tile: Vector3i) -> void:
	var tile := TileGrid.tile_of(colonist)
	var hostile: bool = _relations.is_hostile({"faction_id": String(colonist.get("factionId", "colony"))}, {"faction_id": "colony"})
	# Key order matches EntityCodec._decode_trapped_field(): state_hash() is insertion-order-sensitive.
	colonist["trapped"] = ({"tile": tile, "ticksRemaining": _trench_climb_ticks(colonist), "fromTile": from_tile}
		if hostile else {"tile": tile})
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("status", "")) == "active":
		var job_kind := String(job.get("kind", ""))
		if job_kind in ["haul", "site_fetch", "craft_fetch"]: _drop_carried_haul_item.call(job_id)
		if _finish_job.call(job_id, "cancel_job").get("ok", false):
			_progress_table.clear_terminated_job(job_id, job, true)
			_resolve_giver_association.call(job_id, job_kind)
	if not hostile: return
	_submit_trench_escape(colonist, tile)

# --- climb-out (escape_trench) --------------------------------------------------

## Submits (or re-submits, after a blocked climb-out) the actor's own escape_trench job
## targeting its own tile (the self-tile reservation exception).
func _submit_trench_escape(colonist: Dictionary, tile: Vector3i) -> void:
	_scheduler.submit_autonomous(tile, 1, _clock.tick, "escape_trench", String(colonist["id"]))

## Once per tick, before colonists advance: stamps each newly active escape_trench duration onto
## its target's progress key (read fresh, so a queued escape needs nothing saved).
func activate_pending_escapes() -> void:
	var assignments := _scheduler.get_assignments()
	for worker_id in assignments:
		var job_id: String = String(assignments[worker_id]["job_id"])
		var job := _scheduler.queue.get_job(job_id)
		if String(job.get("kind", "")) != "escape_trench" or String(job.get("status", "")) != "active": continue
		var target: Vector3i = job["target"]
		if _progress_table.get_progress(target) != null: continue
		var actor: Dictionary = _find_colonist.call(worker_id)
		if actor.is_empty(): continue
		_set_work_progress.call(target, _trench_climb_ticks(actor), job_id)

func _trench_climb_ticks(colonist: Dictionary) -> int: # content/actors.json tunables.wild.trench_climb_ticks
	var definition: Dictionary = _content.get_entry("actors", String(colonist.get("kind", "")))
	var wild_tunables: Dictionary = (definition.get("tunables", {}) as Dictionary).get("wild", {})
	return int(wild_tunables.get("trench_climb_ticks", DEFAULT_TRENCH_CLIMB_TICKS))

## Called with every work-progress write: an escaping actor's trapped.ticksRemaining
## follows its escape_trench job's real work timer.
func mirror_climb_ticks(target: Vector3i, ticks_remaining: int) -> void:
	var escaping := _escaping_actor_at(target)
	if not escaping.is_empty() and escaping.get("trapped") != null:
		(escaping["trapped"] as Dictionary)["ticksRemaining"] = ticks_remaining

## The actor with an active escape_trench job targeting `target`, found through the
## scheduler's assignments (never trapped.tile alone: two actors may share a trench tile).
func _escaping_actor_at(target: Vector3i) -> Dictionary:
	var assignments := _scheduler.get_assignments()
	for worker_id in assignments:
		var job_id: String = String(assignments[worker_id]["job_id"])
		var job := _scheduler.queue.get_job(job_id)
		if String(job.get("kind", "")) == "escape_trench" and String(job.get("status", "")) == "active" \
				and job.get("target") == target:
			return _find_colonist.call(worker_id)
	return {}

## The escape_trench arm of the work-complete hook: climbs out to from_tile when passable,
## else the first passable non-trench neighbour; with no exit it stays trapped and retries.
func complete_escape(job_id: String, target: Vector3i) -> void:
	var actor: Dictionary = _find_job_colonist.call(job_id)
	if not actor.is_empty():
		var trapped_state: Dictionary = actor.get("trapped", {})
		var from_tile: Vector3i = trapped_state.get("fromTile", target)
		var actor_faction := String(actor.get("factionId", "colony"))
		var exit_tile := _trench_exit_tile(target, from_tile, actor_faction)
		if exit_tile.x >= 0:
			TileGrid.write_tile(actor, exit_tile)
			on_actor_moved.call(actor)
			actor["trapped"] = null
		else:
			# Recoverable blocked-exit outcome: stays trapped, retries.
			_submit_trench_escape(actor, target)

## escape_trench's exit rule: from_tile when passable for the actor's faction, else
## ADR 026's row-major neighbour order. Vector3i(-1, -1, 0) means no exit (caller retries).
func _trench_exit_tile(tile: Vector3i, from_tile: Vector3i, faction_id: String) -> Vector3i:
	if from_tile != tile and bool(_passability.passability(from_tile, faction_id)["passable"]) \
			and _tile_grid.tile_at(from_tile) != TILE_TRENCH:
		return from_tile
	for neighbor in [Vector3i(tile.x, tile.y - 1, tile.z), Vector3i(tile.x - 1, tile.y, tile.z), Vector3i(tile.x + 1, tile.y, tile.z), Vector3i(tile.x, tile.y + 1, tile.z)]:
		if bool(_passability.passability(neighbor, faction_id)["passable"]) and _tile_grid.tile_at(neighbor) != TILE_TRENCH:
			return neighbor
	return Vector3i(-1, -1, 0)
