extends SceneTree

## Regression: after panning a large world to its far corner,
## replacing it with a smaller world (a later Load, or New Game) used to leave the
## camera at its old, now out-of-range position -- the viewport could stay
## entirely blank until another pan/zoom action. _replace_world() must
## reapply camera bounds (or center) whenever the attached world's dimensions
## change, with no intervening pan or zoom required.

const Boot = preload("res://scripts/boot.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

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
	var large_world := WorldStateType.new(778001, 10, 256, 256)
	boot._replace_world(large_world)
	if boot._map_view == null:
		boot._build_ui()
	camera = boot._map_viewport
	map = boot._map_view
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame

	boot._replace_world(large_world)
	camera.zoom_at(camera.size * 0.5, 1.0)
	for _i in 50:
		camera.pan_by(Vector2(-2000, -2000))
	_expect(map.position.x < -1000 and map.position.y < -1000,
		"test fixture must actually pan deep into the large map's far corner, got %s" % map.position)

	var small_world := WorldStateType.new(778002, 10, 48, 48)
	boot._replace_world(small_world)
	await process_frame

	# Visible immediately: re-applying _constrain() must be a no-op, proving
	# the position _replace_world() left is already inside the valid range
	# for the newly attached (much smaller) map -- not still the large map's
	# far-corner offset, which would sit entirely outside a 48x48 map's
	# on-screen extent.
	var position_after_replace: Vector2 = map.position
	camera._constrain()
	_expect(map.position.is_equal_approx(position_after_replace),
		"replacing with a smaller world must already leave the camera inside its valid bounds, got %s reconstrained to %s"
			% [position_after_replace, map.position])
	# _constrain()'s own invariant guarantees the map's rect always overlaps
	# the viewport (centered on any axis that fits, clamped into [size-extent,
	# 0] on any axis that doesn't) -- checked directly here rather than
	# assuming the small fixture map fits the actual (layout-dependent)
	# viewport size on every axis, which it need not.
	var extent: Vector2 = map.size * camera.zoom_level
	var visible_rect := Rect2(Vector2.ZERO, camera.size).intersection(Rect2(map.position, extent))
	_expect(visible_rect.size.x > 0.0 and visible_rect.size.y > 0.0,
		"the newly attached small map must be at least partially visible immediately after replacement, got position %s size %s viewport %s"
			% [map.position, extent, camera.size])

	# Coordinate conversion must resolve to the newly attached (small) map's
	# own bounds immediately, with no intervening pan or zoom.
	var center_screen: Vector2 = camera.global_position + camera.size * 0.5
	var tile: Vector2i = camera.screen_to_tile(center_screen)
	_expect(tile.x >= 0 and tile.x < small_world.get_map_width() and tile.y >= 0 and tile.y < small_world.get_map_height(),
		"screen-to-tile conversion at the viewport center must resolve to an in-bounds tile of the newly attached small map, got %s" % tile)

	boot.queue_free()
	await process_frame
	if failures.is_empty():
		print("test_map_camera_world_replace: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
