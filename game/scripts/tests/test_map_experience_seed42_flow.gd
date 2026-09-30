extends SceneTree

## An automated graphical exercise of the seed-42
## "create, reach the opposite corner, save, reload" manual verification
## flow, run through the real Boot scene, the real New
## Game/Save/Load button handlers, and (with `--capture`, non-headless) a
## real OpenGL renderer -- not just the headless StateCodec-level round trips
## test_save_dimensions.gd already covers. This automates the mechanical
## claim (does the actual UI-driven save/load preserve terrain, colonist
## positions and orders, on a real render) so only the subjective claim (does
## it look/feel right at a glance) is left to manual verification --
## see docs/architecture/map-experience.md.
##
## Uses an isolated SaveManager directory (never the default "user://saves" a
## real playthrough on this machine would use); optional captures go to
## user://captures.

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")

const SEED := 42
const SAVE_DIR := "user://test-map-experience-seed42-flow-saves"
const EVIDENCE_DIR := "user://captures"
const SEARCH_RADIUS := 40
const PAN_STEPS := 60
const PAN_STEP_DELTA := Vector2(-40, -30)

var failures: Array[String] = []
var boot: Node

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
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame

	# New Game with a visible/editable seed, exactly
	# through the buttons a player uses. Timed on its own -- separately from
	# Save below -- so "generation" and "Save" are never the same number
	# under a shared label.
	boot._seed_input.text = str(SEED)
	var generation_start := Time.get_ticks_usec()
	boot._on_new_game_pressed()
	boot._on_new_game_confirmed()
	# _on_new_game_confirmed() is invoked directly (there is no user here to
	# click the real ConfirmationDialog's OK button), so the popup itself
	# must be explicitly hidden -- otherwise it stays visible and intercepts
	# every subsequent synthetic mouse event meant for the map.
	boot._new_game_confirm.hide()
	await process_frame
	var generation_usec := Time.get_ticks_usec() - generation_start

	var mapgen: Dictionary = ContentRegistryType.new().document("mapgen")
	var expected_size: Vector2i = WorldGeneratorType.default_new_game_size(mapgen)
	_expect(boot.world.get_map_width() == expected_size.x and boot.world.get_map_height() == expected_size.y,
		"New Game with no size override must use mapgen.json's default new-game size (%s)" % expected_size)
	_expect(boot.world.get_colonists().size() > 0, "a fresh seed-42 game must spawn at least one colonist")
	var original_terrain: Array = boot.world.get_tiles()
	var original_colonists: Array = boot.world.get_colonists()

	var camera: Control = boot._map_viewport
	var map: Control = boot._map_view
	# A reproducible, individually-timed pan sequence -- with --capture, each
	# step waits for the real GPU/renderer to actually finish drawing the
	# frame (RenderingServer.frame_post_draw), not just for the engine to
	# queue it, so this is genuine rendered-pan frame time, not CPU-only
	# transform math (see test_map_experience_benchmark.gd
	# for the existing CPU-only pan_by() cost). Headless runs still exercise
	# pan_by() itself, just without a compositor to time against.
	var graphical := "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	var pan_frame_usec: Array = []
	for _step in PAN_STEPS:
		var frame_start := Time.get_ticks_usec()
		camera.pan_by(PAN_STEP_DELTA)
		await process_frame
		if graphical:
			await RenderingServer.frame_post_draw
		pan_frame_usec.append(Time.get_ticks_usec() - frame_start)
	var pan_frame_avg_ms := 0.0
	if not pan_frame_usec.is_empty():
		var pan_frame_total: int = 0
		for usec in pan_frame_usec:
			pan_frame_total += usec
		pan_frame_avg_ms = (pan_frame_total / float(pan_frame_usec.size())) / 1000.0

	# Clamp to the true opposite (far) corner regardless of how
	# PAN_STEPS*PAN_STEP_DELTA compares to this world's own size, mirroring
	# the manual verification's "reach the opposite corner" step exactly.
	camera.pan_by(Vector2(-1000000, -1000000))
	await process_frame
	await _capture("seed42-opposite-corner")

	# A real order near the far corner, issued through the actual pointer/
	# tool path (not injected directly into the job queue), mirroring
	# test_save_dimensions.gd's headless far-edge coverage but exercised
	# through the UI this time.
	var far_tile := _nearest_soil_tile(Vector2i(expected_size.x - 2, expected_size.y - 2))
	_expect(far_tile != Vector2i(-1, -1), "a soil tile must exist near the far corner to designate")
	boot._select_tool(Boot.Tool.DIG)
	if far_tile != Vector2i(-1, -1):
		var far_screen: Vector2 = map.get_global_transform_with_canvas() * (Vector2(far_tile) * 16 + Vector2(8, 8))
		await _button(far_screen, MOUSE_BUTTON_LEFT, true)
		await _button(far_screen, MOUSE_BUTTON_LEFT, false)
	boot._select_tool(-1)
	var jobs_before: int = boot.world.get_jobs().size()
	_expect(jobs_before > 0, "a dig order at the far corner must actually create a job through the real pointer path")

	var save_start := Time.get_ticks_usec()
	boot._on_save_pressed()
	var save_usec := Time.get_ticks_usec() - save_start
	_expect(FileAccess.file_exists(SAVE_DIR.path_join("manual.json")), "the manual save file must exist after pressing Save")

	var load_start := Time.get_ticks_usec()
	boot._on_load_pressed()
	var load_usec := Time.get_ticks_usec() - load_start
	await process_frame
	await _capture("seed42-after-reload")

	_expect(boot.world.get_tiles() == original_terrain, "terrain must be identical after a real Save/Load round trip")
	var reloaded_colonists: Array = boot.world.get_colonists()
	original_colonists.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	reloaded_colonists.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	_expect(original_colonists.size() == reloaded_colonists.size(), "colonist count must be identical after Save/Load")
	for i in mini(original_colonists.size(), reloaded_colonists.size()):
		_expect(original_colonists[i]["x"] == reloaded_colonists[i]["x"] and original_colonists[i]["y"] == reloaded_colonists[i]["y"],
			"colonist positions must be identical after a real Save/Load round trip")
	var reloaded_jobs: Array = boot.world.get_jobs()
	_expect(reloaded_jobs.size() == jobs_before, "job/order count must be identical after a real Save/Load round trip")
	var found_far_job := false
	for job in reloaded_jobs:
		if job["target"] == far_tile and job["kind"] == "dig":
			found_far_job = true
	_expect(far_tile == Vector2i(-1, -1) or found_far_job, "the far-corner dig order must still exist after a real Save/Load round trip")

	print("test_map_experience_seed42_flow: hardware=%s renderer=%s resolution=%s commit=%s"
		% [OS.get_processor_name(), _renderer_description(), root.size, _commit_hash()])
	print("  New Game (create %dx%d, seed %d): %.2f ms" % [expected_size.x, expected_size.y, SEED, generation_usec / 1000.0])
	print("  rendered pan: %.3f ms/frame avg over %d steps" % [pan_frame_avg_ms, PAN_STEPS])
	print("  Save: %.2f ms, Load: %.2f ms" % [save_usec / 1000.0, load_usec / 1000.0])

	boot.queue_free()
	await process_frame
	_cleanup_save_dir()
	if failures.is_empty():
		print("test_map_experience_seed42_flow: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

## Expanding Chebyshev-ring search for the nearest soil tile to `origin`,
## mirroring test_save_dimensions.gd's own _nearest_soil_tile().
func _nearest_soil_tile(origin: Vector2i) -> Vector2i:
	var width: int = boot.world.get_map_width()
	var height: int = boot.world.get_map_height()
	for radius in range(0, SEARCH_RADIUS + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if boot.world.get_tile(x, y) == "soil":
					return Vector2i(x, y)
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

func _capture(label: String) -> void:
	if "--capture" not in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(EVIDENCE_DIR)
	DirAccess.make_dir_recursive_absolute(path)
	var result := root.get_texture().get_image().save_png(path.path_join(label + ".png"))
	_expect(result == OK, "capture " + label)

func _renderer_description() -> String:
	if DisplayServer.get_name() == "headless":
		return "headless (no renderer)"
	return "%s / %s" % [RenderingServer.get_video_adapter_name(), ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")]

func _commit_hash() -> String:
	var output := []
	var exit_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], output)
	if exit_code == 0 and not output.is_empty():
		return String(output[0]).strip_edges()
	return "unknown"

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
