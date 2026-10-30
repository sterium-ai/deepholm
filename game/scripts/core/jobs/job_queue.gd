class_name JobQueue
extends RefCounted

## Deterministic job queue: lifecycle, activation gates and reservations. See README.md.
## Reservations exist only while their job is active; terminal jobs retire to JobHistory.
const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")
const JobIndexType = preload("res://scripts/core/jobs/job_index.gd")
const JobEventLogType = preload("res://scripts/core/jobs/job_event_log.gd")
const JobHistoryType = preload("res://scripts/core/jobs/job_history.gd")

enum Priority { LOW, NORMAL, HIGH }

const BLOCKED_TARGET_RESERVED := "blocked_target_reserved"
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"
const BLOCKED_REACHABILITY_UNAVAILABLE := "blocked_reachability_unavailable"
const BLOCKED_ITEM_RESERVED := "blocked_item_reserved"
const BLOCKED_DESTINATION_FULL := "blocked_destination_full"
const BLOCKED_LABOUR_DISABLED := "labour_disabled"
const BLOCKED_NO_TOOL := "blocked_no_tool"
const SYSTEM_PRIORITY := 50
const ITEM_KEY_PREFIX := "item:"
const HAUL_KIND := "haul"
## site_fetch reserves only its source item; site_work reserves nothing. A site's footprint
## tiles are reserved to "site:<id>" by ConstructionSystem, never to a job (ADR 040).
const SITE_FETCH_KIND := "site_fetch"
const SITE_WORK_KIND := "site_work"

var _random: RandomNumberGenerator
var _can_reach: Callable
var _tick: int = 0
var _next_id: int = 1
var _sequence: int = 0
## Live (queued/active) jobs only: _finish() retires a job to _history (A5).
var _jobs: Array[Dictionary] = []
var _index := JobIndexType.new(_jobs, BLOCKED_LABOUR_DISABLED)
var _history := JobHistoryType.new()
var _table: ReservationTableType = ReservationTableType.new()
var _events := JobEventLogType.new()
## haul-only: item_id -> a free destination cell, or null (colonist-ai.md 3.4).
var _find_haul_destination: Callable = Callable()
## job_id -> {"reason","remedy"} consumed once by fail()/invalidate(); never persisted.
var _pending_fail_reasons: Dictionary = {}
## Haul destination-search backoff (colonist-ai.md 3.3), doubling up to the cap. It gates
## only the retry, never the job's aging position in the fair queue.
var _haul_retry_base_ticks: int = 10
var _haul_retry_cap_ticks: int = 40
## Tool gate callables (ADR 013); logic in ToolMatching.gate_check()/gate_force_backoff().
var _tool_requirement_of: Callable = Callable()
var _tool_available: Callable = Callable()
## job_id -> extra ReservationTable keys (e.g. a rescue's "trapped:<victim>") held in
## lockstep with the target key: acquired on activation/reactivate, never while queued.
var _extra_keys_for_job: Callable = Callable()

## The caller owns/seeds the generator; this queue does not consume random draws.
## can_reach(target: Vector2i) -> bool must be deterministic and non-mutating.
func _init(random_source: RandomNumberGenerator, can_reach: Callable) -> void:
	_random = random_source
	_can_reach = can_reach

func set_haul_backoff(base_ticks: int, cap_ticks: int) -> void:
	_haul_retry_base_ticks = base_ticks
	_haul_retry_cap_ticks = cap_ticks

func set_tool_requirement(tool_requirement_of: Callable, tool_available: Callable) -> void:
	_tool_requirement_of = tool_requirement_of
	_tool_available = tool_available

func set_extra_reservation_keys(extra_keys_for_job: Callable) -> void:
	_extra_keys_for_job = extra_keys_for_job

func _extra_keys(job_id: String) -> Array[String]:
	if not _extra_keys_for_job.is_valid():
		return []
	return _extra_keys_for_job.call(job_id) as Array[String]

## "" when no key is owned by another job, else the first blocking owner.
func _extra_keys_conflict(keys: Array[String], job_id: String) -> String:
	for key in keys:
		var owner: String = _table.owner(key)
		if not owner.is_empty() and owner != job_id:
			return owner
	return ""

