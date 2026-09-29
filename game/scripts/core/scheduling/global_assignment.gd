extends RefCounted

const QueueType = preload("res://scripts/core/scheduling/assignment_queue.gd")
const RouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const JOB_EVALUATION_BUDGET := 32
const PRIORITY_WEIGHT := 16
const MAX_TRAVEL_PENALTY := 15
const ROUTE_CANDIDATES_PER_WORKER := 2
## Caps colonist-ai.md 3.2's priority bracket like MAX_TRAVEL_PENALTY caps
## travel: an unbounded calendar boost could defeat ADR 004's aging proof.
const MAX_PRIORITY_BRACKET := 20
## Top of the labour-level range (0 "off" .. 4); also the "no bonus" level.
const LABOUR_LEVEL_MAX := 4

var queue: QueueType
## The content bundle ActorTable.get_component() (ADR 012) resolves a
## worker's labourTable against.
var _content
var _waiting: Array[Dictionary] = []
var _next_ordinal: int = 0
var _cursors: Dictionary = {}
var _pending: Dictionary = {}
var _assignments: Dictionary = {}
var _metrics: Dictionary = {}
## colonist_id -> true once its one-resume-per-tick routing allowance (ADR
## 004) is spent this tick(); cleared at the top of every call. Shared by
## reference with ToilExecutor via WorldState.set_route_budget() (ADR 012).
var _route_budget: Dictionary = {}
## job_id -> the waiting-queue entry captured when a job is first chosen and
## removed from _waiting, kept live so suspend_assignment() (colonist-ai.md
## 3.6) can restore its exact waiting position. Erased only on finish().
var _activated_entries: Dictionary = {}
## F3 (issue #290): consulted twice -- an early-exit optimization before an
## unrestricted worker is proposed for any job (reaches haul, see
## haul_giver.gd), and again, authoritatively, alongside _may_reserve
## immediately before any job's reserve step, since a restrict_to'd/
## committed-need worker's faction can change before that finishes (ADR 015).
## Callable(worker_id: String) -> bool; unset (Callable()) fails open.
var _may_be_ordered: Callable = Callable()
## F3 (issue #290): consulted immediately before a chosen job's reserve step
## would acquire a tile:/item:/cell: key -- never after, so a refused actor's
## reservation is never even transiently held. Callable(worker_id: String)
## -> bool; unset fails open.
var _may_reserve: Callable = Callable()
## {"job_id", "worker"} pairs refused by _may_be_ordered/_may_reserve since the
## last take_refused_reservations() drain. `worker` travels with `job_id` (F3,
## issue #290 round 2) so WorldState can identify a refused HAUL RESUMPTION's
## colonist and return its carried item -- by the time it is refused,
## _assignments no longer names the worker for that job_id.
var _refused_reservations: Array[Dictionary] = []
## F5 (issue #294, ADR 015 Amendment): the reservation gate consulted for an
## AUTONOMOUS entry instead of _may_reserve -- Callable(worker_id: String,
## target: Vector2i) -> bool, so the owner can answer "may this actor reserve
## THIS target" (a bare tile yes, a colony-owned item/object/cell no) rather
## than _may_reserve's target-blind "may this faction reserve colony items"
## (false for every non-colony faction). Unset falls back to _may_reserve,
## i.e. an autonomous entry is then gated exactly like any other.
var _may_reserve_autonomous: Callable = Callable()
## F5 (issue #294): Callable(worker_id: String, tile: Vector2i) -> cost for an
## AUTONOMOUS entry's own route search, so a non-colony actor's initial
## bounded search runs under its own faction's door permissions instead of
## tick()'s colony-bound `passable`. Unset falls back to `passable`.
var _passable_autonomous: Callable = Callable()

func _init(random_source: RandomNumberGenerator, content_registry) -> void:
	queue = QueueType.new(random_source)
	_content = content_registry

## Reads a colonist's "worker" component labourTable through ActorTable
## (ADR 012) rather than indexing the colonist dict directly.
func _labour_table(colonist: Dictionary) -> Dictionary:
	var worker_component = ActorTableType.get_component(colonist, "worker", _content)
	return worker_component.get("labourTable", {}) if worker_component != null else {}

func set_route_budget(budget: Dictionary) -> void:
	_route_budget = budget

func set_order_eligibility(may_be_ordered: Callable) -> void:
	_may_be_ordered = may_be_ordered

func set_reservation_gate(may_reserve: Callable) -> void:
	_may_reserve = may_reserve

