extends SceneTree

## The full map is captured separately in an enlarged, capture-only viewport
## (following the existing production camera contract, unmodified), since
## 256x256 tiles at 16 px do not fit in 1280x720, 1920x1080 or at the 0.5x
## minimum zoom; that capture must show all four map edges and both ends of
## the river.
##
## Clamping a "fit zoom" into the fixed 1280x720/1920x1080 windows cannot
## work: they can never contain a 256x256 map at 16px (4096x4096 px) even at
## the production camera's 0.5x zoom floor, so every "full-map" image would be
## cropped. Instead this file temporarily enlarges the SceneTree root viewport
## (capture-only) so the whole map's real-pixel extent at the camera's own
## unmodified 0.5x zoom floor (map_viewport.gd's zoom_at(), never touched)
## fits entirely inside it. map_viewport.gd's existing _constrain() then
## centers the whole map in frame unconditionally (extent <= viewport size on
## both axes), showing every edge and both river endpoints, not a
## colonist-centered crop, tile, or stitch. Always passes headless (no
## capture happens without a real DisplayServer); the graphical run is
## a separate, explicit capture saved under user://captures.
##
## godot --headless --path game --script res://scripts/tests/test_river_map_capture.gd
## godot --path game --script res://scripts/tests/test_river_map_capture.gd -- --capture

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")

const SEEDS := [42, 1337, 20260919]
const SAVE_DIR := "user://test-river-map-capture-saves"
const EVIDENCE_DIR := "user://captures"

var failures: Array[String] = []
var boot: Node
var commit_sha := "uncommitted"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_cleanup_save_dir()
	commit_sha = _read_commit_sha()
	boot = Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	boot.save_manager = SaveManagerType.new(SAVE_DIR)
	if boot._map_view == null:
		boot._build_ui()

	for seed_value in SEEDS:
		await _capture_seed(seed_value)

	boot.queue_free()
	await process_frame
	_cleanup_save_dir()
	if failures.is_empty():
		print("test_river_map_capture: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _capture_seed(seed_value: int) -> void:
	boot._seed_input.text = str(seed_value)
	boot._on_new_game_pressed()
	boot._on_new_game_confirmed()
	boot._new_game_confirm.hide()
	await process_frame

	_expect(boot.world.get_seed() == seed_value, "seed %d: New Game must actually apply the requested seed" % seed_value)
	_expect(boot._map_view.is_art_enabled(), "seed %d: the normal view must use the default art renderer" % seed_value)

	var camera: Control = boot._map_viewport
	var map: Control = boot._map_view

	# Full map: enlarge the capture-only root viewport so the whole map's
	# extent (map.size, in world pixels) at the camera's own real 0.5x zoom
	# floor fits entirely inside it -- map_viewport.gd's _constrain() then
	# centers it unconditionally (extent <= size on both axes), showing both
	# river endpoints and every edge, not a colonist-centered crop.
	var needed_extent: Vector2 = map.size * 0.5
	root.size = Vector2i(needed_extent) + Vector2i(400, 200)
	await process_frame
	await process_frame
	camera.zoom_at(camera.size * 0.5, 0.5)
	await process_frame
	await _capture("seed%d-full-map-%s" % [seed_value, commit_sha])

func _read_commit_sha() -> String:
	var output := []
	var exit_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], output, true)
	if exit_code == 0 and not output.is_empty():
		return String(output[0]).strip_edges()
	return "uncommitted"

func _capture(label: String) -> void:
	if "--capture" not in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
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
