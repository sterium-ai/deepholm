class_name NeedGiver
extends RefCounted

## Job-giver for eat_food/drink_water/sleep (colonist-ai.md 3.1/3.6/3.8):
## decides WHEN a need job should exist. Needs decay/thresholds are content
## data (content/needs.json) and needs *state* stays on WorldState
## (colonist.needs) -- this module only reads both, injected below -- and,
## once a threshold is crossed, submits a job through the exact same
## scheduler entry point (submit_job) any order-driven dig/chop/haul job
## uses. From there the existing job-queue -> scheduler -> toil-executor
## pipeline drives it like any other job: no bespoke per-colonist route/work
## stepping lives here (AGENTS.md "one work engine").
##
## Kind -> job mapping (colonist-ai.md "Implemented: increment D"): food ->
## eat_food, water -> drink_water, rest -> sleep. Fixed; a fourth kind is out
## of scope (see the owning task's Non-goals).
##
## Critical needs (colonist-ai.md 3.6) interrupt a colonist's in-progress
## `work` toil immediately: interrupt_current_job frees the colonist's
## scheduler assignment (the paused job itself is left "active", untouched,
## by WorldState._pause_work_job()) so the fair scheduler may offer this
## colonist the need job about to be searched for; resume_interrupted_job
## puts it back once that need job resolves. Urgent needs only ever reach
## this module's evaluation when the colonist is already idle (no route, no
## work), which is a toil boundary by construction -- but that idleness alone
## does not mean the colonist is free of a job: a multi-toil job (haul) idles
## between its instant pick_up/place toils without ever setting colonist.work,
## while its own scheduler assignment stays live. So an urgent need also calls
## interrupt_current_job before searching, exactly like a critical one, so
## that boundary's still-active assignment is freed the same way (a no-op
## when the colonist genuinely holds no assignment at all).

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
var _tile_key: Callable
var _routable_to: Callable
var _submit_job: Callable
var _set_reason: Callable
var _emit_need_unmet: Callable
var _interrupt_current_job: Callable
var _resume_interrupted_job: Callable

## colonist_id -> {kind, candidates: Array[Vector2i], cursor, search}: live
## while a colonist is searching for a need source but has not yet committed
## to one. "search" is a RerouteType instance, one bounded resume() per tick,
## per candidate -- mirrors go_to's own re-route search budget.
var _searching: Dictionary = {}
## colonist_id -> job_id: set the instant a candidate is confirmed free and
## submitted, cleared once resolve_job() reports that job terminal. _commit()
## submits with restrict_to=colonist_id (see GlobalAssignment.submit()), so
## the fair scheduler may only ever offer this job to this same colonist --
## without that, a different colonist could win the assignment and the
## completion effect would land on the wrong colonist while this one's need
## stayed unmet. Persisted across save/load (see get_pending_assignments()/
## restore_pending_assignments()): without it, resolve_job() could not find
## the paused colonist for a need job that was already queued or active at
## save time, and the colonist's interrupted work would never resume.
var _pending: Dictionary = {}
## "<colonist_id>:<kind>" -> {"backoff_ticks", "retry_at"}: throttles
## retrying a need whose last search found no reachable/unreserved source at
## all, mirroring JobQueue's own haul-destination backoff.
var _backoff: Dictionary = {}
## "<colonist_id>:<kind>" -> true once the need_unmet alert has fired for the
## current onset; erased the moment a fresh search for that pair commits to
## a source, so a later relapse alerts again.
var _alerted: Dictionary = {}

