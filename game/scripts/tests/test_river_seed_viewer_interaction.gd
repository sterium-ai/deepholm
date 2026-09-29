extends SceneTree

## Issue #300 Owner verification, driven through the RUNNING VIEWER for
## exactly seeds 1337 and 20260919: "recognise the river at a glance,
## find food and water next to the colonists and complete an initial
## order without being blocked by the river".
##
## Review rounds 5-7 kept this item open because the earlier automation
## (test_river_seed_order_completion.gd) submitted the forage command
## straight into WorldState.apply() and ticked the world by hand -- it never
## touched the viewer's own input path. This test does what a player at the
## PC does, through the same engine input routing a real mouse uses
## (Viewport.push_input, the pattern test_map_camera.gd already relies on):
##
##   1. types the seed into the visible seed field and clicks the real
##      "New Game" button, then the real ConfirmationDialog OK button;
##   2. checks the new game starts PAUSED with an empty job queue (no debug
##      scenario dig orders) and the HUD shows the active seed;
##   3. checks food and water are within the documented route bounds of every
##      colonist (an independent BFS through world.passability(), so a bush
##      or bank across the river never counts);
##   4. checks the river is drawn as water by the viewer's own terrain
##      overlay (one overlay cell per water tile) and, in a graphical run, by
##      sampling the actually rendered pixels: a river tile must render
##      blue-dominant and a plain soil tile must not;
##   5. clicks the real "Forage" tool button, then left-clicks the map at a
##      reachable berry bush -- the click travels root -> MapViewport._gui_input
##      -> MapView._gui_input -> rectangle_committed -> Boot._commit_rectangle
##      -> WorldState.apply(), exactly the player's path;
##   6. clicks the real "x1" speed button and lets the real TickDriver advance
##      the world until that player-selected order completes.
##
## Headless: every check above except the pixel sampling and the PNG
## captures runs and must pass. Graphical (`-- --capture`, no --headless):
## the same run additionally samples the rendered frame and writes
## user://captures/seed<seed>-interactive-*.png.
##
## godot --headless --path game --script res://scripts/tests/test_river_seed_viewer_interaction.gd
## godot --path game --script res://scripts/tests/test_river_seed_viewer_interaction.gd -- --capture

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

const SEEDS := [1337, 20260919]
const SAVE_DIR := "user://test-river-seed-viewer-interaction-saves"
const EVIDENCE_DIR := "user://captures"
const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const WATER_STEP_LIMIT := 40
const FOOD_STEP_LIMIT := 40
const ORDER_TICK_BUDGET := 6000
const TICK_SECONDS := 1.0 / TickDriverType.BASE_TICKS_PER_SECOND

var failures: Array[String] = []
var boot: Node
var camera: Control
var map: Control

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_cleanup_save_dir()
	boot = Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	boot.save_manager = SaveManagerType.new(SAVE_DIR)
	if boot._map_view == null:
		boot._build_ui()
	camera = boot._map_viewport
	map = boot._map_view
	root.size = Vector2i(1920, 1080)
	await process_frame
	await process_frame

	for seed_value in SEEDS:
		await _check_seed(seed_value)

	boot.queue_free()
	await process_frame
	_cleanup_save_dir()
	if failures.is_empty():
		print("test_river_seed_viewer_interaction: PASS")
		quit()
	else:
		for failure in failures:
			push_error("test_river_seed_viewer_interaction: " + failure)
		quit(1)

