class_name NeedGiver
extends RefCounted

## Job-giver for eat_food/drink_water/sleep (colonist-ai.md 3.1/3.6/3.8): decides when a need
## job should exist and submits it through the same scheduler entry point as any order; the
## toil executor runs it (one work engine). Needs state stays on the colonist (NeedsSystem).
## Critical needs interrupt in-progress work; urgent needs interrupt only at a toil boundary,
## and both free the colonist's scheduler assignment first (a haul idles between toils with
## its assignment still live).

const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const REASON_NEED_UNMET_PREFIX := "need_unmet:"
const REASON_BLOCKED_SOURCE_RESERVED := "blocked_source_reserved"

const JOB_KIND_BY_NEED := {"food": "eat_food", "water": "drink_water", "rest": "sleep"}

var _need_definitions: Dictionary
## The content bundle ActorTable.get_component() (ADR 012) resolves a
## colonist's "needs"/"mover" components against.
var _content
var _need_full: int
var _retry_base_ticks: int
var _retry_cap_ticks: int
var _priority: int
var _bounds_max: Vector2i
var _reservation_table
var _claimed_targets: Callable
var _source_candidates: Callable
## kind -> source_candidates(kind), cached for one advance(): nothing in a pass changes a
## need source, a region or a colonist's tile.
var _candidates_this_pass: Dictionary = {}
var _tile_key: Callable
var _routable_to: Callable
## Handed to every RouteSearch: a target in another region is refused before it expands.
var _region_reachable: Callable
var _submit_job: Callable
var _set_reason: Callable
var _emit_need_unmet: Callable
var _interrupt_current_job: Callable
var _resume_interrupted_job: Callable

## colonist_id -> {kind, candidates, distances, cursor, search, found[, ranked]}: a search not
## yet committed to a source; one bounded route resume() per tick.
var _searching: Dictionary = {}
## colonist_id -> job_id, from submit until resolve_job(). Submitted with restrict_to so only
## this colonist can take the job. Persisted (get/restore_pending_assignments) so a paused
## colonist resumes after a load.
var _pending: Dictionary = {}
## "<colonist_id>:<kind>" -> {"backoff_ticks", "retry_at"}: throttles a need with no source.
var _backoff: Dictionary = {}
## "<colonist_id>:<kind>" -> true once need_unmet fired for this onset; cleared on commit.
var _alerted: Dictionary = {}

## need_definitions is shared by reference (tests mutate it in place). reservation_table is
## only peeked here; JobQueue acquires on activation. claimed_targets (NeedsSystem) names
## targets of queued need jobs, which are not reserved until activation, so two colonists never
## submit the same source.
## region_reachable is Passability.region_reachable (ADR 054); invalid means no region check.
func _init(need_definitions: Dictionary, need_full: int, retry_base_ticks: int, retry_cap_ticks: int,
		priority: int, bounds_max: Vector2i, reservation_table, claimed_targets: Callable,
		source_candidates: Callable, tile_key: Callable, routable_to: Callable, submit_job: Callable,
		set_reason: Callable, emit_need_unmet: Callable, interrupt_current_job: Callable,
		resume_interrupted_job: Callable, content_registry, region_reachable: Callable = Callable()) -> void:
	_need_definitions = need_definitions
	_content = content_registry
	_need_full = need_full
	_retry_base_ticks = retry_base_ticks
	_retry_cap_ticks = retry_cap_ticks
	_priority = priority
	_bounds_max = bounds_max
	_reservation_table = reservation_table
	_claimed_targets = claimed_targets
	_source_candidates = source_candidates
	_tile_key = tile_key
	_routable_to = routable_to
	_region_reachable = region_reachable
	_submit_job = submit_job
	_set_reason = set_reason
	_emit_need_unmet = emit_need_unmet
	_interrupt_current_job = interrupt_current_job
	_resume_interrupted_job = resume_interrupted_job

## Components are read through ActorTable (ADR 012), not the colonist dict.
func _needs(colonist: Dictionary) -> Dictionary:
	var needs_component: Variant = ActorTableType.get_component(colonist, "needs", _content)
	return needs_component if needs_component != null else {}

func _route(colonist: Dictionary):
	var mover_component: Variant = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

## Excluded from this tick's fair-scheduler pool (still deciding); pending colonists are not,
## since restrict_to already keeps their job to themselves.
func searching_colonist_ids() -> Array[String]:
	var ids: Array[String] = []
	for colonist_id in _searching.keys():
		ids.append(String(colonist_id))
	return ids

## Backs WorldState.get_active_need_job_id(); "" when none.
func get_pending_job(colonist_id: String) -> String:
	return String(_pending.get(colonist_id, ""))

