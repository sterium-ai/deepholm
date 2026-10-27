extends RefCounted

## JobQueue's diagnostic event log (B1). Appended in emission order and read
## sorted by (tick, system_priority, entity_id, sequence) -- a total order,
## since sequence is unique -- so get_after() returns exactly the tail
## get_all() would list, in the same relative order. Re-sorting the whole log
## on every append made an N-job area order cost O(N^2 log N), and copying it
## whole for every collected command O(N^2).
##
## Invariant: _events[i]["sequence"] == _first_sequence + i.
##
## Bounded retention (A6): trim() drops the oldest events (by sequence) down
## to RETAINED_EVENTS once more than MAX_EVENTS are held. JobQueue calls it
## only at the start of its own tick(), never mid-command or mid-tick. Events
## EventLog.collect_queue_events() has not copied yet are the newest ones, so
## they survive a trim unless more than RETAINED_EVENTS were emitted since the
## last collection (every command handler and WorldState tick collects).

const MAX_EVENTS := 4096
const RETAINED_EVENTS := 3072

var _events: Array[Dictionary] = []
var _first_sequence: int = 0

## Empties the log; the next appended event carries first_sequence.
func reset(first_sequence: int) -> void:
	_events = []
	_first_sequence = first_sequence

func append(event: Dictionary) -> void:
	_events.append(event)

## Drops the oldest events down to RETAINED_EVENTS once more than MAX_EVENTS are held.
func trim() -> void:
	if _events.size() <= MAX_EVENTS:
		return
	var drop := _events.size() - RETAINED_EVENTS
	_events = _events.slice(drop)
	_first_sequence += drop

## Number of retained events.
func size() -> int:
	return _events.size()

## {"events", "next", "truncated"}: "events" are get_after(sequence - 1);
## "next" (the queue's next sequence) is the cursor for the following call;
## "truncated" is true when trim() already dropped an event at or after
## `sequence`.
func since(sequence: int, next: int) -> Dictionary:
	return {"events": get_after(sequence - 1), "next": next, "truncated": sequence < _first_sequence}

## Deep copy of the whole log, sorted.
func get_all() -> Array[Dictionary]:
	var events := _events.duplicate(true)
	events.sort_custom(_before)
	return events

## Deep copies of the events whose sequence is above after_sequence, sorted.
func get_after(after_sequence: int) -> Array[Dictionary]:
	var start := clampi(after_sequence + 1 - _first_sequence, 0, _events.size())
	var events: Array[Dictionary] = _events.slice(start).duplicate(true)
	events.sort_custom(_before)
	return events

static func _before(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]
