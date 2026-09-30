class_name RescueGiver
extends RefCounted

## Job-giver for `rescue` (ADR 026): decides when a
## rescue job should exist for a trapped colonist. Modelled directly on
## need_giver.gd's own committed-job pattern -- constructor-injected
## callables, the same submit()/restrict_to entry point, and the same
## multi-tick, budgeted search (at most one RerouteType resume() per
## candidate colonist per tick, see "Route budget" below) -- but
## need_giver.gd's own roles doubly swapped:
## need_giver holds one colonist fixed and ranks many candidate source tiles
## by real route length; this instead ranks candidate rescuer colonists by
## Manhattan distance to the victim first (cheap pre-sort), then, for
## whichever candidate is currently being tried, ranks the victim's own (up to
## four) adjacent, passable, non-trench neighbour tiles by real route length
## from that candidate -- exactly need_giver's own single-subject, multi-
## target search, just run once per candidate in ranked order until one
## candidate reaches at least one target. A single fixed target picked without
## regard to the approaching rescuer is not enough: on a corridor-width map the
## only real route to an adjacent tile on the trench's far side can be
## straight through the trench itself, which is exactly the fall-in this
## module exists to prevent.
##
## Route safety (replaces an earlier "does the path cross the victim's own
## tile" check): that check only protected against the one trench this module
## already knew about -- a candidate whose only real route crossed a different
## trench entirely
## (e.g. victim at (5,0), rescuer at (0,0), an unrelated trench at (2,0) on
## the only straight route to a target at (4,0)) was still accepted, sending
## the rescuer through a trench it was never trying to reach. go_to's real
## execution (world_state.gd's _routable_to(), the exact callable this module
## is itself constructed with) always computes its own unrestricted shortest
## route, ignoring any detour a restricted search found, so every search here
## runs with that same unrestricted, ordinary routable_to callable -- the
## identical route go_to will really walk -- and a (candidate, target) pair is
## only ever accepted (_advance_target_search() below) when the resulting real
## path crosses no trench tile at all, anywhere along its length, not merely
## the victim's own (_is_trench, constructor-injected so this module never
## hardcodes the tile-kind string itself; this subsumes the old victim-tile-
## only check, since the victim's own tile is itself trench). A pair whose
## only real route crosses any trench is simply rejected, never replaced by an
## assumed detour: if every candidate's real route to every target crosses a
## trench, this module reports REASON_NO_RESCUER_AVAILABLE exactly like it
## would with no candidate at all, rather than send a rescuer in to fall in
## itself. This module validates the commit-time route only; everything a
## committed rescue does after that (its scheduler activation, a resume after
## a need interrupt, a mid-travel re-route around a newly blocked corridor)
## is kept trench-safe by world_state.gd at its own existing boundaries --
## the go_to toil's passability hook (`_toil_go_to_passable()` hands a rescue
## job `_rescue_routable_to()`, under which a trench is simply impassable and
## the target gets no impassable-target exception, so a re-route can never
## cross a trench nor be trimmed to start work off-target) and the first
## drive of a fresh activation (`_rescue_activation_safe()`, which scans the
## scheduler's own already-computed path tile by tile and retires the
## commitment when the map changed under it). Nothing here ever runs a route
## search to completion synchronously: a resumed rescue re-routes through the
## toil executor's own budgeted, multi-tick search like any other job.
##
## Route budget (ADR 004): every search here shares
## WorldState's own per-colonist, per-tick `_route_budget` ledger (the same
## Dictionary GlobalAssignment.tick() clears at its start and the toil
## executor's go_to re-route honours) -- _advance_target_search() below skips
## a candidate's resume() for the rest of the tick once any route work
## (the scheduler's own activation search, a toil re-route, or another
## victim's search evaluating that same candidate) has already spent that
## colonist's single allowance, and marks the ledger itself after resuming.
## An unfinished search is simply retained in `_searching` and picked up next
## tick, never restarted. advance() therefore runs after GlobalAssignment.tick()
## (which clears the ledger) and before _advance_colonists() (world_state.gd's
## tick()), so all three route consumers see one shared ledger per tick.
##
## Candidate drift (bounded by MAX_STALE_RETRIES): unlike need_giver.gd's own
## fixed candidate target tiles, a
## rescue candidate is a living, moving colonist that can keep walking its own
## ordinary job while this multi-tick search is still in progress.
## _advance_search() below re-reads the current cursor candidate's live
## position from `candidates` every tick and, the instant it differs from the
## position the in-progress search was built against, discards that stale
## progress (a route/safety check computed from a position the candidate has
## since left proves nothing about the route it would really walk from where
## it is now) and restarts the search from the candidate's new position -- but
## only up to MAX_STALE_RETRIES times per candidate: a candidate that keeps
## moving every single tick (an ordinary worker mid-travel) would otherwise
## never let even one sweep survive long enough to finish, monopolizing the
## search forever and starving out every later-ranked candidate, including an
## idle one that could rescue right now. Once the bound is hit, this module
## gives up on that candidate for this search and advances to the next one
## (_advance_to_next_candidate(), which also resets the counter for whichever
## candidate comes next).
##
## Priority ("above ordinary work, below critical needs", colonist-ai.md
## 3.1/3.6): a rescue job is submitted through the exact same committed-
## proposal pathway (get_pending_assignments() feeding GlobalAssignment.tick()'s
## committed_needs, see world_state.gd's _committed_jobs()) any need job uses,
## so it pre-empts ordinary labour identically. It never pre-empts a
## colonist's own need: the candidate pool WorldState hands to advance() has
## already excluded any colonist mid need-search or already committed to a
## need job (world_state.gd's _rescue_candidates()), so this module never even
## considers such a colonist, let alone interrupts one.
##
## Reservation-table convention (orders-and-movement.md "ReservationTable key
## domains"): besides the
## rescue job's own ordinary "tile:x,y" target key, a rescue job needs a
## second, new-domain key -- "trapped:<victim_id>" -- so a second search can
## never also commit to the same victim. That key is acquired the exact
## same activation-gated way the target key itself is, through JobQueue's
## generic set_extra_reservation_keys()/extra_keys_for_job() callback (see
## extra_keys_for_job() below) -- never by this module calling acquire()
## directly on the shared table outside JobQueue's own activation/
## reactivation boundary, which would violate the "a reservation exists only
## while its job is actually in progress" invariant suspend()'s own doc
## comment states, and which reactivate() alone could never restore (it only
## re-acquires the ordinary target key). Dedup itself
## (advance()'s own claimed_victims check) reads this module's own
## _job_victim record instead of the ReservationTable, so it still correctly
## excludes a victim whose rescue job is merely queued or suspended right now
## -- exactly when no "trapped:" key is held at all. Beyond that generic
## callback, reservation_table.gd and job_queue.gd need nothing
## rescue-specific: acquire()/is_reserved() stay fully generic.
##
## Persistence note (why the victim association is saved rather than
## reconstructed): target-tile-plus-adjacency does not uniquely identify a
## victim -- two victims can share a target, or have overlapping candidate
## adjacency sets, and a greedy lowest-id match can silently reassign who a
## surviving job rescues, or leave a job matched to no victim at all. No
## per-job field may name "which colonist is being rescued" (a deliberate
## design constraint), but the giver's own save data is not a per-job field: this
## module's _job_victim is exposed verbatim by get_job_victims() for
## state_codec.gd's encode() to persist alongside the giver's other
## continuation state, and restore_victim_assignments() below restores it
## verbatim, with no guessing. _pending is still rebuilt (not persisted
## directly) by restore_pending_assignments(), since the scheduler's own
## restored restrict_to already names it losslessly (see that method's own
## doc comment) -- the victim half runs before JobQueue.restore() (restore()'s
## own active-job reservation rebuild depends on extra_keys_for_job(), which
## reads _job_victim); the pending half runs after restore_scheduling().
## set_reservation_table() repoints this module's own ReservationTable
## reference at the table JobQueue.restore() rebuilds, so this module's
## is_reserved()/owner() peeks are never left reading an obsolete, orphaned
## table after a load.

