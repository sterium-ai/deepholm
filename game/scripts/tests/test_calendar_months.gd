extends SceneTree

## F0 (ADR 060): months and years on top of the day count. content/calendar.json
## declares 3 days per month and 12 months per year; CalendarService derives month and
## year from the day number (nothing new is stored), a window may be declared by
## from_month/to_month and then matches exactly the ticks of the equivalent day range,
## WorldState.get_view_snapshot() carries the date of the world's own calendar, and the
## viewer's information column shows "day D · month M · year Y" plus the open window.

const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const InfoPanelType = preload("res://scripts/viewer/info_panel.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const FIXTURE_DIR := "user://test-calendar-months-content/"
const BOOT_SCENE_PATH := "res://scenes/boot.tscn"

var _failed := false

func _init() -> void:
	_check_content_declares_months_and_years()
	_check_month_and_year_of_tick()
	_check_date_is_deterministic()
	_check_month_window_matches_day_range()
	_check_registry_requires_one_complete_range()
	_check_month_window_through_world_ticks()
	_check_view_snapshot_carries_the_world_calendar_date()
	_check_viewer_date_label()
	if _failed:
		quit(1)
		return
	print("test_calendar_months: PASS")
	quit()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true

## The owner's calendar (BACKLOG F0, 2026-10-29): 3-day months, 12-month years, day length
## unchanged, and the sow window still declared by days 1-20.
func _check_content_declares_months_and_years() -> void:
	var calendar := CalendarServiceType.new()
	_expect(calendar.day_length_ticks() == 2200, "day_length_ticks stays 2200, got %d" % calendar.day_length_ticks())
	_expect(calendar.days_per_month() == 3, "a month is 3 days, got %d" % calendar.days_per_month())
	_expect(calendar.months_per_year() == 12, "a year is 12 months, got %d" % calendar.months_per_year())
	var windows := calendar.window_definitions()
	_expect(windows.size() == 1 and int(windows[0]["from"]) == 1 and int(windows[0]["to"]) == 20
		and not windows[0].has("from_month"), "sow stays declared as days 1-20, got %s" % [windows])

## Boundaries of the shipped calendar: every month's first and last tick, the year turn,
## and a tick far into the game.
func _check_month_and_year_of_tick() -> void:
	var calendar := CalendarServiceType.new()
	var day := 2200
	var cases := [
		[0, 1, 1, 1], [3 * day - 1, 3, 1, 1], [3 * day, 4, 2, 1], [6 * day, 7, 3, 1],
		[35 * day, 36, 12, 1], [36 * day - 1, 36, 12, 1], [36 * day, 37, 1, 2], [39 * day, 40, 2, 2],
		[72 * day, 73, 1, 3], [(36 * 9 + 34) * day + 5, 36 * 9 + 35, 12, 10], [-5, 1, 1, 1],
	]
	for case in cases:
		var date := calendar.date_of_tick(int(case[0]))
		_expect(int(date["day"]) == int(case[1]) and int(date["month"]) == int(case[2]) and int(date["year"]) == int(case[3]),
			"tick %d must be day %d month %d year %d, got %s" % [case[0], case[1], case[2], case[3], date])
		_expect(calendar.month_of_tick(int(case[0])) == int(case[2]) and calendar.year_of_tick(int(case[0])) == int(case[3]),
			"month_of_tick/year_of_tick must agree with date_of_tick at tick %d" % int(case[0]))
	_expect(String(calendar.date_of_tick(19 * day)["window_label"]) == "calendar.window.sow", "day 20 is inside sow")
	_expect(String(calendar.date_of_tick(20 * day)["window_label"]) == "", "day 21 is past sow")

## An independent walk (one day at a time, counting months and years by hand) agrees with
## two separately built services at every day's first and last tick for three years.
func _check_date_is_deterministic() -> void:
	var first := CalendarServiceType.new()
	var second := CalendarServiceType.new()
	var day_length := first.day_length_ticks()
	var month := 1
	var year := 1
	var day_in_month := 1
	for day in range(1, 36 * 3 + 1):
		for tick in [(day - 1) * day_length, day * day_length - 1]:
			var date := first.date_of_tick(tick)
			_expect(date == second.date_of_tick(tick), "two services must agree at tick %d" % tick)
			_expect(int(date["day"]) == day and int(date["month"]) == month and int(date["year"]) == year,
				"tick %d: expected day %d month %d year %d, got %s" % [tick, day, month, year, date])
		day_in_month += 1
		if day_in_month > 3:
			day_in_month = 1
			month += 1
			if month > 12:
				month = 1
				year += 1

func _calendar_with(window: Dictionary, day_length: int = 10) -> CalendarServiceType:
	var entry := {"id": "w", "labour": "farm", "boost": 2, "label": "test window"}
	entry.merge(window)
	return CalendarServiceType.new("", {"day_length_ticks": day_length, "days_per_month": 3, "months_per_year": 12,
		"windows": [entry]})

## Months 3-5 are days 7-15: every query answers the same on every tick of the first two
## years, and the month window reports the day range it was converted to.
func _check_month_window_matches_day_range() -> void:
	var by_month := _calendar_with({"from_month": 3, "to_month": 5})
	var by_day := _calendar_with({"from": 7, "to": 15})
	var defined: Dictionary = by_month.window_definitions()[0]
	_expect(int(defined["from"]) == 7 and int(defined["to"]) == 15, "months 3-5 are days 7-15, got %s" % defined)
	var active_ticks := 0
	for tick in range(0, 72 * 10):
		_expect(by_month.active_boost("farm", tick) == by_day.active_boost("farm", tick),
			"active_boost differs at tick %d" % tick)
		_expect(by_month.date_of_tick(tick) == by_day.date_of_tick(tick), "date_of_tick differs at tick %d" % tick)
		_expect(by_month.alert_state(tick, false, true, true, false) == by_day.alert_state(tick, false, true, true, false),
			"alert_state differs at tick %d" % tick)
		if by_month.active_boost("farm", tick) > 0:
			active_ticks += 1
	_expect(active_ticks == 9 * 10, "the window is open for 9 days of 10 ticks, got %d ticks" % active_ticks)
	_expect(by_month.active_boost("farm", 59) == 0 and by_month.active_boost("farm", 60) == 2
		and by_month.active_boost("farm", 149) == 2 and by_month.active_boost("farm", 150) == 0,
		"the window opens at tick 60 (day 7) and closes after tick 149 (day 15)")

## The schema's oneOf (exactly one complete pair, from/to or from_month/to_month) is not part of
## ContentRegistry's schema subset, so the registry checks it itself: a bundle whose calendar.json
## has a half pair, a mixed pair, both pairs or no range at all is rejected as schema_violation,
## and a month window loads and converts like its day range.
func _check_registry_requires_one_complete_range() -> void:
	var base := {"id": "w", "labour": "farm", "boost": 1, "label": "test window"}
	var rejected := [{"from_month": 2}, {"from": 4, "to_month": 3}, {"from": 4, "to": 9, "from_month": 2, "to_month": 3},
		{}, {"to": 9}]
	for ranges: Dictionary in rejected:
		var window := base.duplicate()
		window.merge(ranges)
		var registry := _registry_with_windows([window])
		if registry == null:
			return
		var error := registry.get_error()
		_expect(not registry.is_valid() and error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION
			and error.get("file") == "calendar.json", "window %s must be rejected as schema_violation, got %s" % [ranges, error])
		_expect(CalendarServiceType.window_range_error({"windows": [window]}) != "", "window_range_error must flag %s" % [ranges])
	var by_month := base.duplicate()
	by_month.merge({"from_month": 2, "to_month": 3})
	var registry := _registry_with_windows([by_month])
	if registry == null:
		return
	_expect(registry.is_valid(), "a complete month range must load, got %s" % [registry.get_error()])
	if registry.is_valid():
		var calendar := CalendarServiceType.new("", registry.document("calendar"))
		var defined: Dictionary = calendar.window_definitions()[0]
		_expect(int(defined["from"]) == 4 and int(defined["to"]) == 9, "months 2-3 load as days 4-9, got %s" % defined)
	_expect(ContentRegistryType.new().is_valid(), "the shipped content still loads")

## A copy of res://content/ whose calendar.json has `windows` (3-day months, 12-month years), or
## null after recording a failure when the fixture cannot be written (a read-only user:// must fail
## the test, not skip the registry checks and still print PASS).
func _registry_with_windows(windows: Array) -> ContentRegistryType:
	var made := DirAccess.make_dir_recursive_absolute(FIXTURE_DIR)
	_expect(made == OK, "could not create %s: %s" % [FIXTURE_DIR, error_string(made)])
	var copied := 0
	for file_name in DirAccess.get_files_at("res://content/"):
		if file_name.ends_with(".json"):
			var result := DirAccess.copy_absolute("res://content/" + file_name, FIXTURE_DIR + file_name)
			_expect(result == OK, "could not copy %s into %s: %s" % [file_name, FIXTURE_DIR, error_string(result)])
			copied += 1 if result == OK else 0
	_expect(copied > 0, "no content file was copied into %s" % FIXTURE_DIR)
	var file := FileAccess.open(FIXTURE_DIR + "calendar.json", FileAccess.WRITE)
	_expect(file != null, "could not write %scalendar.json: %s" % [FIXTURE_DIR, error_string(FileAccess.get_open_error())])
	if _failed or file == null:
		return null
	file.store_string(JSON.stringify({"day_length_ticks": 2200, "days_per_month": 3, "months_per_year": 12,
		"windows": windows}))
	file.close()
	return ContentRegistryType.new(FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)

## Through WorldState.tick(): a month-declared window raises the farm boost and fires its
## calendar_alert on the same ticks as the equivalent day-declared window.
func _check_month_window_through_world_ticks() -> void:
	var traces: Array = []
	for window in [{"from_month": 4, "to_month": 5}, {"from": 10, "to": 15}]:
		var world := WorldStateType.new()
		TestAccess.set_calendar(world, _calendar_with(window))
		for colonist in world.get_colonists():
			world.apply({"actor": "test", "command_id": "zero_farm_%s" % colonist["id"], "tick": world.get_tick(),
				"type": "set_labour", "payload": {"colonist": colonist["id"], "kind": "farm", "level": 0}})
		TestAccess.set_tile(world, 0, 0, WorldStateType.TILE_PLOWED_SOIL)
		TestAccess.item_table(world).items["item_1"] = {"id": "item_1", "x": 1, "y": 0, "kind": "seed", "count": 1}
		TestAccess.item_table(world).next_item_id = 2
		var boosts: Array[int] = []
		for _i in 170:
			world.tick()
			boosts.append(world.get_active_calendar_boost("farm"))
		var alert_ticks: Array[int] = []
		for event in world.get_events(["calendar_alert"]):
			alert_ticks.append(int(event["tick"]))
		traces.append({"boosts": boosts, "alerts": alert_ticks, "hash": world.state_hash()})
	_expect(traces[0]["boosts"] == traces[1]["boosts"], "the farm boost must follow the same ticks")
	_expect(traces[0]["alerts"] == [60] and traces[1]["alerts"] == [60],
		"both windows alert once at tick 60 (day 7), got %s and %s" % [traces[0]["alerts"], traces[1]["alerts"]])
	_expect(traces[0]["hash"] == traces[1]["hash"], "month and day declarations must leave the same state_hash()")

## The snapshot's date comes from the world's own calendar (a test calendar here, not the
## shipped one) and follows the ticks.
func _check_view_snapshot_carries_the_world_calendar_date() -> void:
	var world := WorldStateType.new()
	_expect(world.get_view_snapshot()["date"] == {"day": 1, "month": 1, "year": 1, "window_label": "calendar.window.sow"},
		"a new world is on day 1, month 1, year 1 in the sow window, got %s" % [world.get_view_snapshot()["date"]])
	TestAccess.set_calendar(world, CalendarServiceType.new("", {"day_length_ticks": 2, "days_per_month": 3,
		"months_per_year": 2, "windows": [{"id": "w", "labour": "farm", "from_month": 2, "to_month": 2, "boost": 1,
		"label": "test window"}]}))
	var expected := [
		[0, {"day": 1, "month": 1, "year": 1, "window_label": ""}],
		[6, {"day": 4, "month": 2, "year": 1, "window_label": "test window"}],
		[12, {"day": 7, "month": 1, "year": 2, "window_label": ""}],
	]
	for row in expected:
		while world.get_tick() < int(row[0]):
			world.tick()
		var date: Dictionary = world.get_view_snapshot()["date"]
		_expect(date == row[1], "tick %d: expected %s, got %s" % [row[0], row[1], date])
		_expect(date.is_read_only(), "the snapshot's date is read-only like the rest of it")

## The boot scene's information column shows the date line from the snapshot, with the
## window label resolved through the text table, and follows the world as it ticks.
func _check_viewer_date_label() -> void:
	var boot_scene: PackedScene = load(BOOT_SCENE_PATH)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	boot_node.save_manager = SaveManagerType.new()
	boot_node.call("_build_ui")
	var panel: InfoPanelType = boot_node.get("_ui_scroll")
	var text_table := TextTableType.new("en")
	var sow_text := text_table.get_string("calendar.window.sow")
	var opening := text_table.format("calendar.date_window_label", [1, 1, 1, sow_text])
	_expect(panel.date_label.text == opening, "the date line must read '%s', got '%s'" % [opening, panel.date_label.text])
	_expect(opening.contains("1") and opening.contains(sow_text), "the date line names the open window")
	var world: WorldStateType = boot_node.get("world")
	TestAccess.set_calendar(world, CalendarServiceType.new("", {"day_length_ticks": 2, "days_per_month": 3,
		"months_per_year": 12, "windows": []}))
	for _i in 8:
		world.tick()
	boot_node.call("_refresh")
	var later := text_table.format("calendar.date_label", [5, 2, 1])
	_expect(panel.date_label.text == later, "after 8 ticks of 2 the line must read '%s', got '%s'" % [later, panel.date_label.text])
	boot_node.queue_free()
