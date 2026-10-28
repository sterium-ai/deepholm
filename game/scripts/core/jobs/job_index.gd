extends RefCounted

## JobQueue's lookup indexes over its job list (B1), so a read by id, kind or
## reservation state costs what it returns instead of a scan -- or a deep copy
## -- of every job, which a whole-map order (~58k jobs) made seconds per tick.
## Plain data over the same live Dictionaries JobQueue holds; no state of its
## own beyond them.
##
## Invariants:
## - Jobs are only ever appended to the list and never change id or kind; a
##   job leaves the indexes only through remove(), on its terminal transition
##   (A5). The list and _by_kind may still hold removed jobs until the next
##   compaction, which runs once they outnumber half the list (amortized O(1)
##   per removal) and filters both in place, keeping the list's identity.
##   Every read skips them: only _by_id names a live job.
## - _position is a job's submission ordinal (list order), never reused, so
##   compaction needs no renumbering and JobHistory can merge by it.
## - Every read takes the caller's current job list and answers from the
##   indexes only while it is the list they were built for (covers()):
##   AssignmentQueue.advance_selection() temporarily swaps JobQueue._jobs for
##   a subset, and every read then scans that subset exactly as before.
## - _watched is a superset of the jobs reservations() reports: every job made
##   active or given a retry_at backoff is watch()ed, and only those two
##   transitions can make a job count; a watched job that no longer counts is
##   dropped as reservations() reads.
## - _labour_disabled holds exactly the jobs whose reason is labour_disabled
##   (JobQueue._set_reason() is the only reason writer).
## - _pending_by_target[tile] lists, in list order, the live pending jobs
##   targeting tile other than construction-site jobs (whose target moves
##   and whose tile Cancel resolves through the site itself), kept by the same
##   job_queued / terminal events as _designations (AreaOrders' Cancel).
## - _designations[tile] counts the pending (queued or active) jobs targeting
##   tile, site_fetch excepted (its target moves between sources): a job is
##   pending from its job_queued event until its terminal one, and on_event()
##   sees every JobQueue event. Each count change appends its tile to
##   _designation_log, append-only like WorldState.get_dirty_cells(); a
##   restored index logs every pending tile once, so reading the log from 0
##   always yields the full current picture.

var _jobs: Array[Dictionary]
var _labour_disabled_reason: String
var _by_id: Dictionary = {}
var _position: Dictionary = {}
var _kinds: Dictionary = {}
var _by_kind: Dictionary = {}
var _watched: Dictionary = {}
var _labour_disabled: Dictionary = {}
var _designations: Dictionary = {}
var _pending_by_target: Dictionary = {}
var _designation_log: Array[Vector2i] = []
var _next_position: int = 0
## Jobs removed since the last compaction.
var _removed: int = 0

## Indexes `jobs` (restored or empty) as it stands.
func _init(jobs: Array[Dictionary], labour_disabled_reason: String) -> void:
	_jobs = jobs
	_labour_disabled_reason = labour_disabled_reason
	for job in jobs:
		_add_at(job)
		if job["status"] == "active" or int(job.get("retry_at", 0)) > 0:
			watch(job)
		note_reason(job)
		if job["status"] in ["queued", "active"]:
			_designate(job, 1)
			_track_pending(job, true)

func covers(jobs: Array[Dictionary]) -> bool:
	return is_same(jobs, _jobs)

## Records a job JobQueue just appended to `jobs`.
func add(jobs: Array[Dictionary], job: Dictionary) -> void:
	if covers(jobs):
		_add_at(job)

func _add_at(job: Dictionary) -> void:
	var job_id: String = job["id"]
	var kind := String(job.get("kind", ""))
	_by_id[job_id] = job
	_position[job_id] = _next_position
	_next_position += 1
	_kinds[job_id] = kind
	if not _by_kind.has(kind):
		var of_kind: Array[Dictionary] = []
		_by_kind[kind] = of_kind
	_by_kind[kind].append(job)

## Drops a job JobQueue just made terminal (after its terminal event reached
## on_event()) from every index; returns its position, or -1 if not indexed.
func remove(job: Dictionary) -> int:
	var job_id: String = job["id"]
	var position: int = _position.get(job_id, -1)
	if position < 0:
		return -1
	for index: Dictionary in [_by_id, _position, _kinds, _watched, _labour_disabled]:
		index.erase(job_id)
	_removed += 1
	if _removed * 2 > _jobs.size():
		_compact()
	return position

func _compact() -> void:
	_jobs.assign(_jobs.filter(_is_live))
	for kind: String in _by_kind:
		(_by_kind[kind] as Array).assign((_by_kind[kind] as Array).filter(_is_live))
	_removed = 0

func _is_live(job: Dictionary) -> bool:
	return _by_id.has(job["id"])

## The submission position of the live job job_id, or -1.
func position_of(job_id: String) -> int:
	var position: int = _position.get(job_id, -1)
	return position

## The live job with job_id in `jobs`, or {}.
func find(jobs: Array[Dictionary], job_id: String) -> Dictionary:
	if covers(jobs):
		return _by_id.get(job_id, {})
	for job in jobs:
		if job["id"] == job_id:
			return job
	return {}

