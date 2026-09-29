extends SceneTree

## Exercises the viewer's pure coordinate/command boundary without creating a
## window or sending operating-system input events.

const MapViewType = preload("res://scripts/viewer/map_view.gd")
const BootType = preload("res://scripts/boot.gd")
const BootScenePath := "res://scenes/boot.tscn"

var _failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var boot_scene: PackedScene = load(BootScenePath)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	boot_node.tick_driver.pause()
	boot_node._replace_world(BootType.build_default_world())
	var world = boot_node.get("world")
	_expect(world != null, "boot scene must expose a world")
	if world == null:
		_finish(boot_node)
		return

	var map_view := MapViewType.new()
	map_view.set_world(world)
	var soil := _find_tile(world, "soil")
	var tree := _find_tile(world, "tree")
	var rock := _find_tile(world, "rock")
	_expect(map_view.tile_at_local(Vector2(soil.x * MapViewType.TILE_SIZE + 1.0,
		soil.y * MapViewType.TILE_SIZE + 1.0)) == soil,
		"local pixel coordinates must map to the expected tile")

	var dig: Dictionary = boot_node._command_for_tile(BootType.Tool.DIG, soil)
	_expect(dig["type"] == "dig" and world.apply(dig).get("ok", false),
		"a dig command on soil must be accepted")
	var invalid_chop: Dictionary = boot_node._command_for_tile(BootType.Tool.CHOP, soil)
	var chop_result: Dictionary = world.apply(invalid_chop)
	_expect(chop_result.get("rejection", {}).get("reason") == "invalid_target",
		"a chop command on non-tree must be rejected as invalid_target")

	var no_job_cancel: Dictionary = boot_node._command_for_tile(BootType.Tool.CANCEL, rock)
	_expect(no_job_cancel.is_empty(), "cancel without a matching job must be empty")
	var queued_target := _find_tile(world, "soil", [soil])
	var queued_dig: Dictionary = boot_node._command_for_tile(BootType.Tool.DIG, queued_target)
	var queued_result: Dictionary = world.apply(queued_dig)
	_expect(queued_result.get("ok", false), "a second soil dig must create a queued job")
	var cancel: Dictionary = boot_node._command_for_tile(BootType.Tool.CANCEL, queued_target)
	_expect(cancel.get("type") == "cancel_job", "cancel must select the queued matching job")
	if not cancel.is_empty():
		_expect(world.apply(cancel).get("ok", false), "cancel_job command must be accepted")

	var rect_tiles: Array[Vector2i] = MapViewType.tiles_in_rectangle(Vector2i(2, 5), Vector2i(0, 3))
	var expected_rect: Array[Vector2i] = [
		Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 3),
		Vector2i(0, 4), Vector2i(1, 4), Vector2i(2, 4),
		Vector2i(0, 5), Vector2i(1, 5), Vector2i(2, 5),
	]
	_expect(rect_tiles == expected_rect,
		"tiles_in_rectangle must list every tile in row-major (ascending y, then x) order regardless of corner order")
	var single_tile_rect: Array[Vector2i] = MapViewType.tiles_in_rectangle(Vector2i(4, 4), Vector2i(4, 4))
	_expect(single_tile_rect == [Vector2i(4, 4)],
		"a rectangle with equal corners (a plain click) must be a single tile, reusing the same path")

	boot_node._select_tool(BootType.Tool.DIG)
	var rect_soil_a := _find_tile(world, "soil", [soil, queued_target])
	var rect_soil_b := _find_tile(world, "soil", [soil, queued_target, rect_soil_a])
	var rect_rock := rock
	var ordered_tiles: Array[Vector2i] = [rect_soil_a, rect_rock, rect_soil_b]
	var rejected: Array[Dictionary] = boot_node._commit_rectangle(ordered_tiles)
	_expect(rejected.size() == 1 and rejected[0]["tile"] == rect_rock and rejected[0]["reason"] == "invalid_target",
		"a rectangle mixing valid and invalid tiles must reject only the invalid one, with its actual reason")
	var jobs_for_a := _jobs_targeting(world, rect_soil_a)
	var jobs_for_b := _jobs_targeting(world, rect_soil_b)
	_expect(not jobs_for_a.is_empty() and not jobs_for_b.is_empty(),
		"each valid tile in the rectangle must get a command applied")
	if not jobs_for_a.is_empty() and not jobs_for_b.is_empty():
		# Job ids only ever increase, so the highest id on each target is the
		# one _commit_rectangle just created (any earlier job on the same
		# tile, e.g. from the scenario's own seeded orders, has a lower id).
		var id_a := _max_job_id(jobs_for_a)
		var id_b := _max_job_id(jobs_for_b)
		_expect(id_a < id_b,
			"commands must be applied in the given row-major order, first tile in the list first")

	var place_excluded: Array[Vector2i] = [soil, queued_target, rect_soil_a, rect_soil_b]
	for colonist in world.get_colonists():
		place_excluded.append(Vector2i(colonist["x"], colonist["y"]))
	var place_target := _find_tile(world, "floor", place_excluded)
	# Instant placement remains a test/debug command, never a toolbar tool.
	var place_wall: Dictionary = {"actor": "test", "command_id": "fixture_wall", "tick": world.get_tick(),
		"type": "place_object", "payload": {"x": place_target.x, "y": place_target.y, "kind": "wooden_wall"}}
	_expect(place_wall["type"] == "place_object" and place_wall["payload"] == {"x": place_target.x, "y": place_target.y, "kind": "wooden_wall"},
		"debug fixture must use the explicit place_object command")
	var place_result: Dictionary = world.apply(place_wall)
	_expect(place_result.get("ok", false), "a place_object command on an empty floor tile must be accepted")
	_expect(world.get_object(place_target.x, place_target.y) == "wooden_wall",
		"a committed place_object command must place the object on the world")

	var occupied_place: Dictionary = place_wall.duplicate(true)
	var occupied_result: Dictionary = world.apply(occupied_place)
	_expect(occupied_result.get("rejection", {}).get("reason") == "invalid_target",
		"place_object on an already-occupied tile must be rejected as invalid_target")

	var remove_object: Dictionary = boot_node._command_for_tile(BootType.Tool.REMOVE_OBJECT, place_target)
	_expect(remove_object["type"] == "remove_object" and remove_object["payload"] == {"x": place_target.x, "y": place_target.y},
		"remove-object tool must build a remove_object command")
	var remove_result: Dictionary = world.apply(remove_object)
	_expect(remove_result.get("ok", false), "a remove_object command on a placed object must be accepted")
	_expect(world.get_object(place_target.x, place_target.y) == "",
		"a committed remove_object command must clear the object from the world")

	var empty_remove: Dictionary = boot_node._command_for_tile(BootType.Tool.REMOVE_OBJECT, place_target)
	var empty_remove_result: Dictionary = world.apply(empty_remove)
	_expect(empty_remove_result.get("rejection", {}).get("reason") == "invalid_target",
		"remove_object on a tile with no object must be rejected as invalid_target")

	var expected_reason_text: String = boot_node._text_table.get_string("status.reason.invalid_target")
	var expected_rejected_line: String = boot_node._text_table.format(
		"status.rejected_tile_label", [rect_rock.x, rect_rock.y, expected_reason_text])
	_expect(boot_node._rejected_tiles_label.text == expected_rejected_line,
		"the rejected-tiles label must show '(x, y): <reason text>' for exactly the rejected tile")
	var rect_soil_c := _find_tile(world, "soil", [soil, queued_target, rect_soil_a, rect_soil_b])
	var single_valid_tile: Array[Vector2i] = [rect_soil_c]
	var clean_rejected: Array[Dictionary] = boot_node._commit_rectangle(single_valid_tile)
	_expect(clean_rejected.is_empty(), "an all-valid rectangle must reject nothing")
	_expect(boot_node._rejected_tiles_label.text.is_empty(),
		"a later commit with no rejections must replace (not leave stale) the rejected-tiles label")

	boot_node._select_tool(BootType.Tool.MINE)
	var mine: Dictionary = boot_node._command_for_tile(BootType.Tool.MINE, rock)
	_expect(mine.get("type") == "mine" and world.apply(mine).get("ok", false),
		"a mine command on rock must be accepted")
	var invalid_mine: Dictionary = boot_node._command_for_tile(BootType.Tool.MINE, soil)
	var mine_result: Dictionary = world.apply(invalid_mine)
	_expect(not mine_result.get("ok", true)
			and mine_result.get("rejection", {}).get("reason") == "invalid_target",
		"a mine command on non-rock must be rejected as invalid_target")
	var mine_rock := _find_tile(world, "rock", [rock])
	var mine_tiles: Array[Vector2i] = [mine_rock, soil]
	_expect(boot_node._preview_validity(mine_tiles) == [true, false],
		"Mine preview must mark rock valid and non-rock invalid")
	var mine_rejected: Array[Dictionary] = boot_node._commit_rectangle(mine_tiles)
	_expect(mine_rejected.size() == 1 and mine_rejected[0]["tile"] == soil
			and mine_rejected[0]["reason"] == "invalid_target",
		"a Mine rectangle mixing rock and non-rock must reject only the invalid tile")
	var mine_jobs := _jobs_targeting(world, mine_rock)
	_expect(mine_jobs.size() == 1 and mine_jobs[0]["kind"] == "mine",
		"the valid rock tile in a mixed Mine rectangle must receive a mine job")

	# Build tools (issue #278/#303 round 2): the toolbar's build buttons build
	# a real `build` command, so the hover preview runs WorldState.preview()'s
	# own rule (valid on an open floor tile once wood is stockpiled, invalid
	# on rock), and Cancel resolves a pending build by its construction site,
	# not by the wood tile its scheduler target names.
	var stock_tile := place_target
	world._items["ui_build_wood"] = {"id": "ui_build_wood", "x": stock_tile.x, "y": stock_tile.y, "kind": "wood", "count": 1}
	_expect(world.apply({"actor": "test", "command_id": "ui_build_zone", "tick": world.get_tick(), "type": "zone_add",
		"payload": {"x": stock_tile.x, "y": stock_tile.y, "width": 1, "height": 1}}).get("ok", false),
		"a stockpile zone over the build wood must be accepted")
	var build_site := _find_open_floor_tile(world, [stock_tile])
	_expect(build_site.x >= 0, "the boot world must offer an open floor tile for a build site")
	var bed_command: Dictionary = boot_node._command_for_tile(BootType.Tool.BUILD_BED, build_site)
	_expect(bed_command.get("type") == "build" and bed_command.get("payload") == {"kind": "bed", "x": build_site.x, "y": build_site.y},
		"the Build Bed tool must build a build command for kind bed")
	boot_node._select_tool(BootType.Tool.WALL)
	var build_preview_tiles: Array[Vector2i] = [build_site, rock]
	_expect(boot_node._preview_validity(build_preview_tiles) == [true, false],
		"Build Wall preview must mark an open floor tile valid and rock invalid (got %s)" % [boot_node._preview_validity(build_preview_tiles)])
	var build_single: Array[Vector2i] = [build_site]
	var build_command: Dictionary = boot_node._wall_command(build_single)
	var build_result: Dictionary = world.apply(build_command)
	_expect(build_result.get("ok", false), "the previewed-valid build command must be accepted: %s" % [build_result])
	_expect(boot_node._preview_validity(build_preview_tiles) == [false, false],
		"once ordered, the same site must preview invalid (claimed by the pending build)")
	var cancel_build: Dictionary = boot_node._command_for_tile(BootType.Tool.CANCEL, build_site)
	_expect(cancel_build.get("type") == "cancel_site" and cancel_build.get("payload", {}).get("x") == build_site.x
		and cancel_build.get("payload", {}).get("y") == build_site.y,
		"Cancel over the construction site must select cancel_site (got %s)" % [cancel_build])
	_expect(boot_node._command_for_tile(BootType.Tool.CANCEL, stock_tile).is_empty(),
		"Cancel over the wood's own tile must not select the build job")
	if not cancel_build.is_empty():
		_expect(world.apply(cancel_build).get("ok", false), "cancelling the build at its site must be accepted")
	boot_node._select_tool(-1)

	# F3 (issue #290): a dig command naming an assignee whose faction may not
	# be ordered by the player is rejected not_ordered_by_player, typed.
	var raider_id: String = world.get_colonists()[0]["id"]
	var set_faction_result: Dictionary = world.apply({
		"actor": "test", "command_id": "set_raider_faction", "tick": world.get_tick(),
		"type": "set_faction", "payload": {"target": raider_id, "faction_id": "raiders"},
	})
	_expect(set_faction_result.get("ok", false), "set_faction to raiders must be accepted")
	var raider_tile := _find_passable_soil_tile(world, [soil, queued_target, rect_soil_a, rect_soil_b, rect_soil_c])
	var raider_dig: Dictionary = {
		"actor": "player", "command_id": "raider_dig", "tick": world.get_tick(), "type": "dig",
		"payload": {"x": raider_tile.x, "y": raider_tile.y, "assignee": raider_id},
	}
	var raider_dig_result: Dictionary = world.apply(raider_dig)
	_expect(not raider_dig_result.get("ok", true)
			and raider_dig_result.get("rejection", {}).get("reason") == "not_ordered_by_player",
		"a dig command assigned to a non-colony (raiders) actor must be rejected not_ordered_by_player")

	map_view.free()
	_check_wall_gesture(boot_node)
	_finish(boot_node)