func set_autonomous_reservation_gate(may_reserve_target: Callable) -> void:
	_may_reserve_autonomous = may_reserve_target

func set_autonomous_passability(passable_for_worker: Callable) -> void:
	_passable_autonomous = passable_for_worker

func _worker_may_be_ordered(worker: String) -> bool:
	return not _may_be_ordered.is_valid() or bool(_may_be_ordered.call(worker))

func _worker_may_reserve(worker: String) -> bool:
	return not _may_reserve.is_valid() or bool(_may_reserve.call(worker))

## The reservation gate for one ready pair: _may_reserve for an ordinary
## entry; the target-aware _may_reserve_autonomous for an autonomous one
## (falling back to _may_reserve when none is wired). Never skipped.
func _pair_may_reserve(worker: String, entry: Dictionary) -> bool:
	if _is_autonomous(entry) and _may_reserve_autonomous.is_valid():
		return bool(_may_reserve_autonomous.call(worker, entry["target"]))
	return _worker_may_reserve(worker)

func _is_autonomous(entry: Dictionary) -> bool:
	return bool(entry.get("autonomous", false))

## The cost callable a route search for `entry` runs under: `passable`
## (tick()'s colony-bound one) for an ordinary entry, the worker's own
## faction-aware _passable_autonomous for an autonomous one.
func _passable_for(worker: String, entry: Dictionary, passable: Callable) -> Callable:
	if _is_autonomous(entry) and _passable_autonomous.is_valid():
		return func(tile: Vector2i): return _passable_autonomous.call(worker, tile)
	return passable

## {"job_id", "worker"} pairs _may_be_ordered/_may_reserve refused since the
## last drain, cleared on read so WorldState resolves each exactly once.
func take_refused_reservations() -> Array[Dictionary]:
	var refused := _refused_reservations
	_refused_reservations = []
	return refused

## restrict_to: when non-empty, only that worker's own scan may propose this
## entry; used both for a committed need job (NeedGiver._commit()) and a
## critical-need-interrupted work job (suspend_assignment() below) -- NOT
## equivalent: tick()'s `committed_needs` param, not this flag, is what makes
## a need strictly precede work. Empty for an ordinary order.
## autonomous (F5, issue #294, ADR 015 Amendment): when true, the "ready"
## loop's authoritative gate check below never calls _worker_may_be_ordered()
## for this entry -- _may_be_ordered exists to stop a PLAYER ORDER from
## targeting a non-colony actor (WorldState._apply_job_command()'s assignee
## check), not to veto that actor's own autonomous submission of its own job.
## restrict_to must still name the one worker this entry may ever activate
## for; submit_autonomous() below is the narrow entry point that sets both.
## The flag is stored on the entry ONLY when true (absence reads false), so
## every ordinary entry -- and every snapshot()/save taken of a world that
## never submits an autonomous job -- keeps its exact pre-#294 shape.
func submit(target: Vector2i, priority: int, tick_number: int, kind: String = "dig", restrict_to: String = "",
		autonomous: bool = false) -> Dictionary:
	var result := queue.submit_dig(target, priority, kind)
	if result["ok"]:
		var entry := {"id": result["job_id"], "target": target,
			"base": PRIORITY_WEIGHT * priority - tick_number,
			"submitted_tick": tick_number, "ordinal": _next_ordinal, "restrict_to": restrict_to}
		if autonomous:
			entry["autonomous"] = true
		_next_ordinal += 1
		var index := 0
		while index < _waiting.size() and _entry_before(_waiting[index], entry):
			index += 1
		_waiting.insert(index, entry)
		for worker in _cursors:
			if int(_cursors[worker]) > index:
				_cursors[worker] += 1
	return result

## Narrow autonomous-actor activation path (ADR 015 Amendment, issue #294):
## submits target restricted to worker's own scan, exactly like submit()'s
## restrict_to, but additionally exempted from _worker_may_be_ordered() at
## the "ready" loop's authoritative check -- never from the reservation gate
## (_pair_may_reserve(): the target-aware _may_reserve_autonomous when
## wired, else _may_reserve itself), the ordinary tick()/advance_selection()
## clock-driven activation, the reservation table's target-conflict check,
## or route search (run under _passable_autonomous, the worker's own
## faction): an autonomous job goes through every other gate/step a
## colonist's own job does, and is refused (take_refused_reservations())
## exactly like one if its reservation gate ever says no.
func submit_autonomous(target: Vector2i, priority: int, tick_number: int, kind: String, worker: String) -> Dictionary:
	return submit(target, priority, tick_number, kind, worker, true)

