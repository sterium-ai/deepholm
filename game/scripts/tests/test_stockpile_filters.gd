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
## - on a two-layer map, a stockpile on another layer ranks after one on the item's layer;
## - F5a-b: a stocked pick in A, switched to materials only, keeps its id and is carried by a
##   colonist's haul_tool job to B (every group) within a day; with no B it is carried to a free
##   tile beside A, outside every zone; both runs are deterministic and replay; when B stops
##   accepting tools while the pick is carried there, it is not stocked in B (deterministic too);
##   a pick walled off while its haul_tool job goes to fetch it fails that job once
##   (blocked_target_unreachable), stays stocked in A, is not offered again while walled off, and is
##   carried to B once the wall is gone; with the preferred accepting stockpile C walled off, the
##   pick is carried to the reachable B instead;
## - F5a-b, the owner's rule (BACKLOG.md, c769a48): a haul_tool job that cannot continue for any
##   reason (a need interrupt, a target that rejects tools, is unreachable or walled, a missing
##   reservation) sets the tool down on the carrier's tile and fails through the shared engine;
##   HaulGiver re-plans from the ground. A tick-driven table covers interrupt before/after pickup x
##   target rejects/unreachable/walled x reservation kept/removed (with and without a need): the
##   pick is never held by a colonist without an open haul_tool job for it, and ends on the ground
##   outside every stockpile or stocked in one that accepts tools, with its id.

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
	_check_rejected_stocked_tool_moves_to_b_with_its_id()
	_check_rejected_stocked_tool_without_b_is_dropped_beside_a()
	_check_rejected_stocked_tool_is_deterministic_and_replays()
	_check_hauled_tool_is_not_stocked_where_the_target_now_rejects_tools()
	_check_need_interrupt_mid_carry_sets_the_tool_down()
	_check_walled_off_rejected_tool_fails_once_without_a_retry_loop()
	_check_walled_off_preferred_stockpile_yields_to_a_reachable_one()
	_check_destination_walled_off_mid_carry_sets_the_tool_down()
	_check_destination_rejects_tools_after_an_interrupt_leaves_the_tool_outside()
	_check_interrupt_outside_a_is_replanned_from_the_ground_into_b()
	_check_set_down_tool_is_replanned_after_the_filters_change()
	_check_haul_tool_failure_matrix()
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
		if String(tool_item["kind"]) == "axe" and String(location["type"]) == "stockpile" \
				and rect.has_point(Vector2i(int(location["x"]), int(location["y"]))):
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

## F5a-b: a world with A (every group) holding a stocked pick at A's first cell, and B when with_b.
func _stocked_pick_world(seed_value: int, with_b: bool) -> WorldStateType:
	var world := _world(seed_value, false)
	_add_zone(world, A)
	if with_b:
		_add_zone(world, B)
	var pick_id := world.spawn_ground_tool_item("pick", A.position.x, A.position.y)
	_expect(world.set_tool_item_stockpile(pick_id, A.position.x, A.position.y), "the pick must be stocked in A")
	return world

func _pick_location(world: WorldStateType) -> Dictionary:
	var location: Dictionary = (world.get_tool_items()[0] as Dictionary)["location"]
	return location

## Records into seen whether a colonist has held the pick ("carrier") and whether a haul_tool job
## completed ("completed"): the pick must be carried there by a haul job, not moved by a write.
func _observe_haul(world: WorldStateType, seen: Dictionary) -> void:
	var location := _pick_location(world)
	if String(location["type"]) == "held":
		seen["carrier"] = String(location["colonist_id"])
	for job in world.get_jobs(["haul_tool"]):
		if String(job["status"]) == "completed":
			seen["completed"] = true

func _expect_carried(seen: Dictionary, label: String) -> void:
	_expect(String(seen.get("carrier", "")).begins_with("colonist_"), "%s: a colonist must carry the pick: %s" % [label, seen])
	_expect(bool(seen.get("completed", false)), "%s: a haul_tool job must complete: %s" % [label, seen])

func _check_rejected_stocked_tool_moves_to_b_with_its_id() -> void:
	var world := _stocked_pick_world(64016, true)
	var pick_id := String(world.get_tool_items()[0]["id"])
	for _i in 10:
		world.tick()
	_expect(String(_pick_location(world)["type"]) == "stockpile" and int(_pick_location(world)["x"]) == A.position.x,
		"while A accepts tools the pick must stay in A: %s" % [_pick_location(world)])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var seen: Dictionary = {}
	var in_b := func() -> bool:
		_observe_haul(world, seen)
		var location := _pick_location(world)
		return String(location["type"]) == "stockpile" and B.has_point(Vector2i(int(location["x"]), int(location["y"])))
	_expect(_tick_until(world, _day_ticks, in_b) <= _day_ticks, "within a day the pick must be stocked in B: %s" % [_pick_location(world)])
	_expect(world.get_tool_items().size() == 1 and world.get_tool_item(pick_id).get("kind") == "pick",
		"the same pick id must be the only tool: %s" % [world.get_tool_items()])
	_expect(_axes_in(world, A) == {"loose": 0, "stocked": 0} and _units_in(world, "pick", A) == 0, "A's cell must be free")
	_expect_carried(seen, "to B")