const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

const REASON_NO_RESCUER_AVAILABLE := "no_rescuer_available"

## Bounds _advance_search()'s own stale-position discard: a candidate whose
## live position still differs after
## this many consecutive restarts is skipped for the next-ranked one, rather
## than retried forever.
const MAX_STALE_RETRIES := 3

var _priority: int
var _bounds_max: Vector2i
var _reservation_table
var _tile_key: Callable
var _routable_to: Callable
var _rescue_target_candidates: Callable
var _submit_job: Callable
var _set_reason: Callable
var _interrupt_current_job: Callable
var _resume_interrupted_job: Callable
var _is_trench: Callable
## WorldState._route_budget, shared by reference (see the class doc comment's
## "Route budget"): colonist_id -> true once that colonist's single route
## resume() for the current tick has been spent by anyone.
var _route_budget: Dictionary
## colonist_id -> how many RerouteType.resume() calls this module made for
## that colonist during the most recent advance() (telemetry only, reset
## every advance(); exposed by get_route_telemetry() so a test can prove the
## shared budget is honoured, ADR 004's "telemetry reports actual resume
## calls, not merely a configured allowance").
var _tick_route_resumes: Dictionary = {}
## WorldState._get_job(job_id) -> Dictionary: the live queue entry, read in
## advance() for the scheduler's own block reason on a committed rescue.
var _get_job: Callable
## WorldState._retire_rescue_job(job_id) -> void: cancels a committed rescue
## through the shared finish boundary and calls resolve_job() below -- the
## one path an unreachable commitment leaves by.
var _retire_job: Callable