func finish(job_id: String, operation: String) -> Dictionary:
	var result: Dictionary
	match operation:
		"complete_job": result = queue.complete(job_id)
		"cancel_job": result = queue.cancel(job_id)
		"fail_job": result = queue.fail(job_id)
		_: result = queue.invalidate(job_id)
	if result["ok"]:
		_activated_entries.erase(job_id)
		_remove_waiting(job_id)
		for worker in _pending.keys():
			var request: Dictionary = _pending[worker]
			for index in range(request["candidates"].size() - 1, -1, -1):
				if request["candidates"][index]["id"] == job_id:
					request["candidates"].remove_at(index)
					if index < request["cursor"]:
						request["cursor"] -= 1
					elif index == request["cursor"]:
						request["route"] = null
			for index in range(request["found"].size() - 1, -1, -1):
				if request["found"][index]["entry"]["id"] == job_id:
					request["found"].remove_at(index)
			if request["candidates"].is_empty():
				_pending.erase(worker)
		for worker in _assignments.keys():
			if _assignments[worker]["job_id"] == job_id:
				_assignments.erase(worker)
	return result

## One global pair pool, followed by disjoint routing and activation phases.
## get_job_labour/get_calendar_boost wire colonist-ai.md 3.2's formula.
## all_colonists is the full roster for _refresh_labour_disabled_reasons(),
## defaulting to `colonists` (already filtered to "not mid-search").
## committed_needs (worker id -> job id) names each worker's committed need
## job: nothing else is proposed to it (colonist-ai.md 3.1/3.6).
## region_check(a, b) -> bool (F5 "Regions"): checked once per pending candidate
## before RouteType construction; unset fails open (pre-#292 callers unchanged).
func tick(tick_number: int, colonists: Array[Dictionary], passable: Callable,
		bounds_min: Vector2i, bounds_max: Vector2i,
		get_job_labour: Callable = Callable(), get_calendar_boost: Callable = Callable(),
		all_colonists: Array[Dictionary] = [], committed_needs: Dictionary = {},
		region_check: Callable = Callable()) -> void:
	_metrics = {}
	_route_budget.clear()
	var workers: Array[Dictionary] = colonists.duplicate(true)
	workers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	var proposals: Array[Dictionary] = []
	var selected: Array[String] = []
	var reachable: Dictionary = {}
	# A committed need discards any of this worker's OTHER pending route batch
	# (not its own, still resuming across ticks -- see _pending_matches_job()).
	for worker in committed_needs:
		if not _pending_matches_job(worker, String(committed_needs[worker])):
			_pending.erase(worker)
	var claimed_jobs: Dictionary = {}
	for worker in _pending:
		for entry in _pending[worker]["candidates"]:
			claimed_jobs[entry["id"]] = true
	## job_id -> job kind, indexed once per tick for _priority_bracket();
	## skipped when no caller wires labour scoring in.
	var job_kinds: Dictionary = {}
	if get_job_labour.is_valid():
		for job in queue.get_jobs():
			job_kinds[job["id"]] = String(job.get("kind", ""))
		# Before advance_selection() below, so a labour re-enable's job_unblocked fires first.
		_refresh_labour_disabled_reasons(all_colonists if not all_colonists.is_empty() else workers, job_kinds, get_job_labour)
	var reservations := queue.get_reservations()
	for colonist in workers:
		var worker: String = colonist["id"]
		_metrics[worker] = {"job_evaluations": 0, "route_steps": 0, "route_calls": 0}
		if _assignments.has(worker) or _pending.has(worker) or _waiting.is_empty():
			continue
		var labour_table: Dictionary = _labour_table(colonist)
		var need_job_id := String(committed_needs.get(worker, ""))
		if not need_job_id.is_empty():
			_propose_committed_need(worker, colonist, need_job_id, job_kinds, labour_table,
				tick_number, get_job_labour, get_calendar_boost, reservations, claimed_jobs, selected, proposals)
			continue
		var cursor: int = int(_cursors.get(worker, 0)) % _waiting.size()
		var count := mini(JOB_EVALUATION_BUDGET, _waiting.size() - cursor)
		var worker_proposals: Array[Dictionary] = []
		for index in range(cursor, cursor + count):
			_metrics[worker]["job_evaluations"] += 1
			var entry: Dictionary = _waiting[index]
			if claimed_jobs.has(entry["id"]):
				continue
			var restrict_to := String(entry.get("restrict_to", ""))
			if not restrict_to.is_empty() and restrict_to != worker:
				continue
			# F3 (issue #290): an unrestricted entry (haul, or any order with
			# no assignee) is never even proposed to an order-ineligible
			# worker -- an early-exit optimization only. A restrict_to'd
			# entry skips this filter (vetted at submission time) but is NOT
			# exempt from eligibility: the "ready" loop below revalidates
			# _worker_may_be_ordered() for every proposal, since its faction
			# can still change during a multi-tick route search.
			if restrict_to.is_empty() and not _worker_may_be_ordered(worker):
				continue
			if not _is_labour_enabled(entry, job_kinds, labour_table, get_job_labour):
				continue
			if reservations.has(entry["target"]):
				if entry["id"] not in selected:
					selected.append(entry["id"])
				continue
			worker_proposals.append(_score_candidate(worker, colonist, entry, job_kinds, labour_table,
				tick_number, get_job_labour, get_calendar_boost))
		proposals.append_array(worker_proposals)
		_cursors[worker] = (cursor + count) % _waiting.size()
	proposals.sort_custom(_pair_before)
	var batches: Dictionary = {}
	# Fill one slot for each worker before offering second slots. Actual router
	# distances, rather than lower bounds, decide which candidate is activated.
	for slot in ROUTE_CANDIDATES_PER_WORKER:
		for proposal in proposals:
			var worker: String = proposal["worker"]
			var entry: Dictionary = proposal["entry"]
			if claimed_jobs.has(entry["id"]):
				continue
			if not batches.has(worker):
				var new_candidates: Array[Dictionary] = []
				batches[worker] = {"candidates": new_candidates, "cursor": 0,
					"route": null, "found": [], "start": proposal["start"]}
			if batches[worker]["candidates"].size() > slot:
				continue
			batches[worker]["candidates"].append(entry)
			claimed_jobs[entry["id"]] = true
	for worker in batches:
		_pending[worker] = batches[worker]
	var ready: Array[Dictionary] = []
	var finished_workers: Array[String] = []
	for colonist in workers:
		var worker: String = colonist["id"]
		if not _pending.has(worker):
			continue
		var labour_table: Dictionary = _labour_table(colonist)
		var request: Dictionary = _pending[worker]
		if request["cursor"] < request["candidates"].size():
			var entry: Dictionary = request["candidates"][request["cursor"]]
			# F5 "Regions": treated like a completed search that found none --
			# still scored/ranked normally on its next cursor slot below.
			if request["route"] == null and region_check.is_valid() and not bool(region_check.call(request["start"], entry["target"])):
				if _is_labour_enabled(entry, job_kinds, labour_table, get_job_labour):
					selected.append(entry["id"])
				request["cursor"] += 1
				request["route"] = null
				continue
			if request["route"] == null:
				request["route"] = RouteType.new(request["start"], entry["target"],
					_routable(entry["target"], _passable_for(worker, entry, passable)), bounds_min, bounds_max)
			var route: RouteType = request["route"]
			var before := route.expansions
			if not route.is_terminal():
				if not bool(_route_budget.get(worker, false)):
					route.resume()
					_route_budget[worker] = true
				_metrics[worker]["route_calls"] = 1
			_metrics[worker]["route_steps"] = route.expansions - before
			assert(int(_metrics[worker]["route_steps"]) <= RouteType.STEP_BUDGET)
			if not route.is_terminal():
				continue
			if route.get_status() == RouteType.STATUS_FOUND:
				request["found"].append({"worker": worker, "entry": entry,
					"travel": route.get_path().size() - 1, "path": route.get_path()})
			elif _is_labour_enabled(entry, job_kinds, labour_table, get_job_labour):
				selected.append(entry["id"])
			request["cursor"] += 1
			request["route"] = null
		if request["cursor"] == request["candidates"].size():
			finished_workers.append(worker)
			for pair in request["found"]:
				if not _is_labour_enabled(pair["entry"], job_kinds, labour_table, get_job_labour):
					continue
				var bracket := _priority_bracket(pair["entry"], job_kinds, labour_table, tick_number, get_job_labour, get_calendar_boost)
				var ticks_waiting := tick_number - int(pair["entry"]["submitted_tick"])
				pair["score"] = PRIORITY_WEIGHT * bracket + ticks_waiting - mini(MAX_TRAVEL_PENALTY, int(pair["travel"]))
				ready.append(pair)
	ready.sort_custom(_pair_before)
	var chosen: Array[Dictionary] = []
	var chosen_workers: Dictionary = {}
	for pair in ready:
		if chosen_workers.has(pair["worker"]):
			continue
		chosen_workers[pair["worker"]] = true
		# F3 (issue #290, round 2): both gates are revalidated here, right
		# before advance_selection() below ever acquires this job's
		# reservation -- never after. This is the ONE point every proposal
		# reaches regardless of how it got here (unrestricted scan,
		# restrict_to'd order/committed-need entry, or a multi-tick pending
		# routing batch): the scan loop's own early filter above is only an
		# optimization, not proof of current eligibility -- a restrict_to'd
		# worker's faction can still change before its route search finishes.
		# F5 (issue #294, ADR 015 Amendment): an "autonomous" entry (an
		# incident actor's own submission, never a player order) skips ONLY
		# _may_be_ordered here -- that gate exists to keep a PLAYER ORDER from
		# naming a non-colony assignee. Its reservation gate is never skipped:
		# _pair_may_reserve() consults the target-aware
		# _may_reserve_autonomous ("may this actor reserve THIS target": a
		# bare tile yes, a colony-owned item/object/cell no) so the
		# colony-item restriction still holds, and the reservation table's
		# own target-conflict check (JobQueue.tick()/advance_selection(),
		# right below) still refuses a target another job already owns.
		var ordered := _is_autonomous(pair["entry"]) or _worker_may_be_ordered(pair["worker"])
		if not ordered or not _pair_may_reserve(pair["worker"], pair["entry"]):
			_refused_reservations.append({"job_id": pair["entry"]["id"], "worker": pair["worker"]})
			continue
		chosen.append(pair)
		selected.append(pair["entry"]["id"])
		reachable[pair["entry"]["target"]] = true
	queue.advance_selection(selected, reachable)
	for pair in chosen:
		var job_id: String = pair["entry"]["id"]
		if queue.get_job(job_id)["status"] == "active":
			var path: Array = pair.get("path", [])
			# _routable() lets the search terminate ON an impassable resource tile
			# (a chop job's tree); trim that last step so execution stops adjacent
			# to it instead, after scoring so travel-cost math is untouched.
			if path.size() > 1 and not _is_passable_value(_passable_for(pair["worker"], pair["entry"], passable).call(pair["entry"]["target"])):
				path = path.slice(0, path.size() - 1)
			_assignments[pair["worker"]] = {"job_id": job_id,
				"started_tick": tick_number, "travel_ticks": pair["travel"], "path": path}
			if not _activated_entries.has(job_id):
				_activated_entries[job_id] = pair["entry"].duplicate(true)
			_remove_waiting(job_id)
	for worker in finished_workers:
		_pending.erase(worker)