## Pure check shared with CommandChecks' preview, which must not emit events or advance
## the sequence. {} when allowed, else submit_dig()'s rejection. Never mutates.
static func check_submission(target: Vector2i, priority: int) -> Dictionary:
	if priority not in [Priority.LOW, Priority.NORMAL, Priority.HIGH]:
		return {"reason": "invalid_priority", "remedy": "choose_supported_priority"}
	if target.x < 0 or target.y < 0:
		return {"reason": "invalid_target", "remedy": "choose_valid_target"}
	return {}

func submit_dig(target: Vector2i, priority: int = Priority.NORMAL, kind: String = "dig") -> Dictionary:
	var submission_check := check_submission(target, priority)
	if not submission_check.is_empty():
		return _reject("", submission_check["reason"], submission_check["remedy"])
	var job_id := "job_%d" % _next_id
	_next_id += 1
	var job := {
		"id": job_id, "kind": kind, "status": "queued",
		"priority": priority, "target": target,
		"reason": "", "remedy": "", "blocking_job_id": "",
		# haul-only fields (colonist-ai.md 3.3/3.4), defaulted for every kind.
		"item_id": "", "cell": null, "backoff_ticks": 0, "retry_at": 0,
		# site_fetch/site_work: the site's origin tile (attach_site()).
		"site": null,
	}
	_jobs.append(job)
	_index.add(_jobs, job)
	_emit("job_queued", job_id, {})
	return {"ok": true, "job_id": job_id}

## Attaches a queued haul job's ground item. No-op false unless the job is queued, so a
## stale caller cannot change an item already captured by activation.
func attach_item(job_id: String, item_id: String) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return false
	job["item_id"] = item_id
	return true

## Records the site origin of a queued site_fetch/site_work job (bookkeeping only; the
## site already reserves its footprint). Same no-op-false guard as attach_item().
func attach_site(job_id: String, site: Vector2i) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return false
	job["site"] = site
	return true

## Moves an active site_fetch job's current source (item_id and target together) after the
## caller (ToilBindings/ConstructionSystem) has reserved the new item. The old source's
## reservation stays with the job until release_all(). No-op false otherwise.
func retarget_site_fetch_source(job_id: String, item_id: String, target: Vector2i) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active" or String(job["kind"]) != SITE_FETCH_KIND:
		return false
	job["item_id"] = item_id
	job["target"] = target
	return true

## Sets "cell" = "site": the job stops fetching and delivers what its hands hold
## (ToilBindings._toil_is_first_leg() reads it). No-op false unless active site_fetch.
func mark_site_fetch_delivering(job_id: String) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active" or String(job["kind"]) != SITE_FETCH_KIND:
		return false
	job["cell"] = job["site"]
	return true

## Chains a delivering site_fetch job onto another site: "site" and "cell" move together.
## Only a delivering-leg transition (cell != null); no new persisted field.
func retarget_site_fetch_site(job_id: String, site: Vector2i) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active" or String(job["kind"]) != SITE_FETCH_KIND:
		return false
	if job["cell"] == null:
		return false
	job["site"] = site
	job["cell"] = site
	return true

## item_id -> Vector2i free cell, or null when none free (colonist-ai.md 3.4).
func set_haul_destination_finder(finder: Callable) -> void:
	_find_haul_destination = finder

## The marker lives in blocking_job_id, not item_id (ADR 013, "Drop-leg identity marker").
func set_active_item_marker(job_id: String, item_id: String) -> void:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active":
		return
	job["blocking_job_id"] = item_id

## Reads the live record, not a caller-held duplicate, so a same-tick write is visible immediately.
func get_active_item_marker(job_id: String) -> String:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active":
		return ""
	return String(job["blocking_job_id"])

## Lets a caller report a typed reason (e.g. blocked_destination_gone) through the next
## fail()/invalidate() of job_id instead of a new termination API.
func set_pending_fail_reason(job_id: String, reason: String, remedy: String) -> void:
	_pending_fail_reasons[job_id] = {"reason": reason, "remedy": remedy}

## Non-terminal labour_disabled block for a queued job, driven by GlobalAssignment's
## per-tick scan (colonist-ai.md 3.2). Never resets a haul's retry_at backoff.
func set_labour_disabled(job_id: String, disabled: bool) -> void:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return
	if disabled:
		_block(job, BLOCKED_LABOUR_DISABLED, "enable_labour_for_a_colonist")
	elif job["reason"] == BLOCKED_LABOUR_DISABLED:
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
		_set_reason(job, "", "")