func _check_rejected_stocked_tool_without_b_is_dropped_beside_a() -> void:
	var world := _stocked_pick_world(64017, false)
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var seen: Dictionary = {}
	var on_ground := func() -> bool:
		_observe_haul(world, seen)
		return String(_pick_location(world)["type"]) == "ground"
	_expect(_tick_until(world, _day_ticks, on_ground) <= _day_ticks, "within a day the pick must be dropped: %s" % [_pick_location(world)])
	var dropped := _pick_location(world)
	var cell := Vector2i(int(dropped["x"]), int(dropped["y"]))
	var beside := not A.has_point(cell) and A.grow(1).has_point(cell) \
		and ((cell.x >= A.position.x and cell.x < A.end.x) != (cell.y >= A.position.y and cell.y < A.end.y))
	_expect(beside and int(dropped["z"]) == TileGrid.SURFACE, "the pick must lie on a tile sharing an edge with A: %s" % [dropped])
	# The nearest such tile to A's first cell (30, 2): (29, 2), then (30, 1) by y.
	_expect(cell == Vector2i(30, 1), "nearest tile beside A, ties by y then x: %s" % [cell])
	_expect_carried(seen, "beside A")
	for _i in 50:
		world.tick()
	var later := _pick_location(world)
	_expect(String(later["type"]) != "stockpile", "a pick on the ground beside A must not be moved back into A: %s" % [later])

