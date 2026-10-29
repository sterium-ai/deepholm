class_name CalendarService
extends RefCounted

## Calendar content and pure calendar queries (colonist-ai.md 3.7, ADR 060): a day length in
## ticks, days per month and months per year, and labour boost windows ({labour, from, to, boost,
## label}, 1-indexed inclusive day numbers counted from the start of the game, or the same window
## declared as {from_month, to_month}). Day numbering is the only clock: month and year are derived
## from the day, so nothing about them is stored. Content is read once in the constructor; every
## query is a pure function.

const CALENDAR_CONTENT_PATH := "res://content/calendar.json"

## A window is "due" exactly this many days before it opens (colonist-ai.md 3.7).
const ALERT_LEAD_DAYS := 3

var _day_length_ticks: int = 1
var _days_per_month: int = 1
var _months_per_year: int = 1
var _windows: Array[Dictionary] = []

## content_override is for tests; production uses the zero-argument form.
func _init(content_path: String = CALENDAR_CONTENT_PATH, content_override: Dictionary = {}) -> void:
	var raw := content_override if not content_override.is_empty() else _read_content_file(content_path)
	_day_length_ticks = maxi(1, int(raw.get("day_length_ticks", 1)))
	_days_per_month = maxi(1, _int_of(raw.get("days_per_month", 1)))
	_months_per_year = maxi(1, _int_of(raw.get("months_per_year", 1)))
	var windows: Array[Dictionary] = []
	if typeof(raw.get("windows")) == TYPE_ARRAY:
		for entry: Variant in raw["windows"]:
			if typeof(entry) == TYPE_DICTIONARY:
				windows.append(_with_day_range(entry as Dictionary))
	_windows = windows

## A window declared by months gets the equivalent day range: month m covers days
## (m - 1) * days_per_month + 1 .. m * days_per_month, so from_month 1, to_month 7 with 3-day
## months is from 1, to 21. Every query reads only from/to; a day-range window is kept as is.
func _with_day_range(entry: Dictionary) -> Dictionary:
	if not (entry.has("from_month") and entry.has("to_month")):
		return entry
	var window := entry.duplicate(true)
	window["from"] = (_int_of(entry["from_month"]) - 1) * _days_per_month + 1
	window["to"] = _int_of(entry["to_month"]) * _days_per_month
	return window

## A content number as an int: parsed JSON gives floats, ContentRegistry and tests ints.
static func _int_of(value: Variant) -> int:
	if value is float:
		return int(value as float)
	return value as int

func day_length_ticks() -> int:
	return _day_length_ticks

func days_per_month() -> int:
	return _days_per_month

func months_per_year() -> int:
	return _months_per_year

## Read-only copy of the loaded windows (a month-declared one with its from/to added), for
## tests that want to check calendar.json's shape without re-parsing the file themselves.
func window_definitions() -> Array[Dictionary]:
	return _windows.duplicate(true)

## Day 1 covers ticks [0, day_length_ticks).
func day_of_tick(tick: int) -> int:
	return int(floor(float(maxi(tick, 0)) / float(_day_length_ticks))) + 1

## Month of the year, 1..months_per_year: day 1 is month 1 of year 1.
func month_of_tick(tick: int) -> int:
	return floori(float(day_of_tick(tick) - 1) / float(_days_per_month)) % _months_per_year + 1

## Year, from 1: a year is days_per_month * months_per_year days.
func year_of_tick(tick: int) -> int:
	return floori(float(day_of_tick(tick) - 1) / float(_days_per_month * _months_per_year)) + 1

## The tick's date for display: {day, month, year, window_label}, where day is the day
## number from the start (day_of_tick), and window_label the label of the first window, in
## declaration order, whose [from, to] contains that day ("" when none is open).
func date_of_tick(tick: int) -> Dictionary:
	var day := day_of_tick(tick)
	var window_label := ""
	for window in _windows:
		if day >= _int_of(window.get("from", 0)) and day <= _int_of(window.get("to", 0)):
			window_label = str(window.get("label", ""))
			break
	return {"day": day, "month": month_of_tick(tick), "year": year_of_tick(tick), "window_label": window_label}

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
