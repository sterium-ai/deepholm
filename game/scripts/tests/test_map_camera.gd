extends SceneTree

const Boot = preload("res://scripts/boot.gd")
const Scenario = preload("res://scripts/viewer/debug_scenario.gd")
var failures: Array[String] = []
var committed: Array[Vector2i] = []
var boot: Node
var camera: Control
var map: Control

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	boot = Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	boot._replace_world(Scenario.build())
	if boot._map_view == null:
		boot._build_ui()
	camera = boot._map_viewport
	map = boot._map_view
	map.rectangle_committed.connect(func(tiles): committed.assign(tiles))
	for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.size = resolution
		await process_frame
		await process_frame
		boot._replace_world(Scenario.build())
		camera.zoom_at(camera.size * 0.5, 1.0)
		camera.center_colonists()
		_expect(camera.size.x > 500 and camera.size.y > 500, "free map area at %s" % resolution)
		_expect(camera.clip_contents, "map clips to its own viewport")
		boot._select_tool(-1)
		var hash_before: int = boot.world.state_hash()
		await _click(camera.global_position + camera.size * 0.5)
		_expect(boot.world.state_hash() == hash_before and map._preview_tiles.is_empty(), "navigation click is inert")
		var click_position := map.position
		await _motion(camera.global_position + camera.size * 0.5 + Vector2(24, 12), Vector2(24, 12), 0)
		_expect(map.position == click_position, "hover after navigation click does not pan")
		var pan_point := camera.global_position + camera.size * 0.5
		var pan_start := map.position
		await _button(pan_point, MOUSE_BUTTON_LEFT, true)
		await _motion(pan_point + Vector2(24, 12), Vector2(24, 12), MOUSE_BUTTON_MASK_LEFT)
		await _button(pan_point + Vector2(24, 12), MOUSE_BUTTON_LEFT, false)
		var left_pan_position := map.position
		map.position = pan_start
		await _button(pan_point, MOUSE_BUTTON_MIDDLE, true)
		await _motion(pan_point + Vector2(24, 12), Vector2(24, 12), MOUSE_BUTTON_MASK_MIDDLE)
		await _button(pan_point + Vector2(24, 12), MOUSE_BUTTON_MIDDLE, false)
		_expect(left_pan_position == map.position, "navigate left drag pans like middle drag")
		map.position = pan_start
		boot._select_tool(Boot.Tool.CHOP)
		var tool_pan_start := map.position
		await _button(pan_point, MOUSE_BUTTON_LEFT, true)
		await _motion(pan_point + Vector2(24, 12), Vector2(24, 12), MOUSE_BUTTON_MASK_LEFT)
		var tool_preview: Array = map._preview_tiles.duplicate()
		_expect(map.position == tool_pan_start and not tool_preview.is_empty(), "tool left drag does not pan")
		await _button(pan_point + Vector2(24, 12), MOUSE_BUTTON_LEFT, false)
		_expect(committed == tool_preview, "tool left drag still commits its rectangle")
		boot._select_tool(-1)
		await _capture("%dx%d-normal" % [resolution.x, resolution.y])
		for zoom in [0.5, 1.0, 3.0]:
			boot._replace_world(Scenario.build())
			camera.zoom_at(camera.size * 0.5, zoom)
			camera.pan_by(Vector2(-123, -79))
			var hud_position: Vector2 = boot._controls.global_position
			var panel_position: Vector2 = boot._ui_scroll.global_position
			var center_screen: Vector2 = camera.global_position + camera.size * 0.5
			var tile: Vector2i = camera.screen_to_tile(center_screen)
			# Pick a visible real tree, leaving room for a mixed rectangle.
			var best_distance := INF
			for y in range(1, 45):
				for x in range(1, 44):
					if boot.world.get_tiles()[y * 48 + x] != "tree":
						continue
					var point := map.get_global_transform_with_canvas() * (Vector2(x, y) * 16 + Vector2(8, 8))
					var far_point: Vector2 = point + Vector2(3, 2) * 16 * zoom
					if not camera.get_global_rect().has_point(point) or not camera.get_global_rect().has_point(far_point):
						continue
					var distance := point.distance_squared_to(center_screen)
					if distance < best_distance:
						best_distance = distance
						tile = Vector2i(x, y)
			var end_tile := tile + Vector2i(3, 2)
			var start := map.get_global_transform_with_canvas() * (Vector2(tile) * 16 + Vector2(8, 8))
			var end := map.get_global_transform_with_canvas() * (Vector2(end_tile) * 16 + Vector2(8, 8))
			_expect(camera.screen_to_tile(start) == tile, "inverse transform at %s" % zoom)
			boot._select_tool(Boot.Tool.CHOP)
			var before_preview: int = boot.world.state_hash()
			await _button(start, MOUSE_BUTTON_LEFT, true)
			await _motion(end, end - start, MOUSE_BUTTON_MASK_LEFT)
			var preview: Array = map._preview_tiles.duplicate()
			_expect(preview == map.tiles_in_rectangle(tile, end_tile), "exact preview after pan at %s" % zoom)
			var expected_valid: Array = boot._preview_validity(map._preview_tiles)
			_expect(boot.world.state_hash() == before_preview, "hover and rectangle validation leave live state unchanged")
			_expect(true in expected_valid and false in expected_valid, "preview contains valid and invalid real targets")
			var preview_hash: int = boot.world.state_hash()
			await _capture("%dx%d-selection-%s" % [resolution.x, resolution.y, str(zoom).replace(".", "_")])
			_expect(boot.world.state_hash() == preview_hash, "preview never mutates world")
			await _button(end, MOUSE_BUTTON_LEFT, false)
			_expect(committed == preview, "confirmed rectangle matches preview at %s" % zoom)
			for i in preview.size():
				if expected_valid[i]:
					var found := false
					for job in boot.world.get_jobs():
						if job["target"] == preview[i] and job["kind"] == "chop":
							found = true
					_expect(found, "valid preview creates real chop job")
			_expect(map._preview_tiles.is_empty(), "grid disappears on confirm")
			hash_before = boot.world.state_hash()
			await _button(start, MOUSE_BUTTON_LEFT, true)
			await _button(start, MOUSE_BUTTON_MIDDLE, true)
			await _motion(start + Vector2(24, 12), Vector2(24, 12), MOUSE_BUTTON_MASK_MIDDLE)
			await _button(start, MOUSE_BUTTON_MIDDLE, false)
			await _button(start, MOUSE_BUTTON_LEFT, false)
			_expect(not map._dragging and map._preview_tiles.is_empty(), "pan cancels selection")
			for button in boot._controls.get_children():
				if button.text == "Step":
					button.grab_focus()
			await _key(KEY_SPACE, true)
			await _button(start, MOUSE_BUTTON_LEFT, true)
			await _motion(start + Vector2(24, 12), Vector2(24, 12), MOUSE_BUTTON_MASK_LEFT)
			await _button(start, MOUSE_BUTTON_LEFT, false)
			await _key(KEY_SPACE, false)
			var zoom_before: float = camera.zoom_level
			await _button(boot._ui_scroll.global_position + Vector2(20, 150), MOUSE_BUTTON_WHEEL_UP, true)
			_expect(camera.zoom_level == zoom_before, "wheel over panel cannot zoom map")
			await _button(start, MOUSE_BUTTON_LEFT, true)
			await _button(boot._ui_scroll.global_position + Vector2(20, 150), MOUSE_BUTTON_LEFT, false)
			_expect(not map._dragging, "release over panel aborts designation")
			await _key(KEY_ESCAPE, true)
			await _key(KEY_ESCAPE, false)
			_expect(not map.tool_enabled and map._preview_tiles.is_empty(), "Escape leaves tool")
			for button in boot._controls.get_children():
				if button.text == "Center colonists":
					await _click(button.get_global_rect().get_center())
			_expect(boot.world.state_hash() == hash_before, "pan/HUD/Escape/center do not create or cancel jobs")
			_expect(boot._controls.global_position == hud_position and boot._ui_scroll.global_position == panel_position, "camera never moves HUD")
			boot._select_tool(Boot.Tool.CHOP)
			await _button(camera.global_position + camera.size * 0.5, MOUSE_BUTTON_LEFT, true)
			camera.center_colonists()
			await _button(camera.global_position + camera.size * 0.5, MOUSE_BUTTON_LEFT, false)
			_expect(boot.world.state_hash() == hash_before and not map._dragging, "centering discards unfinished rectangle")
			for direction in [-1, 1]:
				camera.pan_by(Vector2.ONE * direction * 100000)
				var extent: Vector2 = map.size * zoom
				for axis in 2:
					if extent[axis] <= camera.size[axis]:
						_expect(is_equal_approx(map.position[axis], (camera.size[axis] - extent[axis]) * 0.5), "small map centered")
					else:
						_expect(map.position[axis] <= 0 and map.position[axis] >= camera.size[axis] - extent[axis], "large map clamped")
				var edge := Vector2i.ZERO if direction > 0 else Vector2i(47, 47)
				var edge_screen := map.get_global_transform_with_canvas() * (Vector2(edge) * 16 + Vector2(8, 8))
				_expect(camera.screen_to_tile(edge_screen) == edge, "edge conversion at %s" % zoom)
				boot._select_tool(Boot.Tool.CHOP)
				await _button(edge_screen, MOUSE_BUTTON_LEFT, true)
				var edge_preview: Array = map._preview_tiles.duplicate()
				await _button(edge_screen, MOUSE_BUTTON_LEFT, false)
				_expect(edge_preview == [edge] and committed == edge_preview, "edge preview equals confirmed tile")
	# Cursor anchoring away from clamps, then zoom bounds through real GUI input.
	camera.zoom_at(camera.size * 0.5, 3.0)
	camera.pan_by(Vector2(-400, -400))
	var cursor: Vector2 = camera.global_position + camera.size * 0.5
	var anchor: Vector2 = camera.screen_to_world(cursor)
	await _button(cursor, MOUSE_BUTTON_WHEEL_DOWN, true)
	_expect(camera.screen_to_world(cursor).is_equal_approx(anchor), "wheel preserves cursor world anchor away from bounds")
	camera.zoom_at(camera.size * 0.5, 100.0)
	_expect(camera.zoom_level == 3.0, "maximum zoom")
	camera.zoom_at(camera.size * 0.5, 0.01)
	_expect(camera.zoom_level == 0.5, "minimum zoom")
	boot._select_tool(Boot.Tool.CHOP)
	await _button(cursor, MOUSE_BUTTON_MIDDLE, true)
	boot._replace_world(Scenario.build())
	_expect(camera._pan_button == 0 and not map._dragging and map._preview_tiles.is_empty(), "load clears transient gestures")
	await _button(cursor, MOUSE_BUTTON_MIDDLE, false)
	boot.queue_free()
	await process_frame
	if failures.is_empty():
		print("test_map_camera: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _button(at: Vector2, button: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = button
	event.pressed = pressed
	event.button_mask = (1 << (button - 1)) if pressed else 0
	root.push_input(event, true)
	if pressed and button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		event = event.duplicate()
		event.pressed = false
		event.button_mask = 0
		root.push_input(event, true)
	await process_frame

func _motion(at: Vector2, delta: Vector2, mask: int) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = delta
	event.button_mask = mask
	root.push_input(event, true)
	await process_frame

func _click(at: Vector2) -> void:
	await _button(at, MOUSE_BUTTON_LEFT, true)
	await _button(at, MOUSE_BUTTON_LEFT, false)

func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = pressed
	root.push_input(event)
	await process_frame

func _capture(label: String) -> void:
	if "--capture" not in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("user://captures")
	DirAccess.make_dir_recursive_absolute(path)
	var result := root.get_texture().get_image().save_png(path.path_join(label + ".png"))
	_expect(result == OK, "capture " + label)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
