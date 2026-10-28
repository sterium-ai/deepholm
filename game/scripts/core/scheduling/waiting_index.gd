extends RefCounted

## GlobalAssignment's job_id -> position lookup into its sorted waiting queue (B1).
## Invariants: the queue is always sorted by _entry_before() on (base, ordinal); an entry's
## (base, ordinal) never changes and is unique, so index_of() can binary-search; a job never
## record()ed falls back to a scan.

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
	var key: Variant = _keys.get(job_id)
	if key == null:
		for index in waiting.size():
			if waiting[index]["id"] == job_id:
				return index
		return -1
	var index := waiting.bsearch_custom(key, entry_before, true)
	if index < waiting.size() and waiting[index]["id"] == job_id:
		return index
	return -1

## Calls queue.set_labour_disabled() for waiting entries in waiting order; with no labour
## disabled, only jobs still blocked labour_disabled can change, so only those are called.
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
