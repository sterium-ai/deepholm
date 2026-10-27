class_name EventLog
extends RefCounted

## WorldState's event log: the sorted event list, the sequence counter every
## event draws from, the JobQueue event collector, and the applied/rejected
## command envelopes. Plain data, no scene/node/RNG/wall-clock dependency.
##
## Invariants:
## - _events stays sorted by (tick, system_priority, entity_id, sequence) at
##   all times (binary-search insert in insert_event(), at the same index the
##   former backward scan found), and so does each _by_type list.
## - insert_event() is the only way in: _by_type indexes every event by type
##   so get_events(types) never walks or copies the whole log (B1), and
##   _arrival keeps the same events in insertion order for
##   get_events_since() (A6).
## - Bounded retention (A6): once the log holds more than MAX_EVENTS, the
##   oldest events in log order are dropped down to RETAINED_EVENTS, from
##   _events, _by_type and _arrival alike. _trimmed_sequence remembers the
##   highest sequence dropped, so a get_events_since() cursor at or below it
##   is reported as truncated instead of silently missing events.
## - Only the two counters are persisted (StateCodec "scheduling".
##   eventSequence/queueEventSequence); the event list itself is never saved
##   and starts empty after a load.
## - Nothing here is part of state_hash(): two runs that differ only in their
##   event log hash equal.
## - pure_rejection() never appends an event or advances the sequence -- the
##   only rejection path preview() may call.

const MAX_EVENTS := 8192
const RETAINED_EVENTS := 6144

var _events: Array[Dictionary] = []
var _by_type: Dictionary = {}
## The retained events in insertion order (sequence order on every core path).
var _arrival: Array[Dictionary] = []
## False once an event arrived with a sequence below its predecessor's (only a
## test inserting a hand-made event): get_events_since() then scans _arrival
## whole instead of binary-searching it.
var _arrival_sorted := true
## Highest sequence among the events retention dropped; -1 while none was.
var _trimmed_sequence: int = -1
var _event_sequence: int = 0
## Highest JobQueue event sequence already copied into _events.
var _queue_event_sequence: int = -1
var _clock: SeededClock
var _queue: JobQueue
var _command_priority: int

func _init(clock: SeededClock, queue: JobQueue, command_priority: int) -> void:
	_clock = clock
	_queue = queue
	_command_priority = command_priority

func encode() -> Dictionary:
	return {"queueEventSequence": _queue_event_sequence, "eventSequence": _event_sequence}

## Reads the counters from a decoded save's "scheduling" block; the event list restarts empty.
func decode(scheduling: Dictionary) -> void:
	_events = []
	_by_type = {}
	_arrival = []
	_arrival_sorted = true
	_trimmed_sequence = -1
	_event_sequence = int(scheduling["eventSequence"])
	_queue_event_sequence = int(scheduling["queueEventSequence"])

func collect_queue_events() -> void:
	# Cheap when nothing is new; otherwise only the new tail is copied (B1).
	if _queue.get_sequence() <= _queue_event_sequence + 1:
		return
	var highest := _queue_event_sequence
	for event in _queue.get_events_after(_queue_event_sequence):
		var queue_sequence: int = event["sequence"]
		if queue_sequence <= _queue_event_sequence:
			continue
		highest = maxi(highest, queue_sequence)
		event["sequence"] = next_sequence()
		insert_event(event)
	_queue_event_sequence = highest
	# Only now may the queue's own log drop them (A6, job_event_log.gd).
	_queue.get_event_log().release_through(highest)

## Deep copies of the log, or of only its events whose type is in a non-empty
## `types` (same order), costing only the events returned.
func get_events(types: Array = []) -> Array[Dictionary]:
	var source: Array[Dictionary] = _events
	if not types.is_empty():
		source = []
		for type in types:
			source.append_array(_by_type.get(type, []))
		if types.size() > 1:
			source.sort_custom(_event_less)
	var copy: Array[Dictionary] = []
	for event in source:
		copy.append(event.duplicate(true))
	return copy

## The log as a stream (A6): {"events", "next", "truncated"}. "events" are deep
## copies of the retained events whose sequence is at least `sequence` (only
## those whose type is in a non-empty `types`), in log order; "next" is the
## cursor for the following call; "truncated" is true when retention already
## dropped an event at or after `sequence`. A later read can return an event
## that sorts before one an earlier read returned (a command applied at tick T
## orders before tick T's tick_advanced): the reads merged in log order are
## the log.
func get_events_since(sequence: int, types: Array = []) -> Dictionary:
	var start := _arrival_start(sequence) if _arrival_sorted else 0
	var picked: Array[Dictionary] = []
	for i in range(start, _arrival.size()):
		var event: Dictionary = _arrival[i]
		var event_sequence: int = event["sequence"]
		if event_sequence >= sequence and (types.is_empty() or types.has(event["type"])):
			picked.append(event.duplicate(true))
	picked.sort_custom(_event_less)
	return {"events": picked, "next": _event_sequence, "truncated": sequence <= _trimmed_sequence}

