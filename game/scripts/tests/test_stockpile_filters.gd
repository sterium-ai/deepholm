extends SceneTree

## F5a (ADR 064): stockpile item-group filters and priorities, through the real triggers only
## (zone_add / zone_set_stockpile commands, a ripe crop's harvest, chop and ticks).
## - acceptance: stockpile A (food only, priority 3) and B (every group, priority 1), a harvested
##   food stack and a wood stack on the ground -> the food goes to A although B is nearer, the
##   wood (and the harvest's seed) to B; switching A to "materials only" moves the food to B
##   within a day, and nothing that B already holds moves to A;
## - the same seed reproduces every state_hash(); save/load (in memory and through SaveIO)
##   keeps the filters and continues tick for tick; a recorded session replays (A11);
## - with equal priority the nearest accepting stockpile wins; a stockpile accepting nothing
##   is never a destination; a new stockpile is the pre-F5a record (all groups, priority 2);
## - zone_set_stockpile is validated, and preview() agrees with apply();
## - the viewer's stockpile panel shows each stockpile and changes it only through commands, and
##   rebuilds its rows for another world whose zones reuse the same ids;
## - a loose tool delivered into a stockpile that stopped accepting tools mid-haul is not
##   stocked there (CraftingSystem.stock_tools()) but hauled out to one that accepts it;
## - the save snapshot never aliases a stockpile's live groups;
## - drop_tool (ToolDropToil) skips a nearer stockpile that rejects tools;
## - on a two-layer map, a stockpile on another layer ranks after one on the item's layer.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")
const StockpilePanelType = preload("res://scripts/viewer/stockpile_panel.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")

## A is far from the drops, B is next to them: only the priority sends the food to A.
const A := Rect2i(30, 2, 2, 2)
const B := Rect2i(2, 18, 3, 3)
const CROP := Vector3i(6, 16, TileGrid.SURFACE)
const WOOD := Vector3i(7, 16, TileGrid.SURFACE)
const SAVE_PATH := "user://test-stockpile-filters-save.json"

var _failed := false
var _next_command := 0
var _day_ticks := 0

func _init() -> void:
	_check_acceptance_food_to_a_wood_to_b_then_switch_moves_food()
	_check_same_seed_same_hashes()
	_check_save_load_keeps_filters_and_continues()
	_check_recorded_session_replays()
	_check_equal_priority_prefers_the_nearest_stockpile()
	_check_stockpile_accepting_nothing_is_never_a_destination()
	_check_commands_are_validated_and_preview_agrees()
	_check_panel_changes_a_stockpile_through_commands()
	_check_tool_delivered_after_its_stockpile_rejects_tools_is_hauled_out()
	_check_save_snapshot_does_not_alias_the_live_filter()
	_check_panel_rebuilds_for_another_world_with_the_same_zone_ids()
	_check_drop_tool_skips_a_stockpile_that_rejects_tools()
	_check_a_stockpile_on_another_layer_ranks_after_the_items_layer()
	if _failed:
		quit(1)
		return
	print("test_stockpile_filters: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _command(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	return Scenarios.command(world, "stockpile_test_%d" % _next_command, type, payload)

func _command_ok(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	var result := _command(world, type, payload)
	_expect(bool(result.get("ok", false)), "%s %s must be accepted: %s" % [type, payload, result])
	return result

func _add_zone(world: WorldStateType, rect: Rect2i) -> String:
	return String(_command_ok(world, "zone_add", {"x": rect.position.x, "y": rect.position.y,
		"width": rect.size.x, "height": rect.size.y}).get("zone_id", ""))

## A floor map with two idle colonists, a ripe crop at CROP (its harvest leaves food and a seed)
## and a wood stack at WOOD. still_needs zeroes need decay so nobody eats the stocked food; the
## decay rates are not saved, so the save/load and replay checks keep them.
func _world(seed_value: int, still_needs: bool = true) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	if still_needs:
		Scenarios.isolate_need(world, "")
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 10, 10))
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_1", 11, 10))
	TestAccess.set_tile(world, CROP.x, CROP.y, "crop_ripe")
	TestAccess.tile_grid(world).reset_cells()
	# Through the dirty-cell stream, as a growing crop would: FarmSystem records it as ripe.
	TestAccess.tile_grid(world).mark_dirty(CROP)
	world.tick()
	Scenarios.add_stock(world, "wood", 3, WOOD.x, WOOD.y)
	_day_ticks = TestAccess.calendar(world).day_length_ticks()
	return world

