extends RefCounted

const QueueType = preload("res://scripts/core/scheduling/assignment_queue.gd")
const RouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const WaitingIndexType = preload("res://scripts/core/scheduling/waiting_index.gd")
const JOB_EVALUATION_BUDGET := 32
const PRIORITY_WEIGHT := 16
const MAX_TRAVEL_PENALTY := 15
const ROUTE_CANDIDATES_PER_WORKER := 2
## Caps the priority bracket so a calendar boost cannot defeat ADR 004's aging proof.
const MAX_PRIORITY_BRACKET := 20
## Top of the labour-level range (0 "off" .. 4); also the "no bonus" level.
const LABOUR_LEVEL_MAX := 4

var queue: QueueType
## Content bundle for ActorTable.get_component() (ADR 012).
var _content
var _waiting: Array[Dictionary] = []
var _waiting_index := WaitingIndexType.new() # B1: finds a _waiting entry by binary search
var _next_ordinal: int = 0
var _cursors: Dictionary = {}
var _pending: Dictionary = {}
var _assignments: Dictionary = {}
var _metrics: Dictionary = {}
## colonist_id -> true once its one route resume this tick is spent (ADR 004); shared by
## reference with ToilExecutor (ADR 013).
var _route_budget: Dictionary = {}
## job_id -> its waiting entry, captured when first chosen, so a suspend restores the exact
## aging position. Erased only on finish().
var _activated_entries: Dictionary = {}
## Callable(worker_id) -> bool: may this worker take orders (ADR 014)? An early filter in the
## scan, then authoritative before every reserve step. Unset fails open.
var _may_be_ordered: Callable = Callable()
## Callable(worker_id) -> bool, checked before (never after) a reserve step acquires a key,
## so a refused worker never holds a reservation even transiently. Unset fails open.
var _may_reserve: Callable = Callable()
## {"job_id","worker"} pairs refused since the last take_refused_reservations(); the worker
## travels with the job because _assignments no longer names it.
var _refused_reservations: Array[Dictionary] = []
## Callable(worker_id, target) -> bool: the target-aware reservation gate for an autonomous
## entry (ADR 014 Amendment); unset falls back to _may_reserve.
var _may_reserve_autonomous: Callable = Callable()
## Callable(worker_id, tile) -> cost: an autonomous entry's route search runs under its own
## faction's door rules; unset falls back to tick()'s `passable`.
var _passable_autonomous: Callable = Callable()

func _init(random_source: RandomNumberGenerator, content_registry) -> void:
	queue = QueueType.new(random_source)
	_content = content_registry

func _labour_table(colonist: Dictionary) -> Dictionary:
	var worker_component: Variant = ActorTableType.get_component(colonist, "worker", _content)
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

## _may_reserve, or the target-aware autonomous gate for an autonomous entry. Never skipped.
func _pair_may_reserve(worker: String, entry: Dictionary) -> bool:
	if _is_autonomous(entry) and _may_reserve_autonomous.is_valid():
		return bool(_may_reserve_autonomous.call(worker, entry["target"]))
	return _worker_may_reserve(worker)

func _is_autonomous(entry: Dictionary) -> bool:
	return bool(entry.get("autonomous", false))

func _passable_for(worker: String, entry: Dictionary, passable: Callable) -> Callable:
	if _is_autonomous(entry) and _passable_autonomous.is_valid():
		return func(tile: Vector2i): return _passable_autonomous.call(worker, tile)
	return passable

## Cleared on read so the caller resolves each refusal exactly once.
func take_refused_reservations() -> Array[Dictionary]:
	var refused := _refused_reservations
	_refused_reservations = []
	return refused

## restrict_to: only that worker's scan may propose the entry (a committed need or a
## need-interrupted job); tick()'s committed_needs, not this flag, makes a need precede work.
## autonomous entries skip only the order-eligibility gate; the flag is stored only when true
## so ordinary entries and saves keep their shape.
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
		var index := _waiting.bsearch_custom(entry, _entry_before, true) # = the old scan's index
		_waiting.insert(index, entry)
		_waiting_index.record(entry)
		for worker in _cursors:
			if int(_cursors[worker]) > index:
				_cursors[worker] += 1
	return result

