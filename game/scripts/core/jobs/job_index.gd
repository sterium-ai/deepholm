extends RefCounted

## JobQueue's lookup indexes (B1): reads by id, kind or reservation state cost what they
## return, not a scan of every job. Plain data over JobQueue's live Dictionaries.
## Invariants:
## - Jobs are appended, never change id or kind, and leave only through remove() (A5);
##   removed jobs linger in the list until compaction (> half removed). Only _by_id is live.
## - _position is the submission ordinal, never reused, so JobHistory can merge by it.
## - Reads answer from the indexes only while covers(jobs) (advance_selection() swaps lists).
## - _watched ⊇ the jobs reservations() reports (activation or a retry_at backoff).
## - _labour_disabled is exactly the jobs whose reason is labour_disabled.
## - _designations/_pending_by_target count pending jobs per tile (site jobs excepted);
##   _designation_log is append-only, and a restored index logs every pending tile once.

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

## job id -> kind for every job; while covered, the live index (never mutate).
func kinds_of(jobs: Array[Dictionary]) -> Dictionary:
	if covers(jobs):
		return _kinds
	var kinds: Dictionary = {}
	for job in jobs:
		kinds[job["id"]] = String(job.get("kind", ""))
	return kinds

## The live jobs named by job_ids, each once, in list order.
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
		# Every activation emits job_active; every haul backoff follows a haul_destination_attempt.
		"job_active", "haul_destination_attempt":
			watch(job)
		"job_queued":
			_designate(job, 1)
			_track_pending(job, true)
		"job_completed", "job_cancelled", "job_failed":
			_designate(job, -1)
			_track_pending(job, false)

## {"next": log position to read next, "tiles": tile -> pending count changed since `from`}.
## A negative `from` reads nothing.
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
	if String(job.get("kind", "")) in ["site_fetch", "craft_fetch", "site_work"]:
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
	if String(job.get("kind", "")) in ["site_fetch", "craft_fetch"]:
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

## JobQueue.get_reservations()'s rule: active targets, then backed-off queued targets, in list order.
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

## {"queued": count, "first_blocked": reason/remedy of the lowest-id blocked queued job, or {}},
## for ColonistPanel, without copying jobs.
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