## Proposes worker's committed need job only, by direct id lookup (never
## tick()'s bounded scan); never a scored competitor (see submit()).
func _propose_committed_need(worker: String, colonist: Dictionary, job_id: String, job_kinds: Dictionary,
		labour_table: Dictionary, tick_number: int, get_job_labour: Callable, get_calendar_boost: Callable,
		reservations: Dictionary, claimed_jobs: Dictionary, selected: Array[String], proposals: Array[Dictionary]) -> void:
	if claimed_jobs.has(job_id):
		return
	var entry := _find_waiting_entry(job_id)
	if entry.is_empty():
		return
	if reservations.has(entry["target"]):
		if job_id not in selected:
			selected.append(job_id)
		return
	proposals.append(_score_candidate(worker, colonist, entry, job_kinds, labour_table,
		tick_number, get_job_labour, get_calendar_boost))

func _find_waiting_entry(job_id: String) -> Dictionary:
	for entry in _waiting:
		if entry["id"] == job_id:
			return entry
	return {}

func _pending_matches_job(worker: String, job_id: String) -> bool:
	if not _pending.has(worker):
		return false
	for entry in _pending[worker]["candidates"]:
		if entry["id"] == job_id:
			return true
	return false

## Shared by tick()'s scan and _propose_committed_need().
func _score_candidate(worker: String, colonist: Dictionary, entry: Dictionary, job_kinds: Dictionary,
		labour_table: Dictionary, tick_number: int, get_job_labour: Callable, get_calendar_boost: Callable) -> Dictionary:
	var bracket := _priority_bracket(entry, job_kinds, labour_table, tick_number, get_job_labour, get_calendar_boost)
	var start := Vector2i(colonist["x"], colonist["y"])
	var delta: Vector2i = entry["target"] - start
	var ticks_waiting := tick_number - int(entry["submitted_tick"])
	return {"worker": worker, "entry": entry, "start": start,
		"score": PRIORITY_WEIGHT * bracket + ticks_waiting - mini(MAX_TRAVEL_PENALTY, absi(delta.x) + absi(delta.y))}