func _check_seed(seed_value: int) -> void:
	var tag := "seed %d" % seed_value

	# 1. New Game through the visible seed field, the real New Game button and
	#    the real confirmation dialog's OK button.
	boot._seed_input.text = str(seed_value)
	await _click_button("New Game")
	_expect(boot._new_game_confirm.visible, "%s: clicking New Game must open the confirmation dialog" % tag)
	boot._new_game_confirm.get_ok_button().pressed.emit()
	boot._new_game_confirm.hide()
	await process_frame
	await process_frame
	var world = boot.world
	_expect(world.get_seed() == seed_value, "%s: the running world must carry the requested seed" % tag)
	_expect(boot._active_seed_label.text == "Active seed: %d" % seed_value,
		"%s: the HUD must show the active seed, got '%s'" % [tag, boot._active_seed_label.text])

	# 2. Paused, no random debug dig queue.
	_expect(boot.tick_driver.speed == TickDriverType.Speed.PAUSED, "%s: a new game must start paused" % tag)
	_expect(world.get_jobs().is_empty(), "%s: a new game must start with an empty job queue, found %d jobs" % [tag, world.get_jobs().size()])
	var colonists: Array = world.get_colonists()
	_expect(colonists.size() == 3, "%s: New Game must spawn exactly 3 colonists, found %d" % [tag, colonists.size()])
	if colonists.size() != 3:
		return

	# 3. Food and water next to the colonists, by real route per colonist.
	for colonist in colonists:
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var colonist_id := String(colonist["id"])
		var water_steps := _bfs_route_distance(world, start, func(x, y): return world.get_tile(x, y) == "water")
		var food_steps := _bfs_route_distance(world, start, func(x, y): return world.get_object(x, y) == "berry_bush")
		_expect(water_steps != -1 and water_steps <= WATER_STEP_LIMIT,
			"%s colonist %s must reach water within %d steps, got %d" % [tag, colonist_id, WATER_STEP_LIMIT, water_steps])
		_expect(food_steps != -1 and food_steps <= FOOD_STEP_LIMIT,
			"%s colonist %s must reach food within %d steps, got %d" % [tag, colonist_id, FOOD_STEP_LIMIT, food_steps])

	# 4. The river reads as water in the viewer: every water tile gets its
	#    own registered water cell in the terrain TileMapLayer -- never
	#    another kind's cell (e.g. hazard's). Issue #301 round 3: water no
	#    longer carries directional shore cells of its own -- the jagged
	#    bank comes from the grass overlay layer on the neighbouring prairie
	#    tiles instead, so every water tile must resolve to the single plain
	#    water cell.
	_expect(map.is_art_enabled(), "%s: the normal view must be the default art renderer" % tag)
	var tile_map: TileMapLayer = map.get("_tile_map_layer")
	_expect(tile_map != null, "%s: the map view must own a terrain TileMapLayer" % tag)
	var water_tiles := 0
	var tiles: Array = world.get_tiles()
	var map_width: int = world.get_map_width()
	for kind in tiles:
		if kind == "water":
			water_tiles += 1
	if tile_map != null:
		var water_atlas: Dictionary = TileAtlasMapType.TILE_ATLAS_MAP["water"]
		var water_source_id: int = int(water_atlas["source_id"])
		var water_coords: Vector2i = water_atlas["coords"]
		var hazard_coords: Vector2i = TileAtlasMapType.TILE_ATLAS_MAP["hazard"]["coords"]
		_expect(water_coords != hazard_coords,
			"%s: the water cell must be unmistakably distinct from the hazard cell, got %s for both" % [tag, water_coords])
		var painted_water := 0
		for i in tiles.size():
			if tiles[i] != "water":
				continue
			var x: int = i % map_width
			var y: int = i / map_width
			var pos := Vector2i(x, y)
			# source_id AND coords must both match: several single-crop
			# sources legitimately reuse local coords (0,0) for their own one
			# tile (e.g. the hazard/tree/sprout decor sources), so coords
			# alone cannot tell a water cell apart from one of those.
			if tile_map.get_cell_atlas_coords(pos) == water_coords and tile_map.get_cell_source_id(pos) == water_source_id:
				painted_water += 1
		_expect(painted_water == water_tiles,
			"%s: every river tile must render as the plain water cell -- source_id %d, coords %s (%d painted, %d water tiles)" % [tag, water_source_id, water_coords, painted_water, water_tiles])

		# Headless-safe blue-dominant check: samples the registered water
		# cell's OWN texture region straight from its TileSetAtlasSource, so
		# this runs under plain `--headless` and does not depend on the
		# graphical-only rendered-frame sampling below (step 4's pixel check
		# only runs under `-- --capture`).
		var water_source := tile_map.tile_set.get_source(water_source_id) as TileSetAtlasSource
		_expect(water_source != null, "%s: water source %d must be a TileSetAtlasSource" % [tag, water_source_id])
		if water_source != null:
			var region := water_source.get_tile_texture_region(water_coords)
			var image := water_source.texture.get_image()
			var total := Color(0, 0, 0)
			var sampled := 0
			for py in range(region.position.y, region.position.y + region.size.y):
				for px in range(region.position.x, region.position.x + region.size.x):
					total += image.get_pixel(px, py)
					sampled += 1
			var average := total / float(sampled)
			_expect(average.b > average.r + 0.2 and average.b > average.g + 0.1,
				"%s: the registered water cell's own texture region must be blue-dominant, got %s" % [tag, average])

	# Frame the spawn at 0.5x so a bush and a bank within 40 steps are on
	# screen, exactly as a player zooms out to look around.
	camera.zoom_at(camera.size * 0.5, 0.5)
	camera.center_colonists()
	await process_frame
	await process_frame

	var origin := Vector2i(int(colonists[0]["x"]), int(colonists[0]["y"]))
	var bush := _bfs_nearest(world, origin, func(x, y): return world.get_object(x, y) == "berry_bush")
	var bush_steps: int = _bfs_steps.get(bush.y * world.get_map_width() + bush.x, -1)
	var bank := _bfs_nearest(world, origin, func(x, y): return world.get_tile(x, y) == "water")
	var soil := _bfs_nearest(world, origin, func(x, y): return world.get_tile(x, y) == "soil" and world.get_object(x, y) == "" and not _has_colonist(world, x, y))
	_expect(bush != Vector2i(-1, -1), "%s: colonist_0 must have a reachable berry bush to order against" % tag)
	_expect(bank != Vector2i(-1, -1), "%s: colonist_0 must have a reachable river bank" % tag)
	_expect(soil != Vector2i(-1, -1), "%s: colonist_0 must stand near plain soil" % tag)
	if bush == Vector2i(-1, -1) or bank == Vector2i(-1, -1) or soil == Vector2i(-1, -1):
		return
	var bush_screen := _tile_screen_center(bush)
	var bank_screen := _tile_screen_center(bank)
	var soil_screen := _tile_screen_center(soil)
	for point in [bush_screen, bank_screen, soil_screen]:
		_expect(camera.get_global_rect().has_point(point), "%s: %s must be on screen at 0.5x centred on the colonists" % [tag, point])
	_expect(camera.screen_to_tile(bush_screen) == bush, "%s: screen/tile conversion must round-trip the bush" % tag)

	await _capture("seed%d-interactive-spawn" % seed_value)
	var frame := await _rendered_frame()
	if frame != null:
		var water_pixel := frame.get_pixelv(Vector2i(bank_screen))
		var soil_pixel := frame.get_pixelv(Vector2i(soil_screen))
		_expect(water_pixel.b > water_pixel.r + 0.2 and water_pixel.b > water_pixel.g + 0.1,
			"%s: the rendered river tile %s must be blue-dominant, got %s" % [tag, bank, water_pixel])
		_expect(not (soil_pixel.b > soil_pixel.r and soil_pixel.b > soil_pixel.g),
			"%s: the rendered soil tile %s must not read as water, got %s" % [tag, soil, soil_pixel])

	# 5. Player-selected order: the real Forage tool button, then a real left
	#    click on the map at the bush.
	await _click_button(boot._text_table.get_string("controls.tool_forage"))
	_expect(boot._selected_tool == Boot.Tool.FORAGE, "%s: clicking the Forage button must select the forage tool" % tag)
	var jobs_before: int = world.get_jobs().size()
	await _click(bush_screen)
	var order := _job_at(world, bush, "forage")
	_expect(not order.is_empty(), "%s: the map click must queue one forage job at %s (jobs before %d, after %d)" % [tag, bush, jobs_before, world.get_jobs().size()])
	_expect(boot._rejected_tiles_label.text == "", "%s: the order must not be rejected: '%s'" % [tag, boot._rejected_tiles_label.text])
	boot._select_tool(-1)
	await _capture("seed%d-interactive-order-placed" % seed_value)

	# 6. Resume with the real x1 button; the real TickDriver drives the world.
	await _click_button(boot._text_table.get_string("controls.speed_x1"))
	_expect(boot.tick_driver.speed == TickDriverType.Speed.X1, "%s: clicking x1 must resume the world" % tag)
	var ticks := 0
	var start_tick: int = int(world.get_tick())
	while ticks < ORDER_TICK_BUDGET and world.get_object(bush.x, bush.y) == "berry_bush":
		boot.tick_driver._process(TICK_SECONDS)
		ticks += 1
	_expect(world.get_tick() > start_tick, "%s: the tick driver must advance the world at x1" % tag)
	_expect(world.get_object(bush.x, bush.y) != "berry_bush",
		"%s: the player-selected forage order at %s must complete within %d ticks" % [tag, bush, ORDER_TICK_BUDGET])
	_expect(world.get_ground_berries(bush.x, bush.y) > 0,
		"%s: completing the forage must leave ground berries at %s" % [tag, bush])
	print("%s: colonist_0 at %s, forage clicked at %s (%d steps), bank %s, order completed after %d ticks at x1" % [
		tag, origin, bush, bush_steps, bank, ticks])
	boot.tick_driver.pause()
	await process_frame
	await _capture("seed%d-interactive-order-done" % seed_value)

