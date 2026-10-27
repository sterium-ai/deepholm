extends RefCounted

## GlobalAssignment's job_id -> position lookup into its sorted waiting queue
## (B1). A whole-map order puts ~58k entries in that queue, and finding one by
## scanning it -- on every removal, activation and committed-need lookup --
## made cancelling an area order O(N^2).
##
## Invariants:
## - The waiting queue is always sorted by GlobalAssignment._entry_before()
##   on (base, ordinal): every insert is a sorted insert.
## - An entry's base and ordinal never change once submitted: a suspend or
##   requeue reinserts the snapshot captured at activation, with the same
##   pair. Ordinals are unique, so (base, ordinal) names one entry.
## - So index_of() finds a known job by binary search, or proves it absent;
##   a job never record()ed here falls back to the scan it always used.

var _keys: Dictionary = {}

func record(entry: Dictionary) -> void:
	_keys[entry["id"]] = {"base": entry["base"], "ordinal": entry["ordinal"]}

## Rebuilds the keys from a restored waiting queue and activation snapshots.
func restore(waiting: Array[Dictionary], activated_entries: Dictionary) -> void:
	_keys = {}
	for entry in waiting:
		record(entry)
	for job_id in activated_entries:
		record(activated_entries[job_id])

## job_id's index in `waiting`, or -1.
func index_of(waiting: Array[Dictionary], job_id: String, entry_before: Callable) -> int:
	var key = _keys.get(job_id)
	if key == null:
		for index in waiting.size():
			if waiting[index]["id"] == job_id:
				return index
		return -1
	var index := waiting.bsearch_custom(key, entry_before, true)
	if index < waiting.size() and waiting[index]["id"] == job_id:
		return index
	return -1

## GlobalAssignment._refresh_labour_disabled_reasons()'s last step: calls
## queue.set_labour_disabled(id, labour disabled?) for the waiting entries, in
## waiting order. With no labour disabled, only a job still blocked
## labour_disabled can change, so only those are called (the rest are no-ops);
## otherwise every entry is, asking get_job_labour (a pure kind -> labour
## lookup) once per kind.
func apply_labour_disabled(queue, waiting: Array[Dictionary], disabled_labours: Dictionary,
		job_kinds: Dictionary, get_job_labour: Callable, entry_before: Callable) -> void:
	if not disabled_labours.values().has(true):
		var indexes: Array[int] = []
		for job_id in queue.get_index().labour_disabled_ids():
			var index := index_of(waiting, String(job_id), entry_before)
			if index >= 0:
				indexes.append(index)
		indexes.sort()
		var job_ids: Array[String] = []
		for index in indexes:
			job_ids.append(String(waiting[index]["id"]))
		for job_id in job_ids:
			queue.set_labour_disabled(job_id, false)
		return
	var labours: Dictionary = {}
	for entry in waiting:
		var kind := String(job_kinds.get(entry["id"], ""))
		if not labours.has(kind):
			labours[kind] = String(get_job_labour.call(kind))
		queue.set_labour_disabled(entry["id"], bool(disabled_labours.get(labours[kind], false)))
