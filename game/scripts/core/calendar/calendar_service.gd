class_name CalendarService
extends RefCounted

## Calendar content and pure calendar queries (colonist-ai.md 3.7): content
## declares a day length in ticks and a list of labour boost windows
## ({labour, from, to, boost, label}, day numbers 1-indexed and inclusive).
## No season-length content exists yet (no other subsystem tracks seasons),
## so a window's "from"/"to" are plain day-of-year numbers and day 1 is
## documented here as spring day 1 -- the seed window ("sow", days 1-20)
## is exactly colonist-ai.md's "spring days 1-20" under that reading. A
## later task adding more seasons only needs to add windows whose day
## numbers account for the seasons that come before them; this service does
## not need to change.
##
## Like ToilExecutor/WorldState's own content loaders, this class reads
## CALENDAR_CONTENT_PATH once, in the constructor, and caches it; every
## method after that (day_of_tick, active_boost, alert_state) is a pure
## function of its arguments and the cached content -- no FileAccess,
## RandomNumberGenerator or OS time anywhere else in this file.

const CALENDAR_CONTENT_PATH := "res://content/calendar.json"

## alert_state() reports a window as "due" exactly this many days before it
## opens (colonist-ai.md 3.7: "warns N days before a window"). Fixed here so
## test_calendar.gd can assert against the same constant instead of a
## hand-copied literal.
const ALERT_LEAD_DAYS := 3

var _day_length_ticks: int = 1
var _windows: Array[Dictionary] = []

## content_override lets a test exercise this class's pure logic against a
## synthetic window list (e.g. one whose "from" is far enough from day 1 to
## show a due alert) without writing a second content file; production code
## always uses the zero-argument form, which loads CALENDAR_CONTENT_PATH.
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

## Pure day-of-tick lookup: day 1 covers ticks [0, day_length_ticks), day 2
## the next day_length_ticks ticks, and so on -- driven only by the
## content-injected day length and the tick passed in.
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

## Reports on the soonest not-yet-open window (the one with the smallest
## non-negative days_until at this tick). due is true only when that window
## is exactly ALERT_LEAD_DAYS days from opening, nobody already has its
## labour enabled, the colony already has both a plowed plot and seed
## stock, and the window has not already fired. Colony facts are taken as
## plain booleans (not read from WorldState) so this stays wireable by a
## later task without depending on colonist or farm-order state existing.
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
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
