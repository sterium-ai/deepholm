class_name CommandRouter
extends RefCounted

## The command boundary: validates the envelope and dispatches each type to its handler
## under commands/handlers/.
## Invariants:
## - Validation follows commands/README.md's order; the first failing check rejects.
## - preview() never mutates (no event, no sequence draw) and runs the same checks as
##   apply()'s handlers, so a preview and apply() always agree.

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const ConstructionSystemType = preload("res://scripts/core/objects/construction_system.gd")
const OrderHandlerType = preload("res://scripts/core/commands/handlers/order_handler.gd")
const ConstructionHandlerType = preload("res://scripts/core/commands/handlers/construction_handler.gd")
const ZoneHandlerType = preload("res://scripts/core/commands/handlers/zone_handler.gd")
const ActorHandlerType = preload("res://scripts/core/commands/handlers/actor_handler.gd")
const IncidentHandlerType = preload("res://scripts/core/commands/handlers/incident_handler.gd")
const CraftingHandlerType = preload("res://scripts/core/commands/handlers/crafting_handler.gd")
const CraftingSystemType = preload("res://scripts/core/crafting/crafting_system.gd")

var _clock: SeededClockType
var _event_log: EventLogType
var _construction_system: ConstructionSystemType
## (rule, command) -> Dictionary: runs one CommandChecks rule against the world.
var _check: Callable
var _orders: OrderHandlerType
var _construction: ConstructionHandlerType
var _zones: ZoneHandlerType
var _actors: ActorHandlerType
var _incidents: IncidentHandlerType
var _crafting: CraftingHandlerType
var _crafting_system: CraftingSystemType

func _init(clock: SeededClockType, event_log: EventLogType, construction_system: ConstructionSystemType,
		check: Callable, orders: OrderHandlerType, construction: ConstructionHandlerType, zones: ZoneHandlerType,
		actors: ActorHandlerType, incidents: IncidentHandlerType, crafting_system: CraftingSystemType) -> void:
	_clock = clock
	_event_log = event_log
	_construction_system = construction_system
	_check = check
	_orders = orders
	_construction = construction
	_zones = zones
	_actors = actors
	_incidents = incidents
	_crafting_system = crafting_system
	_crafting = CraftingHandlerType.new(event_log, crafting_system)

## Read-only dry run of apply(): state_hash() and the event log are unchanged.
func preview(command) -> Dictionary:
	var validation := validate_command(command, false)
	if not validation["ok"]:
		return validation
	if command["type"] == "build_line":
		var classification := _construction_system.classify_build_line_command(command["payload"])
		if classification.has("reason"):
			return _event_log.pure_rejection(command["command_id"], command["actor"], classification["reason"], classification["params"])
		return {"ok": true, "skipped": classification["skipped"]}
	var check: Dictionary
	if command["type"] == "build":
		check = _construction_system.check_construction_command(command["payload"])
	elif command["type"] == "cancel_site":
		check = _check.call(CommandChecks.check_cancel_site_command, command)
	elif command["type"] == "place_object":
		check = _check.call(CommandChecks.check_place_object_command, command)
	elif command["type"] in CraftingSystemType.COMMAND_TYPES:
		var craft_command: Dictionary = command
		check = _crafting_system.check_command(craft_command)
	else:
		check = _check.call(CommandChecks.check, command)
	if not check.is_empty():
		return _event_log.pure_rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	return {"ok": true}

## Validates a command envelope and applies it through its family's handler.
func apply(command) -> Dictionary:
	var validation := validate_command(command)
	if not validation["ok"]:
		return validation
	match command["type"]:
		"noop":
			return _event_log.apply_noop(command)
		"dig", "chop", "forage", "till", "sow", "mine", "complete_job", "fail_job", "invalidate_job":
			return _orders.apply_job_command(command)
		"cancel_job":
			return _orders.apply_cancel_job_command(command)
		"build":
			return _construction.apply_build_command(command)
		"build_line":
			return _construction.apply_build_line_command(command)
		"area_order":
			return _orders.apply_area_order_command(command)
		"cancel_site":
			return _construction.apply_cancel_site_command(command)
		"place_object":
			return _construction.apply_place_object_command(command)
		"remove_object":
			return _construction.apply_remove_object_command(command)
		"set_labour":
			return _actors.apply_set_labour_command(command)
		"set_faction":
			return _actors.apply_set_faction_command(command)
		"spawn_incident":
			return _incidents.apply_spawn_incident_command(command)
		"accept_trade":
			return _incidents.apply_accept_trade_command(command)
		"zone_add":
			return _zones.apply_zone_add_command(command)
		"zone_remove":
			return _zones.apply_zone_remove_command(command)
		"craft_set_target", "craft_add_order", "craft_cancel_order":
			var craft_command: Dictionary = command
			return _crafting.apply_craft_command(craft_command)
		_:
			return _event_log.rejection(
				command["command_id"], command["actor"], "unknown_command_type",
				{"detail": "unknown_command_type", "type": command["type"]}
			)

## record=false (preview() only) rejects through EventLog.pure_rejection().
func validate_command(command, record: bool = true) -> Dictionary:
	if typeof(command) != TYPE_DICTIONARY:
		return _event_log.reject(null, null, "invalid_envelope", {"detail": "command_not_dictionary"}, record)
	if not (command.has("actor") and typeof(command["actor"]) == TYPE_STRING and command["actor"] != ""):
		return _event_log.reject(command.get("command_id"), command.get("actor"), "invalid_envelope",
			{"detail": "missing_actor"}, record)
	if not (command.has("command_id") and typeof(command["command_id"]) == TYPE_STRING and command["command_id"] != ""):
		return _event_log.reject(null, command["actor"], "invalid_envelope",
			{"detail": "missing_command_id"}, record)
	if not (command.has("tick") and typeof(command["tick"]) == TYPE_INT):
		return _event_log.reject(command["command_id"], command["actor"], "invalid_envelope",
			{"detail": "missing_tick"}, record)
	if not (command.has("type") and typeof(command["type"]) == TYPE_STRING and command["type"] != ""):
		return _event_log.reject(command["command_id"], command["actor"], "invalid_envelope",
			{"detail": "missing_type"}, record)
	if not (command.has("payload") and typeof(command["payload"]) == TYPE_DICTIONARY):
		return _event_log.reject(command["command_id"], command["actor"], "invalid_envelope",
			{"detail": "missing_payload"}, record)
	# build_line's "tiles" (an Array of {x, y} Dictionaries) is the one exception
	# to the flat String/int payload shape, scoped by both type and key.
	for key in command["payload"].keys():
		if command["type"] == "build_line" and key == "tiles":
			continue
		var value: Variant = command["payload"][key]
		if typeof(value) != TYPE_STRING and typeof(value) != TYPE_INT:
			return _event_log.reject(command["command_id"], command["actor"], "invalid_payload",
				{"detail": "payload_value_type"}, record)
	if command["tick"] != _clock.tick:
		return _event_log.reject(command["command_id"], command["actor"], "tick_mismatch",
			{"detail": "tick_mismatch", "command_tick": command["tick"], "current_tick": _clock.tick}, record)
	var layer_check: Dictionary = _check.call(CommandChecks.check_command_layer, command)
	if not layer_check.is_empty():
		return _event_log.reject(command["command_id"], command["actor"], layer_check["reason"], layer_check["params"], record)
	return {"ok": true}