## Two runs of each scenario give the same state_hash() tick for tick, and a recorded session replays.
func _check_rejected_stocked_tool_is_deterministic_and_replays() -> void:
	for with_b in [true, false]:
		var first := _stocked_pick_world(64018, with_b)
		var second := _stocked_pick_world(64018, with_b)
		var recorder := CommandRecorderType.new()
		recorder.start(first, 100, false)
		var seen: Dictionary = {}
		for step in _day_ticks / 2:
			if step == 20:
				_command_ok(first, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
				_command_ok(second, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
			first.tick()
			recorder.observe_tick(first)
			_observe_haul(first, seen)
			second.tick()
			if first.state_hash() != second.state_hash():
				_fail("with_b %s: the same seed must give the same state_hash() at tick %d" % [with_b, first.get_tick()])
				break
		_expect(String(_pick_location(first)["type"]) == ("stockpile" if with_b else "ground"),
			"with_b %s: the pick must have moved: %s" % [with_b, _pick_location(first)])
		_expect_carried(seen, "with_b %s" % with_b)
		var result := recorder.stop().replay()
		_expect(bool(result.get("ok", false)), "with_b %s: the session must replay every checkpoint: %s" % [with_b, result])

## F5a-b review round 2: B (zone_2) stops accepting tools while a colonist carries the pick
## there. ToilExecutor rechecks the target every tick and fails the haul_tool job through the
## engine (invalid_target); the pick is set down, never left loose inside a stockpile and never
## stocked in B, and ends on the ground outside every stockpile (neither A nor B takes tools).
## Two worlds from one seed keep equal state_hash() every tick, and the recorded session replays.
func _check_hauled_tool_is_not_stocked_where_the_target_now_rejects_tools() -> void:
	var first := _stocked_pick_world(64019, true)
	var second := _stocked_pick_world(64019, true)
	var recorder := CommandRecorderType.new()
	recorder.start(first, 100, false)
	for world: WorldStateType in [first, second]:
		_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var seen: Dictionary = {}
	var switched := false
	var failed := false
	var settled := false
	for _step in _day_ticks * 2:
		first.tick()
		recorder.observe_tick(first)
		_observe_haul(first, seen)
		second.tick()
		if first.state_hash() != second.state_hash():
			_fail("the same seed must give the same state_hash() at tick %d" % first.get_tick())
			break
		var location := _pick_location(first)
		var type := String(location["type"])
		if not switched:
			if type == "held":
				for world: WorldStateType in [first, second]:
					_command_ok(world, "zone_set_stockpile", {"id": "zone_2", "groups": "material", "priority": 1})
				switched = true
			continue
		for job in first.get_jobs(["haul_tool"]):
			if String(job["status"]) == "failed" and String(job["reason"]) == "invalid_target":
				failed = true
		if type == "held":
			continue
		var cell := Vector2i(int(location["x"]), int(location["y"]))
		var in_zone := A.has_point(cell) or B.has_point(cell)
		_expect(not (type == "ground" and in_zone), "the pick must never lie loose inside a stockpile: %s" % [location])
		_expect(not (type == "stockpile" and B.has_point(cell)), "the pick must never be stocked in B: %s" % [location])
		if type == "ground" and not in_zone:
			settled = true
			break
	_expect(switched, "a colonist must pick the pick up: %s" % [seen])
	_expect(String(seen.get("carrier", "")).begins_with("colonist_"), "a colonist must carry the pick: %s" % [seen])
	_expect(failed, "the haul_tool job must fail with invalid_target: %s" % [first.get_jobs(["haul_tool"])])
	_expect(settled, "the pick must end on the ground outside every stockpile: %s" % [_pick_location(first)])
	var result := recorder.stop().replay()
	_expect(bool(result.get("ok", false)), "the session must replay every checkpoint: %s" % [result])

## F5a-b, the owner's rule (c769a48): a critical food need interrupts the carrier while it holds
## the pick. A haul_tool job is not resumable: the carrier sets the pick down on its tile at once
## and the job fails through the engine (need_interrupt), never paused with the pick in a hand.
## HaulGiver re-plans from the ground (a pick set down on a tile of A is stocked there and hauled
## out again, since A rejects tools), so it ends stocked in B or on the ground outside every
## stockpile, with its id, and is never held by a colonist without an open job for it.
func _check_need_interrupt_mid_carry_sets_the_tool_down() -> void:
	var world := _stocked_pick_world(64020, true)
	Scenarios.isolate_need(world, "food")
	var pick_id := String(world.get_tool_items()[0]["id"])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	var carrier := ""
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) == "held":
			carrier = String(location["colonist_id"])
			for job in world.get_jobs(["haul_tool"]):
				if String(job["status"]) == "active":
					job_id = String(job["id"])
			break
	_expect(not carrier.is_empty() and not job_id.is_empty(), "a colonist must pick the pick up for a haul_tool job")
	if carrier.is_empty() or job_id.is_empty():
		return
	for colonist in TestAccess.colonists(world):
		if String(colonist["id"]) == carrier:
			colonist["needs"]["food"] = 5
	var job_of := func() -> Dictionary: return TestAccess.get_job(world, job_id)
	var ended := false
	for _i in 60:
		world.tick()
		if not (job_of.call().get("status", "") in ["queued", "active"]):
			ended = true
			break
	_expect(ended and String(job_of.call().get("status", "")) == "failed" and String(job_of.call().get("reason", "")) == "need_interrupt",
		"the food need must fail the haul_tool job (need_interrupt): %s" % [job_of.call()])
	_expect(String(_pick_location(world)["type"]) != "held", "the interrupted carrier must set the pick down: %s" % [_pick_location(world)])
	var settled := func() -> bool:
		_expect_holder_busy(world, "after the interrupt")
		return _haul_tool_closed(world) and _tool_rests_validly(world, true)
	_expect(_tick_until(world, _day_ticks * 2, settled) <= _day_ticks * 2,
		"the pick must end stocked in B or on the ground outside every stockpile: %s" % [_pick_location(world)])
	_expect(world.get_tool_items().size() == 1 and String(world.get_tool_items()[0]["id"]) == pick_id,
		"the same pick id must be the only tool: %s" % [world.get_tool_items()])

## Rock on every tile sharing an edge or a corner with rect (rock = true), or floor again (false).
## Raw tile writes, so the passability cache and the region and room maps are rebuilt on query.
func _wall_around(world: WorldStateType, rect: Rect2i, rock: bool) -> void:
	var ring := rect.grow(1)
	for x in range(ring.position.x, ring.end.x):
		for y in range(ring.position.y, ring.end.y):
			if not rect.has_point(Vector2i(x, y)):
				TestAccess.set_tile(world, x, y, WorldStateType.TILE_ROCK if rock else WorldStateType.TILE_FLOOR)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	TestAccess.tile_grid(world).rooms = null

## F5a-b review round 6: A is walled off while a colonist walks to fetch the pick for its haul_tool
## job. The fetch finds the pick unreachable and fails the job through the engine
## (blocked_target_unreachable) instead of re-reserving it every tick; the pick stays stocked in A
## (never teleported, never left reserved), HaulGiver offers no new job while the wall stands, and
## once the wall is gone the pick is carried to B by a colonist.
func _check_walled_off_rejected_tool_fails_once_without_a_retry_loop() -> void:
	var world := _stocked_pick_world(64021, true)
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	for _i in _day_ticks:
		world.tick()
		for job in world.get_jobs(["haul_tool"]):
			if String(job["status"]) == "active":
				job_id = String(job["id"])
		if not job_id.is_empty():
			break
	_expect(not job_id.is_empty() and String(_pick_location(world)["type"]) == "stockpile",
		"a haul_tool job must go active while the pick is still in A: %s" % [world.get_jobs(["haul_tool"])])
	if job_id.is_empty():
		return
	_wall_around(world, A, true)
	var failed := false
	for _i in 200:
		world.tick()
		for job in world.get_jobs(["haul_tool"]):
			if String(job["id"]) == job_id and String(job["status"]) == "failed":
				_expect(String(job["reason"]) == "blocked_target_unreachable", "the job must fail as unreachable: %s" % [job])
				failed = true
		if failed:
			break
	_expect(failed, "the haul_tool job must fail once the pick is walled off: %s" % [world.get_jobs(["haul_tool"])])
	var jobs_after_fail := world.get_jobs(["haul_tool"]).size()
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) != "stockpile" or not A.has_point(Vector2i(int(location["x"]), int(location["y"]))):
			_fail("a walled-off pick must stay stocked in A: %s" % [location])
			break
	_expect(world.get_jobs(["haul_tool"]).size() == jobs_after_fail,
		"no haul_tool job may be offered again while the pick is walled off: %s" % [world.get_jobs(["haul_tool"])])
	_expect(world.get_jobs(["haul_tool"]).filter(func(job: Dictionary) -> bool: return job["status"] in ["queued", "active"]).is_empty(),
		"no haul_tool job may stay open on the walled-off pick: %s" % [world.get_jobs(["haul_tool"])])
	_expect(world.get_tool_item_reservation(String(world.get_tool_items()[0]["id"])).is_empty(),
		"the walled-off pick must not stay reserved")
	_wall_around(world, A, false)
	var seen: Dictionary = {}
	var in_b := func() -> bool:
		_observe_haul(world, seen)
		var location := _pick_location(world)
		return String(location["type"]) == "stockpile" and B.has_point(Vector2i(int(location["x"]), int(location["y"])))
	_expect(_tick_until(world, _day_ticks, in_b) <= _day_ticks, "with the wall gone the pick must reach B: %s" % [_pick_location(world)])
	_expect_carried(seen, "after the wall")