## colonist-ai.md 3.2's non-terminal "labour_disabled" reason: a queued job
## whose labour is off for every colonist in `colony` is marked so
## (JobQueue.set_labour_disabled()) over every waiting entry. `colony` must be
## the full roster, not tick()'s own filtered `colonists`: excluding a
## searching colonist could wrongly report a job disabled or miss one.
func _refresh_labour_disabled_reasons(colony: Array[Dictionary], job_kinds: Dictionary, get_job_labour: Callable) -> void:
	var disabled_labours: Dictionary = {}
	for colonist in colony:
		var table: Dictionary = _labour_table(colonist)
		for kind in table:
			var level := int(table[kind])
			if not disabled_labours.has(kind):
				disabled_labours[kind] = true
			if level > 0:
				disabled_labours[kind] = false
	for entry in _waiting:
		var labour := String(get_job_labour.call(String(job_kinds.get(entry["id"], ""))))
		queue.set_labour_disabled(entry["id"], bool(disabled_labours.get(labour, false)))

## Frees worker's current assignment without touching the underlying job's own
## record (colonist-ai.md 3.6). A no-op when worker has no assignment.
func clear_assignment(worker: String) -> void:
	_assignments.erase(worker)

## F5/#302 (round-5 review, dead-worker gap): erases worker's own in-flight
## candidate-routing batch, if any. tick() rebuilds claimed_jobs from every
## entry still in _pending on every call, which excludes those job ids from
## being proposed to any OTHER worker -- a removed worker that never advances
## its own batch again (it no longer appears in the `colonists` array tick()
## receives) would otherwise starve them of it forever, even though the jobs
## themselves remain valid for a living worker to pick up. Leaves _waiting,
## _assignments and every other worker's own state untouched: a no-op when
## worker has no pending batch (already assigned, or never started a search).
func retire_worker(worker: String) -> void:
	_pending.erase(worker)

