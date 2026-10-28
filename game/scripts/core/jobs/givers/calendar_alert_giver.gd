class_name CalendarAlertGiver
extends RefCounted

## Job-giver for the sowing-window calendar alert (ADR 008, colonist-ai.md 3.7): fires the
## soonest window's one-shot alert from live colony facts (labour on, plowed plot, seed
## stock). CalendarService.alert_state() stays pure; the fired set is owned by WorldState.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")

const TILE_PLOWED_SOIL := ContentRegistryType.TILE_PLOWED_SOIL

var _get_colonists: Callable
var _get_tiles: Callable
var _has_item_of_kind: Callable
var _insert_event: Callable
var _next_sequence: Callable
var _priority: int

## Wired by WorldState: the live worker view (read only), has_item_of_kind (counts seed in
## hands too) and EventLog.insert_event/next_sequence, so the alert orders like any event.
func _init(get_colonists: Callable, get_tiles: Callable, has_item_of_kind: Callable,
		insert_event: Callable, next_sequence: Callable, priority: int) -> void:
	_get_colonists = get_colonists
	_get_tiles = get_tiles
	_has_item_of_kind = has_item_of_kind
	_insert_event = insert_event
	_next_sequence = next_sequence
	_priority = priority

## Runs once per tick (TickPipeline). Marks fired_state[window_id] (one shot per occurrence)
## in place and emits calendar_alert; calendar and fired_state are passed fresh each call.
func advance(tick: int, calendar: CalendarServiceType, fired_state: Dictionary) -> void:
	var window := _soonest_window(calendar, tick)
	if window.is_empty():
		return
	var window_id := String(window.get("id", ""))
	var labour := String(window.get("labour", ""))
	var already_fired := bool(fired_state.get(window_id, false))
	var state := calendar.alert_state(tick, _has_labour_enabled(labour), _has_plowed_plot(),
		_has_seed_stock(), already_fired)
	if not bool(state["due"]):
		return
	fired_state[window_id] = true
	_insert_event.call({
		"type": "calendar_alert", "tick": tick, "system_priority": _priority,
		"entity_id": "world", "sequence": _next_sequence.call(),
		"data": {"id": window_id, "label": String(state["window_label"]), "days_until": int(state["days_until"])},
	})

## Re-derives alert_state()'s soonest window to get its id, the key of the one-shot flag.
func _soonest_window(calendar: CalendarServiceType, tick: int) -> Dictionary:
	var day := calendar.day_of_tick(tick)
	var best_window: Dictionary = {}
	var best_days_until := -1
	for window in calendar.window_definitions():
		var days_until: int = int(window.get("from", 0)) - day
		if days_until < 0:
			continue
		if best_window.is_empty() or days_until < best_days_until:
			best_window = window
			best_days_until = days_until
	return best_window

func _has_labour_enabled(labour: String) -> bool:
	if labour.is_empty():
		return false
	for colonist in (_get_colonists.call() as Array):
		var labour_table: Dictionary = colonist.get("labourTable", {})
		if int(labour_table.get(labour, 0)) > 0:
			return true
	return false

func _has_plowed_plot() -> bool:
	return (_get_tiles.call() as Array).has(TILE_PLOWED_SOIL)

func _has_seed_stock() -> bool:
	return bool(_has_item_of_kind.call("seed"))