func _click_button(text: String) -> void:
	var button: Button = _find_button(text)
	_expect(button != null, "HUD must have a '%s' button" % text)
	if button == null:
		return
	await _click(button.global_position + button.size * 0.5)

func _find_button(text: String) -> Button:
	for child in boot._controls.get_children():
		if child is Button and child.text == text:
			return child
	return null

func _tile_screen_center(tile: Vector2i) -> Vector2:
	return map.get_global_transform_with_canvas() * ((Vector2(tile) + Vector2(0.5, 0.5)) * map.TILE_SIZE)

func _job_at(world, tile: Vector2i, kind: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["kind"]) == kind and job["target"] == tile:
			return job
	return {}

func _has_colonist(world, x: int, y: int) -> bool:
	for colonist in world.get_colonists():
		if int(colonist["x"]) == x and int(colonist["y"]) == y:
			return true
	return false

## Real-route BFS (world.passability(), four neighbours) to the nearest
## neighbour `is_target` accepts: steps to stand next to it, plus one.
func _bfs_route_distance(world, start: Vector2i, is_target: Callable) -> int:
	var target := _bfs_nearest(world, start, is_target)
	if target == Vector2i(-1, -1):
		return -1
	return _bfs_steps[target.y * world.get_map_width() + target.x]

var _bfs_steps: Dictionary = {}