## Re-establishes worker's assignment to job_id directly, bypassing
## proposal/routing/scoring: resuming an interrupted job, not a new pick.
func set_assignment(worker: String, job_id: String) -> void:
	_assignments[worker] = {"job_id": job_id, "started_tick": 0, "travel_ticks": 0, "path": []}

## Critical-need interrupt (ADR 009): clears the assignment, suspends the
## job's reservation, and reinserts its _activated_entries snapshot back into
## _waiting at its exact aging position, pinned to `worker` so only this same
## colonist's scan may be offered it back (resume_assignment() reverses
## this). A no-op when job_id was never chosen or is already back in _waiting.
func suspend_assignment(worker: String, job_id: String) -> void:
	clear_assignment(worker)
	queue.suspend(job_id)
	ToolMatchingType.reinsert_activated_entry(_waiting, _cursors, _activated_entries, job_id, worker, _entry_before)

## Ordinary requeue for a failure unrelated to a critical-need interrupt
## (issue #271 round 6): the same aging-preserved reinsert as
## suspend_assignment(), but keeps the entry's ORIGINAL restrict_to (empty
## for an ordinary order) so any eligible colonist may pick it back up.
func requeue_assignment(worker: String, job_id: String) -> void:
	clear_assignment(worker)
	queue.suspend(job_id)
	ToolMatchingType.reinsert_activated_entry(_waiting, _cursors, _activated_entries, job_id, "", _entry_before)

## Reverses suspend_assignment(): queue.reactivate(job_id) re-derives the
## job's activation directly by ownership. When the target is still free,
## drops the reinserted waiting entry and restores the assignment. When a
## different job claimed the target meanwhile, this is a no-op: job_id stays
## queued/restricted for the ordinary fair-queue path (ADR 009).
func resume_assignment(worker: String, job_id: String) -> void:
	# F3 (issue #290, round 2): both gates checked before reactivate() below
	# re-acquires the reservation -- never after -- so a faction change made
	# while suspended cannot reacquire on resume. Same gates as the "ready"
	# loop (F5/#302 round 7): an autonomous entry skips _worker_may_be_ordered().
	var entry: Dictionary = _activated_entries.get(job_id, {})
	if not (_is_autonomous(entry) or _worker_may_be_ordered(worker)) or not _pair_may_reserve(worker, entry):
		_refused_reservations.append({"job_id": job_id, "worker": worker})
		return
	if not queue.reactivate(job_id):
		return
	_remove_waiting(job_id)
	set_assignment(worker, job_id)

