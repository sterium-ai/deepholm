class_name ApproachGiver
extends RefCounted

## Job-giver for `approach` (issue #390, ADR 031): decides WHEN a hostile actor
## (one with a `combat` component whose own faction's relation to `colony` is
## `hostile`, read via `Relations.relation()` off each side's runtime
## `factionId` field exactly like CombatTargeting -- never
## `Relations.is_hostile()`, which reads the wrong content key per ADR 020's
## documented pitfall) should walk toward a hostile target it is not already
## adjacent to. Runs once per tick, after `CombatResolver.resolve_tick()` and
## `CombatGiver.advance()` (both inside `WorldState._apply_combat()`, earlier
## in `tick()`), so the adjacent-only attack rule and the flee decision both
## get first say. Wired from `WorldState.tick()` itself, AFTER
## `_advance_colonists()` (not alongside `_apply_combat()`): its own rule-1
## adjacency check must see this tick's post-movement positions -- the exact
## ones `CombatResolver.resolve_tick()` will check first thing next tick,
## since nothing moves in between -- and running after `_advance_colonists()`
## means an actor trapped this very tick already carries `trapped` by the
## time this giver ever looks at it, so it can never win a same-tick race for
## that actor's own scheduler slot against a freshly submitted `escape_trench`
## job (see `WorldState.tick()`'s own doc comment on this call site).
##
## Per-tick decision table (t1 of #389, retargeting added by issue #391 t2).
## `advance()` itself evaluates rule 2, THEN a tracked job's own target-loss/
## blocked-unreachable cleanup, THEN rule 1, in that fixed order (round-2
## review finding 3; round-1 review of issue #391's own revision 1):
## 1. `CombatTargeting.nearest_adjacent_hostile()` is non-empty for this actor
##    -- do nothing further; the existing attack rule already has it. Checked
##    LAST among the "do nothing" rules (see below) so it never skips the
##    cleanup that must happen first.
## 2. `CombatGiver.owns(actor_id)` (an open flee episode) -- do nothing at
##    all: never submit, interrupt, or keep tracking an approach job for an
##    actor CombatGiver currently owns, so "fleeing keeps its priority over
##    approaching" holds by construction, not by a race. Checked FIRST: it
##    must fire even on the tick adjacency also becomes true, or a fleeing
##    actor that just walked adjacent keeps a stale approach association
##    instead of having it released.
## 2.5. A tracked job's own recorded target having died/been destroyed, or
##    the job itself having gone queued+blocked-unreachable (see
##    "Retargeting" below), cancels it and drops the association -- checked
##    BEFORE rule 1's own adjacency check, never after: the actor can stand
##    adjacent to a DIFFERENT hostile (the attack rule's own target, not this
##    stale job's) on the very tick its own tracked target is lost, and rule
##    1's "do nothing" must never skip this cleanup (round-1 review of issue
##    #391's own revision 1 -- the bug this fixed left a dead target's job,
##    and its reservation, tracked forever whenever another hostile happened
##    to be adjacent).
## 3. A non-terminal `approach` job is still tracked after 2.5 above (i.e. it
##    was not cancelled) -- leave it running, regardless of adjacency.
## 4. No job is tracked (never was, or 2.5 just cancelled one) and rule 1's
##    adjacency check is also empty -- pick the single nearest reachable
##    target (see `_start_search()`) and submit one fresh single-leg
##    `approach` job through `GlobalAssignment.submit_autonomous()` (the same
##    entry point `CombatGiver`/`IncidentScheduler` use), so a non-colony
##    actor is never refused by the ordinary `may_be_ordered` gate.
## 5. No reachable target at all -- do nothing that tick, re-evaluated fresh
##    every tick (issue #391: never a permanent latch); today's
##    incident-driven walk-to-a-bare-tile-then-wait behaviour is untouched.
##
## Target selection mirrors `need_giver.gd`'s own single-subject, multi-
## candidate, real-route-ranked search (one actor, many candidate tiles,
## budgeted one `RerouteType.resume()` per tick through the shared
## `_route_budget` ledger `rescue_giver.gd`/`combat_giver.gd` also share, ADR
## 004 -- never a fresh synchronous full search): every living actor and
## every placed object with a health entry that this actor's own faction
## relation makes it hostile to is a candidate target; for each, the single
## Chebyshev-adjacent tile nearest this actor (among those passable,
## reservation-eligible, unreserved and region-reachable for it) is that
## target's own candidate tile. Candidates are ranked by real route length,
## tied-broken deterministically: an actor candidate before an object
## candidate, then ascending target id (actor) or ascending `"%d_%d"` tile key
## (object).
##
## Retargeting (issue #391, t2 of #389; supersedes t1's own permanent-retire
## design below). A tracked job's own recorded target (`_job_targets`) is
## checked BEFORE its scheduler status, and BEFORE rule 1's own adjacency
## check (round-1 review of issue #391's own revision 1 -- see rule 2.5
## above), every tick this giver looks at it: a dead actor target or a
## destroyed/cleared object target (its health/`objectAt` entry gone)
## cancels the job through `_cancel_job` (the same shared finish boundary
## `combat_giver.gd`'s own `_cancel_job`/`rescue_giver.gd`'s own
## `_retire_job` use) regardless of the job's current status -- active or
## queued, the target is gone either way, and regardless of whether the
## actor now stands adjacent to some OTHER hostile the attack rule already
## covers. A job still "queued" with `JobQueueType.BLOCKED_TARGET_UNREACHABLE`
## (the same reason `combat_giver.gd` already watches for its own flee legs:
## JobQueue retries an unreachable queued target forever on its own, it never
## resolves itself) is cancelled the same way. Either cancellation drops the
## association (`_tracking`/`_job_targets`/`_job_actor`) and falls through
## into rule 1's adjacency check and then, if empty, rule 4's own search THIS
## SAME TICK -- never waits a tick, and never latches a permanent "no further
## search" state the way t1's own `_retired` did. A job already cancelled
## elsewhere this tick (`WorldState._toil_on_unreachable()`, a route that
## became unreachable mid-walk after activation) is detected by its status no
## longer being "active"/"queued" and falls through exactly the same way. If
## the fresh search (rule 4) finds no reachable target at all, this giver
## simply does nothing that tick -- rule 5, re-evaluated fresh every tick,
## never a permanent latch -- and the actor is free for `IncidentScheduler`'s
## own walk-then-wait to drive; this giver never cancels or interferes with
## an unrelated incident job (a dormant approach job merely sitting queued
## behind a busy incident job's own active assignment is never touched here
## either -- GlobalAssignment.tick() itself never re-selects a busy worker's
## other queued entries for reachability re-checking, so it is left exactly
## as queued until the incident job itself frees the worker).