func _check_wall_gesture(boot) -> void:
	if boot._map_view == null:
		boot._build_ui()
	var world := preload("res://scripts/core/world_state.gd").new(452, 10)
	world._tiles.fill("floor")
	world._colonists.clear()
	world._objects.clear()
	world._items.clear()
	boot._replace_world(world)
	var view = boot._map_view
	boot._tool_buttons[BootType.Tool.WALL].pressed.emit()
	_expect(view.tool_enabled and not view.is_build_tool_enabled(), "Wall must arm the rectangle gesture")
	_expect(boot._command_for_tile(BootType.Tool.WALL, Vector2i(4, 4)).is_empty(),
		"Wall must have no single-tile build/instant-placement command path")
	var start := Vector2i(4, 4)
	var end := Vector2i(6, 5)
	var tiles := MapViewType.tiles_in_rectangle(start, end)
	var observed_kinds: Array[String] = []
	view.preview_validity = func(candidates: Array[Vector2i]) -> Array[bool]:
		observed_kinds.append(boot._wall_command(candidates)["payload"]["kind"])
		return boot._preview_validity(candidates)
	var before := world.get_events().size()
	_mouse_button(view, end, true)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(start * MapViewType.TILE_SIZE) + Vector2.ONE
	view._gui_input(motion)
	_expect(world.get_events().size() == before, "wall press and drag must not submit commands")
	_expect(view._preview_tiles == tiles and view._preview_valid == [true, true, true, true, true, true],
		"reverse drag must preview the complete filled rectangle in row-major order")
	var hash_before: int = world.state_hash()
	boot._wall_kind_buttons["stone_wall"].pressed.emit()
	_expect(observed_kinds[-1] == "stone_wall" and world.state_hash() == hash_before,
		"material picker must immediately refresh the live rectangle using a read-only stone batch preview")
	_expect(view._preview_tiles == tiles, "material change must preserve the candidate rectangle")
	_mouse_button(view, start, false)
	var events: Array = world.get_events().slice(before)
	_expect(events.size() == 1 and events[0]["type"] == "command_applied"
		and events[0]["data"] == boot._wall_command(tiles)["payload"],
		"release must apply exactly one complete build_line payload for the selected stone kind")
	_expect(boot._wall_command(tiles)["type"] == "build_line", "wall command must be build_line")
	_expect(world.get_construction_sites().size() == tiles.size(), "one drag must create a site for every clear tile")
	_expect(boot._preview_validity(tiles) == [false, false, false, false, false, false],
		"claimed sites must all turn red")
	boot._wall_kind_buttons["wooden_wall"].pressed.emit()
	var mixed: Array[Vector2i] = [start, Vector2i(9, 9)]
	_expect(boot._preview_validity(mixed) == [false, true], "batch preview must colour skipped and surviving tiles separately")
	var rejected: Array = boot._commit_rectangle(mixed)
	_expect(rejected.size() == 1 and rejected[0]["tile"] == start, "skipped batch cells must report their rejection")
	var single: Array[Vector2i] = [Vector2i(12, 12)]
	before = world.get_events().size()
	_mouse_button(view, single[0], true)
	boot._select_tool(-1)
	_mouse_button(view, single[0], false)
	_expect(world.get_events().size() == before, "leaving Wall must cancel an unfinished rectangle")
	boot._tool_buttons[BootType.Tool.WALL].pressed.emit()
	_mouse_button(view, single[0], true)
	_mouse_button(view, single[0], false)
	events = world.get_events().slice(before)
	_expect(events.size() == 1 and events[0]["data"] == boot._wall_command(single)["payload"]
		and events[0]["data"]["kind"] == "wooden_wall", "a wooden click must submit one 1x1 batch")
	view.preview_validity = boot._preview_validity
	# Only the complete north row seals this room; per-tile previews miss it.
	var enclosed := preload("res://scripts/core/world_state.gd").new(4521, 10)
	enclosed._tiles.fill("floor")
	enclosed._colonists.clear()
	enclosed._objects.clear()
	enclosed._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 5, "y": 5,
		"needs": {"food": 100, "water": 100, "rest": 100}, "route": null, "work": null, "carrying": null})
	boot._replace_world(enclosed)
	var sides: Array[Vector2i] = [Vector2i(4, 7), Vector2i(5, 7), Vector2i(6, 7), Vector2i(7, 7),
		Vector2i(4, 5), Vector2i(4, 6), Vector2i(7, 5), Vector2i(7, 6)]
	_expect(enclosed.apply(boot._wall_command(sides)).get("ok", false), "room fixture must accept its open sides")
	var north := MapViewType.tiles_in_rectangle(Vector2i(4, 4), Vector2i(7, 4))
	for kind in ["wooden_wall", "stone_wall"]:
		boot._wall_kind_buttons[kind].pressed.emit()
		_expect(boot._preview_validity(north) == [false, false, false, false],
			"whole-batch enclosure rejection must colour every candidate red for " + kind)
	var sites_before := enclosed.get_construction_sites().size()
	rejected = boot._commit_rectangle(north)
	_expect(rejected.size() == north.size() and rejected[0]["reason"] == "blocked_target_unreachable"
		and enclosed.get_construction_sites().size() == sites_before,
		"whole-batch rejection must report every tile without placing partial walls")