## One explicit tick evaluates every queued job, highest priority first, FIFO
## within a priority. Blocked jobs remain queued and are retried on every tick.
func tick() -> void:
	_tick += 1
	for priority in [Priority.HIGH, Priority.NORMAL, Priority.LOW]:
		for job in _jobs:
			if job["status"] != "queued" or job["priority"] != priority:
				continue
			if String(job["kind"]) == HAUL_KIND:
				_tick_haul(job)
				continue
			if String(job["kind"]) == SITE_FETCH_KIND:
				_tick_site_fetch(job)
				continue
			if String(job["kind"]) == SITE_WORK_KIND:
				_tick_site_work(job)
				continue
			if ToolMatchingType.gate_backed_off(job, _tick, _tool_requirement_of): continue
			var target: Vector2i = job["target"]
			var owner: String = _table.owner(_target_key(target))
			if not owner.is_empty() and owner != job["id"]:
				_block(job, BLOCKED_TARGET_RESERVED, "wait_for_target_release", owner)
				continue
			if _blocked_unreachable(job, target):
				continue
			if not _tool_requirement_satisfied(job):
				continue
			var extra_keys := _extra_keys(job["id"])
			var extra_blocked_by := _extra_keys_conflict(extra_keys, job["id"])
			if not extra_blocked_by.is_empty():
				_block(job, BLOCKED_TARGET_RESERVED, "wait_for_target_release", extra_blocked_by)
				continue
			if not String(job["reason"]).is_empty():
				_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
			_set_reason(job, "", "")
			_table.acquire(_target_key(target), job["id"])
			for key in extra_keys:
				_table.acquire(key, job["id"])
			job["status"] = "active"
			_emit("reservation_acquired", job["id"], {"target": target})
			_emit("job_active", job["id"], {})

## Haul activation (colonist-ai.md 3.3/3.4): reserves the item and a free destination cell
## together before travel; no free cell blocks with an explicit doubling backoff.
func _tick_haul(job: Dictionary) -> void:
		# Backed off: return before the reachability check, whatever reason is shown; a
		# reachability call here would misreport the job unreachable and starve it.
	if _tick < int(job["retry_at"]):
		return
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var owner: String = _table.owner(item_key)
	if not owner.is_empty() and owner != job["id"]:
		_block(job, BLOCKED_ITEM_RESERVED, "wait_for_item_release", owner)
		return
	if _blocked_unreachable(job, job["target"]):
		return
	var cell: Variant = _find_haul_destination.call(String(job["item_id"])) if _find_haul_destination.is_valid() else null
	_emit("haul_destination_attempt", job["id"], {"attempt_tick": _tick})
	if cell == null:
		var backoff: int = int(job["backoff_ticks"])
		backoff = _haul_retry_base_ticks if backoff == 0 else mini(backoff * 2, _haul_retry_cap_ticks)
		job["backoff_ticks"] = backoff
		job["retry_at"] = _tick + backoff
		_block(job, BLOCKED_DESTINATION_FULL, "wait_for_free_destination")
		return
	if not _table.acquire(item_key, job["id"]):
		_block(job, BLOCKED_ITEM_RESERVED, "wait_for_item_release", _table.owner(item_key))
		return
	var cell_key := _cell_key(cell)
	if not _table.acquire(cell_key, job["id"]):
		_table.release(item_key, job["id"])
		_block(job, BLOCKED_DESTINATION_FULL, "wait_for_free_destination")
		return
	if not String(job["reason"]).is_empty():
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
	_set_reason(job, "", "")
	job["cell"] = cell
	job["backoff_ticks"] = 0
	job["retry_at"] = 0
	job["status"] = "active"
	_emit("reservation_acquired", job["id"], {"target": job["item_id"], "key": item_key})
	_emit("reservation_acquired", job["id"], {"target": cell, "key": cell_key})
	_emit("job_active", job["id"], {})

## site_fetch activation: reserves only the source item (see SITE_FETCH_KIND).
func _tick_site_fetch(job: Dictionary) -> void:
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var item_owner: String = _table.owner(item_key)
	if not item_owner.is_empty() and item_owner != job["id"]:
		_block(job, BLOCKED_ITEM_RESERVED, "wait_for_item_release", item_owner)
		return
	if _blocked_unreachable(job, job["target"]):
		return
	if not String(job["reason"]).is_empty():
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
	_set_reason(job, "", "")
	_table.acquire(item_key, job["id"])
	job["status"] = "active"
	_emit("reservation_acquired", job["id"], {"target": job["item_id"], "key": item_key})
	_emit("job_active", job["id"], {})