const TargetingType = preload("res://scripts/core/combat/combat_targeting.gd")
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")

const APPROACH_KIND := "approach"
const APPROACH_PRIORITY := 1

## JobQueue's own reason for a queued job the scheduler's coarse reachability
## check has proven can never progress on its own (issue #391): a local copy
## of its typed-reason vocabulary, exactly like `combat_giver.gd`'s own
## identical constant (job_queue.gd is not owned by this task).
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"

## The 8 Chebyshev-adjacent offsets around a target tile, cardinal first
## (matching CombatTargeting.NEIGHBOR_OFFSETS' own scan order).
const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
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
var _bounds_max: Vector2i
var _content
var _relations
var _route_budget: Dictionary
var _combat_owns: Callable
var _list_objects: Callable
var _object_at: Callable
var _object_health_at: Callable
var _object_faction_at: Callable
## cancel_job(job_id)->void (issue #391) must be WorldState._cancel_autonomous_job
## (the same shared _finish_job() boundary combat_giver.gd's own `_cancel_job`
## already uses) so a tracked job whose target has died/been destroyed, or
## that has gone queued+BLOCKED_TARGET_UNREACHABLE, can be retired without
## waiting on `_toil_on_unreachable()`, which only ever fires once a job has
## activated.
var _cancel_job: Callable

## actor_id -> job_id for the approach job currently tracked for it -- rebuilt
## from the scheduler's own restored queue after a load (see
## `restore_job_targets()`), never persisted directly, mirroring
## `CombatGiver._fleeing`/`RescueGiver._pending`.
var _tracking: Dictionary = {}
## actor_id -> {candidates, cursor, search, found, ranked, commit_cursor}:
## live while an actor has no tracked job but a multi-tick target search is
## in progress, mirroring need_giver.gd's own `_searching`.
var _searching: Dictionary = {}
## job_id -> {"kind": "actor", "id": actor_id} or {"kind": "object", "tile":
## Vector2i}: this giver's own record of which target an approach job was
## submitted for, mirroring `rescue_giver.gd`'s `_job_victim` -- never a
## per-job field. Not reconstructable after a load (an object target has no
## living record to re-scan), so `state_codec.gd` persists it verbatim via
## `get_job_targets()`/`restore_job_targets()`.
var _job_targets: Dictionary = {}
## job_id -> actor_id for every job with a live `_job_targets` entry,
## INCLUDING one `_release_tracking()` (rule 2) has dropped from `_tracking`
## while CombatGiver owns the actor: `_tracking` only reflects who this giver
## is CURRENTLY driving, so it is the wrong map for `forget()` (round-1
## review) to consult when an actor is removed mid-flee, after its approach
## job has been released from `_tracking` but is still paused, not
## terminated. Never persisted directly -- rebuilt in `restore_job_targets()`
## exactly like `_tracking` itself, since it is derivable from the scheduler's
## restored queue.
var _job_actor: Dictionary = {}