## victim_id -> {victim_tile, targets: Array[Vector2i], candidates:
## Array[{id, pos}], cursor, target_cursor, search, found}: live while a
## victim has no committed rescue job yet but a search is in progress.
## `candidates` is pre-sorted by Manhattan distance to victim_tile; `cursor`
## is which one is currently being tried. `targets` is fixed for the whole
## search; `target_cursor`/`found` restart at 0/[] each time `cursor` advances
## to a new candidate (see _advance_to_next_candidate()).
var _searching: Dictionary = {}
## rescuer_colonist_id -> job_id: the ground truth of which rescue job, if
## any, a colonist is actually committed to -- get_pending_assignments()'
## backing store, merged into world_state.gd's _committed_jobs() exactly like
## NeedGiver's own.
var _pending: Dictionary = {}
## job_id -> victim_id: this module's own record of which trapped colonist a
## rescue job targets -- the source both extra_keys_for_job() (the "trapped:"
## key's own activation-gated acquisition) and victim_for_job()
## (world_state.gd's own completion-effect lookup)
## read. An unreachable or unsafe committed rescue is never resubmitted under
## a fresh id (world_state.gd's _retire_rescue_job() cancels it and calls
## resolve_job() below so the victim's next search may pick another
## rescuer), so nothing ever carries an association from one
## job id to another. Rebuilt after a load by restore_victim_assignments()
## (see the class doc comment's persistence note), since no per-job field may
## persist it.
var _job_victim: Dictionary = {}

## reservation_table must be the scheduler's shared ReservationTable (jobs/
## reservation_table.gd), only ever peeked here (is_reserved()/owner()) to
## filter candidate targets -- never acquired directly (see the class doc
## comment: the "trapped:" key domain this module owns is acquired only
## through JobQueue's own activation/reactivation boundary now).
## tile_key(x,y) -> String must be WorldState._tile_key. routable_to(target,
## faction_id="colony") -> Callable must be WorldState._routable_to.
## rescue_target_candidates(victim_tile: Vector2i) -> Array[Vector2i] must be
## WorldState._rescue_target_candidates (every passable, non-trench neighbour
## of victim_tile; empty when none qualify). submit_job(target, priority,
## tick, kind, restrict_to) -> Dictionary must be the scheduler's own submit()
## (_scheduler.submit), the same entry point every other job-giver and player
## order uses. set_reason(victim_id, reason) -> void must write WorldState's
## own exposed rescue-reason cache. interrupt_current_job(colonist: Dictionary)
## -> void and resume_interrupted_job(colonist_id: String) -> void must be
## WorldState's _pause_work_job()/_resume_paused_job() wrappers -- the exact
## same callables NeedGiver is constructed with. is_trench(tile: Vector2i)
## -> bool must be WorldState's own `func(tile): return get_tile(tile.x,
## tile.y) == TILE_TRENCH`: the real-route
## safety check below rejects a path that crosses any trench tile, not merely
## the victim's own. route_budget must be WorldState's own `_route_budget`
## Dictionary itself (never a copy), the same instance GlobalAssignment and
## ToilExecutor already share.
func _init(priority: int, bounds_max: Vector2i, reservation_table, tile_key: Callable,
		routable_to: Callable, rescue_target_candidates: Callable, submit_job: Callable,
		set_reason: Callable, interrupt_current_job: Callable, resume_interrupted_job: Callable,
		is_trench: Callable, route_budget: Dictionary, get_job: Callable, retire_job: Callable) -> void:
	_priority = priority
	_bounds_max = bounds_max
	_reservation_table = reservation_table
	_tile_key = tile_key
	_routable_to = routable_to
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