## The restrict_to job_id was submitted with, from its _activated_entries
## snapshot (captured the instant it was first chosen); "" for an unknown or
## never-activated job_id. Lets WorldState._resubmit_unreachable_job()
## preserve a player-ordered dig/chop/forage job's assignee restriction
## across an unreachable-target resubmission -- NeedGiver.colonist_for_job()
## already covers a need job's own restriction the same way, but a plain
## order has no NeedGiver association at all.
func restrict_to_for(job_id: String) -> String:
	return String(_activated_entries.get(job_id, {}).get("restrict_to", ""))

## The waiting-queue entry captured for job_id the instant it was first
## chosen, for callers that persist it across the job's active lifetime
## (state_codec.gd) beyond this scheduler's own suspend/resume use above.
func get_activated_entries() -> Dictionary:
	return _activated_entries.duplicate(true)

func get_metrics() -> Dictionary:
	return _metrics.duplicate(true)

func get_assignments() -> Dictionary:
	return _assignments.duplicate(true)

func get_waiting() -> Array[Dictionary]:
	return _waiting.duplicate(true)

func get_next_ordinal() -> int:
	return _next_ordinal

func get_cursors() -> Dictionary:
	return _cursors.duplicate()

## Pending route-evaluation batches, one per worker still mid-evaluation.
## "route" is the in-flight RouteType's snapshot(), or null when no search has
## started yet for the batch's current candidate.
func get_pending() -> Dictionary:
	var pending: Dictionary = {}
	for worker in _pending:
		var request: Dictionary = _pending[worker].duplicate(true)
		var route: RouteType = _pending[worker]["route"]
		request["route"] = route.snapshot() if route != null else null
		pending[worker] = request
	return pending

## Overwrites waiting/cursor/pending/assignment continuation state from a
## prior save state, rebuilding pending routes with the same _routable()
## wrapper tick() uses. Round-8 review: routed per-entry through
## _passable_for(), exactly like tick()'s own live search, so a restored
## autonomous entry is gated by its own actor's faction, not the colony's.
func restore_scheduling(state: Dictionary, is_passable: Callable, bounds_min: Vector2i, bounds_max: Vector2i) -> void:
	_waiting = state["waiting"].duplicate(true)
	_next_ordinal = state["next_ordinal"]
	_cursors = state["cursors"].duplicate()
	_assignments = state["assignments"].duplicate(true)
	_activated_entries = state.get("activated_entries", {}).duplicate(true)
	_metrics = {}
	_pending = {}
	for worker in state["pending"]:
		var saved: Dictionary = state["pending"][worker]
		var request: Dictionary = saved.duplicate(true)
		var route_state = saved["route"]
		if route_state == null:
			request["route"] = null
		else:
			var entry: Dictionary = request["candidates"][request["cursor"]]
			var route: RouteType = RouteType.new(route_state["start"], route_state["start"], _routable(entry["target"], _passable_for(worker, entry, is_passable)), bounds_min, bounds_max)
			route.restore(route_state)
			request["route"] = route
		# StateCodec cannot persist a found pair's resolved path, so it is
		# dropped on encode and rebuilt here: RouteSearch is deterministic, so
		# re-running it from the same start/target reproduces the same path.
		var restored_found: Array = []
		for pair in request["found"]:
			var restored_pair: Dictionary = pair.duplicate(true)
			restored_pair["path"] = _resolve_path(request["start"], pair["entry"]["target"], _passable_for(worker, pair["entry"], is_passable), bounds_min, bounds_max)
			restored_found.append(restored_pair)
		request["found"] = restored_found
		_pending[worker] = request