## submit_job(target, priority, tick, kind, worker)->Dictionary must be
## WorldState._scheduler.submit_autonomous. get_job(job_id)->Dictionary must
## be WorldState._get_job. list_jobs()->Array must be
## WorldState._scheduler.queue.get_jobs. restrict_to_for(job_id)->String must
## be WorldState._job_restricted_to (the same raw-waiting-queue fallback
## CombatGiver uses, so a save/load mid-search still finds its own actor's
## restriction). passable_for_actor(actor_id,x,y)->Dictionary must be a
## faction-aware WorldState passability wrapper (WorldState._passable_for_flee,
## shared with CombatGiver -- generic despite the name). may_reserve_target
## (actor_id,target)->bool must be WorldState._actor_may_reserve_target.
## reachable(from,target)->bool must be WorldState._region_reachable.
## is_target_reserved(x,y)->bool must be WorldState._flee_target_reserved
## (shared with CombatGiver -- generic despite the name). routable_to(target,
## faction_id)->Callable must be WorldState._routable_to. content/relations
## are WorldState's own frozen ContentRegistry/Relations instances.
## route_budget must be WorldState._route_budget itself (shared by reference).
## combat_owns(actor_id)->bool must be CombatGiver.owns. list_objects()->Array
## must be WorldState.get_objects. object_at/object_health_at/object_faction_at
## must be WorldState.get_object/_object_health_at/get_object_faction_id.
## cancel_job(job_id)->void (issue #391) must be WorldState._cancel_autonomous_job.
func _init(submit_job: Callable, get_job: Callable, list_jobs: Callable, restrict_to_for: Callable,
		passable_for_actor: Callable, may_reserve_target: Callable, reachable: Callable,
		is_target_reserved: Callable, routable_to: Callable, bounds_max: Vector2i, content, relations,
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

## Drops every association this giver holds for actor_id, INCLUDING its
## job's own persisted target (unlike the plain rule-2 release in advance()
## below) -- called by WorldState on death/removal (mirroring
## CombatGiver.forget()) or once this actor's own faction relation to colony
## stops being hostile, both permanent: no future tick will ever re-adopt
## this actor's job again. Walks `_job_actor`, not `_tracking` (round-1
## review): `_tracking` alone misses a job `_release_tracking()` (rule 2) had
## already dropped from it while CombatGiver owned this actor -- exactly the
## paused-approach-then-removed sequence that left a stale `_job_targets`
## entry (and a stale persisted association) behind. `_job_actor` covers both
## the actively-tracked and the paused-while-owned case in one scan.
func forget(actor_id: String) -> void:
	_tracking.erase(actor_id)
	_searching.erase(actor_id)
	for job_id in _job_actor.keys().duplicate():
		if String(_job_actor[job_id]) == actor_id:
			_job_targets.erase(job_id)
			_job_actor.erase(job_id)

## job_id -> target lookups for a job re-adopted after CombatGiver releases
## an actor it owned (see advance()'s rule 2 handling) must still resolve, so
## only `_tracking`/`_searching` -- never `_job_targets` -- are cleared here:
## the underlying job can survive a flee interrupt paused (not cancelled) and
## resume once the episode closes, and this giver must still recognise it as
## its own when that happens.
func _release_tracking(actor_id: String) -> void:
	_tracking.erase(actor_id)
	_searching.erase(actor_id)

## True (and adopted into `_tracking`) when a non-terminal `approach` job
## already exists restricted to actor_id -- the case right after this actor's
## own flee episode closes (CombatGiver's interrupt paused, rather than
## cancelled, the job this giver had submitted) or right after a fresh load,
## mirroring CombatGiver._adopt_existing_flee_job().
func _adopt_existing_job(actor_id: String) -> bool:
	for job in (_list_jobs.call() as Array):
		if String(job.get("kind", "")) != APPROACH_KIND or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if _restrict_to_for.call(String(job["id"])) != actor_id:
			continue
		_tracking[actor_id] = String(job["id"])
		return true
	return false

## This giver's own job_id -> target association, for state_codec.gd's
## encode() to persist verbatim (mirrors RescueGiver.get_job_victims()).
func get_job_targets() -> Dictionary:
	return _job_targets.duplicate(true)

## state_codec.gd's decode() counterpart: replaces `_job_targets` wholesale
## (already filtered by the caller to jobs that survived decode), then
## reconciles `_tracking` against the scheduler's restored queue -- every
## non-terminal `approach` job is re-adopted for the actor it is restricted
## to, mirroring CombatGiver.restore_blocked_targets(). Must run after the
## scheduler queue/scheduling state has been restored.
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

## Runs once per tick, after CombatResolver.resolve_tick() and
## CombatGiver.advance() (see WorldState._apply_combat()).
func advance(actors: Array[Dictionary], tick: int) -> void:
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
		# Rule 2 checked BEFORE rule 1 (round-2 review finding 3): ownership must
		# release tracking even on a tick where adjacency also just became true,
		# or a fleeing actor that walked adjacent this same tick keeps a stale
		# approach association instead of having it released.
		if _combat_owns.call(actor_id):
			_release_tracking(actor_id) # rule 2: never keep tracking while CombatGiver owns this actor
			continue
		if not _tracking.has(actor_id):
			_adopt_existing_job(actor_id) # a job CombatGiver's own interrupt paused, not cancelled, survives its episode
		if _tracking.has(actor_id):
			var job_id: String = String(_tracking[actor_id])
			var job: Dictionary = _get_job.call(job_id)
			var status := String(job.get("status", ""))
			# issue #391 rule (A): a tracked job's own recorded target dying/
			# being destroyed, or the job itself going queued+blocked-
			# unreachable (mirroring combat_giver.gd's own flee-leg watch),
			# cancels it through the shared finish boundary regardless of
			# status -- active or queued, the target loss is real either way
			# -- and drops the tracking, falling through to a fresh rule-4
			# search THIS SAME TICK rather than waiting a tick. Checked
			# BEFORE rule 1's own adjacency early-return (round-1 review): a
			# stale job's target can die/be destroyed on a tick the actor
			# also happens to stand adjacent to a DIFFERENT hostile (the
			# attack rule's own target, not this job's), and that stale
			# association must still be cancelled -- rule 1 taking the early
			# return first used to skip this cleanup entirely, leaving a dead
			# target's job (and its reservation) tracked forever.
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
				# Every other way a tracked job ends without this giver
				# cancelling it here (completed successfully, or already
				# cancelled elsewhere this tick by
				# WorldState._toil_on_unreachable() once its route became
				# unreachable mid-walk after activation) also falls through
				# into a fresh rule-4 search THIS SAME TICK -- issue #391
				# replaces t1's own permanent `_retired` latch with a retry
				# every tick a job is not tracked, never a one-shot
				# retirement.
				_tracking.erase(actor_id)
				_job_targets.erase(job_id)
				_job_actor.erase(job_id)
		if not TargetingType.nearest_adjacent_hostile(actor, actors, _relations,
				_object_at, _object_health_at, _object_faction_at).is_empty():
			continue # rule 1: the attack rule already covers whichever hostile this actor now stands adjacent to
		if _searching.has(actor_id):
			_advance_search(actor, actor_id, tick)
			continue
		_start_search(actor, actor_id, actors, tick)

## True when job_id's own recorded target (`_job_targets`) is gone: an actor
## target no longer present in `actors` (removed) or now dead, or an object
## target whose health entry and placed-object record have both cleared
## (destroyed via `_damage_object()`'s own zero-hp `_set_object(x, y, "")`, or
## cleared by any other system) -- issue #391 rule (A)'s death/destruction
## retarget trigger. `{}` (no recorded target at all, e.g. a job this giver
## never submitted) is never "lost" -- nothing to have lost.
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
	var tile: Vector2i = target["tile"]
	return _object_health_at.call(tile.x, tile.y).is_empty() or String(_object_at.call(tile.x, tile.y)).is_empty()

## Every living actor and every placed object with a health entry that
## `actor`'s own faction relation makes it hostile to (rule 4's target set).
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
		targets.append({"kind": "actor", "id": String(other["id"]), "tile": Vector2i(int(other["x"]), int(other["y"]))})
	for placed_object in (_list_objects.call() as Array):
		var x := int(placed_object["x"])
		var y := int(placed_object["y"])
		var health: Dictionary = _object_health_at.call(x, y)
		if health.is_empty():
			continue
		if _relations.relation(own_faction, String(_object_faction_at.call(x, y))) != "hostile":
			continue
		targets.append({"kind": "object", "tile_key": "%d_%d" % [x, y], "tile": Vector2i(x, y)})
	return targets

## The Chebyshev-adjacent tile of target_tile nearest `start` (Manhattan,
## fixed-offset-order tie-break) that is in bounds, passable for actor_id's
## own faction, reservation-eligible, not already another job's live target
## reservation, and region-reachable from `start` -- null when none qualify.
func _best_adjacent_tile(actor_id: String, start: Vector2i, target_tile: Vector2i):
	var best = null
	var best_distance := -1
	for offset in NEIGHBOR_OFFSETS:
		var candidate := target_tile + offset
		if candidate.x < 0 or candidate.y < 0 or candidate.x > _bounds_max.x or candidate.y > _bounds_max.y:
			continue
		if not bool((_passable_for_actor.call(actor_id, candidate.x, candidate.y) as Dictionary).get("passable", false)):
			continue
		if not bool(_may_reserve_target.call(actor_id, candidate)):
			continue
		if bool(_is_target_reserved.call(candidate.x, candidate.y)):
			continue
		if not bool(_reachable.call(start, candidate)):
			continue
		var distance := absi(candidate.x - start.x) + absi(candidate.y - start.y)
		if best == null or distance < best_distance:
			best = candidate
			best_distance = distance
	return best

## Deterministic tie-break for two candidates at an equal real route length:
## an actor candidate before an object candidate; within the same kind,
## ascending target id (actor) or ascending tile key (object).
static func _target_precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_is_actor := String(a["kind"]) == "actor"
	var b_is_actor := String(b["kind"]) == "actor"
	if a_is_actor != b_is_actor:
		return a_is_actor
	if a_is_actor:
		return String(a["id"]) < String(b["id"])
	return String(a["tile_key"]) < String(b["tile_key"])

## Starts a fresh search: one candidate tile per hostile target (its own
## nearest valid Chebyshev-adjacent tile), pre-sorted by Chebyshev distance
## for a cheap search order and early-stop pruning (see _search_can_stop()).
## Chebyshev, not Manhattan (round-2 review finding 4): movement permits
## diagonals, so Manhattan distance can exceed a candidate's true route cost
## and is not a safe (admissible) lower bound -- pruning against it could
## stop the search before a genuinely nearer target is ever tried. Chebyshev
## distance never exceeds the real route length regardless of diagonal moves.
## No target at all with any valid adjacent tile is rule 5: do nothing, no
## state kept, retried fresh next tick.
func _start_search(actor: Dictionary, actor_id: String, actors: Array[Dictionary], tick: int) -> void:
	var start := Vector2i(int(actor["x"]), int(actor["y"]))
	var candidates: Array = []
	for target in _hostile_targets(actor, actors):
		var tile = _best_adjacent_tile(actor_id, start, target["tile"])
		if tile == null:
			continue
		var distance: int = maxi(absi(tile.x - start.x), absi(tile.y - start.y))
		candidates.append({"tile": tile, "target": target, "distance": distance})
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return _target_precedes(a["target"], b["target"]))
	_searching[actor_id] = {"candidates": candidates, "cursor": 0, "search": null, "found": []}
	_advance_search(actor, actor_id, tick)