## The acceptance setup: A food only at priority 3, B every group at priority 1.
func _acceptance_world(seed_value: int, still_needs: bool = true) -> WorldStateType:
	var world := _world(seed_value, still_needs)
	var zone_a := _add_zone(world, A)
	var zone_b := _add_zone(world, B)
	_command_ok(world, "zone_set_stockpile", {"id": zone_a, "groups": "food", "priority": 3})
	_command_ok(world, "zone_set_stockpile", {"id": zone_b, "groups": "food,material,seed,tool,valuable", "priority": 1})
	return world

func _units_in(world: WorldStateType, kind: String, rect: Rect2i) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind and int(item["z"]) == TileGrid.SURFACE and rect.has_point(Vector2i(int(item["x"]), int(item["y"]))):
			total += int(item["count"])
	return total

func _units(world: WorldStateType, kind: String) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind:
			total += int(item["count"])
	return total

## Ticks until done() holds or limit ticks passed; returns the ticks taken (limit + 1 if never).
func _tick_until(world: WorldStateType, limit: int, done: Callable) -> int:
	for step in limit + 1:
		if bool(done.call()):
			return step
		if step < limit:
			world.tick()
	return limit + 1

## No haul under way (a carried stack is not in get_items()) and every stack where it belongs.
func _no_haul_open(world: WorldStateType) -> bool:
	return world.get_jobs(["haul"]).filter(func(job: Dictionary) -> bool: return job["status"] in ["queued", "active"]).is_empty()

func _settled(world: WorldStateType) -> bool:
	var food := _units(world, "food")
	return _no_haul_open(world) and food > 0 and _units_in(world, "food", A) == food and _units_in(world, "wood", B) == 3 \
		and _units_in(world, "seed", B) == _units(world, "seed")

## Acceptance (F5a): food to A (priority beats distance), wood and seed to B; then A switched to
## materials only moves the food to B within a day and pulls nothing out of B.
func _check_acceptance_food_to_a_wood_to_b_then_switch_moves_food() -> void:
	var world := _acceptance_world(64001)
	var zone_a := "zone_1"
	_expect(_tick_until(world, _day_ticks, _settled.bind(world)) <= _day_ticks,
		"within a day the food must lie in A and the wood and seed in B: A food %d, B wood %d, food %d, seed %d" %
		[_units_in(world, "food", A), _units_in(world, "wood", B), _units(world, "food"), _units(world, "seed")])
	var food := _units(world, "food")
	_expect(food > 0 and _units_in(world, "food", B) == 0, "the harvest must have yielded food, none of it in B")
	_command_ok(world, "zone_set_stockpile", {"id": zone_a, "groups": "material", "priority": 3})
	var start := world.get_tick()
	var moved := func() -> bool: return _no_haul_open(world) and _units_in(world, "food", B) == food
	_expect(_tick_until(world, _day_ticks, moved) <= _day_ticks,
		"within a day of the switch every food unit must be in B, got %d of %d (A holds %d)" %
		[_units_in(world, "food", B), food, _units_in(world, "food", A)])
	print("test_stockpile_filters: food moved to B %d ticks after the switch (day = %d ticks)" % [world.get_tick() - start, _day_ticks])
	for _i in 300:
		world.tick()
	_expect(_units_in(world, "wood", B) == 3 and _units_in(world, "wood", A) == 0,
		"wood already in B (a valid stockpile) must not move to the higher-priority A")
	_expect(_units_in(world, "food", B) == food, "the food must stay in B: B %d, A %d, total %d of %d, jobs %s" % [
		_units_in(world, "food", B), _units_in(world, "food", A), _units(world, "food"), food, world.get_jobs(["haul"])])