## The rescue job id a rescuer colonist is currently committed to (queued or
## active), or "" when none -- get_pending_assignments()'s per-colonist read.
func get_pending_job(colonist_id: String) -> String:
	return String(_pending.get(colonist_id, ""))

## GlobalAssignment.tick()'s `committed_needs`-style param (see
## world_state.gd's _committed_jobs()): rescuer id -> job id, so a committed
## rescue job always wins over ordinary priority scoring for that worker.
func get_pending_assignments() -> Dictionary:
	return _pending.duplicate()

## The rescuer colonist_id currently pending on job_id, or "" when job_id
## names no pending rescue job (mirrors NeedGiver.colonist_for_job()).
func colonist_for_job(job_id: String) -> String:
	for rescuer_id in _pending.keys():
		if String(_pending[rescuer_id]) == job_id:
			return String(rescuer_id)
	return ""

## Runs once per tick, immediately after the fair scheduler's own tick() and
## before _advance_colonists() (see the class doc comment's "Route budget":
## the scheduler clears the shared per-colonist route ledger at its start,
## so this must run after it to share that ledger with it and with the toil
## executor). Priority is unaffected by the ordering (colonist-ai.md 3.1/3.6:
## rescue sits below critical/urgent needs, above ordinary work): a commitment
## made here is proposed to the scheduler from the next tick on, and _commit()
## suspends the rescuer's current assignment before it is driven. `candidates`
## is WorldState's own pre-filtered pool of colonists eligible to be proposed
## a rescue job this tick (never trapped, never mid need-search or already
## committed to a need -- world_state.gd's _rescue_candidates()); `victims` is
## every currently-trapped, rescuable colonist (world_state.gd's
## _trapped_rescue_victims()).
func advance(candidates: Array[Dictionary], victims: Array[Dictionary], tick: int) -> void:
	_tick_route_resumes = {}
	# A committed rescue the scheduler itself has
	# just proven unreachable (its own region check at activation, after the
	# map changed under the commit) is retired here, the same tick, rather
	# than left blocked-but-committed forever with the rescuer pinned to it
	# -- the victim's own search below is then free to pick anyone.
	for rescuer_id in _pending.keys().duplicate():
		var job_id: String = String(_pending[rescuer_id])
		var job: Dictionary = _get_job.call(job_id)
		if String(job.get("status", "")) == "queued" \
				and String(job.get("reason", "")) == JobQueueType.BLOCKED_TARGET_UNREACHABLE:
			_retire_job.call(job_id)
	# Dedup reads this module's own _job_victim
	# record, not the ReservationTable -- a queued or suspended rescue job
	# holds no "trapped:" key at all (see extra_keys_for_job()'s own doc
	# comment: that key only exists while the job is actually active), so a
	# reservation-table peek would let a second search start for a victim
	# whose first rescue is merely queued/suspended right now.
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

## Computes the victim's own (up to four) target candidates and pre-sorts the
## rescuer candidate pool by Manhattan distance to the victim's own tile --
## a cheap search order only, since the real per-candidate ranking (below)
## is by real route length to whichever target that candidate can best reach.
func _start_search(victim: Dictionary, candidates: Array[Dictionary], tick: int) -> void:
	var victim_id: String = String(victim["id"])
	var victim_tile := Vector2i(int(victim["x"]), int(victim["y"]))
	var targets: Array = []
	for target in (_rescue_target_candidates.call(victim_tile) as Array):
		if not _reservation_table.is_reserved(String(_tile_key.call(target.x, target.y))):
			targets.append(target)
	if targets.is_empty():
		_onset_failed(victim_id)
		return
	var pool: Array = []
	for candidate in candidates:
		var candidate_id: String = String(candidate["id"])
		if _pending.has(candidate_id):
			continue
		pool.append({"id": candidate_id, "pos": Vector2i(int(candidate["x"]), int(candidate["y"]))})
	if pool.is_empty():
		_onset_failed(victim_id)
		return
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da: int = absi(a["pos"].x - victim_tile.x) + absi(a["pos"].y - victim_tile.y)
		var db: int = absi(b["pos"].x - victim_tile.x) + absi(b["pos"].y - victim_tile.y)
		if da != db:
			return da < db
		return String(a["id"]) < String(b["id"]))
	_searching[victim_id] = {"victim_tile": victim_tile, "targets": targets, "candidates": pool,
		"cursor": 0, "target_cursor": 0, "search": null, "found": [], "stale_retries": 0}
	_set_reason.call(victim_id, "")
	_advance_search(victim_id, candidates, tick)