## F5a-b review round 7: C (every group, priority 3, beside A) outranks B, but it is walled off.
## The destination search skips C's unreachable cells and goes on, so a colonist carries the pick
## to the reachable B; C is never targeted and stays empty.
func _check_walled_off_preferred_stockpile_yields_to_a_reachable_one() -> void:
	var c := Rect2i(35, 2, 2, 2)
	var world := _stocked_pick_world(64022, true)
	var zone_c := _add_zone(world, c)
	_command_ok(world, "zone_set_stockpile", {"id": zone_c, "groups": "food,material,seed,tool,valuable", "priority": 3})
	_wall_around(world, c, true)
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var seen: Dictionary = {}
	var in_b := func() -> bool:
		_observe_haul(world, seen)
		var location := _pick_location(world)
		return String(location["type"]) == "stockpile" and B.has_point(Vector2i(int(location["x"]), int(location["y"])))
	_expect(_tick_until(world, _day_ticks, in_b) <= _day_ticks,
		"with C walled off the pick must reach the reachable B: %s" % [_pick_location(world)])
	_expect_carried(seen, "past walled-off C")
	for job in world.get_jobs(["haul_tool"]):
		var target: Vector3i = job["target"]
		_expect(not c.has_point(Vector2i(target.x, target.y)), "no haul_tool job may target walled-off C: %s" % [job])
	_expect(_axes_in(world, c) == {"loose": 0, "stocked": 0}, "walled-off C must stay empty")

