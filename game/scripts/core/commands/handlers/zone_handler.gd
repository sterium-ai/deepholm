class_name ZoneHandler
extends RefCounted

## Zone commands: zone_add (a stockpile, or with {"kind": "farm", "crop"} a farm zone, F1), zone_remove.
## Invariant: removing a zone fails every active haul job whose reserved cell
## lay inside it, with a typed reason and no leaked reservation.

const EventLogType = preload("res://scripts/core/world/event_log.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const ZoneTableType = preload("res://scripts/core/objects/zone_table.gd")

var _event_log: EventLogType
var _scheduler: AssignmentType
var _zone_table: ZoneTableType
## (check: Callable, command: Dictionary) -> Dictionary: check.call(world, command).
var _check: Callable
## (job_id: String, reason: String, remedy: String) -> void: drops the carried item and fails the haul job.
var _terminate_haul_job_by_id: Callable

func _init(event_log: EventLogType, scheduler: AssignmentType, zone_table: ZoneTableType, check: Callable,
		terminate_haul_job_by_id: Callable) -> void:
	_event_log = event_log
	_scheduler = scheduler
	_zone_table = zone_table
	_check = check
	_terminate_haul_job_by_id = terminate_haul_job_by_id

## Draws a rectangular stockpile or farm zone.
func apply_zone_add_command(command: Dictionary) -> Dictionary:
	var check: Dictionary = _check.call(CommandChecks.check_zone_add_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var payload: Dictionary = command["payload"]
	var crop: String = payload.get("crop", "")
	var zone_id := _zone_table.add(int(payload["x"]), int(payload["y"]), int(payload["width"]), int(payload["height"]), crop)
	var applied := _event_log.applied(command)
	applied["zone_id"] = zone_id
	return applied

## Removes a stockpile zone by id.
func apply_zone_remove_command(command: Dictionary) -> Dictionary:
	var check: Dictionary = _check.call(CommandChecks.check_zone_remove_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var payload: Dictionary = command["payload"]
	var zone_id: String = payload["id"]
	var removed := _zone_table.remove(zone_id)
	_fail_haul_jobs_targeting_removed_zone(int(removed["x"]), int(removed["y"]), int(removed["width"]), int(removed["height"]))
	_event_log.collect_queue_events()
	return _event_log.applied(command)

## Scans every active haul job, since a zone is rarely removed.
func _fail_haul_jobs_targeting_removed_zone(x: int, y: int, width: int, height: int) -> void:
	for job in _scheduler.queue.get_jobs():
		if String(job["kind"]) != "haul" or job["status"] != "active":
			continue
		var cell: Variant = job.get("cell")
		if cell == null:
			continue
		var cx: int = cell.x
		var cy: int = cell.y
		if cx >= x and cx < x + width and cy >= y and cy < y + height:
			_terminate_haul_job_by_id.call(job["id"], "blocked_destination_gone", "choose_reachable_destination")