## An incident actor's own job (ADR 014 Amendment): restricted to `worker` and exempt only
## from _worker_may_be_ordered(); every other gate, the reservation check and routing apply.
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

## One global pair pool, then disjoint routing and activation phases (ADR 004).
## all_colonists is the full roster for labour_disabled; committed_needs (worker -> job id)
## means nothing else is proposed to that worker; region_check(a, b) unset fails open.
func tick(tick_number: int, colonists: Array[Dictionary], passable: Callable,
		bounds_min: Vector2i, bounds_max: Vector2i,
		get_job_labour: Callable = Callable(), get_calendar_boost: Callable = Callable(),
		all_colonists: Array[Dictionary] = [], committed_needs: Dictionary = {},
		region_check: Callable = Callable()) -> void:
	_metrics = {}
	_route_budget.clear()
	var workers: Array[Dictionary] = colonists.duplicate() # read-only (A5): no deep copy
	workers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	var proposals: Array[Dictionary] = []
	var selected: Array[String] = []
	var reachable: Dictionary = {}
	# A committed need discards the worker's other pending route batch, not its own.
	for worker in committed_needs:
		if not _pending_matches_job(worker, String(committed_needs[worker])):
			_pending.erase(worker)
	var claimed_jobs: Dictionary = {}
	for worker in _pending:
		for entry in _pending[worker]["candidates"]:
			claimed_jobs[entry["id"]] = true
	# job_id -> kind for _priority_bracket(), only when labour scoring is wired.
	var job_kinds: Dictionary = {}
	if get_job_labour.is_valid():
		job_kinds = queue.get_job_kinds()
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
			# Early filter only: the "ready" loop revalidates eligibility for every proposal.
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
	# One slot per worker before any second slot; real route distances decide activation.
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
			# Region-disconnected: treated like a search that found nothing.
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
		# Gates revalidated here, before advance_selection() reserves: a worker's faction may
		# change during a multi-tick search. Autonomous entries skip only _may_be_ordered.
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
		if queue.view_job(job_id)["status"] == "active":
			var path: Array = pair.get("path", [])
			# Stop adjacent to an impassable target (a tree); trimmed after scoring.
			if path.size() > 1 and not _is_passable_value(_passable_for(pair["worker"], pair["entry"], passable).call(pair["entry"]["target"])):
				path = path.slice(0, path.size() - 1)
			_assignments[pair["worker"]] = {"job_id": job_id,
				"started_tick": tick_number, "travel_ticks": pair["travel"], "path": path}
			if not _activated_entries.has(job_id):
				_activated_entries[job_id] = pair["entry"].duplicate(true)
			_remove_waiting(job_id)
	for worker in finished_workers:
		_pending.erase(worker)

## Proposes worker's committed need job by direct lookup, never a scored scan competitor.
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
	var index := _waiting_index.index_of(_waiting, job_id, _entry_before)
	return _waiting[index] if index >= 0 else {}

func waiting_restrict_to(job_id: String) -> String:
	return String(_find_waiting_entry(job_id).get("restrict_to", ""))

func _pending_matches_job(worker: String, job_id: String) -> bool:
	if not _pending.has(worker):
		return false
	for entry in _pending[worker]["candidates"]:
		if entry["id"] == job_id:
			return true
	return false

func _score_candidate(worker: String, colonist: Dictionary, entry: Dictionary, job_kinds: Dictionary,
		labour_table: Dictionary, tick_number: int, get_job_labour: Callable, get_calendar_boost: Callable) -> Dictionary:
	var bracket := _priority_bracket(entry, job_kinds, labour_table, tick_number, get_job_labour, get_calendar_boost)
	var start := Vector2i(colonist["x"], colonist["y"])
	var delta: Vector2i = entry["target"] - start
	var ticks_waiting := tick_number - int(entry["submitted_tick"])
	return {"worker": worker, "entry": entry, "start": start,
		"score": PRIORITY_WEIGHT * bracket + ticks_waiting - mini(MAX_TRAVEL_PENALTY, absi(delta.x) + absi(delta.y))}