## Two worlds from the same seed and commands hash equal every 100 ticks and at the end.
func _check_same_seed_same_hashes() -> void:
	var first := _acceptance_world(64002)
	var second := _acceptance_world(64002)
	for step in 2 * _day_ticks:
		if step == _day_ticks / 2:
			_command_ok(first, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 3})
			_command_ok(second, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 3})
		first.tick()
		second.tick()
		if step % 100 == 0 and first.state_hash() != second.state_hash():
			_fail("the same seed must give the same state_hash() at tick %d" % first.get_tick())
			return
	_expect(first.state_hash() == second.state_hash(), "the same seed must end on the same state_hash()")

## The filters survive save/load (in memory, and through SaveIO's file and validator) and the
## loaded world keeps ticking in step, mid-move included.
func _check_save_load_keeps_filters_and_continues() -> void:
	var world := _acceptance_world(64003, false)
	_expect(_tick_until(world, _day_ticks, _settled.bind(world)) <= _day_ticks, "the food must first reach A")
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 3})
	for _i in 5:
		world.tick()
	_expect(world.get_zone("zone_1").get("groups") == ["material"] and int(world.get_zone("zone_1").get("priority", 0)) == 3,
		"A must hold its filter and priority: %s" % [world.get_zone("zone_1")])
	_expect(not world.get_zone("zone_2").has("groups") and int(world.get_zone("zone_2").get("priority", 0)) == 1,
		"B (every group) must store no groups and priority 1: %s" % [world.get_zone("zone_2")])
	var restored := WorldStateType.from_save_state(world.to_save_state())
	_expect(restored.state_hash() == world.state_hash(), "the loaded world must hash like the saved one")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	var write := SaveIOType.write_atomic(SAVE_PATH, StateCodecType.encode(world))
	_expect(write["ok"], "a world with stockpile filters must save: %s" % write)
	var read := SaveIOType.read(SAVE_PATH)
	_expect(read["ok"], "and load back: %s" % read)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	if not read["ok"]:
		return
	var from_file := StateCodecType.decode(read["state"])
	_expect(from_file.state_hash() == world.state_hash(), "the file round trip must keep state_hash()")
	for step in _day_ticks:
		world.tick()
		restored.tick()
		from_file.tick()
		if restored.state_hash() != world.state_hash() or from_file.state_hash() != world.state_hash():
			_fail("a loaded world diverged %d ticks after the load (in memory %s, file %s)" % [step + 1,
				restored.state_hash() == world.state_hash(), from_file.state_hash() == world.state_hash()])
			return
	_expect(_units_in(world, "food", A) == 0, "the loaded run must still move the food out of A")

## Acceptance (F5a): "replay identical" -- the session recorded through the viewer's
## CommandRecorder (A11), the filter switch included, replays every checkpoint.
func _check_recorded_session_replays() -> void:
	var world := _world(64004, false)
	var recorder := CommandRecorderType.new()
	recorder.start(world, 100, false)
	_add_zone(world, A)
	_add_zone(world, B)
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "food", "priority": 3})
	_command_ok(world, "zone_set_stockpile", {"id": "zone_2", "groups": "food,material,seed,tool,valuable", "priority": 1})
	var switched := false
	for _i in _day_ticks:
		world.tick()
		recorder.observe_tick(world)
		if not switched and (_settled(world) or world.get_tick() >= _day_ticks / 2):
			_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 3})
			switched = true
	var recording := recorder.stop()
	_expect(switched, "the recorded session must reach the switch")
	var accepted := 0
	for entry: Dictionary in recording.commands:
		if bool(entry["ok"]) and String(entry["command"]["type"]) == "zone_set_stockpile":
			accepted += 1
	_expect(accepted == 3, "the three zone_set_stockpile commands must be recorded as accepted, got %d" % accepted)
	var result := recording.replay()
	_expect(bool(result.get("ok", false)), "the recorded stockpile session must replay every checkpoint: %s" % [result])