## Used by WorldState.state_hash(), not save/load. "path" is left out: it is
## fully re-derivable from job_id/start/target (RouteSearch is deterministic).
func snapshot() -> Dictionary:
	var pending: Dictionary = {}
	for worker in _pending:
		var request: Dictionary = _pending[worker].duplicate(true)
		var route: RouteType = _pending[worker]["route"]
		request["route"] = route.snapshot() if route != null else {}
		var found: Array = []
		for pair in request["found"]:
			found.append({"worker": pair["worker"], "entry": pair["entry"], "travel": pair["travel"]})
		request["found"] = found
		pending[worker] = request
	var assignments: Dictionary = {}
	for worker in _assignments:
		var assignment: Dictionary = _assignments[worker]
		assignments[worker] = {"job_id": assignment["job_id"],
			"started_tick": assignment["started_tick"], "travel_ticks": assignment["travel_ticks"]}
	return {"version": 1, "waiting": _waiting.duplicate(true), "next_ordinal": _next_ordinal,
		"cursors": _cursors.duplicate(), "pending": pending,
		"assignments": assignments, "reservations": queue.get_reservations(),
		"activated_entries": _activated_entries.duplicate(true)}

## Wraps a cost callable so a route search may terminate on its own target
## tile even when otherwise impassable (a chop job's tree); coerced to cost 1.
func _routable(target: Vector2i, cost_fn: Callable) -> Callable:
	return func(tile: Vector2i):
		if tile == target:
			var underlying = cost_fn.call(tile)
			return underlying if _is_passable_value(underlying) else 1
		return cost_fn.call(tile)

## Normalizes a cost/passable result to bool, mirroring RouteSearch._cost_of().
func _is_passable_value(value) -> bool:
	if typeof(value) == TYPE_BOOL:
		return value
	return float(value) > 0.0

## colonist-ai.md 3.2's hard eligibility filter, checked before any score is
## computed and kept separate from _priority_bracket(): a legitimately
## negative bracket (enabled labour, a negative calendar window) must still
## score and age normally, never mistaken for a "disabled" sentinel.
func _is_labour_enabled(entry: Dictionary, job_kinds: Dictionary, labour_table: Dictionary, get_job_labour: Callable) -> bool:
	if not get_job_labour.is_valid():
		return true
	var labour := String(get_job_labour.call(String(job_kinds.get(entry["id"], ""))))
	return WorkerType.labour_level(labour_table, labour, LABOUR_LEVEL_MAX) > 0

## colonist-ai.md 3.2's bracket for a pair _is_labour_enabled() already
## confirmed eligible: "order_priority + calendar_boost + 4 - labour_level",
## capped at MAX_PRIORITY_BRACKET but never floored. order_priority is
## recovered from entry["base"]; an invalid get_job_labour reproduces ADR
## 004's original formula (bracket == priority).
func _priority_bracket(entry: Dictionary, job_kinds: Dictionary, labour_table: Dictionary,
		tick_number: int, get_job_labour: Callable, get_calendar_boost: Callable) -> int:
	var order_priority := (int(entry["base"]) + int(entry["submitted_tick"])) / PRIORITY_WEIGHT
	if not get_job_labour.is_valid():
		return order_priority
	var labour := String(get_job_labour.call(String(job_kinds.get(entry["id"], ""))))
	var labour_level := WorkerType.labour_level(labour_table, labour, LABOUR_LEVEL_MAX)
	var calendar_boost := int(get_calendar_boost.call(labour, tick_number)) if get_calendar_boost.is_valid() else 0
	return mini(order_priority + calendar_boost + LABOUR_LEVEL_MAX - labour_level, MAX_PRIORITY_BRACKET)

## Re-runs a route search to completion for restore_scheduling(): safe to run
## unbounded since it repeats a search that already reached STATUS_FOUND once.
func _resolve_path(start: Vector2i, target: Vector2i, passable: Callable, bounds_min: Vector2i, bounds_max: Vector2i) -> Array:
	var route := RouteType.new(start, target, _routable(target, passable), bounds_min, bounds_max)
	while not route.is_terminal():
		route.resume()
	return route.get_path()

func _remove_waiting(job_id: String) -> void:
	for index in _waiting.size():
		if _waiting[index]["id"] != job_id:
			continue
		_waiting.remove_at(index)
		for worker in _cursors:
			if int(_cursors[worker]) > index:
				_cursors[worker] -= 1
		return

func _entry_before(a: Dictionary, b: Dictionary) -> bool:
	if a["base"] != b["base"]:
		return a["base"] > b["base"]
	return a["ordinal"] < b["ordinal"]

func _pair_before(a: Dictionary, b: Dictionary) -> bool:
	if a["score"] != b["score"]:
		return a["score"] > b["score"]
	if a["entry"]["ordinal"] != b["entry"]["ordinal"]:
		return a["entry"]["ordinal"] < b["entry"]["ordinal"]
	return a["worker"] < b["worker"]