## site_work activation: reachability only; ConstructionGiver caps builders per site.
func _tick_site_work(job: Dictionary) -> void:
	if _blocked_unreachable(job, job["target"]):
		return
	if not String(job["reason"]).is_empty():
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
	_set_reason(job, "", "")
	job["status"] = "active"
	_emit("job_active", job["id"], {})

func _blocked_unreachable(job: Dictionary, target: Variant) -> bool:
	var reachable: Variant = _can_reach.call(target) if _can_reach.is_valid() else null
	if not reachable is bool:
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return true
	if not reachable:
		_block(job, BLOCKED_TARGET_UNREACHABLE, "restore_target_access")
	return not reachable

## Gates activation on a matching free tool existing anywhere (ADR 013).
func _tool_requirement_satisfied(job: Dictionary) -> bool:
	return ToolMatchingType.gate_check(job, _tick, _tool_requirement_of, _tool_available, _block_no_tool)

## Applies the needs_tool backoff once fetch_tool finds no candidate
## (ToilBindings._toil_on_no_tool_found()). No-op unless queued.
func block_no_tool(job_id: String) -> void:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return
	ToolMatchingType.gate_force_backoff(job, _tick, _tool_requirement_of, _block_no_tool)

func _block_no_tool(job: Dictionary, remedy: String) -> void:
	_index.watch(job) # every ToolMatching retry_at backoff ends here
	_block(job, BLOCKED_NO_TOOL, remedy)

## Need interrupt (ADR 009): releases the job's reservations and requeues it unchanged, so
## another job may claim the target meanwhile. Not terminal; rejects unless active.
func suspend(job_id: String) -> Dictionary:
	var job := _find_job(job_id)
	if job.is_empty():
		return _reject(job_id, "unknown_job", "choose_existing_job")
	if job["status"] != "active":
		return _reject(job_id, "job_not_active", "wait_for_activation")
	var target: Vector2i = job["target"]
	for key in _table.release_all(job_id):
		_emit("reservation_released", job_id, {"target": target, "key": key, "reason": "need_interrupt"})
	job["status"] = "queued"
	_set_reason(job, "", "")
	return {"ok": true, "job_id": job_id}

## Reverses suspend() by ownership alone (reachability was proven at activation). Returns
## false and leaves the job queued if another job claimed a key; a haul re-takes both keys or neither.
func reactivate(job_id: String) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return false
	if String(job["kind"]) == HAUL_KIND:
		return _reactivate_haul(job)
	if String(job["kind"]) == SITE_FETCH_KIND:
		return _reactivate_site_fetch(job)
	if String(job["kind"]) == SITE_WORK_KIND:
		job["status"] = "active"
		_set_reason(job, "", "")
		_emit("job_active", job_id, {})
		return true
	var target: Vector2i = job["target"]
	var owner: String = _table.owner(_target_key(target))
	if not owner.is_empty() and owner != job_id:
		return false
	var extra_keys := _extra_keys(job_id)
	if not _extra_keys_conflict(extra_keys, job_id).is_empty():
		return false
	_table.acquire(_target_key(target), job_id)
	for key in extra_keys:
		_table.acquire(key, job_id)
	job["status"] = "active"
	_set_reason(job, "", "")
	_emit("reservation_acquired", job_id, {"target": target})
	_emit("job_active", job_id, {})
	return true

func _reactivate_haul(job: Dictionary) -> bool:
	var job_id: String = job["id"]
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var item_owner: String = _table.owner(item_key)
	if not item_owner.is_empty() and item_owner != job_id:
		return false
	var cell_key := _cell_key(job["cell"])
	var cell_owner: String = _table.owner(cell_key)
	if not cell_owner.is_empty() and cell_owner != job_id:
		return false
	_table.acquire(item_key, job_id)
	_table.acquire(cell_key, job_id)
	job["status"] = "active"
	_set_reason(job, "", "")
	_emit("reservation_acquired", job_id, {"target": job["item_id"], "key": item_key})
	_emit("reservation_acquired", job_id, {"target": job["cell"], "key": cell_key})
	_emit("job_active", job_id, {})
	return true