## Marks queued jobs labour_disabled when no colonist in `colony` has the labour on.
## `colony` must be the full roster, not tick()'s filtered list.
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
	_waiting_index.apply_labour_disabled(queue, _waiting, disabled_labours, job_kinds, get_job_labour, _entry_before)

## Frees worker's assignment without touching the job record (colonist-ai.md 3.6).
func clear_assignment(worker: String) -> void:
	_assignments.erase(worker)

## Erases a removed worker's pending routing batch so its claimed jobs return to the pool.
func retire_worker(worker: String) -> void:
	_pending.erase(worker)

## Restores an assignment directly (resuming an interrupted job, not a new pick).
func set_assignment(worker: String, job_id: String) -> void:
	_assignments[worker] = {"job_id": job_id, "started_tick": 0, "travel_ticks": 0, "path": []}

## Need interrupt (ADR 009): suspends the job and reinserts its entry at its exact aging
## position, pinned to `worker`. No-op when job_id is not chosen or already waiting.
func suspend_assignment(worker: String, job_id: String) -> void:
	clear_assignment(worker)
	queue.suspend(job_id)
	ToolMatchingType.reinsert_activated_entry(_waiting, _cursors, _activated_entries, job_id, worker, _entry_before)

## Requeue for a non-need failure: same aging-preserving reinsert, original restrict_to kept.
func requeue_assignment(worker: String, job_id: String) -> void:
	clear_assignment(worker)
	queue.suspend(job_id)
	ToolMatchingType.reinsert_activated_entry(_waiting, _cursors, _activated_entries, job_id, "", _entry_before)

## Reverses suspend_assignment(); a no-op (job stays queued) when another job took the target.
func resume_assignment(worker: String, job_id: String) -> void:
	# Same gates as the "ready" loop, checked before reactivate() re-acquires the reservation.
	var entry: Dictionary = _activated_entries.get(job_id, {})
	if not (_is_autonomous(entry) or _worker_may_be_ordered(worker)) or not _pair_may_reserve(worker, entry):
		_refused_reservations.append({"job_id": job_id, "worker": worker})
		return
	if not queue.reactivate(job_id):
		return
	_remove_waiting(job_id)
	set_assignment(worker, job_id)

## The restrict_to job_id was submitted with ("" if never activated), so
## WorldState._resubmit_unreachable_job() keeps an order's assignee.
func restrict_to_for(job_id: String) -> String:
	return String(_activated_entries.get(job_id, {}).get("restrict_to", ""))

## Activated-entry snapshots, persisted by state_codec.gd.
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

## Pending route batches; "route" is the in-flight search's snapshot(), or null.
func get_pending() -> Dictionary:
	var pending: Dictionary = {}
	for worker in _pending:
		var request: Dictionary = _pending[worker].duplicate(true)
		var route: RouteType = _pending[worker]["route"]
		request["route"] = route.snapshot() if route != null else null
		pending[worker] = request
	return pending