## Equal priority: the nearest accepting stockpile (B here) wins over the lower zone id (A),
## whatever their creation order; before F5a the first zone id won.
func _check_equal_priority_prefers_the_nearest_stockpile() -> void:
	var world := _world(64005)
	_add_zone(world, A)
	_add_zone(world, B)
	_expect(_tick_until(world, _day_ticks, func() -> bool: return _units_in(world, "wood", B) == 3) <= _day_ticks,
		"with both stockpiles at the default, the wood must go to the nearer B")
	_expect(_units_in(world, "wood", A) == 0 and _units_in(world, "food", A) == 0, "nothing must go to the farther A")

## A stockpile accepting nothing ("") is never a destination: the haul waits blocked until a
## stockpile accepts the item, and an item left in it is hauled out.
func _check_stockpile_accepting_nothing_is_never_a_destination() -> void:
	var world := _world(64006)
	var zone := _add_zone(world, B)
	_command_ok(world, "zone_set_stockpile", {"id": zone, "groups": "", "priority": 2})
	Scenarios.add_stock(world, "stone", 1, B.position.x, B.position.y)
	for _i in 300:
		world.tick()
	_expect(_units_in(world, "wood", B) == 0, "a stockpile accepting nothing must receive no wood")
	var blocked := Scenarios.jobs_of_kind(world, "haul").filter(func(job: Dictionary) -> bool:
		return job["status"] == "queued" and job["reason"] == "blocked_destination_full")
	_expect(not blocked.is_empty(), "the wood hauls must wait as blocked_destination_full")
	var other := _add_zone(world, A)
	_expect(_tick_until(world, _day_ticks, func() -> bool:
		return _units_in(world, "wood", A) == 3 and _units_in(world, "stone", A) == 1) <= _day_ticks,
		"once A accepts everything, the wood and the stone left in B must reach it")
	_expect(String(world.get_zone(other).get("id", "")) == other and world.get_zone(other).keys().size() == 6,
		"a new stockpile is the pre-F5a record {id, x, y, z, width, height}: %s" % [world.get_zone(other)])

func _reason_detail(result: Dictionary) -> String:
	var rejection: Dictionary = result.get("rejection", {})
	return "%s/%s" % [rejection.get("reason", ""), (rejection.get("params", {}) as Dictionary).get("detail", "")]

## zone_set_stockpile's rules, the same through preview() and apply(); a no-op payload (every
## group, priority 2) stores the default record.
func _check_commands_are_validated_and_preview_agrees() -> void:
	var world := _world(64007)
	var zone := _add_zone(world, B)
	var farm := String(_command_ok(world, "zone_add", {"x": 20, "y": 20, "width": 2, "height": 2, "kind": "farm", "crop": "carrot"}).get("zone_id", ""))
	var cases := [
		[{"id": zone, "groups": "food"}, "invalid_payload/zone_set_stockpile_payload"],
		[{"id": zone, "groups": 3, "priority": 2}, "invalid_payload/zone_set_stockpile_payload"],
		[{"id": "zone_99", "groups": "food", "priority": 2}, "invalid_target/unknown_zone"],
		[{"id": farm, "groups": "food", "priority": 2}, "invalid_target/zone_not_stockpile"],
		[{"id": zone, "groups": "food", "priority": 0}, "invalid_payload/stockpile_priority_out_of_range"],
		[{"id": zone, "groups": "food", "priority": 4}, "invalid_payload/stockpile_priority_out_of_range"],
		[{"id": zone, "groups": "food,gems", "priority": 2}, "invalid_payload/unknown_item_group"],
		[{"id": zone, "groups": "food,food", "priority": 2}, "invalid_payload/unknown_item_group"],
		[{"id": zone, "groups": "food,", "priority": 2}, "invalid_payload/unknown_item_group"],
	]
	var hash_before := world.state_hash()
	for entry: Array in cases:
		_next_command += 1
		var command := {"actor": "test", "command_id": "stockpile_bad_%d" % _next_command, "tick": world.get_tick(),
			"type": "zone_set_stockpile", "payload": entry[0]}
		var preview := world.preview(command)
		var applied := world.apply(command)
		_expect(not preview["ok"] and _reason_detail(preview) == entry[1], "preview %s must reject as %s: %s" % [entry[0], entry[1], preview])
		_expect(not applied["ok"] and _reason_detail(applied) == entry[1], "apply %s must reject as %s: %s" % [entry[0], entry[1], applied])
	_expect(world.state_hash() == hash_before, "rejected commands must not change the world")
	var good := {"actor": "test", "command_id": "stockpile_good", "tick": world.get_tick(), "type": "zone_set_stockpile",
		"payload": {"id": zone, "groups": "seed,food", "priority": 3}}
	_expect(world.preview(good)["ok"] and world.apply(good)["ok"], "a valid zone_set_stockpile must preview and apply")
	_expect(world.get_zone(zone).get("groups") == ["food", "seed"] and int(world.get_zone(zone)["priority"]) == 3,
		"groups are stored sorted, with the priority: %s" % [world.get_zone(zone)])
	_command_ok(world, "zone_set_stockpile", {"id": zone, "groups": "valuable,tool,seed,material,food", "priority": 2})
	_expect(world.get_zone(zone).keys().size() == 6, "every group at priority 2 is the default record again: %s" % [world.get_zone(zone)])

