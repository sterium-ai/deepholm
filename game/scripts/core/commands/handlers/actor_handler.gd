class_name ActorHandler
extends RefCounted

## Actor commands: set_labour (colonist-ai.md 3.2) and the set_faction debug
## command (F3). Plain data, no scene/node/RNG/wall-clock dependency; every
## WorldState rule it needs arrives as a Callable.
##
## Invariant: set_faction only rewrites an actor's own "factionId" (any actor in
## the roster, ADR 012), never an object's or item's faction_id.

const EventLogType = preload("res://scripts/core/world/event_log.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")

var _event_log: EventLogType
## (check: Callable, command: Dictionary) -> Dictionary: check.call(world, command).
var _check: Callable
## (colonist_id: String) -> Dictionary: the live actor record, or {}.
var _find_colonist: Callable

func _init(event_log: EventLogType, check: Callable, find_colonist: Callable) -> void:
	_event_log = event_log
	_check = check
	_find_colonist = find_colonist

## Mutates one colonist's labour table.
func apply_set_labour_command(command: Dictionary) -> Dictionary:
	var check: Dictionary = _check.call(CommandChecks.check_set_labour_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var payload: Dictionary = command["payload"]
	var colonist: Dictionary = _find_colonist.call(String(payload["colonist"]))
	WorkerType.set_labour_level(colonist, String(payload["kind"]), int(payload["level"]))
	return _event_log.applied(command)

## Mutates one actor's existing "factionId" field.
func apply_set_faction_command(command: Dictionary) -> Dictionary:
	var check: Dictionary = _check.call(CommandChecks.check_set_faction_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var payload: Dictionary = command["payload"]
	var actor: Dictionary = _find_colonist.call(String(payload["target"]))
	actor["factionId"] = String(payload["faction_id"])
	return _event_log.applied(command)
