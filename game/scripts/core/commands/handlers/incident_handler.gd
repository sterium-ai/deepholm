class_name IncidentHandler
extends RefCounted

## Incident commands: spawn_incident (tests, debug buttons) and accept_trade (ADR 035/036).
## Invariant: spawn_incident proposes the incident's actors now, bypassing
## min_day/cooldown/budget gating; each actor spawns only once its job activates.

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const TradeSystemType = preload("res://scripts/core/economy/trade_system.gd")

var _clock: SeededClockType
var _event_log: EventLogType
var _trade: TradeSystemType
## (check: Callable, command: Dictionary) -> Dictionary: check.call(world, command).
var _check: Callable
## (incident_id: String, tick: int) -> Array: IncidentScheduler.force_spawn(), through a
## lambda because StateCodec.decode() rebuilds the scheduler.
var _force_spawn: Callable

func _init(clock: SeededClockType, event_log: EventLogType, trade: TradeSystemType, check: Callable,
		force_spawn: Callable) -> void:
	_clock = clock
	_event_log = event_log
	_trade = trade
	_check = check
	_force_spawn = force_spawn

## "actor_ids" in the applied envelope lists the proposed actors.
func apply_spawn_incident_command(command: Dictionary) -> Dictionary:
	var check: Dictionary = _check.call(CommandChecks.check_spawn_incident_command, command)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var payload: Dictionary = command["payload"]
	var applied := _event_log.applied(command)
	applied["actor_ids"] = _force_spawn.call(String(payload["id"]), _clock.tick)
	return applied

func apply_accept_trade_command(command: Dictionary) -> Dictionary:
	return _trade.apply_accept_trade_command(command)
