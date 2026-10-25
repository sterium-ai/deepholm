extends RefCounted

## JobQueue's lookup indexes over its job list (B1), so a read by id, kind or
## reservation state costs what it returns instead of a scan -- or a deep copy
## -- of every job, which a whole-map order (~58k jobs) made seconds per tick.
## Plain data over the same live Dictionaries JobQueue holds; no state of its
## own beyond them.
##
## Invariants:
## - Jobs are only ever appended to the list and never change id or kind, so
##   add() is the only write besides watch()/note_reason().
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
var _designation_log: Array[Vector2i] = []

## Indexes `jobs` (restored or empty) as it stands.
func _init(jobs: Array[Dictionary], labour_disabled_reason: String) -> void:
	_jobs = jobs
	_labour_disabled_reason = labour_disabled_reason
	for position in jobs.size():
		var job: Dictionary = jobs[position]
		_add_at(job, position)
		if job["status"] == "active" or int(job.get("retry_at", 0)) > 0:
			watch(job)
		note_reason(job)
		if job["status"] in ["queued", "active"]:
			_designate(job, 1)

func covers(jobs: Array[Dictionary]) -> bool:
	return is_same(jobs, _jobs)

## Records a job JobQueue just appended to `jobs`.
func add(jobs: Array[Dictionary], job: Dictionary) -> void:
	if covers(jobs):
		_add_at(job, jobs.size() - 1)

func _add_at(job: Dictionary, position: int) -> void:
	var job_id: String = job["id"]
	var kind := String(job.get("kind", ""))
	_by_id[job_id] = job
	_position[job_id] = position
	_kinds[job_id] = kind
	if not _by_kind.has(kind):
		var of_kind: Array[Dictionary] = []
		_by_kind[kind] = of_kind
	_by_kind[kind].append(job)

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
		result.append_array(_by_kind.get(kind, []))
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
		"job_completed", "job_cancelled", "job_failed":
			_designate(job, -1)

## {"next": the log position to read from next time, "tiles": tile -> pending
## job count for every tile whose count changed since log position `from`}.
## A negative `from` reads nothing (just "next").
func designation_changes(from: int) -> Dictionary:
	var tiles: Dictionary = {}
	for index in range(maxi(from, 0) if from >= 0 else _designation_log.size(), _designation_log.size()):
		var tile := _designation_log[index]
		tiles[tile] = int(_designations.get(tile, 0))
	return {"next": _designation_log.size(), "tiles": tiles}

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
func queued_summary(jobs: Array[Dictionary]) -> Dictionary:
	var queued := 0
	var first: Dictionary = {}
	for job in jobs:
		if job["status"] != "queued":
			continue
		queued += 1
		if not String(job["reason"]).is_empty() and (first.is_empty() or String(job["id"]) < String(first["id"])):
			first = job
	var blocked := {} if first.is_empty() else {"reason": first["reason"], "remedy": first["remedy"]}
	return {"queued": queued, "first_blocked": blocked}

func _before(a: Dictionary, b: Dictionary) -> bool:
	return int(_position[a["id"]]) < int(_position[b["id"]])