## F5a-b review round 8: B is walled off while a colonist carries the pick to it. Under the owner's
## rule (c769a48) the haul_tool job fails through the shared engine (invalid_target or
## blocked_target_unreachable, whichever check sees it first) and sets the pick down where the
## carrier stands, keeping its id; it is never cancelled and
## resubmitted as a haul_tool job without item_id, never left in a hand, never stocked in B, and
## never left reserved by a job that is no longer open.
func _check_destination_walled_off_mid_carry_sets_the_tool_down() -> void:
	var world := _stocked_pick_world(64023, true)
	var pick_id := String(world.get_tool_items()[0]["id"])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	for _i in _day_ticks:
		world.tick()
		if String(_pick_location(world)["type"]) == "held":
			for job in world.get_jobs(["haul_tool"]):
				if String(job["status"]) == "active":
					job_id = String(job["id"])
			break
	_expect(not job_id.is_empty(), "a colonist must pick the pick up for a haul_tool job: %s" % [world.get_jobs(["haul_tool"])])
	if job_id.is_empty():
		return
	_wall_around(world, B, true)
	var failed := false
	for _i in 200:
		world.tick()
		for job in world.get_jobs(["haul_tool"]):
			_expect(not (job["status"] in ["queued", "active"]) or not String(job.get("item_id", "")).is_empty(),
				"no open haul_tool job may lose its item_id: %s" % [job])
			if String(job["id"]) == job_id and not (job["status"] in ["queued", "active"]):
				_expect(String(job["status"]) == "failed" and String(job["reason"]) in ["invalid_target", "blocked_target_unreachable"],
					"the job must fail through the engine, not be cancelled and resubmitted: %s" % [job])
				failed = true
		if failed:
			break
	_expect(failed, "the haul_tool job must end once B is walled off: %s" % [world.get_jobs(["haul_tool"])])
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) == "stockpile" and B.has_point(Vector2i(int(location["x"]), int(location["y"]))):
			_fail("the pick must never reach walled-off B: %s" % [location])
			break
	var final := _pick_location(world)
	_expect(String(final["type"]) in ["ground", "stockpile"], "the pick must be set down, not held: %s" % [final])
	_expect(world.get_tool_items().size() == 1 and String(world.get_tool_items()[0]["id"]) == pick_id,
		"the same pick id must be the only tool: %s" % [world.get_tool_items()])
	var owner := String(world.get_tool_item_reservation(pick_id))
	var open_ids := world.get_jobs(["haul_tool"]).filter(func(job: Dictionary) -> bool:
		return job["status"] in ["queued", "active"]).map(func(job: Dictionary) -> String: return String(job["id"]))
	_expect(owner.is_empty() or owner in open_ids, "the pick may only be reserved by an open job: %s" % [owner])

## F5a-b review round 9, under the owner's rule (c769a48): a critical food need interrupts the
## carrier while it holds the pick. The haul_tool job fails through the engine (need_interrupt) and
## the pick is set down on the carrier's tile at once, never kept in a hand while the job waits.
## B then stops accepting tools: HaulGiver re-plans from the ground, neither A nor B takes tools,
## so the pick ends on the ground outside every stockpile, with the same id.
func _check_destination_rejects_tools_after_an_interrupt_leaves_the_tool_outside() -> void:
	var world := _stocked_pick_world(64024, true)
	Scenarios.isolate_need(world, "food")
	var pick_id := String(world.get_tool_items()[0]["id"])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	var carrier := ""
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) == "held":
			carrier = String(location["colonist_id"])
			job_id = String(world.get_assignments().get(carrier, {}).get("job_id", ""))
			break
	_expect(not carrier.is_empty() and not job_id.is_empty(), "a colonist must pick the pick up for a haul_tool job")
	if carrier.is_empty() or job_id.is_empty():
		return
	_starve(world, carrier)
	var job_of := func() -> Dictionary: return world.get_job(job_id)
	var ended := func() -> bool: return not (job_of.call().get("status", "") in ["queued", "active"])
	_expect(_tick_until(world, 60, ended) <= 60 and String(job_of.call().get("status", "")) == "failed"
			and String(job_of.call().get("reason", "")) == "need_interrupt",
		"the interrupted haul_tool job must fail with need_interrupt: %s" % [job_of.call()])
	_expect(String(_pick_location(world)["type"]) != "held", "the interrupted carrier must set the pick down: %s" % [_pick_location(world)])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_2", "groups": "material", "priority": 1})
	var outside := func() -> bool:
		_expect_holder_busy(world, "after the interrupt")
		return _haul_tool_closed(world) and _tool_rests_validly(world, false)
	_expect(_tick_until(world, _day_ticks, outside) <= _day_ticks,
		"the pick must end on the ground outside every stockpile: %s" % [_pick_location(world)])
	_expect(world.get_tool_items().size() == 1 and String(world.get_tool_items()[0]["id"]) == pick_id,
		"the same pick id must be the only tool: %s" % [world.get_tool_items()])

