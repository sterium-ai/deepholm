extends SceneTree

## B12: the tile under the pointer and the tile the map highlights must agree at every
## zoom. screen_to_tile() and tile_to_screen() go through the one child transform, a real
## mouse motion hovers the same tile, and a wheel zoom re-reads the hover under a pointer
## that did not move instead of leaving the pre-zoom tile highlighted.

const Boot = preload("res://scripts/boot.gd")
const Scenario = preload("res://scripts/viewer/debug_scenario.gd")
var failures: Array[String] = []
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
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	var map_tiles := Vector2i(map.size / map.TILE_SIZE)
	var tiles: Array[Vector2i] = [Vector2i.ZERO, map_tiles / 2, map_tiles - Vector2i.ONE, Vector2i(3, map_tiles.y - 2)]
	boot._select_tool(Boot.Tool.CHOP)
	for zoom in [0.5, 1.0, 2.0, 3.0]:
		for pan in [Vector2.ZERO, Vector2(-123, -79), Vector2(57, 31)]:
			camera.zoom_at(camera.size * 0.5, zoom)
			camera.pan_by(pan)
			_expect(is_equal_approx(map.scale.x, zoom), "zoom %.1f applied" % zoom)
			for tile in tiles:
				var screen: Vector2 = camera.tile_to_screen(tile)
				_expect(camera.screen_to_tile(screen) == tile,
					"zoom %.1f pan %s: screen_to_tile(tile_to_screen(%s)) == %s" % [zoom, pan, tile, camera.screen_to_tile(screen)])
				if camera.get_global_rect().has_point(screen):
					await _motion(screen)
					_expect(map._hover == tile and map._preview_tiles == [tile],
						"zoom %.1f pan %s: pointer over %s hovers %s" % [zoom, pan, tile, map._hover])
	# Wheel zoom without moving the pointer: from 3x near a corner down to 0.5x, where the
	# map is re-centred and the pre-zoom tile is no longer under the pointer.
	camera.zoom_at(camera.size * 0.5, 3.0)
	var corner: Vector2 = camera.global_position + Vector2(40, 40)
	await _motion(corner)
	var before: Vector2i = map._hover
	for i in 10:
		await _wheel(corner, MOUSE_BUTTON_WHEEL_DOWN)
		var under: Vector2i = camera.screen_to_tile(corner)
		var want: Array = [under] if map._inside(under) else []
		_expect(map._preview_tiles == want,
			"wheel step %d (zoom %.2f): highlight %s follows the pointer tile %s" % [i, camera.zoom_level, map._preview_tiles, under])
	_expect(camera.screen_to_tile(corner) != before, "the corner tile changed while zooming out (test is meaningful)")
	boot._select_tool(-1)
	boot.queue_free()
	await process_frame
	if failures.is_empty():
		print("test_map_zoom_pointer: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	root.push_input(event, true)
	await process_frame

func _wheel(at: Vector2, button: int) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = button
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)
	await process_frame

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