## The panel lists stockpiles (not farm zones), shows priority and groups, and its buttons go
## through zone_set_stockpile: a toggle drops one group, "+" raises the priority, capped at 3.
func _check_panel_changes_a_stockpile_through_commands() -> void:
	var world := _world(64008)
	var zone := _add_zone(world, B)
	_command_ok(world, "zone_add", {"x": 20, "y": 20, "width": 2, "height": 2, "kind": "farm", "crop": "carrot"})
	var panel := StockpilePanelType.new()
	panel.setup(world, TextTableType.new())
	var priority := _find_label(panel, "Priority")
	_expect(priority != null and priority.text == "Priority 2", "the panel must show the default priority: %s" % [priority.text if priority else null])
	var buttons := _buttons(panel)
	_expect(buttons.size() == 2 + 5, "one stockpile: -, + and one toggle per group, got %d buttons" % buttons.size())
	var food: Button = null
	var more: Button = null
	for button in buttons:
		if button.text == "[x] Food":
			food = button
		elif button.text == "+":
			more = button
	_expect(food != null and more != null, "the panel must show Food accepted and a + button")
	if food == null or more == null:
		panel.free()
		return
	food.pressed.emit()
	_expect(world.get_zone(zone).get("groups") == ["material", "seed", "tool", "valuable"], "toggling Food must drop it: %s" % [world.get_zone(zone)])
	_expect(food.text == "[ ] Food", "the button must show Food rejected, got %s" % food.text)
	more.pressed.emit()
	more.pressed.emit()
	_expect(int(world.get_zone(zone).get("priority", 0)) == 3, "+ twice must reach priority 3: %s" % [world.get_zone(zone)])
	_expect(priority.text == "Priority 3", "the label must follow, got %s" % priority.text)
	food.pressed.emit()
	_expect(not world.get_zone(zone).has("groups"), "toggling Food back must restore every group: %s" % [world.get_zone(zone)])
	panel.free()

func _buttons(node: Node) -> Array[Button]:
	var found: Array[Button] = []
	for child in node.get_children():
		if child is Button:
			found.append(child)
		found.append_array(_buttons(child))
	return found

func _find_label(node: Node, prefix: String) -> Label:
	for child in node.get_children():
		if child is Label and (child as Label).text.begins_with(prefix):
			return child
		var below := _find_label(child, prefix)
		if below != null:
			return below
	return null

## Units of an axe in rect: loose ground stacks and ToolItemStore tools stocked there.
func _axes_in(world: WorldStateType, rect: Rect2i) -> Dictionary:
	var loose := _units_in(world, "axe", rect)
	var stocked := 0
	for tool_item in world.get_tool_items():
		var location: Dictionary = tool_item["location"]
		if String(tool_item["kind"]) == "axe" and String(location["type"]) == "stockpile" 				and rect.has_point(Vector2i(int(location["x"]), int(location["y"]))):
			stocked += 1
	return {"loose": loose, "stocked": stocked}