## F5a-b review round 12, the owner's rule (c769a48): the carry is interrupted after the carrier
## has left A, on a tile in neither A nor B. A need cannot interrupt a walk (NeedGiver waits for a
## toil boundary, and the carry is one walk from A to B), so the interruption is B walled off
## mid-route: the haul_tool job fails through the engine and the pick is set down on the ground
## there. B is then reopened and still takes tools, so HaulGiver re-plans the pick from the ground:
## a new haul_tool job carries the same pick into B.
func _check_interrupt_outside_a_is_replanned_from_the_ground_into_b() -> void:
	var world := _stocked_pick_world(64060, true)
	var pick_id := String(world.get_tool_items()[0]["id"])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) != "held":
			continue
		for colonist in TestAccess.colonists(world):
			var cell := Vector2i(int(colonist["x"]), int(colonist["y"]))
			if String(colonist["id"]) == String(location["colonist_id"]) and cell.distance_to(Vector2i(A.position)) >= 6.0 					and not A.has_point(cell) and not B.has_point(cell):
				job_id = String(world.get_assignments().get(String(colonist["id"]), {}).get("job_id", ""))
		if not job_id.is_empty():
			break
	_expect(not job_id.is_empty(), "a colonist must carry the pick out of A for a haul_tool job")
	if job_id.is_empty():
		return
	_wall_around(world, B, true)
	var job_of := func() -> Dictionary: return world.get_job(job_id)
	var ended := func() -> bool: return not (job_of.call().get("status", "") in ["queued", "active"])
	_expect(_tick_until(world, 200, ended) <= 200 and String(job_of.call().get("status", "")) == "failed"
			and String(job_of.call().get("reason", "")) in ["invalid_target", "blocked_target_unreachable"],
		"the interrupted haul_tool job must fail through the engine: %s" % [job_of.call()])
	var dropped := _pick_location(world)
	var dropped_cell := Vector2i(int(dropped.get("x", -1)), int(dropped.get("y", -1)))
	_expect(String(dropped["type"]) == "ground" and not A.has_point(dropped_cell) and not B.has_point(dropped_cell),
		"the interrupted carrier must set the pick down on the ground outside A and B: %s" % [dropped])
	_wall_around(world, B, false)
	var in_b := func() -> bool:
		_expect_holder_busy(world, "re-planned from the ground")
		return _haul_tool_closed(world) and _tool_rests_validly(world, true)
	_expect(_tick_until(world, _day_ticks, in_b) <= _day_ticks,
		"the set-down pick must be re-planned from the ground and stocked in B: %s, jobs %s"
			% [_pick_location(world), world.get_jobs(["haul_tool"])])
	var replans := world.get_jobs(["haul_tool"]).filter(func(job: Dictionary) -> bool:
		return String(job["id"]) != job_id and String(job.get("item_id", "")) == pick_id and String(job["status"]) == "completed")
	_expect(replans.size() == 1, "one new haul_tool job must carry the pick from the ground into B: %s" % [world.get_jobs(["haul_tool"])])
	_expect(world.get_tool_items().size() == 1 and String(world.get_tool_items()[0]["id"]) == pick_id,
		"the same pick id must be the only tool: %s" % [world.get_tool_items()])