## Runs once per tick, before the fair scheduler's tick() (colonist-ai.md 3.1).
func advance(colonists: Array[Dictionary], tick: int) -> void:
	_candidates_this_pass.clear()
	for colonist in colonists:
		if not _may_be_ordered(colonist):
			continue
		var colonist_id: String = colonist["id"]
		if _pending.has(colonist_id):
			continue
		if _searching.has(colonist_id):
			_advance_search(colonist, tick)
			continue
		_evaluate(colonist, tick)

## No need job for a faction whose rules.may_be_ordered is false; fails open for an unknown
## faction id.
func _may_be_ordered(colonist: Dictionary) -> bool:
	var faction_id := String(colonist.get("factionId", "colony"))
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_be_ordered", true))

## Called by ToilBindings when a need job finishes or fails, so the paused colonist resumes
## the same tick.
func resolve_job(job_id: String) -> void:
	for colonist_id in _pending.keys():
		if String(_pending[colonist_id]) == job_id:
			_pending.erase(colonist_id)
			_resume_interrupted_job.call(colonist_id)
			return

## "" when job_id is not a pending need job.
func colonist_for_job(job_id: String) -> String:
	for colonist_id in _pending.keys():
		if String(_pending[colonist_id]) == job_id:
			return String(colonist_id)
	return ""

## WorldState._resubmit_unreachable_job() moved the job to a fresh id (colonist-ai.md 3.3): the
## need is not resolved, so the colonist stays paused and watches the new id.
func reassign_job(old_job_id: String, new_job_id: String) -> void:
	var colonist_id := colonist_for_job(old_job_id)
	if colonist_id.is_empty():
		return
	_pending[colonist_id] = new_job_id

## colonist_id -> job_id for StateCodec; this module never touches file I/O.
func get_pending_assignments() -> Dictionary:
	return _pending.duplicate()

## Called once after construction for a loaded world, before any advance()/resolve_job().
func restore_pending_assignments(pending: Dictionary) -> void:
	_pending = pending.duplicate()

func _evaluate(colonist: Dictionary, tick: int) -> void:
	if colonist.get("work") != null:
		if ToilExecutorType.is_interruptible_toil(ToilExecutorType.TOIL_WORK):
			var critical_kind := _most_need_kind_at_or_below(colonist, "critical", tick)
			if not critical_kind.is_empty():
				_interrupt_current_job.call(colonist)
				_start_search(colonist, critical_kind, tick)
		return
	if _route(colonist) != null:
		return
	var kind := _most_need_kind_at_or_below(colonist, "urgent", tick)
	if kind.is_empty():
		return
	# A toil boundary, but a haul between toils still holds its assignment: free it (no-op
	# when the colonist is truly idle).
	_interrupt_current_job.call(colonist)
	_start_search(colonist, kind, tick)

## Lowest need at/below threshold_key, ties by kind name; backed-off kinds skipped.
func _most_need_kind_at_or_below(colonist: Dictionary, threshold_key: String, tick: int) -> String:
	var needs: Dictionary = _needs(colonist)
	var colonist_id: String = colonist["id"]
	var kinds := _need_definitions.keys()
	kinds.sort()
	var best_kind := ""
	var best_value := _need_full + 1
	for kind in kinds:
		var threshold := int(_need_definitions[kind].get(threshold_key, 0))
		var value := int(needs.get(kind, _need_full))
		if value > threshold:
			continue
		if _is_backed_off(colonist_id, kind, tick):
			continue
		if value < best_value:
			best_value = value
			best_kind = kind
	return best_kind

func _is_backed_off(colonist_id: String, kind: String, tick: int) -> bool:
	var backoff: Dictionary = _backoff.get(_key(colonist_id, kind), {})
	return backoff.has("retry_at") and tick < int(backoff["retry_at"])

## "Nearest" is the shortest real route, not Manhattan distance. The Manhattan pre-sort (ties
## row-major) only orders the search and lets it stop once no candidate can beat the best route.
## Reserved/claimed candidates are dropped here and rechecked at commit (searches span ticks).
func _start_search(colonist: Dictionary, kind: String, tick: int) -> void:
	var colonist_id: String = colonist["id"]
	var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var claimed: Dictionary = _claimed_targets.call()
	var candidates: Array[Vector2i] = []
	if not _candidates_this_pass.has(kind):
		_candidates_this_pass[kind] = _source_candidates.call(kind)
	for tile in (_candidates_this_pass[kind] as Array):
		if claimed.has(tile):
			continue
		if not _reservation_table.is_reserved(String(_tile_key.call(tile.x, tile.y))):
			candidates.append(tile)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := TileGrid.manhattan(a, start)
		var db := TileGrid.manhattan(b, start)
		if da != db:
			return da < db
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	if candidates.is_empty():
		_onset_failed(colonist_id, kind, tick)
		return
	var distances: Array[int] = []
	for candidate in candidates:
		distances.append(TileGrid.manhattan(candidate, start))
	_searching[colonist_id] = {"kind": kind, "candidates": candidates, "distances": distances,
		"cursor": 0, "search": null, "found": []}
	_set_reason.call(colonist_id, "")
	_advance_search(colonist, tick)

