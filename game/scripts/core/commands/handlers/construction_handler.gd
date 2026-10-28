class_name ConstructionHandler
extends RefCounted

## Construction and object commands: build, build_line, cancel_site, place_object, remove_object.
## Invariants:
## - build/build_line rules live in ConstructionSystem, the rest in
##   CommandChecks; CommandRouter.preview() runs the same functions.
## - place_object is the permissive debug/map-gen placement path (ADR 039);
##   the player-facing order flow is build.

const EventLogType = preload("res://scripts/core/world/event_log.gd")
const ConstructionSystemType = preload("res://scripts/core/objects/construction_system.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")

var _event_log: EventLogType
var _construction: ConstructionSystemType
var _object_table: ObjectTableType
## (check: Callable, command: Dictionary) -> Dictionary: check.call(world, command).
var _check: Callable

func _init(event_log: EventLogType, construction: ConstructionSystemType, object_table: ObjectTableType,
		check: Callable) -> void:
	_event_log = event_log
	_construction = construction
	_object_table = object_table
	_check = check

func apply_build_command(command: Dictionary) -> Dictionary:
	return _construction.apply_construction_submission(command)

func apply_build_line_command(command: Dictionary) -> Dictionary:
	return _construction.apply_build_line_command(command)

func apply_cancel_site_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check: Dictionary = _check.call(CommandChecks.check_cancel_site_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var site_id := _construction.construction_site_id_at(int(payload["x"]), int(payload["y"]))
	_construction.cancel_construction_site(site_id)
	_event_log.collect_queue_events()
	var applied := _event_log.applied(command)
	applied["site_id"] = site_id
	return applied

## Applies immediately, no job queue involved.
func apply_place_object_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check: Dictionary = _check.call(CommandChecks.check_place_object_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	_object_table.set_object(int(payload["x"]), int(payload["y"]), String(payload["kind"]), "colony", String(payload.get("orientation", "")))
	return _event_log.applied(command)

func apply_remove_object_command(command: Dictionary) -> Dictionary:
	var check: Dictionary = _check.call(CommandChecks.check_remove_object_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var payload: Dictionary = command["payload"]
	_object_table.set_object(int(payload["x"]), int(payload["y"]), "")
	return _event_log.applied(command)