## Review F5a (blocking 1): a loose axe is hauled towards A (every group); while it is carried A
## stops accepting tools and B (every group) appears. The haul still lands in A (ADR 064), and the
## axe must then neither become a stocked tool in A (stock_tools() respects the filter) nor stay:
## it is hauled out and stocked in B.
func _check_tool_delivered_after_its_stockpile_rejects_tools_is_hauled_out() -> void:
	var world := _world(64010)
	var zone_a := _add_zone(world, A)
	Scenarios.add_stock(world, "axe", 1, 9, 12)
	var carried := func() -> bool:
		return _units(world, "axe") == 0 and not _no_haul_open(world)
	_expect(_tick_until(world, _day_ticks, carried) <= _day_ticks, "the axe must be picked up for A within a day")
	_command_ok(world, "zone_set_stockpile", {"id": zone_a, "groups": "food,material,seed,valuable", "priority": 2})
	_add_zone(world, B)
	var seen := {"stocked_in_a": false}
	var in_b := func() -> bool:
		var axes_a := _axes_in(world, A)
		if int(axes_a["stocked"]) > 0:
			seen["stocked_in_a"] = true
		return int(_axes_in(world, B)["stocked"]) == 1
	_expect(_tick_until(world, 2 * _day_ticks, in_b) <= 2 * _day_ticks,
		"within two days the axe must be stocked in B: A %s, B %s" % [_axes_in(world, A), _axes_in(world, B)])
	_expect(not bool(seen["stocked_in_a"]), "the axe must never become a stocked tool in A, which rejects tools")
	_expect(_axes_in(world, A) == {"loose": 0, "stocked": 0}, "nothing of the axe may stay in A: %s" % [_axes_in(world, A)])

## Review F5a (blocking 2): editing the save snapshot's groups never changes the live stockpile.
func _check_save_snapshot_does_not_alias_the_live_filter() -> void:
	var world := _world(64011)
	var zone := _add_zone(world, B)
	_command_ok(world, "zone_set_stockpile", {"id": zone, "groups": "food,seed", "priority": 3})
	var before := world.state_hash()
	var saved := world.to_save_state()
	var saved_zone: Dictionary = (saved["zones"] as Array)[0]
	(saved_zone["groups"] as Array).clear()
	_expect(world.get_zone(zone).get("groups") == ["food", "seed"], "clearing the snapshot's groups must leave the zone's: %s" % [world.get_zone(zone)])
	_expect(world.state_hash() == before, "and the state_hash()")

## Review F5a (blocking 3): the panel is moved to another world whose stockpile reuses zone_1 at
## another place; its heading follows and its buttons change the new world only.
func _check_panel_rebuilds_for_another_world_with_the_same_zone_ids() -> void:
	var first := _world(64012)
	var second := _world(64013)
	_add_zone(first, A)
	_add_zone(second, B)
	var panel := StockpilePanelType.new()
	panel.setup(first, TextTableType.new())
	var heading := _find_label(panel, "Stockpile (")
	_expect(heading != null and heading.text == "Stockpile (%d, %d)" % [A.position.x, A.position.y],
		"the heading must name A: %s" % [heading.text if heading else null])
	panel.set_world(second)
	heading = _find_label(panel, "Stockpile (")
	_expect(heading != null and heading.text == "Stockpile (%d, %d)" % [B.position.x, B.position.y],
		"after set_world() the heading must name the new world's stockpile: %s" % [heading.text if heading else null])
	var food: Button = null
	for button in _buttons(panel):
		if button.text == "[x] Food":
			food = button
	_expect(food != null and _buttons(panel).size() == 2 + 5, "one row of buttons for the new world's stockpile")
	if food != null:
		food.pressed.emit()
	_expect(second.get_zone("zone_1").get("groups") == ["material", "seed", "tool", "valuable"],
		"the toggle must change the new world's zone_1: %s" % [second.get_zone("zone_1")])
	_expect(not first.get_zone("zone_1").has("groups"), "and leave the old world's: %s" % [first.get_zone("zone_1")])
	# The plain refresh path (a host that only reassigns world) rebuilds too: the rectangle differs.
	panel.world = first
	panel.refresh()
	heading = _find_label(panel, "Stockpile (")
	_expect(heading != null and heading.text == "Stockpile (%d, %d)" % [A.position.x, A.position.y],
		"refresh() on a reassigned world must rebuild the heading: %s" % [heading.text if heading else null])
	panel.free()