## need_definitions must be WorldState's own live _need_definitions Dictionary
## (shared by reference, not copied: a test that mutates a kind's "rate" in
## place must see it reflected here too). need_full is WorldState.NEED_FULL.
## reservation_table must be the scheduler's shared ReservationTable (jobs/
## reservation_table.gd) -- peeked, never acquired, here (JobQueue's own
## activation acquires it once a submitted job is chosen). claimed_targets()
## -> Dictionary (Vector2i -> true) must be WorldState._need_job_targets():
## every target already named by a queued-or-active need job, mirroring
## HaulGiver.advance()'s own "claimed" de-duplication -- a job's target
## is not reservation-acquired until the scheduler actually activates it
## (colonist-ai.md 3.4), so without this a second colonist's independent
## search can find the very same not-yet-reserved candidate and submit a
## duplicate job for it. source_candidates(kind: String) -> Array[Vector2i]
## must be WorldState._need_source_candidates. tile_key(x: int, y: int) ->
## String must be WorldState._tile_key. routable_to(target: Vector2i) ->
## Callable must be WorldState._routable_to. submit_job(target: Vector2i,
## priority: int, tick: int, kind: String) -> Dictionary must be WorldState's
## scheduler entry point (_scheduler.submit), the same one dig/chop/forage
## orders use. set_reason(colonist_id: String, reason: String) -> void must
## write WorldState's own exposed reason cache (_need_status) so
## get_colonist_need_reason() keeps working unchanged. emit_need_unmet(
## colonist_id: String, kind: String) -> void must record the need_unmet
## event exactly once per onset. interrupt_current_job(colonist: Dictionary)
## -> void and resume_interrupted_job(colonist_id: String) -> void must be
## WorldState's _pause_work_job()/_resume_paused_job() wrappers (see
## world_state.gd's _interrupt_current_job()/_resume_interrupted_job()).
func _init(need_definitions: Dictionary, need_full: int, retry_base_ticks: int, retry_cap_ticks: int,
		priority: int, bounds_max: Vector2i, reservation_table, claimed_targets: Callable,
		source_candidates: Callable, tile_key: Callable, routable_to: Callable, submit_job: Callable,
		set_reason: Callable, emit_need_unmet: Callable, interrupt_current_job: Callable,
		resume_interrupted_job: Callable, content_registry) -> void:
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
	_submit_job = submit_job
	_set_reason = set_reason
	_emit_need_unmet = emit_need_unmet
	_interrupt_current_job = interrupt_current_job
	_resume_interrupted_job = resume_interrupted_job

## Colonists excluded from this tick's fair-scheduler pool (colonist-ai.md
## 3.1): still mid-search, not yet committed to any job, so the fair
## scheduler must not also offer this colonist unrelated work the same tick
## it is deciding whether to eat/drink/sleep. A colonist with an already-
## submitted (pending) job is deliberately NOT excluded: it is still free to
## be proposed the routing/activation phases the shared submit()/tick()
## pipeline runs for it -- restrict_to (see _commit()) already guarantees no
## other colonist may ever be offered that same job.
## Reads a colonist's "needs"/"mover" component through ActorTable (ADR 012)
## rather than indexing the colonist dict directly.
func _needs(colonist: Dictionary) -> Dictionary:
	var needs_component = ActorTableType.get_component(colonist, "needs", _content)
	return needs_component if needs_component != null else {}

func _route(colonist: Dictionary):
	var mover_component = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

func searching_colonist_ids() -> Array[String]:
	var ids: Array[String] = []
	for colonist_id in _searching.keys():
		ids.append(String(colonist_id))
	return ids

## The need job id this colonist is currently pursuing (submitted, whether or
## not yet assigned/active), or "" when none -- WorldState.
## get_active_need_job_id()'s backing store.
func get_pending_job(colonist_id: String) -> String:
	return String(_pending.get(colonist_id, ""))

## Runs once per tick, before the fair scheduler's own tick() (colonist-ai.md
## 3.1's layers 2/4, evaluated "before layer 5's work is even considered").
func advance(colonists: Array[Dictionary], tick: int) -> void:
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

## F3 (issue #290): a need job is never created for an actor whose faction's
## rules.may_be_ordered is not true, read through the registry -- never a
## hardcoded "colony" string -- so a future orderable non-colony faction needs
## no change here. Fails open for an actor naming no faction id at all.
func _may_be_ordered(colonist: Dictionary) -> bool:
	var faction_id := String(colonist.get("factionId", "colony"))
	var faction: Dictionary = _content.get_entry("factions", faction_id)
	if faction.is_empty():
		return true
	return bool(faction.get("rules", {}).get("may_be_ordered", true))