func _bfs_nearest(world, start: Vector2i, is_target: Callable) -> Vector2i:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start]
	visited[start.y * width + start.x] = 0
	_bfs_steps = {}
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var distance: int = visited[current.y * width + current.x]
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			if is_target.call(nx, ny):
				_bfs_steps[ny * width + nx] = distance + 1
				return Vector2i(nx, ny)
			var nindex := ny * width + nx
			if not visited.has(nindex) and bool(world.passability(nx, ny)["passable"]):
				visited[nindex] = distance + 1
				queue.append(Vector2i(nx, ny))
	return Vector2i(-1, -1)

func _button(at: Vector2, button: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = button
	event.pressed = pressed
	event.button_mask = (1 << (button - 1)) if pressed else 0
	root.push_input(event, true)
	await process_frame

func _click(at: Vector2) -> void:
	await _button(at, MOUSE_BUTTON_LEFT, true)
	await _button(at, MOUSE_BUTTON_LEFT, false)

func _graphical() -> bool:
	return "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"

func _rendered_frame() -> Image:
	if not _graphical():
		return null
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _capture(label: String) -> void:
	if not _graphical():
		return
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(EVIDENCE_DIR)
	DirAccess.make_dir_recursive_absolute(path)
	var result := root.get_texture().get_image().save_png(path.path_join(label + ".png"))
	_expect(result == OK, "capture " + label)

func _cleanup_save_dir() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_DIR)
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