## One step per tick. Search phase: one bounded resume() per candidate, collecting every found
## route; ranking (length, then pre-sort order) happens on its own tick. Commit phase: recheck
## one ranked candidate per tick; a lost race shows blocked_source_reserved for that tick.
func _advance_search(colonist: Dictionary, tick: int) -> void:
	var colonist_id: String = colonist["id"]
	var state: Dictionary = _searching[colonist_id]
	var kind: String = state["kind"]
	if not state.has("ranked"):
		var candidates: Array = state["candidates"]
		var distances: Array = state["distances"]
		var found: Array = state["found"]
		var cursor: int = int(state["cursor"])
		if cursor < candidates.size() and not _search_can_stop(distances, cursor, found):
			_advance_candidate_search(colonist, state, cursor)
			return
		state["ranked"] = _rank_found(found)
		state["commit_cursor"] = 0
		return
	_advance_commit(colonist_id, kind, state, tick)

func _advance_candidate_search(colonist: Dictionary, state: Dictionary, cursor: int) -> void:
	var candidates: Array = state["candidates"]
	var found: Array = state["found"]
	var target: Vector2i = candidates[cursor]
	var search: RerouteType = state.get("search")
	if search == null:
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		search = RerouteType.new(start, target, _routable_to.call(target), Vector2i.ZERO, _bounds_max, _region_reachable)
		state["search"] = search
	if not search.is_terminal():
		search.resume()
	if not search.is_terminal():
		return
	if search.get_status() == RerouteType.STATUS_FOUND:
		found.append({"target": target, "length": search.get_path().size() - 1, "order": cursor})
	state["cursor"] = cursor + 1
	state["search"] = null

func _search_can_stop(distances: Array, cursor: int, found: Array) -> bool:
	if found.is_empty():
		return false
	var best_length: int = _shortest_found_length(found)
	return int(distances[cursor]) > best_length

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
		if a["length"] != b["length"]:
			return int(a["length"]) < int(b["length"])
		return int(a["order"]) < int(b["order"]))
	return ranked

func _advance_commit(colonist_id: String, kind: String, state: Dictionary, tick: int) -> void:
	var ranked: Array = state["ranked"]
	var commit_cursor: int = int(state["commit_cursor"])
	if commit_cursor >= ranked.size():
		_searching.erase(colonist_id)
		_onset_failed(colonist_id, kind, tick)
		return
	var entry: Dictionary = ranked[commit_cursor]
	var target: Vector2i = entry["target"]
	var claimed: Dictionary = _claimed_targets.call()
	if _reservation_table.is_reserved(String(_tile_key.call(target.x, target.y))) or claimed.has(target):
		_set_reason.call(colonist_id, REASON_BLOCKED_SOURCE_RESERVED)
		state["commit_cursor"] = commit_cursor + 1
		return
	_searching.erase(colonist_id)
	_commit(colonist_id, kind, target, tick)

## A rejected submit (same-tick race) is dropped; the next advance() re-evaluates.
func _commit(colonist_id: String, kind: String, target: Vector2i, tick: int) -> void:
	var job_kind := String(JOB_KIND_BY_NEED.get(kind, ""))
	var result: Dictionary = _submit_job.call(target, _priority, tick, job_kind, colonist_id)
	if not result.get("ok", false):
		return
	_pending[colonist_id] = String(result["job_id"])
	_set_reason.call(colonist_id, "")
	_alerted.erase(_key(colonist_id, kind))
	_backoff.erase(_key(colonist_id, kind))

## No source: need_unmet reason, one alert per onset, backoff, and the paused job resumes
## (colonist-ai.md 3.1/3.8).
func _onset_failed(colonist_id: String, kind: String, tick: int) -> void:
	var reason := "%s%s" % [REASON_NEED_UNMET_PREFIX, kind]
	_set_reason.call(colonist_id, reason)
	var key := _key(colonist_id, kind)
	if not _alerted.has(key):
		_alerted[key] = true
		_emit_need_unmet.call(colonist_id, kind)
	_set_backoff(key, tick)
	_resume_interrupted_job.call(colonist_id)

func _set_backoff(key: String, tick: int) -> void:
	var current: Dictionary = _backoff.get(key, {})
	var backoff: int = int(current.get("backoff_ticks", 0))
	backoff = _retry_base_ticks if backoff == 0 else mini(backoff * 2, _retry_cap_ticks)
	_backoff[key] = {"backoff_ticks": backoff, "retry_at": tick + backoff}

func _key(colonist_id: String, kind: String) -> String:
	return "%s:%s" % [colonist_id, kind]