## WorldState's on_work_complete/on_consume_success/on_toil_fail hooks call
## this the instant a need job they just finished/failed resolves, so a
## colonist paused for it (see interrupt_current_job) resumes the same tick
## rather than waiting for this module's own next advance() call.
func resolve_job(job_id: String) -> void:
	for colonist_id in _pending.keys():
		if String(_pending[colonist_id]) == job_id:
			_pending.erase(colonist_id)
			_resume_interrupted_job.call(colonist_id)
			return

## The colonist_id currently pending on job_id, or "" when job_id names no
## pending need job. Used by WorldState._resubmit_unreachable_job() (colonist-
## ai.md 3.3's unreachable-target resubmission) to carry a need job's
## ownership across to its replacement id via reassign_job() below, rather
## than losing the association the moment the original id stops existing.
func colonist_for_job(job_id: String) -> String:
	for colonist_id in _pending.keys():
		if String(_pending[colonist_id]) == job_id:
			return String(colonist_id)
	return ""

## Repoints the pending association from old_job_id to new_job_id without
## resuming the paused colonist (unlike resolve_job()): used when a need job's
## first-leg target turns out unreachable and WorldState cancels and
## resubmits the exact same target under a fresh id (colonist-ai.md 3.3) --
## the need itself is not resolved, only its job's identity changed, so the
## colonist stays paused/pursuing exactly as before, now watching the new id.
## A no-op when old_job_id names no pending need job.
func reassign_job(old_job_id: String, new_job_id: String) -> void:
	var colonist_id := colonist_for_job(old_job_id)
	if colonist_id.is_empty():
		return
	_pending[colonist_id] = new_job_id

## The WorldState-owned persistence boundary for _pending (see
## persistence/state_codec.gd): NeedGiver itself never touches file I/O or
## schema shapes, so it only ever hands back/accepts the plain colonist_id ->
## job_id Dictionary a caller can encode/decode however its save format
## requires.
func get_pending_assignments() -> Dictionary:
	return _pending.duplicate()

## Overwrites _pending from a prior save's persisted association (see
## get_pending_assignments()). Called once, immediately after a fresh
## NeedGiver is constructed for a loaded WorldState, before any advance()/
## resolve_job() call: without this, resolve_job() could never find the
## paused colonist for a need job that was already queued or active at save
## time, and that colonist's interrupted work would never resume.
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
	# colonist.route/work both null already means this is a toil boundary (no
	# route, no in-progress work), but it does NOT mean the colonist is free of
	# a job: a multi-toil job (haul) idles between its instant pick_up/place
	# toils, which set neither field, while the scheduler's own assignment for
	# it stays live. interrupt_current_job is a no-op when there is truly
	# nothing to interrupt (a genuinely idle colonist), so calling it
	# unconditionally here is what actually delivers "urgent needs interrupt
	# at a toil boundary" for that shape -- without it, the shared scheduler
	# keeps the boundary's active assignment and never offers this colonist
	# the restricted need job until the old job finishes on its own.
	_interrupt_current_job.call(colonist)
	_start_search(colonist, kind, tick)

## The single need kind at/below threshold_key with the lowest value (ties
## break on kind name, ascending), skipping any kind still under retry
## backoff; "" when none qualifies.
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

