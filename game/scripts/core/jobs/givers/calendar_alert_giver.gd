class_name CalendarAlertGiver
extends RefCounted

## Job-giver for the sowing-window calendar alert (ADR 008 consequence 6,
## colonist-ai.md 3.7): decides when the soonest upcoming calendar window's
## one-shot alert fires, from live colony facts -- has_labour_enabled (any
## colonist's labourTable has that window's labour above 0), has_plowed_plot
## (any tile is plowed_soil), has_seed_stock (any "seed" item exists anywhere,
## ground/stockpile or mid-haul in a colonist's carrying slot) -- and
## emits it through the same insert_event()/next_sequence() entry points
## every WorldState event uses (AGENTS.md "one work engine": WorldState
## stays state, validation and orchestration only). CalendarService.
## alert_state() itself stays pure and stateless (colony facts passed in,
## not read from WorldState); this module supplies them each tick and owns
## the caller-persisted one-shot already_fired bookkeeping WorldState hands
## it as fired_state.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")

const TILE_PLOWED_SOIL := ContentRegistryType.TILE_PLOWED_SOIL

var _get_colonists: Callable
var _get_tiles: Callable
var _has_item_of_kind: Callable
var _insert_event: Callable
var _next_sequence: Callable
var _priority: int

## get_colonists/get_tiles must be WorldState's own public methods of the
## same name; has_item_of_kind must be WorldState._has_item_of_kind (the same
## ground/stockpile/carrying-slot query sow's blocked_missing_input
## precondition already uses, so a seed mid-haul in a colonist's carrying
## slot counts here too); insert_event must be WorldState._insert_event,
## next_sequence must be WorldState._next_sequence (the same entry points
## every WorldState event uses); priority must be WorldState.PRIORITY_TICK.
func _init(get_colonists: Callable, get_tiles: Callable, has_item_of_kind: Callable,
		insert_event: Callable, next_sequence: Callable, priority: int) -> void:
	_get_colonists = get_colonists
	_get_tiles = get_tiles
	_has_item_of_kind = has_item_of_kind
	_insert_event = insert_event
	_next_sequence = next_sequence
	_priority = priority

## Runs once per tick (WorldState.tick()): computes the soonest upcoming
## window's colony facts and calls calendar.alert_state() against
## fired_state's persisted already_fired flag for that window. On a due
## report, marks fired_state[window_id] = true (one-shot per occurrence,
## never re-fired) and emits calendar_alert carrying the window's
## id/label/days_until. calendar is WorldState._calendar and fired_state is
## WorldState._calendar_alerts_fired, both passed in fresh each call (rather
## than captured at construction) so a test's direct override of either
## field is honoured the same tick it's set; fired_state is mutated in
## place so WorldState keeps owning the persisted field itself.
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

## Mirrors CalendarService.alert_state()'s own "soonest not-yet-open window"
## selection (day_of_tick + window_definitions()): alert_state() itself
## reports only the chosen window's label/days_until, never its id, but the
## id is exactly what this caller needs to key a one-shot already_fired flag
## per window (ADR 008 consequence 6), so it is re-derived here from the same
## pure content the calendar service already exposes for this purpose.
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
