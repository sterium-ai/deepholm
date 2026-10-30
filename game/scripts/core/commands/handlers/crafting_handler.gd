class_name CraftingHandler
extends RefCounted

## Workbench commands (F2, ADR 061): craft_set_target, craft_add_order, craft_cancel_order.
## The rule is CraftingSystem.check_command(), shared with CommandRouter.preview().

const EventLogType = preload("res://scripts/core/world/event_log.gd")
const CraftingSystemType = preload("res://scripts/core/crafting/crafting_system.gd")

var _event_log: EventLogType
var _crafting: CraftingSystemType

func _init(event_log: EventLogType, crafting: CraftingSystemType) -> void:
	_event_log = event_log
	_crafting = crafting

## craft_add_order's applied result carries the new "order_id".
func apply_craft_command(command: Dictionary) -> Dictionary:
	var check := _crafting.check_command(command)
	if not check.is_empty():
		# CommandRouter.validate_command() already proved both non-empty Strings.
		var command_id: String = command["command_id"]
		var actor: String = command["actor"]
		var reason: String = check["reason"]
		var params: Dictionary = check["params"]
		return _event_log.rejection(command_id, actor, reason, params)
	var extra := _crafting.apply_command(command)
	var applied := _event_log.applied(command)
	applied.merge(extra)
	return applied
