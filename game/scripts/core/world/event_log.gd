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
##   so get_events(types) never walks or copies the whole log (B1).
## - Only the two counters are persisted (StateCodec "scheduling".
##   eventSequence/queueEventSequence); the event list itself is never saved
##   and starts empty after a load.
## - Nothing here is part of state_hash(): two runs that differ only in their
##   event log hash equal.
## - pure_rejection() never appends an event or advances the sequence -- the
##   only rejection path preview() may call.

var _events: Array[Dictionary] = []
var _by_type: Dictionary = {}
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

func _event_less(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]
