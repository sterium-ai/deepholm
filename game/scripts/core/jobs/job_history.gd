extends RefCounted

## JobQueue's last LIMIT retired jobs (A5, ADR 053), so get_job() and check_terminal() still
## see recently finished jobs. Never persisted nor hashed: no simulation decision may read it.
## Invariants: entries are in retirement order and keep their list position (merged() is in
## submission order); _by_id holds exactly the retained jobs.

const LIMIT := 256

var _entries: Array[Dictionary] = []
var _by_id: Dictionary = {}

## Retains `job` (the live record, no longer written by JobQueue) at its list
## position; the oldest entry goes once more than LIMIT are held.
func add(job: Dictionary, position: int) -> void:
	var job_id: String = job["id"]
	_entries.append({"position": position, "job": job})
	_by_id[job_id] = job
	if _entries.size() > LIMIT:
		var evicted_id: String = _entries.pop_front()["job"]["id"]
		_by_id.erase(evicted_id)

func has(job_id: String) -> bool:
	return _by_id.has(job_id)

## The retained job record, or {}; callers must never mutate it.
func find(job_id: String) -> Dictionary:
	return _by_id.get(job_id, {})

func size() -> int:
	return _entries.size()

## Deep copies of `live` (skipping position -1) and of the retained jobs (filtered by `kinds`
## when non-empty; none when with_retired is false), in position order.
func merged(live: Array[Dictionary], position_of: Callable, kinds: Array = [], with_retired: bool = true) -> Array[Dictionary]:
	var retired: Array[Dictionary] = []
	for entry in _entries if with_retired else []:
		var kind: String = entry["job"]["kind"]
		if kinds.is_empty() or kind in kinds:
			retired.append(entry)
	retired.sort_custom(_before)
	var result: Array[Dictionary] = []
	var next := 0
	for job in live:
		var position: int = position_of.call(job["id"])
		if position < 0:
			continue
		while next < retired.size() and (retired[next]["position"] as int) < position:
			result.append((retired[next]["job"] as Dictionary).duplicate(true))
			next += 1
		result.append(job.duplicate(true))
	for index in range(next, retired.size()):
		result.append((retired[index]["job"] as Dictionary).duplicate(true))
	return result

static func _before(a: Dictionary, b: Dictionary) -> bool:
	return (a["position"] as int) < (b["position"] as int)
