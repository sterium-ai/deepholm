extends SceneTree

## Exercises CalendarService (colonist-ai.md 3.7): content/calendar.json
## declares a day length in ticks (2200, issue #349/ADR 023) and one boost
## window ("sow", spring days 1-20, unchanged by issue #349 since from/to are
## day numbers per ADR 008, not ticks -- +1 to farm, "sowing window");
## active_boost() must return that boost for every tick inside the window and
## 0 outside it or for any other labour; alert_state() must report due=true
## only N days before a window
## opens (N = CalendarService.ALERT_LEAD_DAYS, fixed and asserted below) when
## nobody has the window's labour enabled and the colony already has both a
## plowed plot and seed stock, and due=false once already_fired is true.
## Because the seed window opens on day 1 (no earlier day exists to warn
## from), the alert timing checks use a synthetic window (content_override)
## instead of content/calendar.json's real one -- see calendar_service.gd's
## _init() docstring.
##
## Also exercises CalendarAlertGiver (issue #269, ADR 008 consequence 6),
## wired into WorldState.tick() as the job-giver for this alert: it computes
## has_labour_enabled/has_plowed_plot/has_seed_stock from real colony state,
## calls CalendarService.alert_state(), and emits a one-shot "calendar_alert"
## event through the same _insert_event()/get_events() mechanism every other
## WorldState event uses. These checks override world._calendar with the
## same kind of synthetic window content the pure alert-timing checks above
## use, for the same reason (content/calendar.json's real "sow" window opens
## too early to ever be due).

const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CALENDAR_CONTENT_PATH := "res://content/calendar.json"

var _failed := false