## Number of retained events.
func size() -> int:
	return _events.size()

func reject(command_id, actor, reason: String, message: String, record: bool) -> Dictionary:
	if record:
		return rejection(command_id, actor, reason, message)
	return pure_rejection(command_id, actor, reason, message)

func apply_noop(command: Dictionary) -> Dictionary:
	var actor: String = command["actor"]
	var command_id: String = command["command_id"]
	var payload: Dictionary = command["payload"]
	insert_event({
		"type": "command_applied",
		"tick": _clock.tick,
		"system_priority": _command_priority,
		"entity_id": actor,
		"sequence": next_sequence(),
		"command_id": command_id,
		"data": payload.duplicate(true)
	})
	return {"ok": true, "applied": {"command_id": command_id, "actor": actor, "type": "noop", "tick": _clock.tick}}

## apply_noop() with "applied".type set to the command's own type; the shared
## tail of every immediate-apply command handler.
func applied(command: Dictionary) -> Dictionary:
	var result := apply_noop(command)
	result["applied"]["type"] = command["type"]
	return result

func rejection(command_id, actor, reason: String, message: String) -> Dictionary:
	var result := pure_rejection(command_id, actor, reason, message)
	if typeof(actor) == TYPE_STRING and actor != "":
		insert_event({
			"type": "command_rejected",
			"tick": _clock.tick,
			"system_priority": _command_priority,
			"entity_id": actor,
			"sequence": next_sequence(),
			"command_id": command_id if typeof(command_id) == TYPE_STRING else "",
			"data": {"reason": reason}
		})
	return result

## Same Dictionary as rejection(), without the command_rejected event or a sequence draw.
func pure_rejection(command_id, actor, reason: String, message: String) -> Dictionary:
	return {"ok": false, "rejection": {
		"command_id": command_id,
		"actor": actor,
		"reason": reason,
		"message": message,
		"tick": _clock.tick
	}}

func next_sequence() -> int:
	var sequence := _event_sequence
	_event_sequence += 1
	return sequence

func insert_event(event: Dictionary) -> void:
	_events.insert(_events.bsearch_custom(event, _event_less, false), event)
	if not _by_type.has(event["type"]):
		var of_type: Array[Dictionary] = []
		_by_type[event["type"]] = of_type
	var same_type: Array[Dictionary] = _by_type[event["type"]]
	same_type.insert(same_type.bsearch_custom(event, _event_less, false), event)
	if not _arrival.is_empty():
		var sequence: int = event["sequence"]
		var last_sequence: int = _arrival[-1]["sequence"]
		if sequence < last_sequence:
			_arrival_sorted = false
	_arrival.append(event)
	if _events.size() > MAX_EVENTS:
		_trim()

## Drops the oldest events in log order down to RETAINED_EVENTS. They are a
## prefix of _events' total order, so every index keeps exactly the events
## not ordered before the first kept one.
func _trim() -> void:
	var drop := _events.size() - RETAINED_EVENTS
	for i in drop:
		var dropped_sequence: int = _events[i]["sequence"]
		_trimmed_sequence = maxi(_trimmed_sequence, dropped_sequence)
	var first_kept: Dictionary = _events[drop]
	_events = _events.slice(drop)
	for type: String in _by_type.keys():
		var same_type: Array[Dictionary] = _by_type[type]
		var kept: Array[Dictionary] = same_type.slice(same_type.bsearch_custom(first_kept, _event_less, true))
		if kept.is_empty():
			_by_type.erase(type)
		else:
			_by_type[type] = kept
	var arrival: Array[Dictionary] = []
	arrival.assign(_arrival.filter(func(e: Dictionary) -> bool: return not _event_less(e, first_kept)))
	_arrival = arrival

## Index of the first _arrival event whose sequence is at least `sequence`.
func _arrival_start(sequence: int) -> int:
	var low := 0
	var high := _arrival.size()
	while low < high:
		var mid := (low + high) >> 1
		var mid_sequence: int = _arrival[mid]["sequence"]
		if mid_sequence < sequence:
			low = mid + 1
		else:
			high = mid
	return low

func _event_less(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]