func _reactivate_site_fetch(job: Dictionary) -> bool:
	var job_id: String = job["id"]
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var item_owner: String = _table.owner(item_key)
	if not item_owner.is_empty() and item_owner != job_id:
		return false
	_table.acquire(item_key, job_id)
	job["status"] = "active"
	_set_reason(job, "", "")
	_emit("reservation_acquired", job_id, {"target": job["item_id"], "key": item_key})
	_emit("job_active", job_id, {})
	return true

func cancel(job_id: String) -> Dictionary:
	return _finish(job_id, "cancelled", "cancelled_by_command", "resubmit_order")

func fail(job_id: String) -> Dictionary:
	var override := _take_pending_fail_reason(job_id)
	if not override.is_empty():
		return _finish(job_id, "failed", override["reason"], override["remedy"])
	return _finish(job_id, "failed", "job_execution_failed", "inspect_target_and_resubmit")

## Invalidation is a terminal failure, not a separate persisted status.
func invalidate(job_id: String) -> Dictionary:
	var override := _take_pending_fail_reason(job_id)
	if not override.is_empty():
		return _finish(job_id, "failed", override["reason"], override["remedy"])
	return _finish(job_id, "failed", "target_invalidated", "choose_valid_target")

func _take_pending_fail_reason(job_id: String) -> Dictionary:
	if not _pending_fail_reasons.has(job_id):
		return {}
	var override: Dictionary = _pending_fail_reasons[job_id]
	_pending_fail_reasons.erase(job_id)
	return override

func complete(job_id: String) -> Dictionary:
	return _finish(job_id, "completed", "", "", true)

func get_tick() -> int:
	return _tick

## Counters exposed for save/restore (state_codec.gd); only ever incremented.
func get_next_id() -> int:
	return _next_id

func get_sequence() -> int:
	return _sequence

## A copy of the live or retained (job_history.gd) job, or {}.
func get_job(job_id: String) -> Dictionary:
	return view_job(job_id).duplicate(true)

## Copies of every live job and, unless include_retired is false, every
## retained one, in submission order. Saves and state_hash() read live only.
func get_jobs(include_retired: bool = true) -> Array[Dictionary]:
	return _history.merged(_jobs, _index.position_of, [], include_retired)

## get_jobs(include_retired) filtered to `kinds`, costing only the jobs returned.
func get_jobs_of_kinds(kinds: Array, include_retired: bool = true) -> Array[Dictionary]:
	return _history.merged(_index.of_kinds(_jobs, kinds), _index.position_of, kinds, include_retired)

## Read-only views (A5): view_job() is get_job() without the copy; never mutate the result.
func view_job(job_id: String) -> Dictionary:
	var job := _find_job(job_id)
	return job if not job.is_empty() else _history.find(job_id)

func view_jobs_of_kinds(kinds: Array) -> Array[Dictionary]:
	return _index.of_kinds(_jobs, kinds)

## job id -> kind for every live job; a live view callers must never mutate.
func get_job_kinds() -> Dictionary:
	return _index.kinds_of(_jobs)

## The lookup indexes themselves (job_index.gd), for read-only queries.
func get_index() -> JobIndexType:
	return _index

## Vector2i target -> job id for every active job, plus every queued job still in a
## retry_at backoff (haul or needs_tool), so its aging score (ADR 004) cannot keep
## winning a route-search slot while backed off.
func get_reservations() -> Dictionary:
	return _index.reservations(_jobs, _tick)

## The shared ReservationTable itself (by reference): keys acquired through it are freed
## by this queue's release_all() on the job's terminal transition.
func get_reservation_table() -> ReservationTableType:
	return _table

func get_events() -> Array[Dictionary]:
	return _events.get_all()

## The events get_events() lists whose sequence is above after_sequence.
func get_events_after(after_sequence: int) -> Array[Dictionary]:
	return _events.get_after(after_sequence)

## The event log itself, by reference (A6, job_event_log.gd).
func get_event_log() -> JobEventLogType:
	return _events