func _init() -> void:
	_check_calendar_content_file()
	_check_active_boost_inside_and_outside_window()
	_check_alert_state_due_only_under_all_conditions()
	_check_alert_state_not_due_once_already_fired()
	_check_world_state_no_alert_without_plowed_plot_or_seed_stock()
	_check_world_state_alert_fires_once_when_conditions_met()
	_check_world_state_labour_enabled_suppresses_alert()
	_check_world_state_alert_fires_with_carried_seed()
	_check_fired_alert_survives_save_restore()

	if _failed:
		quit(1)
		return
	print("test_calendar: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## game/content/calendar.json must declare day_length_ticks 2200 (issue
## #349/ADR 023) and exactly one window: sow/farm/1-20/+1/"sowing window".
## from/to are day numbers per ADR 008, not ticks, so day_length_ticks
## changing from 100 to 2200 does not rescale them.
func _check_calendar_content_file() -> void:
	if _failed:
		return
	var file := FileAccess.open(CALENDAR_CONTENT_PATH, FileAccess.READ)
	_expect(file != null, "could not open %s" % CALENDAR_CONTENT_PATH)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	_expect(typeof(parsed) == TYPE_DICTIONARY, "%s must contain a top-level object" % CALENDAR_CONTENT_PATH)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var day_length = parsed.get("day_length_ticks")
	_expect(typeof(day_length) == TYPE_FLOAT or typeof(day_length) == TYPE_INT,
		"calendar.json must declare a numeric 'day_length_ticks'")
	_expect(int(day_length) == 2200, "calendar.json's day_length_ticks must be 2200 (issue #349), got %s" % day_length)
	var windows = parsed.get("windows")
	_expect(typeof(windows) == TYPE_ARRAY and windows.size() == 1,
		"calendar.json must declare exactly one window, got %s" % [windows])
	if typeof(windows) != TYPE_ARRAY or windows.size() != 1:
		return
	var window: Dictionary = windows[0]
	_expect(String(window.get("id")) == "sow", "the seed window's id must be 'sow'")
	_expect(String(window.get("labour")) == "farm", "the seed window's labour must be 'farm'")
	_expect(int(window.get("from")) == 1, "the seed window must start at day 1 (spring day 1)")
	_expect(int(window.get("to")) == 20,
		"the seed window must end at day 20, unchanged by issue #349 since from/to are day numbers (ADR 008), not ticks")
	_expect(int(window.get("boost")) == 1, "the seed window's boost must be +1")
	_expect(String(window.get("label")) == "sowing window", "the seed window's label must be 'sowing window'")

## active_boost('farm', tick) must be 1 for every tick inside spring days
## 1-20 and 0 for every tick on day 21 or any other labour. Exhaustively
## walks every tick from day 1 through the end of day 21 at the new
## 2200-tick day length (21 * 2200 = 46200 ticks), same as before issue #349
## rescaled the day length, not weakened to sampling.
func _check_active_boost_inside_and_outside_window() -> void:
	if _failed:
		return
	var calendar := CalendarServiceType.new()
	var day_length := calendar.day_length_ticks()
	var windows := calendar.window_definitions()
	_expect(windows.size() == 1, "the real calendar content must declare exactly one window")
	if windows.size() != 1:
		return
	var window_from := int(windows[0]["from"])
	var window_to := int(windows[0]["to"])
	_expect(window_from == 1 and window_to == 20,
		"expected the seed window to span days 1-20, got %d-%d" % [window_from, window_to])
	var window_end_tick := window_to * day_length - 1
	var day_21_end_tick := (window_to + 1) * day_length - 1

	for tick in range(0, window_end_tick + 1):
		_expect(calendar.active_boost("farm", tick) == 1,
			"active_boost('farm', %d) must be 1 inside spring days 1-%d" % [tick, window_to])
		_expect(calendar.active_boost("mine", tick) == 0,
			"active_boost('mine', %d) must be 0: the window only boosts farm" % tick)

	for tick in range(window_end_tick + 1, day_21_end_tick + 1):
		_expect(calendar.active_boost("farm", tick) == 0,
			"active_boost('farm', %d) must be 0 on day %d (outside spring days 1-%d)" % [tick, window_to + 1, window_to])
		_expect(calendar.active_boost("mine", tick) == 0,
			"active_boost('mine', %d) must be 0: no window ever boosts mine" % tick)

	var far_outside_ticks: Array[int] = [day_21_end_tick + day_length, day_21_end_tick * 5]
	for tick in far_outside_ticks:
		_expect(calendar.active_boost("farm", tick) == 0,
			"active_boost('farm', %d) must be 0 well outside spring days 1-%d" % [tick, window_to])
		_expect(calendar.active_boost("mine", tick) == 0,
			"active_boost('mine', %d) must be 0: no window ever boosts mine" % tick)

## alert_state() timing, using a synthetic window far enough from day 1 that
## "N days before it opens" (N = CalendarService.ALERT_LEAD_DAYS) is a valid,
## representable day. The window opens on day 10; the due tick is therefore
## day (10 - N).
func _check_alert_state_due_only_under_all_conditions() -> void:
	if _failed:
		return
	var day_length := 100
	var calendar := CalendarServiceType.new("", {
		"day_length_ticks": day_length,
		"windows": [{"labour": "farm", "from": 10, "to": 15, "boost": 2, "label": "test window"}],
	})
	var n := CalendarServiceType.ALERT_LEAD_DAYS
	_expect(n > 0, "ALERT_LEAD_DAYS must be a positive number of days")
	var due_day := 10 - n
	_expect(due_day >= 1, "test window's from (10) must leave room for %d lead days" % n)
	var due_tick := (due_day - 1) * day_length

	var due_state := calendar.alert_state(due_tick, false, true, true, false)
	_expect(bool(due_state["due"]) == true,
		"alert_state must be due exactly %d days before the window opens, got %s" % [n, due_state])
	_expect(String(due_state["window_label"]) == "test window", "due alert must report the window's label")
	_expect(int(due_state["days_until"]) == n, "due alert must report days_until == %d" % n)

	var labour_enabled := calendar.alert_state(due_tick, true, true, true, false)
	_expect(bool(labour_enabled["due"]) == false,
		"alert_state must not be due when a colonist already has the window's labour enabled")

	var no_plot := calendar.alert_state(due_tick, false, false, true, false)
	_expect(bool(no_plot["due"]) == false, "alert_state must not be due without a plowed plot")

	var no_seed := calendar.alert_state(due_tick, false, true, false, false)
	_expect(bool(no_seed["due"]) == false, "alert_state must not be due without seed stock")

	var wrong_tick := calendar.alert_state(due_tick - day_length, false, true, true, false)
	_expect(bool(wrong_tick["due"]) == false,
		"alert_state must not be due at a tick other than exactly %d days before the window" % n)

## Once already_fired is true, alert_state must report due=false even at the
## exact due tick with every other condition satisfied.
func _check_alert_state_not_due_once_already_fired() -> void:
	if _failed:
		return
	var day_length := 100
	var calendar := CalendarServiceType.new("", {
		"day_length_ticks": day_length,
		"windows": [{"labour": "farm", "from": 10, "to": 15, "boost": 2, "label": "test window"}],
	})
	var n := CalendarServiceType.ALERT_LEAD_DAYS
	var due_tick := (10 - n - 1) * day_length

	var fired_state := calendar.alert_state(due_tick, false, true, true, true)
	_expect(bool(fired_state["due"]) == false,
		"alert_state must not be due once already_fired is true, got %s" % fired_state)

## A synthetic single-window calendar (day_length_ticks=10, window "from" 10
## "to" 15) whose due tick -- day (10 - ALERT_LEAD_DAYS), i.e. day 7 -- lands
## at tick 60, small enough to tick through quickly while still leaving room
## for the lead days, same shape as _check_alert_state_due_only_under_all_conditions()'s
## synthetic window above.
func _synthetic_alert_world(window_id: String) -> WorldStateType:
	var world := WorldStateType.new()
	world._calendar = CalendarServiceType.new("", {
		"day_length_ticks": 10,
		"windows": [{"id": window_id, "labour": "farm", "from": 10, "to": 15, "boost": 2, "label": "test window"}],
	})
	for colonist in world.get_colonists():
		world.apply({
			"actor": "test", "command_id": "zero_farm_%s" % colonist["id"], "tick": world.get_tick(),
			"type": "set_labour", "payload": {"colonist": colonist["id"], "kind": "farm", "level": 0},
		})
	return world

func _calendar_alert_events(world: WorldStateType, window_id: String) -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	for event in world.get_events():
		if String(event["type"]) == "calendar_alert" and String(event["data"]["id"]) == window_id:
			matches.append(event)
	return matches

## WorldState must never emit "calendar_alert" for a window whose lead time
## is otherwise due -- every colonist's farm labour already at 0 -- when the
## colony has neither a plowed plot nor seed stock (colonist-ai.md 3.7): the
## alert's due conditions require both, and a freshly generated WorldState
## has neither by default.
func _check_world_state_no_alert_without_plowed_plot_or_seed_stock() -> void:
	if _failed:
		return
	var window_id := "no_conditions_test"
	var world := _synthetic_alert_world(window_id)
	for _i in 80:
		world.tick()
	_expect(_calendar_alert_events(world, window_id).is_empty(),
		"WorldState must never emit calendar_alert without a plowed plot and seed stock, got %s"
			% [_calendar_alert_events(world, window_id)])

## With every colonist's farm labour at 0, a plowed_soil tile, and a seed
## item present, WorldState must emit exactly one "calendar_alert" event at
## the due tick (day 7, tick 60) and none on any later tick, since the
## window has only one occurrence and its already_fired flag suppresses
## every subsequent tick within the same due day (colonist-ai.md 3.7, ADR
## 008 consequence 6).
func _check_world_state_alert_fires_once_when_conditions_met() -> void:
	if _failed:
		return
	var window_id := "fires_once_test"
	var world := _synthetic_alert_world(window_id)
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_1"] = {"id": "item_1", "x": 1, "y": 0, "kind": "seed", "count": 1}
	world._next_item_id = 2
	for _i in 80:
		world.tick()
	var events := _calendar_alert_events(world, window_id)
	_expect(events.size() == 1, "WorldState must emit exactly one calendar_alert event, got %d: %s"
		% [events.size(), events])
	if events.size() != 1:
		return
	var event: Dictionary = events[0]
	_expect(int(event["tick"]) == 60, "calendar_alert must fire at the due tick (60), got %d" % int(event["tick"]))
	var data: Dictionary = event["data"]
	_expect(String(data["id"]) == window_id, "calendar_alert data must carry the window's id")
	_expect(String(data["label"]) == "test window", "calendar_alert data must carry the window's label")
	_expect(int(data["days_until"]) == CalendarServiceType.ALERT_LEAD_DAYS,
		"calendar_alert data must carry days_until == ALERT_LEAD_DAYS")

## Giving one colonist a positive farm labour level before the due tick must
## suppress the alert entirely for that window occurrence, even though a
## plowed plot and seed stock are both present (colonist-ai.md 3.7): the
## window never opens again after this single occurrence, so there is no
## later tick where it could still fire.
func _check_world_state_labour_enabled_suppresses_alert() -> void:
	if _failed:
		return
	var window_id := "labour_suppresses_test"
	var world := _synthetic_alert_world(window_id)
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_1"] = {"id": "item_1", "x": 1, "y": 0, "kind": "seed", "count": 1}
	world._next_item_id = 2
	for _i in 10:
		world.tick()
	var colonists := world.get_colonists()
	_expect(not colonists.is_empty(), "expected at least one colonist")
	if colonists.is_empty():
		return
	var enable_result := world.apply({
		"actor": "test", "command_id": "enable_farm", "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": colonists[0]["id"], "kind": "farm", "level": 2},
	})
	_expect(enable_result.get("ok", false), "set_labour setup must be accepted: %s" % enable_result)
	for _i in 70:
		world.tick()
	_expect(_calendar_alert_events(world, window_id).is_empty(),
		"WorldState must not emit calendar_alert once a colonist's farm labour is enabled before the due tick, got %s"
			% [_calendar_alert_events(world, window_id)])