## Review F5a round 2: a holder whose pick a foreign job reserved drops it at the nearest
## stockpile cell within ToolDropToil.TOOL_DROP_RADIUS that accepts tools (a forage order and
## ticks, as test_tool_items_handover.gd). The nearer stockpile, at (2, 0), rejects tools; the
## pick must land in the farther one at (0, 4), not in place and not at (2, 0).
func _check_drop_tool_skips_a_stockpile_that_rejects_tools() -> void:
	var world := WorldStateType.new(64014)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "z": 0, "route": null, "work": null})
	var near := String(_command_ok(world, "zone_add", {"x": 2, "y": 0, "width": 1, "height": 1}).get("zone_id", ""))
	_command_ok(world, "zone_add", {"x": 0, "y": 4, "width": 1, "height": 1})
	_command_ok(world, "zone_set_stockpile", {"id": near, "groups": "food,material,seed,valuable", "priority": 2})
	_command_ok(world, "place_object", {"x": 5, "y": 0, "kind": "berry_bush"})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0") and world.reserve_tool_item(pick_id, "foreign_job"),
		"the pick must be held by colonist_0 and reserved by a foreign job")
	var job_id := String(_command_ok(world, "forage", {"x": 5, "y": 0, "priority": 1}).get("job_id", ""))
	var completed := func() -> bool: return String(Scenarios.find_job(world, job_id).get("status", "")) == "completed"
	_expect(_tick_until(world, 120, completed) <= 120, "colonist_0's forage must complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(String(location.get("type", "")) == "stockpile" and int(location.get("x", -1)) == 0 and int(location.get("y", -1)) == 4,
		"the pick must be dropped in the stockpile that accepts tools at (0, 4), got %s" % [location])

## Review F5a round 2: a two-layer world (a save with map.layerCount 2, loaded as SaveIO would)
## with zone_1 on layer 1 right above a loose wood stack and zone_2 on the surface, far away, both
## at priority 2. Planar distance and id would both pick zone_1; the layer rule sends the wood
## to zone_2 (ZoneTable.OTHER_LAYER_DISTANCE), through zone_add commands and ticks.
func _check_a_stockpile_on_another_layer_ranks_after_the_items_layer() -> void:
	var surface := _world(64015)
	var state := surface.to_save_state()
	state["map"]["layerCount"] = 2
	# Layer 1 is bare floor: no crop or tree there, so no job targets another layer than its worker.
	var deep_tiles: Array = []
	deep_tiles.resize((state["map"]["tiles"] as Array).size())
	deep_tiles.fill(WorldStateType.TILE_FLOOR)
	(state["map"]["tiles"] as Array).append_array(deep_tiles)
	var world := WorldStateType.from_save_state(state)
	_expect(_command(world, "zone_add", {"x": WOOD.x, "y": WOOD.y, "z": 1, "width": 2, "height": 2}).get("ok", false),
		"a stockpile on layer 1 must be accepted on a two-layer map")
	_add_zone(world, A)
	_expect(world.get_zone("zone_1").get("z") == 1 and world.get_zone("zone_2").get("z") == 0,
		"zone_1 must lie on layer 1 and zone_2 on the surface: %s / %s" % [world.get_zone("zone_1"), world.get_zone("zone_2")])
	var deep := Rect2i(WOOD.x, WOOD.y, 2, 2)
	var stored := func() -> bool: return _units_in(world, "wood", A) == 3
	_expect(_tick_until(world, _day_ticks, stored) <= _day_ticks,
		"within a day the wood must reach the surface stockpile A: A %d, total %d" % [_units_in(world, "wood", A), _units(world, "wood")])
	for item in world.get_items():
		_expect(not (int(item["z"]) == 1 and deep.has_point(Vector2i(int(item["x"]), int(item["y"])))),
			"nothing may be hauled into the layer-1 stockpile: %s" % [item])