## Search phase (state["ranked"] absent): one bounded resume() per tick
## against the current candidate tile, recording every reachable one (with
## its real route length) into state["found"], stopping early once the next
## candidate's own Chebyshev distance already exceeds the shortest route
## found so far (it could never win). Commit phase (state["ranked"] present):
## rechecks exactly one ranked candidate per tick for a reservation race
## before committing.
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
	var tile: Vector2i = entry["tile"]
	var actor_id: String = String(actor["id"])
	var actor_faction := TargetingType.actor_faction(actor)
	var search: RerouteType = state.get("search")
	if search == null:
		var start := Vector2i(int(actor["x"]), int(actor["y"]))
		search = RerouteType.new(start, tile, _routable_to.call(tile, actor_faction), Vector2i.ZERO, _bounds_max)
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
	var tile: Vector2i = entry["tile"]
	if _is_target_reserved.call(tile.x, tile.y):
		state["commit_cursor"] = commit_cursor + 1
		return
	_searching.erase(actor_id)
	_commit(actor_id, entry["target"], tile, tick)

## Submits through the same submit_autonomous() entry point CombatGiver/
## IncidentScheduler use, so a non-colony actor is never refused by the
## ordinary may_be_ordered gate, and records the target association.
func _commit(actor_id: String, target: Dictionary, tile: Vector2i, tick: int) -> void:
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