func _mouse_button(view, tile: Vector2i, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = Vector2(tile * MapViewType.TILE_SIZE) + Vector2.ONE
	view._gui_input(event)

func _jobs_targeting(world, tile: Vector2i) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for job in world.get_jobs():
		if job["target"] == tile:
			result.append(job)
	return result

func _max_job_id(jobs: Array[Dictionary]) -> int:
	var best := -1
	for job in jobs:
		best = maxi(best, int(String(job["id"]).trim_prefix("job_")))
	return best

## width/height read from the world itself, not hardcoded (issue #300: the
## default boot world is now 256x256, not the debug scenario's 48x48 -- see
## boot.gd's build_default_world()).
func _find_tile(world, kind: String, excluded: Array[Vector2i] = []) -> Vector2i:
	var tiles: Array[String] = world.get_tiles()
	var width: int = world.get_map_width()
	for y in world.get_map_height():
		for x in width:
			if tiles[y * width + x] == kind and not excluded.has(Vector2i(x, y)):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## Like _find_tile(world, "soil", ...), but also requires passability(): a
## placed object (e.g. a table) can sit on a soil tile, which remains kind
## "soil" but is not a valid dig target (invalid_target).
func _find_passable_soil_tile(world, excluded: Array[Vector2i] = []) -> Vector2i:
	var tiles: Array[String] = world.get_tiles()
	var width: int = world.get_map_width()
	for y in world.get_map_height():
		for x in width:
			if (tiles[y * width + x] == "soil" and not excluded.has(Vector2i(x, y))
					and bool(world.passability(x, y)["passable"])):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## A floor tile whose whole 3x3 neighbourhood is passable floor with no
## object, colonist or ground item, so a build there can neither be rejected
## as occupied nor as enclosing (a tile whose full ring stays passable can
## never cut its component). Vector2i(-1, -1) when none exists.
func _find_open_floor_tile(world, excluded: Array[Vector2i] = []) -> Vector2i:
	var occupied := {}
	for colonist in world.get_colonists():
		occupied[Vector2i(colonist["x"], colonist["y"])] = true
	for item in world.get_items():
		occupied[Vector2i(item["x"], item["y"])] = true
	for y in range(1, world.get_map_height() - 1):
		for x in range(1, world.get_map_width() - 1):
			var open := not excluded.has(Vector2i(x, y))
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var tile := Vector2i(x + dx, y + dy)
					if (world.get_tile(tile.x, tile.y) != "floor" or not world.get_object(tile.x, tile.y).is_empty()
							or occupied.has(tile) or not bool(world.passability(tile.x, tile.y)["passable"])):
						open = false
			if open:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _finish(boot_node: Node) -> void:
	root.remove_child(boot_node)
	boot_node.free()
	if _failures.is_empty():
		print("test_order_input: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("test_order_input: " + failure)
	quit(1)