## Round 3 review regression: _has_seed_stock must count a seed mid-haul in a
## colonist's carrying slot, not only a ground/stockpile item -- the exact
## ground+carrying query world_state.gd's _has_item_of_kind docstring
## promises and sow's own blocked_missing_input precondition already relies
## on. Places the colony's only seed in colonist 0's carrying slot (never in
## world._items) with a plowed plot present and every colonist's farm labour
## at 0, then checks: the alert still fires exactly once at the due tick and
## never repeats, and the seed is still in the carrying slot afterwards (this
## check never consumes it). A ground-only _has_seed_stock query would see no
## seed anywhere and never fire, so this fails against that regression.
func _check_world_state_alert_fires_with_carried_seed() -> void:
	if _failed:
		return
	var window_id := "carried_seed_test"
	var world := _synthetic_alert_world(window_id)
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_PLOWED_SOIL
	var colonists := world.get_colonists()
	_expect(not colonists.is_empty(), "expected at least one colonist")
	if colonists.is_empty():
		return
	var carrier_id := String(colonists[0]["id"])
	for colonist in world._colonists:
		if String(colonist["id"]) == carrier_id:
			InventoryType.add_to_hands(colonist, "seed", 1)
	_expect(world._items.is_empty(),
		"setup must place the colony's only seed in a carrying slot, none on the ground, got %s" % [world._items])
	for _i in 80:
		world.tick()
	var events := _calendar_alert_events(world, window_id)
	_expect(events.size() == 1,
		"WorldState must emit exactly one calendar_alert event for a seed carried (not on the ground), got %d: %s"
			% [events.size(), events])
	var still_carrying_seed := false
	for colonist in world._colonists:
		if String(colonist["id"]) == carrier_id:
			still_carrying_seed = InventoryType.has_kind(colonist, "seed")
	_expect(still_carrying_seed,
		"the carried seed must still be in the carrying slot (this check never consumes it)")
	_expect(world._items.is_empty(),
		"the carried seed must never have been placed on the ground by this check, got %s" % [world._items])

