extends SceneTree

## Coverage for the work table panel (colonist-ai.md 3.2/3.7/3.8's "work
## table shows these active boosts" / labour priority grid / sowing
## calendar banner): WorkTablePanel must render exactly one row per colonist
## (world.get_colonists()) and one column per labour kind (WorldState.
## LABOUR_KINDS), reflect a labour's active calendar boost in its column
## header, cycle a cell's level through the documented order via the real
## set_labour command, and show/hide the calendar-alert banner per
## world.get_events() -- sticky until dismissed or replaced by a different
## alert, never via a panel-local CalendarService or day-based expiry. It also
## covers debug_scenario.gd's pre-plowed starting tile/seed stock (produced
## through world.apply()+world.tick()) and boot.gd's UI layout, which must
## keep the panel, its banner, and the till/sow buttons reachable within a
## scrollable content area.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const WorkTablePanelType = preload("res://scripts/viewer/work_table_panel.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")
const BootType = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const BOOT_SCENE_PATH := "res://scenes/boot.tscn"

var _failed := false

func _init() -> void:
	_check_grid_matches_colonists_and_labour_kinds()
	_check_cell_activation_cycles_level_via_set_labour()
	_check_calendar_boost_reflected_in_column_header()
	_check_banner_shows_most_recent_calendar_alert()
	_check_banner_hides_once_acknowledged()
	_check_banner_persists_across_ticks_without_day_based_expiry()
	_check_banner_replaced_by_different_alert_before_ack()
	_check_banner_replaced_by_different_alert_after_ack()
	_check_cell_button_survives_refresh_across_a_tick()
	_check_grid_reconciles_rows_when_colonist_set_changes()
	_check_debug_scenario_produces_plowed_tile_and_seed_stock_via_apply_and_tick()
	_check_ui_layout_places_new_controls_within_reachable_scroll_area()

	if _failed:
		quit(1)
		return
	print("test_work_table_panel: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _panel_for(world: WorldStateType) -> WorkTablePanelType:
	var panel := WorkTablePanelType.new()
	panel.setup(world, TextTableType.new())
	return panel

func _colonist_by_id(world: WorldStateType, id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == id:
			return colonist
	return {}

## The panel's row count must track world.get_colonists() exactly, and its
## column count the fixed labour-kind vocabulary -- every (colonist, labour)
## combination must have exactly one cell button.
func _check_grid_matches_colonists_and_labour_kinds() -> void:
	var world := WorldStateType.new(10001)
	var panel := _panel_for(world)
	var colonists := world.get_colonists()
	_expect(not colonists.is_empty(), "a fresh WorldState must spawn at least one colonist")

	var expected_cells := colonists.size() * WorldStateType.LABOUR_KINDS.size()
	_expect(panel.cell_count() == expected_cells,
		"panel must render exactly one cell per (colonist, labour) pair, expected %d got %d"
			% [expected_cells, panel.cell_count()])
	for colonist in colonists:
		for labour in WorldStateType.LABOUR_KINDS:
			_expect(panel._cell_button(String(colonist["id"]), labour) != null,
				"missing cell for colonist %s labour %s" % [colonist["id"], labour])

## Activating one cell five times in a row (no ticks between activations)
## must cycle its displayed level through 3 -> 4 -> off(0) -> 1 -> 2 -> 3,
## each step issuing a real set_labour command through world.apply() -- the
## colonist's own labourTable (read via get_colonists()) is the ground truth
## checked after each activation, and the last command_applied event in
## world.get_events() must carry that same set_labour payload.
func _check_cell_activation_cycles_level_via_set_labour() -> void:
	var world := WorldStateType.new(20001)
	var panel := _panel_for(world)
	var colonist_id := String(world.get_colonists()[0]["id"])
	var labour := "farm"

	_expect(int(_colonist_by_id(world, colonist_id)["labourTable"][labour]) == WorldStateType.LABOUR_DEFAULT,
		"a fresh colonist's labour level must start at the documented default (3)")

	var expected_sequence := [4, 0, 1, 2, 3]
	for expected_level in expected_sequence:
		panel._on_cell_pressed(colonist_id, labour)
		var actual_level := int(_colonist_by_id(world, colonist_id)["labourTable"][labour])
		_expect(actual_level == expected_level,
			"cycling must reach level %d next, got %d" % [expected_level, actual_level])

		var last_event: Dictionary = world.get_events()[-1]
		_expect(String(last_event["type"]) == "command_applied",
			"each activation must apply a command, last event type was %s" % last_event["type"])
		var data: Dictionary = last_event["data"]
		_expect(String(data["colonist"]) == colonist_id and String(data["kind"]) == labour and int(data["level"]) == expected_level,
			"the applied set_labour command must carry {colonist: %s, kind: %s, level: %d}, got %s"
				% [colonist_id, labour, expected_level, data])

		var displayed := panel._cell_button(colonist_id, labour).text
		var expected_text := "Off" if expected_level == 0 else str(expected_level)
		_expect(displayed == expected_text,
			"the cell must display '%s' after cycling to level %d, got '%s'" % [expected_text, expected_level, displayed])

## A fresh WorldState's default calendar content boosts "farm" by +1 for the
## whole seeded sowing window (spring days 1-20, which covers tick 0); the
## panel must show that in the "farm" column header without any extra setup,
## reading it from world.get_active_calendar_boost() as documented. A labour
## with no active window (e.g. "mine") must show no boost suffix.
func _check_calendar_boost_reflected_in_column_header() -> void:
	var world := WorldStateType.new(30001)
	_expect(world.get_active_calendar_boost("farm") == 1,
		"the seeded sowing window must boost farm by +1 at tick 0")
	var panel := _panel_for(world)
	_expect(panel._column_header_text("farm").find("(+1)") >= 0,
		"the farm column header must show the active +1 calendar boost, got '%s'" % panel._column_header_text("farm"))
	_expect(panel._column_header_text("mine").find("(+") < 0,
		"a labour with no active boost must show no boost suffix, got '%s'" % panel._column_header_text("mine"))

## Appends a synthetic calendar_alert event (the same {type, tick, data:
## {id, label, days_until}} shape CalendarAlertGiver emits) directly to
## world._events -- a test-only poke, same as test_calendar.gd's own direct
## WorldState-field setup, and outside scripts/viewer/'s purity scan since
## this file lives under scripts/tests/. The panel must reflect it without
## any special wiring beyond world.get_events().
func _fire_synthetic_alert(world: WorldStateType, tick: int, days_until: int, id: String = "sow", label: String = "sowing window") -> void:
	world._events.append({
		"type": "calendar_alert", "tick": tick, "system_priority": 0,
		"entity_id": "world", "sequence": world.get_events().size(),
		"data": {"id": id, "label": label, "days_until": days_until},
	})

func _check_banner_shows_most_recent_calendar_alert() -> void:
	var world := WorldStateType.new(40001)
	_fire_synthetic_alert(world, world.get_tick(), 3)
	var panel := _panel_for(world)
	_expect(panel._banner_label.visible, "the banner must be visible once a calendar_alert event exists")
	_expect(panel._banner_label.text.find("sowing window") >= 0 and panel._banner_label.text.find("3") >= 0,
		"the banner must show the alert's label and days_until, got '%s'" % panel._banner_label.text)

## Dismissing the banner (the button's own handler) must hide it even though
## the same calendar_alert event is still the most recent one in
## world.get_events() -- acknowledgement is sticky per alert.
func _check_banner_hides_once_acknowledged() -> void:
	var world := WorldStateType.new(50001)
	_fire_synthetic_alert(world, world.get_tick(), 3)
	var panel := _panel_for(world)
	_expect(panel._banner_label.visible, "setup: the banner must start visible")

	panel._dismiss_banner()
	_expect(not panel._banner_label.visible, "the banner must hide once dismissed")
	panel.refresh()
	_expect(not panel._banner_label.visible, "a later refresh with the same alert must keep the banner dismissed")

## WorldState exposes no getter for a calendar
## window's own "to" day or the current day number, so the panel must never
## expire the banner on its own -- it must stay visible across any number of
## ticks until the player dismisses it or a different alert arrives.
func _check_banner_persists_across_ticks_without_day_based_expiry() -> void:
	var world := WorldStateType.new(60001)
	_fire_synthetic_alert(world, world.get_tick(), 3)
	var panel := _panel_for(world)
	_expect(panel._banner_label.visible, "setup: the banner must start visible")

	for _i in 500:
		world.tick()
		panel.refresh()
	_expect(panel._banner_label.visible,
		"the banner must remain visible after many ticks with no day-based expiry (WorldState exposes no window 'to' day getter)")

## A different calendar_alert event (a distinct id) becoming the most recent
## one in world.get_events() must replace the banner's text and show it
## again, even though the original alert was never dismissed.
func _check_banner_replaced_by_different_alert_before_ack() -> void:
	var world := WorldStateType.new(70001)
	_fire_synthetic_alert(world, 0, 3, "sow", "sowing window")
	var panel := _panel_for(world)
	_expect(panel._banner_label.text.find("sowing window") >= 0, "setup: banner shows the first alert")

	_fire_synthetic_alert(world, 5, 1, "harvest", "harvest window")
	panel.refresh()
	_expect(panel._banner_label.visible, "a newer, different alert must show")
	_expect(panel._banner_label.text.find("harvest window") >= 0,
		"the banner must show the newer alert's own text, got '%s'" % panel._banner_label.text)

## Mirrors the check above, but the first alert was already dismissed --
## acknowledgement is per-alert (keyed on the alert's own id+tick), so a
## later, different alert must show again rather than staying suppressed by
## an earlier dismissal.
func _check_banner_replaced_by_different_alert_after_ack() -> void:
	var world := WorldStateType.new(80001)
	_fire_synthetic_alert(world, 0, 3, "sow", "sowing window")
	var panel := _panel_for(world)
	panel._dismiss_banner()
	_expect(not panel._banner_label.visible, "setup: banner is dismissed")

	_fire_synthetic_alert(world, 5, 1, "harvest", "harvest window")
	panel.refresh()
	_expect(panel._banner_label.visible,
		"a different alert arriving after an earlier one was dismissed must show again, not stay suppressed")
	_expect(panel._banner_label.text.find("harvest window") >= 0,
		"the banner must show the newer alert's own text, got '%s'" % panel._banner_label.text)

## boot.gd calls refresh() on every simulation tick;
## rebuilding every cell button on every such call would let a real
## press-then-release spanning a tick lose its button mid-press. A cell
## button visible before a tick must be the exact same node afterward, and
## pressing it (its `pressed` signal, the same one a real release fires)
## must still issue exactly one set_labour command.
func _check_cell_button_survives_refresh_across_a_tick() -> void:
	var world := WorldStateType.new(90001)
	var panel := _panel_for(world)
	var colonist_id := String(world.get_colonists()[0]["id"])
	var labour := "farm"

	var button_before := panel._cell_button(colonist_id, labour)
	world.tick()
	panel.refresh()
	var button_after := panel._cell_button(colonist_id, labour)
	_expect(button_before == button_after,
		"an ordinary refresh (colonist set unchanged) must not replace an existing cell button")

	var before_level := int(_colonist_by_id(world, colonist_id)["labourTable"][labour])
	var expected_level := before_level + 1
	if expected_level > WorldStateType.LABOUR_MAX:
		expected_level = WorldStateType.LABOUR_MIN
	button_after.emit_signal("pressed")
	var after_level := int(_colonist_by_id(world, colonist_id)["labourTable"][labour])
	_expect(after_level == expected_level,
		"pressing the surviving button after a refresh must issue exactly one set_labour command, cycling the level once (expected %d, got %d)"
			% [expected_level, after_level])

## The grid must add/remove rows once the colonist set actually changes --
## the counterpart to the "buttons survive an ordinary refresh" check above.
func _check_grid_reconciles_rows_when_colonist_set_changes() -> void:
	var world := WorldStateType.new(95001)
	var panel := _panel_for(world)
	var original_count := panel.cell_count()

	world._colonists.append({
		"id": "colonist_extra", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
		"route": null, "work": null, "carrying": null, "held_tool": "",
	})
	panel.refresh()
	_expect(panel.cell_count() == original_count + WorldStateType.LABOUR_KINDS.size(),
		"the grid must add a new colonist's row once the colonist set changes (expected %d cells, got %d)"
			% [original_count + WorldStateType.LABOUR_KINDS.size(), panel.cell_count()])
	_expect(panel._cell_button("colonist_extra", "farm") != null,
		"the new colonist's cells must be reachable by id after reconciliation")

## debug_scenario.gd must produce its pre-plowed
## starting tile through world.apply() (a till job) plus world.tick(), never
## a direct tile write -- the starting seed stock is the one authorized
## direct-write exception (no public command can spawn a stackable ground
## item on demand).
func _check_debug_scenario_produces_plowed_tile_and_seed_stock_via_apply_and_tick() -> void:
	var world := DebugScenarioType.build()

	var found_plowed := false
	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			if world.get_tile(x, y) == WorldStateType.TILE_PLOWED_SOIL:
				found_plowed = true
	_expect(found_plowed, "the debug scenario must produce at least one plowed_soil tile")

	var till_completed := false
	for job in world.get_jobs():
		if String(job["kind"]) == "till" and String(job["status"]) == "completed":
			till_completed = true
	_expect(till_completed,
		"the pre-plowed tile must come from a completed till job driven by world.apply()+world.tick(), not a direct tile write")

	var seed_count := 0
	for item in world.get_items():
		if String(item["kind"]) == "seed":
			seed_count += int(item["count"])
	_expect(seed_count == DebugScenarioType.STARTING_SEED_COUNT,
		"the debug scenario must seed a starting stock of %d seed(s), got %d"
			% [DebugScenarioType.STARTING_SEED_COUNT, seed_count])

## The work table panel, its banner, and the
## till/sow buttons must stay reachable within boot.gd's actual UI, not
## merely placed past the configured 960x540 viewport's edge. Calls
## _build_ui() directly (via Godot's dynamic call()) since boot.gd's _ready()
## skips it under a headless DisplayServer, so a headless boot alone could
## not detect a layout regression.
func _check_ui_layout_places_new_controls_within_reachable_scroll_area() -> void:
	var boot_scene: PackedScene = load(BOOT_SCENE_PATH)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	# _ready() has not run yet at this point (see test_viewer_hash.gd's own
	# comment on the same gap), so save_manager -- which _update_last_saved_
	# label() inside _build_ui() reads -- would otherwise still be null;
	# _build_ui() is called directly (not through _ready(), which would skip
	# it under a headless DisplayServer anyway) with save_manager set the
	# same way _ready() sets it.
	boot_node.save_manager = SaveManagerType.new()
	boot_node.call("_build_ui")

	var scroll = boot_node.get("_ui_scroll")
	var content = boot_node.get("_ui_content")
	var work_panel = boot_node.get("_work_table_panel")
	var status_label = boot_node.get("_status_label")
	var controls = boot_node.get("_controls")

	_expect(scroll is ScrollContainer,
		"the information/work panel must remain scrollable at small resolutions")
	_expect(content != null and content.get_parent() == scroll,
		"the UI content root must be the ScrollContainer's own direct child")
	_expect(work_panel != null and _is_descendant_of(work_panel, content),
		"_work_table_panel must live inside the scrollable content, not attached elsewhere")
	_expect(controls != null and not _is_descendant_of(controls, content),
		"the wrapping toolbar must stay anchored outside the panel scroll area")

	if content != null and work_panel != null and controls != null:
		var content_size: Vector2 = content.custom_minimum_size
		_expect(content_size.x > work_panel.position.x and content_size.y > work_panel.position.y,
			"the scrollable content must be sized to actually cover _work_table_panel's position (content=%s, panel at %s)"
				% [content_size, work_panel.position])
		_expect(content_size.x > controls.position.x and content_size.y > controls.position.y,
			"the scrollable content must be sized to actually cover the toolbar's position (content=%s, toolbar at %s)"
				% [content_size, controls.position])

	_expect(status_label != null, "status label must exist once the UI is built")
	if status_label != null and work_panel != null:
		_expect(absf(work_panel.position.y - status_label.position.y) < 400.0,
			"the work table panel (whose banner is its own first child) must sit near _status_label, not in a separate far-off column (panel y=%s, status y=%s)"
				% [work_panel.position.y, status_label.position.y])

	root.remove_child(boot_node)
	boot_node.free()

func _is_descendant_of(node: Node, ancestor: Node) -> bool:
	var current := node.get_parent()
	while current != null:
		if current == ancestor:
			return true
		current = current.get_parent()
	return false