## Processes the candidate pool strictly in ranked order: for the candidate
## `cursor` currently points at, ranks every target it can actually reach by a
## real route that never crosses any trench tile, not merely the victim's own
## (every route that does is rejected outright, see _advance_target_search()
## below) and commits to the shortest such one the instant every target has
## been tried.
## A candidate with no safe route to any target is skipped for the
## next-ranked one, never retried. Every target in a sweep is searched from
## the same fixed candidate["pos"] (need_giver.gd's own single-subject search
## shape); once every target has been tried, and only then, this re-reads the
## candidate's own live position from `candidates`: a rescue candidate is a
## moving colonist, not a fixed tile, and may have
## kept walking its own ordinary job for the whole (possibly long, STEP_BUDGET
## -bounded-per-tick) duration this sweep took. A change means every route
## just computed started from a tile the candidate has since left, proving
## nothing about the route it would really walk now -- discard the whole
## sweep's results and redo it from the candidate's current position, rather
## than checking (and potentially discarding) progress after every single
## target, which would let a continuously-moving candidate (walking its own
## ordinary job the whole time this search runs) never survive long enough to
## finish even one full sweep.
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
	var live_pos := Vector2i(int(live["x"]), int(live["y"]))
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
	var target: Vector2i = best["target"]
	if _reservation_table.is_reserved(String(_tile_key.call(target.x, target.y))):
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

## Searches with the exact same unrestricted routable_to(target) callable
## go_to's own real execution uses (world_state.gd's _routable_to(), this
## module's own constructor-injected `_routable_to`) -- never a version that
## treats any trench tile specially -- so the path found here is the path the
## rescuer would really walk. Only accepts
## it (appends to `found`) when that real path crosses no trench tile at all;
## a shorter "found" path that does cross one is rejected outright rather than
## assumed to be avoidable by some other, unfollowed detour -- see
## _path_crosses_trench() below. Spends at most one resume() per candidate
## colonist per tick through the shared `_route_budget` ledger (class doc
## comment, "Route budget"): when the ledger already names this candidate,
## the search is left exactly where it is and retried next tick.
func _advance_target_search(state: Dictionary, candidate: Dictionary, target_cursor: int) -> void:
	var targets: Array = state["targets"]
	var found: Array = state["found"]
	var target: Vector2i = targets[target_cursor]
	var candidate_id: String = String(candidate["id"])
	var search: RerouteType = state.get("search")
	if search == null:
		search = RerouteType.new(candidate["pos"], target, _routable_to.call(target), Vector2i.ZERO, _bounds_max)
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

## True when any step of path (start through target inclusive) is a trench
## tile (checked against every trench, not
## merely the victim's own -- a route can cross a trench this module never
## itself searched for, e.g. an unrelated one between the candidate and the
## target). A trench is never impassable to an ordinary routable_to() search
## (test_trapped_actors.gd's own _check_route_choice_unaffected_by_trench() --
## "a trench routes exactly like floor"), so the only way to guarantee the
## rescuer's real route never crosses one is to check the real, unrestricted
## path itself, once found, tile by tile through the constructor-injected
## `_is_trench` predicate.
func _path_crosses_trench(path: Array) -> bool:
	for step in path:
		if _is_trench.call(step):
			return true
	return false

## colonist_id -> RerouteType.resume() calls this module made for that
## colonist during the most recent advance() (ADR 004 telemetry): never
## more than 1 per colonist, and 0 for any colonist the
## scheduler already routed for this tick, since both share `_route_budget`.
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

## Submits first (cheap, no colonist mutation) so a losing race costs nothing;
## only once the job is truly ours does this interrupt the chosen rescuer's
## current work (pre-empting ordinary labour exactly like a need job already
## does, colonist-ai.md 3.6) and record the victim association extra_keys_for_job()
## reads to acquire the "trapped:" reservation key once this job activates.
func _commit(victim_id: String, rescuer: Dictionary, target: Vector2i, tick: int) -> void:
	var rescuer_id: String = String(rescuer["id"])
	var result: Dictionary = _submit_job.call(target, _priority, tick, "rescue", rescuer_id)
	if not result.get("ok", false):
		return
	var job_id: String = String(result["job_id"])
	_interrupt_current_job.call(rescuer)
	_pending[rescuer_id] = job_id
	# The "trapped:" key itself is acquired later, only once this job actually
	# activates (JobQueue's own extra_keys_for_job() callback, see below) --
	# recording the association here is what makes that callback (and this
	# module's own advance()) see it from this tick on.
	_job_victim[job_id] = victim_id
	_set_reason.call(victim_id, "")