## Starts a fresh search for the nearest reachable, unreserved, not-already-
## targeted source of `kind` (colonist-ai.md 3.1): "nearest" means the
## shortest actual bounded-route path (see _advance_commit()), not straight-
## line distance -- a farther candidate by Manhattan distance can have a much
## shorter real route than a closer one blocked behind a detour. Candidates
## are pre-sorted by Manhattan distance (ties broken row-major, matching the
## routing module's own tie-break convention) purely to pick a cheap search
## order and to let _advance_search() prune remaining candidates once no
## unsearched candidate could possibly beat the best route found so far
## (Manhattan distance is always <= real route length, so once a candidate's
## Manhattan distance alone exceeds the current best route length, searching
## it can never improve on that best). Already-reserved or already-claimed
## candidates are dropped up front as a cheap pre-filter, then every
## remaining candidate is re-checked again at commit time (see
## _advance_commit()) since a search can span several ticks, during which
## another colonist may reserve or claim any of them.
func _start_search(colonist: Dictionary, kind: String, tick: int) -> void:
	var colonist_id: String = colonist["id"]
	var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var claimed: Dictionary = _claimed_targets.call()
	var candidates: Array[Vector2i] = []
	for tile in (_source_candidates.call(kind) as Array):
		if claimed.has(tile):
			continue
		if not _reservation_table.is_reserved(String(_tile_key.call(tile.x, tile.y))):
			candidates.append(tile)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - start.x) + absi(a.y - start.y)
		var db := absi(b.x - start.x) + absi(b.y - start.y)
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
		distances.append(absi(candidate.x - start.x) + absi(candidate.y - start.y))
	_searching[colonist_id] = {"kind": kind, "candidates": candidates, "distances": distances,
		"cursor": 0, "search": null, "found": []}
	_set_reason.call(colonist_id, "")
	_advance_search(colonist, tick)

## Advances the colonist's current search by exactly one step per tick, same
## cadence as the single-candidate search this replaced. Two phases share the
## same per-tick "one step" budget, distinguished by state["ranked"]:
## - Search phase (state["ranked"] absent): one bounded resume() call against
##   the current candidate, recording every STATUS_FOUND candidate (with its
##   real route length) into state["found"] rather than committing to the
##   first one reached -- see _start_search() for why the pre-sort order
##   alone cannot decide the nearest candidate. Stops early, without
##   searching the remaining candidates, once the next candidate's Manhattan
##   distance already exceeds the shortest route length found so far (a
##   candidate's real route can only be >= its own Manhattan distance, so it
##   could never win). Ending the phase ranks state["found"] into
##   state["ranked"] (shortest length first, ties broken by the pre-sort
##   order, so the same map/start/candidate-set always yields the same
##   ranking) and defers the first commit attempt to the next tick, so a
##   commit-phase transition never lands on the same tick as the search
##   phase's own last transition.
## - Commit phase (state["ranked"] present): rechecks exactly one ranked
##   candidate per tick for a reservation/claim race before committing to it.
##   A candidate that lost that race records blocked_source_reserved (visible
##   for that whole tick, mirroring colonist-ai.md 3.8) and the next tick
##   tries the next-best already-found alternative rather than restarting the
##   search. Only once every ranked candidate is taken, or none were ever
##   found, is this a full onset failure.
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
		search = RerouteType.new(start, target, _routable_to.call(target), Vector2i.ZERO, _bounds_max)
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

## Submits the need job through the same scheduler entry point any
## order-driven job uses (colonist-ai.md 3.1/3.4). Losing a last-instant race
## for the target (another submission this same tick) simply gives up this
## attempt; the next advance() call re-evaluates from scratch.
func _commit(colonist_id: String, kind: String, target: Vector2i, tick: int) -> void:
	var job_kind := String(JOB_KIND_BY_NEED.get(kind, ""))
	var result: Dictionary = _submit_job.call(target, _priority, tick, job_kind, colonist_id)
	if not result.get("ok", false):
		return
	_pending[colonist_id] = String(result["job_id"])
	_set_reason.call(colonist_id, "")
	_alerted.erase(_key(colonist_id, kind))
	_backoff.erase(_key(colonist_id, kind))

## Exhausting every candidate (or finding none at all): exposes
## need_unmet:<kind> (colonist-ai.md 3.8), emits the alert exactly once per
## onset, starts a backoff so this colonist stops re-searching every tick,
## and resumes whatever job interrupt_current_job() paused for it, if any
## (colonist-ai.md 3.1's "the colonist keeps working" -- with no reachable
## source at all, there is nothing left to interrupt work for).
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
