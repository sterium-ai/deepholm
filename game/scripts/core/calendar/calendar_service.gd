class_name CalendarService
extends RefCounted

## Calendar content and pure calendar queries (colonist-ai.md 3.7): a day length in ticks and
## labour boost windows ({labour, from, to, boost, label}, 1-indexed inclusive day-of-year; day 1
## is spring day 1). Content is read once in the constructor; every query is a pure function.

const CALENDAR_CONTENT_PATH := "res://content/calendar.json"

## A window is "due" exactly this many days before it opens (colonist-ai.md 3.7).
const ALERT_LEAD_DAYS := 3

var _day_length_ticks: int = 1
var _windows: Array[Dictionary] = []

## content_override is for tests; production uses the zero-argument form.
func _init(content_path: String = CALENDAR_CONTENT_PATH, content_override: Dictionary = {}) -> void:
	var raw := content_override if not content_override.is_empty() else _read_content_file(content_path)
	_day_length_ticks = maxi(1, int(raw.get("day_length_ticks", 1)))
	var windows: Array[Dictionary] = []
	if typeof(raw.get("windows")) == TYPE_ARRAY:
		for entry in raw["windows"]:
			if typeof(entry) == TYPE_DICTIONARY:
				windows.append(entry)
	_windows = windows

func day_length_ticks() -> int:
	return _day_length_ticks

## Read-only copy of the loaded windows, for tests that want to check
## calendar.json's shape without re-parsing the file themselves.
func window_definitions() -> Array[Dictionary]:
	return _windows.duplicate(true)

## Day 1 covers ticks [0, day_length_ticks).
func day_of_tick(tick: int) -> int:
	return int(floor(float(maxi(tick, 0)) / float(_day_length_ticks))) + 1

## Sum of every window's boost whose labour matches and whose [from, to]
## (inclusive) contains the tick's day; 0 when no window matches.
func active_boost(labour: String, tick: int) -> int:
	var day := day_of_tick(tick)
	var total := 0
	for window in _windows:
		if String(window.get("labour", "")) != labour:
			continue
		if day >= int(window.get("from", 0)) and day <= int(window.get("to", 0)):
			total += int(window.get("boost", 0))
	return total

## The soonest not-yet-open window; due only when it opens in exactly ALERT_LEAD_DAYS, nobody has
## its labour enabled, there is a plowed plot and seed stock, and it has not fired. Colony facts
## are plain booleans so this stays independent of WorldState.
func alert_state(tick: int, has_labour_enabled: bool, has_plowed_plot: bool, has_seed_stock: bool,
		already_fired: bool) -> Dictionary:
	var day := day_of_tick(tick)
	var best_window: Dictionary = {}
	var best_days_until := -1
	for window in _windows:
		var days_until: int = int(window.get("from", 0)) - day
		if days_until < 0:
			continue
		if best_window.is_empty() or days_until < best_days_until:
			best_window = window
			best_days_until = days_until
	if best_window.is_empty():
		return {"due": false, "window_label": "", "days_until": -1}
	var due := not already_fired and not has_labour_enabled and has_plowed_plot and has_seed_stock \
		and best_days_until == ALERT_LEAD_DAYS
	return {"due": due, "window_label": String(best_window.get("label", "")), "days_until": best_days_until}

func _read_content_file(content_path: String) -> Dictionary:
	var file := FileAccess.open(content_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