## The live jobs of `jobs` whose kind is in `kinds`, in list order.
func of_kinds(jobs: Array[Dictionary], kinds: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not covers(jobs):
		for job in jobs:
			if String(job["kind"]) in kinds:
				result.append(job)
		return result
	for kind in kinds:
		for job: Dictionary in _by_kind.get(kind, []):
			if _by_id.has(job["id"]):
				result.append(job)
	if kinds.size() > 1:
		result.sort_custom(_before)
	return result

## job id -> kind for every job in `jobs`. While covered, the live index:
## callers read it and must never mutate it.
func kinds_of(jobs: Array[Dictionary]) -> Dictionary:
	if covers(jobs):
		return _kinds
	var kinds: Dictionary = {}
	for job in jobs:
		kinds[job["id"]] = String(job.get("kind", ""))
	return kinds

## The live jobs named by job_ids, each once, in list order: what a scan of
## `jobs` testing `job["id"] in job_ids` returns, at the cost of the ids.
func with_ids(jobs: Array[Dictionary], job_ids: Array[String]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not covers(jobs):
		for job in jobs:
			if job["id"] in job_ids:
				result.append(job)
		return result
	var seen: Dictionary = {}
	for job_id in job_ids:
		if seen.has(job_id) or not _by_id.has(job_id):
			continue
		seen[job_id] = true
		result.append(_by_id[job_id])
	result.sort_custom(_before)
	return result

## JobQueue._emit()'s hook, with the event's job ({} for none).
func on_event(event_type: String, job: Dictionary) -> void:
	if job.is_empty():
		return
	match event_type:
		# Every activation emits job_active right away; every haul destination
		# backoff (a new retry_at) follows a haul_destination_attempt.
		"job_active", "haul_destination_attempt":
			watch(job)
		"job_queued":
			_designate(job, 1)
			_track_pending(job, true)
		"job_completed", "job_cancelled", "job_failed":
			_designate(job, -1)
			_track_pending(job, false)

## {"next": the log position to read from next time, "tiles": tile -> pending
## job count for every tile whose count changed since log position `from`}.
## A negative `from` reads nothing (just "next").
func designation_changes(from: int) -> Dictionary:
	var tiles: Dictionary = {}
	for index in range(maxi(from, 0) if from >= 0 else _designation_log.size(), _designation_log.size()):
		var tile := _designation_log[index]
		tiles[tile] = int(_designations.get(tile, 0))
	return {"next": _designation_log.size(), "tiles": tiles}

## The live pending non-site jobs targeting tile (see _pending_by_target).
func pending_at(tile: Vector2i) -> Array:
	return _pending_by_target.get(tile, [])

## The ids of pending_at(tile), in list order.
func pending_ids_at(tile: Vector2i) -> Array[String]:
	var ids: Array[String] = []
	for job in pending_at(tile):
		ids.append(String(job["id"]))
	return ids

func _track_pending(job: Dictionary, pending: bool) -> void:
	if String(job.get("kind", "")) in ["site_fetch", "site_work"]:
		return
	var tile: Vector2i = job["target"]
	var jobs: Array = _pending_by_target.get(tile, [])
	if pending:
		jobs.append(job)
		_pending_by_target[tile] = jobs
		return
	jobs.erase(job)
	if jobs.is_empty():
		_pending_by_target.erase(tile)

func _designate(job: Dictionary, delta: int) -> void:
	if String(job.get("kind", "")) == "site_fetch":
		return
	var tile: Vector2i = job["target"]
	var count := int(_designations.get(tile, 0)) + delta
	if count > 0:
		_designations[tile] = count
	else:
		_designations.erase(tile)
	_designation_log.append(tile)

func watch(job: Dictionary) -> void:
	_watched[job["id"]] = job

func note_reason(job: Dictionary) -> void:
	if String(job["reason"]) == _labour_disabled_reason:
		_labour_disabled[job["id"]] = true
	else:
		_labour_disabled.erase(job["id"])

func labour_disabled_ids() -> Array:
	return _labour_disabled.keys()

## JobQueue.get_reservations()'s rule (see its doc comment) over the jobs
## that can satisfy it: every active job's target, then every still-backed-off
## queued job's target not already present, each in list order.
func reservations(jobs: Array[Dictionary], tick: int) -> Dictionary:
	var candidates: Array[Dictionary] = jobs
	if covers(jobs):
		candidates = []
		for job_id in _watched.keys():
			var job: Dictionary = _watched[job_id]
			if job["status"] == "active" or (job["status"] == "queued" and tick < int(job["retry_at"])):
				candidates.append(job)
			else:
				_watched.erase(job_id)
		candidates.sort_custom(_before)
	var result: Dictionary = {}
	for job in candidates:
		if job["status"] == "active":
			result[job["target"]] = job["id"]
	for job in candidates:
		if job["status"] == "queued" and tick < int(job["retry_at"]):
			if not result.has(job["target"]):
				result[job["target"]] = job["id"]
	return result

## {"queued": how many jobs are queued, "first_blocked": {reason, remedy} of
## the queued job with the lowest String id whose reason is non-empty, or {}}:
## what ColonistPanel shows an idle colonist, read off the live jobs without
## copying them.
func queued_summary() -> Dictionary:
	var queued := 0
	var first: Dictionary = {}
	for job in _jobs:
		if job["status"] != "queued":
			continue
		queued += 1
		if not String(job["reason"]).is_empty() and (first.is_empty() or String(job["id"]) < String(first["id"])):
			first = job
	var blocked := {} if first.is_empty() else {"reason": first["reason"], "remedy": first["remedy"]}
	return {"queued": queued, "first_blocked": blocked}

func _before(a: Dictionary, b: Dictionary) -> bool:
	return int(_position[a["id"]]) < int(_position[b["id"]])