## Exposes "no one can help" (world_state.gd's get_colonist_rescue_reason(),
## mirroring get_colonist_need_reason()'s pattern) whenever this tick's search
## for victim_id found no reachable candidate at all -- including the
## degenerate case where every other colonist is itself trapped. No
## interrupt was ever issued for this onset (unlike
## NeedGiver's _onset_failed()), so there is nothing to resume.
func _onset_failed(victim_id: String) -> void:
	_set_reason.call(victim_id, REASON_NO_RESCUER_AVAILABLE)

## WorldState's on_work_complete/on_toil_fail/death-cleanup hooks call this the
## instant a rescue job they just finished/failed/cancelled resolves (mirrors
## NeedGiver.resolve_job()), so the rescuer resumes whatever it was doing
## before the rescue (colonist-ai.md 3.6's pre-empt/resume pair) the same tick.
func resolve_job(job_id: String) -> void:
	_job_victim.erase(job_id)
	var rescuer_id := colonist_for_job(job_id)
	if rescuer_id.is_empty():
		return
	_pending.erase(rescuer_id)
	_resume_interrupted_job.call(rescuer_id)

## JobQueue's own extra-reservation-keys callback (job_queue.gd's
## set_extra_reservation_keys()/_extra_keys_for_job): the "trapped:<victim_id>"
## key job_id must hold while (and only while) it is active, mirroring how a
## haul job's own item:/cell: keys move with its own activation. Returns []
## for any job_id this module has no victim association for -- every non-
## rescue job, and a rescue job whose association was somehow lost.
func extra_keys_for_job(job_id: String) -> Array[String]:
	var victim_id: String = String(_job_victim.get(job_id, ""))
	if victim_id.is_empty():
		return []
	return [_trapped_key(victim_id)]

## The trapped victim's colonist_id job_id is committed to rescuing, or "" if
## none -- world_state.gd's own completion effect (_toil_on_work_complete()'s
## "rescue" case) reads this instead of guessing "whichever trapped colonist
## happens to be adjacent to the target," which is ambiguous whenever two
## different victims are each adjacent to the very same target tile.
func victim_for_job(job_id: String) -> String:
	return String(_job_victim.get(job_id, ""))

## The live job_id -> victim_id association, for
## state_codec.gd's own encode() to persist verbatim alongside the giver's
## other continuation state (its own save data, never a per-job field).
func get_job_victims() -> Dictionary:
	return _job_victim.duplicate()

## Restores _job_victim verbatim from state_codec.gd's own persisted
## job_id -> victim_id association (see the class doc comment's persistence
## note): target-tile-plus-adjacency does not uniquely
## identify a victim -- two victims can share a target, or have overlapping
## candidate adjacency sets -- so nothing here may be re-derived by guesswork.
## `assignments` is exactly what get_job_victims() returned at save time
## (state_codec.gd's own "rescueVictimAssignments" field), already filtered by
## the caller to jobs that still exist. Must run before JobQueue.restore()
## (state_codec.gd's decode()), since restore()'s own active-job reservation
## rebuild calls extra_keys_for_job() above, which reads _job_victim.
func restore_victim_assignments(assignments: Dictionary) -> void:
	_job_victim = assignments.duplicate()
	_searching = {}

## Overwrites _pending from a caller-supplied rescuer_id -> job_id map,
## mirroring NeedGiver.restore_pending_assignments() exactly (same method
## name/shape). Unlike NeedGiver's, this map is not read straight off a saved
## field -- state_codec.gd's decode() builds it after restore_scheduling()
## runs, by reading each surviving rescue job's own restrict_to straight off
## the scheduler (GlobalAssignment.restrict_to_for()/get_waiting()), the same
## field a player-ordered dig/chop job's own assignee restriction already
## persists -- so no new save data is needed here either. Called once, after
## state_codec.gd's decode() finishes restoring the scheduler, before any
## advance()/resolve_job() call.
func restore_pending_assignments(pending: Dictionary) -> void:
	_pending = pending.duplicate()

## Repoints this module's own ReservationTable reference (used only for the
## is_reserved()/owner() peeks in _start_search()/_advance_search() below) at
## the table JobQueue.restore() just built: JobQueue.restore() replaces its own `_table` with a brand-new instance,
## so without this call, this module would keep peeking a stale, orphaned
## table after every load. Called once, right after queue.restore().
func set_reservation_table(reservation_table) -> void:
	_reservation_table = reservation_table