## Restores continuation state from a save; routes rebuild through _passable_for() like
## tick(), so an autonomous entry keeps its own faction's passability. region_check as in tick().
func restore_scheduling(state: Dictionary, is_passable: Callable, bounds_min: Vector2i, bounds_max: Vector2i, region_check: Callable = Callable()) -> void:
	_waiting = state["waiting"].duplicate(true)
	_waiting_index.restore(_waiting, state.get("activated_entries", {}))
	_next_ordinal = state["next_ordinal"]
	_cursors = state["cursors"].duplicate()
	_assignments = state["assignments"].duplicate(true)
	_activated_entries = state.get("activated_entries", {}).duplicate(true)
	_metrics = {}
	_pending = {}
	for worker in state["pending"]:
		var saved: Dictionary = state["pending"][worker]
		var request: Dictionary = saved.duplicate(true)
		var route_state: Variant = saved["route"]
		if route_state == null:
			request["route"] = null
		else:
			var entry: Dictionary = request["candidates"][request["cursor"]]
			var route: RouteType = RouteType.new(route_state["start"], route_state["start"], _routable(entry["target"], _passable_for(worker, entry, is_passable)), bounds_min, bounds_max)
			route.restore(route_state)
			request["route"] = route
		# Found paths are not saved; RouteSearch is deterministic, so re-running rebuilds them.
		var restored_found: Array = []
		for pair in request["found"]:
			var restored_pair: Dictionary = pair.duplicate(true)
			restored_pair["path"] = _resolve_path(request["start"], pair["entry"]["target"], _passable_for(worker, pair["entry"], is_passable), bounds_min, bounds_max, region_check)
			restored_found.append(restored_pair)
		request["found"] = restored_found
		_pending[worker] = request

## For state_hash(), not saves. "path" is omitted: it is re-derivable (deterministic search).
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

## Lets a search end on an impassable target tile (a tree), costed 1.
func _routable(target: Vector2i, cost_fn: Callable) -> Callable:
	return func(tile: Vector2i):
		if tile == target:
			var underlying: Variant = cost_fn.call(tile)
			return underlying if _is_passable_value(underlying) else 1
		return cost_fn.call(tile)

func _is_passable_value(value) -> bool:
	if typeof(value) == TYPE_BOOL:
		return value
	return float(value) > 0.0

## Hard labour filter, kept apart from _priority_bracket(): a negative bracket still scores.
func _is_labour_enabled(entry: Dictionary, job_kinds: Dictionary, labour_table: Dictionary, get_job_labour: Callable) -> bool:
	if not get_job_labour.is_valid():
		return true
	var labour := String(get_job_labour.call(String(job_kinds.get(entry["id"], ""))))
	return WorkerType.labour_level(labour_table, labour, LABOUR_LEVEL_MAX) > 0

## colonist-ai.md 3.2: order_priority + calendar_boost + 4 - labour_level, capped at
## MAX_PRIORITY_BRACKET; without get_job_labour it is ADR 004's plain priority.
func _priority_bracket(entry: Dictionary, job_kinds: Dictionary, labour_table: Dictionary,
		tick_number: int, get_job_labour: Callable, get_calendar_boost: Callable) -> int:
	var order_priority := (int(entry["base"]) + int(entry["submitted_tick"])) / PRIORITY_WEIGHT
	if not get_job_labour.is_valid():
		return order_priority
	var labour := String(get_job_labour.call(String(job_kinds.get(entry["id"], ""))))
	var labour_level := WorkerType.labour_level(labour_table, labour, LABOUR_LEVEL_MAX)
	var calendar_boost := int(get_calendar_boost.call(labour, tick_number)) if get_calendar_boost.is_valid() else 0
	return mini(order_priority + calendar_boost + LABOUR_LEVEL_MAX - labour_level, MAX_PRIORITY_BRACKET)

## Unbounded re-run of a found search; region_check (ADR 054) refuses a target cut off since.
func _resolve_path(start: Vector2i, target: Vector2i, passable: Callable, bounds_min: Vector2i, bounds_max: Vector2i, region_check: Callable) -> Array:
	var route := RouteType.new(start, target, _routable(target, passable), bounds_min, bounds_max, region_check)
	while not route.is_terminal():
		route.resume()
	return route.get_path()

func _remove_waiting(job_id: String) -> void:
	var index := _waiting_index.index_of(_waiting, job_id, _entry_before)
	if index < 0:
		return
	_waiting.remove_at(index)
	for worker in _cursors:
		if int(_cursors[worker]) > index:
			_cursors[worker] -= 1

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