## F5a-b review round 13: recovery must not hang on the filters of the moment. A rejects tools, a
## haul_tool job picks the pick up, A takes tools again while it is carried, and B is walled off
## mid-route, so the job fails outside every stockpile and the pick is set down there, marked
## set_down. No stockpile rejects tools any more, yet the mark keeps it a haul candidate: it
## survives save/load (in memory and through SaveIO) and, with B still walled off, HaulGiver
## re-plans it into A, which takes tools again. Same id, no haul_tool job open, no stale
## reservation, and the mark is gone once it is stocked.
func _check_set_down_tool_is_replanned_after_the_filters_change() -> void:
	var world := _stocked_pick_world(64061, true)
	var pick_id := String(world.get_tool_items()[0]["id"])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) != "held":
			continue
		for colonist in TestAccess.colonists(world):
			var cell := Vector2i(int(colonist["x"]), int(colonist["y"]))
			if String(colonist["id"]) == String(location["colonist_id"]) and cell.distance_to(Vector2i(A.position)) >= 6.0 					and not A.has_point(cell) and not B.has_point(cell):
				job_id = String(world.get_assignments().get(String(colonist["id"]), {}).get("job_id", ""))
		if not job_id.is_empty():
			break
	_expect(not job_id.is_empty(), "a colonist must carry the pick out of A for a haul_tool job")
	if job_id.is_empty():
		return
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "food,material,seed,tool,valuable", "priority": 2})
	_wall_around(world, B, true)
	var job_of := func() -> Dictionary: return world.get_job(job_id)
	var ended := func() -> bool: return not (job_of.call().get("status", "") in ["queued", "active"])
	_expect(_tick_until(world, 200, ended) <= 200 and String(job_of.call().get("status", "")) == "failed"
			and String(job_of.call().get("reason", "")) in ["invalid_target", "blocked_target_unreachable"],
		"the haul_tool job must fail through the engine once B is walled off: %s" % [job_of.call()])
	var dropped := _pick_location(world)
	var dropped_cell := Vector2i(int(dropped.get("x", -1)), int(dropped.get("y", -1)))
	_expect(String(dropped["type"]) == "ground" and not A.has_point(dropped_cell) and not B.has_point(dropped_cell)
			and bool(world.get_tool_item(pick_id).get("set_down", false)),
		"the pick must be set down, marked, on the ground outside A and B: %s" % [world.get_tool_item(pick_id)])
	var restored := WorldStateType.from_save_state(world.to_save_state())
	_expect(bool(restored.get_tool_item(pick_id).get("set_down", false)) and restored.state_hash() == world.state_hash(),
		"save/load must keep the set_down mark: %s" % [restored.get_tool_item(pick_id)])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	var write := SaveIOType.write_atomic(SAVE_PATH, StateCodecType.encode(world))
	var read := SaveIOType.read(SAVE_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(write["ok"] and read["ok"], "a world with a set-down pick must save and load through SaveIO: %s %s" % [write, read])
	if read["ok"]:
		var from_file := StateCodecType.decode(read["state"])
		_expect(bool(from_file.get_tool_item(pick_id).get("set_down", false)) and from_file.state_hash() == world.state_hash(),
			"the file round trip must keep the set_down mark: %s" % [from_file.get_tool_item(pick_id)])
	var in_a := func() -> bool:
		_expect_holder_busy(world, "re-planned after the filters changed")
		var location := _pick_location(world)
		return _haul_tool_closed(world) and String(location["type"]) == "stockpile" 			and A.has_point(Vector2i(int(location["x"]), int(location["y"])))
	_expect(_tick_until(world, _day_ticks, in_a) <= _day_ticks,
		"the set-down pick must be re-planned into A, which takes tools again: %s, jobs %s"
			% [_pick_location(world), world.get_jobs(["haul_tool"])])
	_expect(not world.get_tool_item(pick_id).has("set_down") and world.get_tool_item_reservation(pick_id).is_empty(),
		"once stocked the pick must carry no set_down mark and no reservation: %s" % [world.get_tool_item(pick_id)])
	_expect(world.get_tool_items().size() == 1 and String(world.get_tool_items()[0]["id"]) == pick_id,
		"the same pick id must be the only tool: %s" % [world.get_tool_items()])

## A critical food need on one colonist, so NeedsSystem interrupts its job on the next need tick.
func _starve(world: WorldStateType, colonist_id: String) -> void:
	for colonist in TestAccess.colonists(world):
		if String(colonist["id"]) == colonist_id:
			colonist["needs"]["food"] = 5

## No haul_tool job is queued or active.
func _haul_tool_closed(world: WorldStateType) -> bool:
	for job in world.get_jobs(["haul_tool"]):
		if job["status"] in ["queued", "active"]:
			return false
	return true

## The pick rests where the owner's rule (c769a48) allows: not in a hand; stocked in B while B takes
## tools (b_takes_tools: HaulGiver re-plans a set-down pick from the ground into B, review round 12),
## otherwise on the ground outside every stockpile; and reserved by no job that is no longer open.
func _tool_rests_validly(world: WorldStateType, b_takes_tools: bool) -> bool:
	var location := _pick_location(world)
	var type := String(location["type"])
	if type == "held":
		return false
	var cell := Vector2i(int(location["x"]), int(location["y"]))
	var rests := (type == "stockpile" and B.has_point(cell)) if b_takes_tools \
		else (type == "ground" and not A.has_point(cell) and not B.has_point(cell))
	var holder := String(world.get_tool_item_reservation(String(world.get_tool_items()[0]["id"])))
	return rests and (holder.is_empty() or String(world.get_job(holder).get("status", "")) in ["queued", "active"])

## Never in the hands of an idle colonist: whoever holds the pick is assigned an open job, and when
## that job is a haul_tool job it hauls this pick. Reports once per world to keep the log readable.
func _expect_holder_busy(world: WorldStateType, label: String) -> bool:
	var location := _pick_location(world)
	if String(location["type"]) != "held":
		return true
	var job_id := String(world.get_assignments().get(String(location["colonist_id"]), {}).get("job_id", ""))
	var job := world.get_job(job_id) if not job_id.is_empty() else {}
	var busy := String(job.get("status", "")) in ["queued", "active"] \
		and (String(job.get("kind", "")) != "haul_tool" or String(job.get("item_id", "")) == String(world.get_tool_items()[0]["id"]))
	if not busy and not world.has_meta("idle_holder_reported"):
		world.set_meta("idle_holder_reported", true)
		_fail("%s: an idle colonist holds the pick at tick %d: %s, job %s" % [label, world.get_tick(), location, job])
	return busy

## F5a-b, the owner's rule (c769a48), as a table driven tick by tick: moment (the haul_tool job is
## under way but the pick is still in A / the pick is carried) x interruption (a critical food need
## on the carrier / none) x destination fault (B rejects tools / B is walled off / the target cell
## itself turns to rock) x reservation (kept / released). In every case the job fails once through
## the shared engine with an existing reason, the carrier sets the pick down where it stands and
## HaulGiver re-plans from the ground. Every tick the pick is never held by a colonist without an
## open job for it; once the fault is undone the pick ends stocked in B (only while B takes tools)
## or on the ground outside every stockpile, with its id, no haul_tool job open, no stale reservation.
func _check_haul_tool_failure_matrix() -> void:
	var seed_value := 64025
	for moment in ["before", "after"]:
		for need in [true, false]:
			for fault in ["rejects", "unreachable", "walled"]:
				for release in [false, true]:
					var label := "%s/%s/%s/%s" % [moment, "need" if need else "no need", fault, "released" if release else "reserved"]
					_run_haul_tool_failure_case(seed_value, label, moment == "after", need, fault, release)
					seed_value += 1

func _run_haul_tool_failure_case(seed_value: int, label: String, carried: bool, need: bool, fault: String, release: bool) -> void:
	var world := _stocked_pick_world(seed_value, true)
	Scenarios.isolate_need(world, "food")
	var pick_id := String(world.get_tool_items()[0]["id"])
	_command_ok(world, "zone_set_stockpile", {"id": "zone_1", "groups": "material", "priority": 2})
	var job_id := ""
	var carrier := ""
	for _i in _day_ticks:
		world.tick()
		var location := _pick_location(world)
		if String(location["type"]) == "held":
			if carried:
				carrier = String(location["colonist_id"])
				job_id = String(world.get_assignments().get(carrier, {}).get("job_id", ""))
			break
		var assignments := world.get_assignments()
		for colonist_id in assignments:
			var assigned := world.get_job(String(assignments[colonist_id]["job_id"]))
			if not carried and String(assigned.get("kind", "")) == "haul_tool" and String(assigned.get("status", "")) == "active":
				job_id = String(assigned["id"])
				carrier = String(colonist_id)
		if not job_id.is_empty():
			break
	_expect(not job_id.is_empty() and not carrier.is_empty(), "%s: a haul_tool job must be under way: %s" % [label, world.get_jobs(["haul_tool"])])
	if job_id.is_empty() or carrier.is_empty():
		return
	var target: Vector3i = world.get_job(job_id)["target"]
	match fault:
		"rejects":
			_command_ok(world, "zone_set_stockpile", {"id": "zone_2", "groups": "material", "priority": 1})
		"unreachable":
			_wall_around(world, B, true)
		"walled":
			_set_rock(world, target, true)
	if release:
		world.release_tool_item_reservation(pick_id, job_id)
	if need:
		_starve(world, carrier)
	var job_of := func() -> Dictionary: return world.get_job(job_id)
	var ended := func() -> bool:
		_expect_holder_busy(world, label)
		return not (job_of.call().get("status", "") in ["queued", "active"])
	_expect(_tick_until(world, _day_ticks, ended) <= _day_ticks, "%s: the haul_tool job must end: %s" % [label, job_of.call()])
	var job: Dictionary = job_of.call()
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) in ["need_interrupt", "invalid_target", "blocked_target_unreachable"],
		"%s: the job must fail through the engine with an existing reason: %s" % [label, job])
	match fault:
		"unreachable":
			_wall_around(world, B, false)
		"walled":
			_set_rock(world, target, false)
	var rests := func() -> bool:
		_expect_holder_busy(world, label)
		return _haul_tool_closed(world) and _tool_rests_validly(world, fault != "rejects")
	_expect(_tick_until(world, _day_ticks * 2, rests) <= _day_ticks * 2,
		"%s: the pick must end stocked in a valid stockpile or on the ground outside every stockpile: %s, jobs %s"
			% [label, _pick_location(world), world.get_jobs(["haul_tool"])])
	_expect(world.get_tool_items().size() == 1 and String(world.get_tool_items()[0]["id"]) == pick_id,
		"%s: the same pick id must be the only tool: %s" % [label, world.get_tool_items()])

## Rock on one cell (rock = true), or floor again (false): a raw tile write, as in _wall_around.
func _set_rock(world: WorldStateType, cell: Vector3i, rock: bool) -> void:
	TestAccess.set_tile(world, cell.x, cell.y, WorldStateType.TILE_ROCK if rock else WorldStateType.TILE_FLOOR)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	TestAccess.tile_grid(world).rooms = null