## Overwrites jobs and counters from a save. Reservations are re-derived from active jobs;
## the event log is not restored. Terminal jobs in `jobs` retire to the history.
func restore(jobs: Array[Dictionary], tick_value: int, next_id: int, sequence: int) -> void:
	_jobs = jobs
	_index = JobIndexType.new(_jobs, BLOCKED_LABOUR_DISABLED)
	_history = JobHistoryType.new()
	for job: Dictionary in jobs.duplicate():
		if job["status"] not in ["queued", "active"]:
			_history.add(job, _index.remove(job))
	_tick = tick_value
	_next_id = next_id
	_sequence = sequence
	_table = ReservationTableType.new()
	_pending_fail_reasons = {}
	for job in _jobs:
		if job["status"] != "active":
			continue
		if String(job["kind"]) == HAUL_KIND:
			_table.acquire(ITEM_KEY_PREFIX + String(job["item_id"]), job["id"])
			var cell: Variant = job.get("cell")
			if cell != null:
				_table.acquire(_cell_key(cell), job["id"])
		elif String(job["kind"]) == SITE_FETCH_KIND:
			_table.acquire(ITEM_KEY_PREFIX + String(job["item_id"]), job["id"])
		elif String(job["kind"]) == SITE_WORK_KIND:
			pass # no reservation of its own -- see _tick_site_work().
		else:
			_table.acquire(_target_key(job["target"]), job["id"])
			for key in _extra_keys(job["id"]):
				_table.acquire(key, job["id"])
	_events.reset(_sequence)

## Tile keys are namespaced so "item:"/"cell:" keys never collide with them.
func _target_key(target: Vector2i) -> String:
	return TileGrid.target_key(target.x, target.y)

## Same format as WorldState._cell_key(): is_cell_free() must see haul cell reservations.
func _cell_key(cell: Vector2i) -> String:
	return TileGrid.cell_key(cell.x, cell.y)

func _find_job(job_id: String) -> Dictionary:
	return _index.find(_jobs, job_id)

## Pure check shared with CommandChecks.check_terminal_job_command() so the two never
## drift. {} when job_id may finish, else _finish()'s rejection. Never mutates.
func check_terminal(job_id: String, active_only: bool = false) -> Dictionary:
	var job := view_job(job_id)
	if job.is_empty():
		return {"reason": "unknown_job", "remedy": "choose_existing_job"}
	if job["status"] not in ["queued", "active"]:
		return {"reason": "job_already_terminal", "remedy": "submit_new_order"}
	if active_only and job["status"] != "active":
		return {"reason": "job_not_active", "remedy": "wait_for_activation"}
	return {}

func _finish(job_id: String, status: String, reason: String, remedy: String, active_only: bool = false) -> Dictionary:
	var terminal_check := check_terminal(job_id, active_only)
	if not terminal_check.is_empty():
		return _reject(job_id, terminal_check["reason"], terminal_check["remedy"])
	var job := _find_job(job_id)
	var target: Vector2i = job["target"]
	for key in _table.release_all(job_id):
		_emit("reservation_released", job_id, {"target": target, "key": key, "reason": reason})
	job["status"] = status
	_set_reason(job, reason, remedy)
	_emit("job_" + status, job_id, {"reason": reason, "remedy": remedy})
	_history.add(job, _index.remove(job))
	return {"ok": true, "job_id": job_id}

func _block(job: Dictionary, reason: String, remedy: String, owner: String = "") -> void:
	if job["reason"] == reason and job["remedy"] == remedy and job["blocking_job_id"] == owner:
		return
	_set_reason(job, reason, remedy, owner)
	_emit("job_blocked", job["id"], {"reason": reason, "remedy": remedy, "blocking_job_id": owner})

func _set_reason(job: Dictionary, reason: String, remedy: String, owner: String = "") -> void:
	job["reason"] = reason
	job["remedy"] = remedy
	job["blocking_job_id"] = owner
	_index.note_reason(job)

func _reject(job_id: String, reason: String, remedy: String) -> Dictionary:
	var rejection := {"job_id": job_id, "reason": reason, "remedy": remedy, "tick": _tick}
	_emit("job_rejected", job_id, rejection)
	return {"ok": false, "rejection": rejection.duplicate(true)}

func _emit(event_type: String, job_id: String, data: Dictionary) -> void:
	_events.append({
		"type": event_type, "tick": _tick, "system_priority": SYSTEM_PRIORITY,
		"entity_id": job_id, "sequence": _sequence, "data": data.duplicate(true),
	})
	_sequence += 1
	_index.on_event(event_type, _find_job(job_id))