## Round 2 review regression: already_fired is real persisted state
## (calendarAlerts.fired, ADR 008 consequence 6), not an in-memory flag a
## reload conveniently resets. Fires the alert, saves through
## WorldState.to_save_state(), restores through WorldState.from_save_state(),
## reinstalls the same synthetic calendar on the restored world (from_save_state
## always rebuilds _calendar from real content, since the calendar definition
## itself is content, not save data), and checks: the saved state's
## calendarAlerts.fired array carries the window id; the restored world's
## state_hash() matches the source's (calendar_alerts_fired is part of the
## state_hash() snapshot); and ticking the restored world well past the
## window's own occurrence never re-emits calendar_alert for it.
func _check_fired_alert_survives_save_restore() -> void:
	if _failed:
		return
	var window_id := "save_restore_test"
	var world := _synthetic_alert_world(window_id)
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_1"] = {"id": "item_1", "x": 1, "y": 0, "kind": "seed", "count": 1}
	world._next_item_id = 2
	for _i in 60:
		world.tick()
	var pre_save_events := _calendar_alert_events(world, window_id)
	_expect(pre_save_events.size() == 1,
		"setup must fire exactly one calendar_alert before saving, got %d: %s" % [pre_save_events.size(), pre_save_events])

	var saved := world.to_save_state()
	var fired_ids: Array = saved["calendarAlerts"]["fired"]
	_expect(fired_ids.has(window_id),
		"saved state must persist the fired window id '%s', got %s" % [window_id, fired_ids])

	var restored := WorldStateType.from_save_state(saved)
	restored._calendar = CalendarServiceType.new("", {
		"day_length_ticks": 10,
		"windows": [{"id": window_id, "labour": "farm", "from": 10, "to": 15, "boost": 2, "label": "test window"}],
	})
	_expect(restored.state_hash() == world.state_hash(),
		"restoring a fired alert must keep state_hash matching the source, since calendar_alerts_fired is part of the hash")

	for _i in 70:
		restored.tick()
	_expect(_calendar_alert_events(restored, window_id).is_empty(),
		"a restored world must never re-fire an already-fired calendar alert, got %s"
			% [_calendar_alert_events(restored, window_id)])
