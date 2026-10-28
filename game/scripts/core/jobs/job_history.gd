extends RefCounted

## JobQueue's retired jobs (A5, ADR 053): a job leaves the live list on its
## terminal transition (completed, cancelled, failed) and is kept here, last
## LIMIT retirements only, so get_job()/get_jobs() still show a recently
## finished job and check_terminal() still tells "already terminal" from
## "unknown". Never persisted and never hashed: a loaded world starts with an
## empty history, so no simulation decision may depend on what it holds beyond
## the call that retired the job.
##
## Invariants:
## - Entries are in retirement order; each keeps the job's position in the
##   live list (JobIndex.remove()), so merged() lists jobs in submission order.
## - _by_id holds exactly the retained entries' jobs.

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

## Deep copies of `live` (ascending positions; position_of(job_id) is -1 for a
## job retired since the list was last compacted, which is skipped) and of
## every retained job (none when with_retired is false), in position order. A
## non-empty `kinds` keeps only the retained jobs of those kinds (`live` is
## already filtered by the caller).
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
