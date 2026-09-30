extends SceneTree

## Reproducible generation/load/pan timing evidence for
## a 256x256 world, tagged with the commit and environment that produced it,
## for later comparison. This is CPU-bound headless
## instrumentation (world generation, SaveIO, and MapViewport's own transform
## math), not a GPU frame-time measurement -- a headless run has no
## display/GPU to measure real render or interactive pan latency against, so it
## always prints its numbers and passes; it is evidence to quote, not a pass/
## fail performance gate a slower or faster machine should fail on.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const MapViewportType = preload("res://scripts/viewer/map_viewport.gd")

const WIDTH := 256
const HEIGHT := 256
const SEED := 42
const PAN_SAMPLES := 200
const SAVE_PATH := "user://test-map-experience-benchmark.json"

func _init() -> void:
	var generation_start := Time.get_ticks_usec()
	var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
	var generation_usec := Time.get_ticks_usec() - generation_start

	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	var encode_start := Time.get_ticks_usec()
	var state := StateCodecType.encode(world)
	var encode_usec := Time.get_ticks_usec() - encode_start
	var save_start := Time.get_ticks_usec()
	SaveIOType.write_atomic(SAVE_PATH, state)
	var save_usec := Time.get_ticks_usec() - save_start

	var read_start := Time.get_ticks_usec()
	var read_result := SaveIOType.read(SAVE_PATH)
	var decode_usec := 0
	if read_result.get("ok", false):
		var decode_start := Time.get_ticks_usec()
		StateCodecType.decode(read_result["state"])
		decode_usec = Time.get_ticks_usec() - decode_start
	var load_usec := Time.get_ticks_usec() - read_start
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))

	var map_view := MapViewType.new()
	var rebuild_start := Time.get_ticks_usec()
	map_view.set_world(world)
	var rebuild_usec := Time.get_ticks_usec() - rebuild_start

	var no_op_tick_start := Time.get_ticks_usec()
	map_view.refresh()
	var no_op_refresh_usec := Time.get_ticks_usec() - no_op_tick_start

	var viewport := MapViewportType.new()
	root.add_child(viewport)
	viewport.size = Vector2(1280, 720)
	viewport.attach(map_view)
	var pan_start := Time.get_ticks_usec()
	for _i in PAN_SAMPLES:
		viewport.pan_by(Vector2(-7, -5))
	var pan_usec := Time.get_ticks_usec() - pan_start

	print("test_map_experience_benchmark: %dx%d seed=%d commit=%s" % [WIDTH, HEIGHT, SEED, _commit_hash()])
	print("  world generation: %.2f ms" % (generation_usec / 1000.0))
	print("  encode: %.2f ms, write_atomic: %.2f ms, read+integrity: %.2f ms, decode: %.2f ms"
		% [encode_usec / 1000.0, save_usec / 1000.0, (load_usec - decode_usec) / 1000.0, decode_usec / 1000.0])
	print("  TileMapLayer full rebuild (set_world): %.2f ms over %d cells" % [rebuild_usec / 1000.0, WIDTH * HEIGHT])
	print("  TileMapLayer no-op refresh (no terrain change): %.2f ms, %d cells touched"
		% [no_op_refresh_usec / 1000.0, map_view.last_tile_map_cells_touched])
	print("  camera pan_by(): %.3f ms/call over %d calls (%.2f ms total)"
		% [(pan_usec / 1000.0) / PAN_SAMPLES, PAN_SAMPLES, pan_usec / 1000.0])
	print("test_map_experience_benchmark: PASS (headless CPU timing only -- see docs/architecture/map-experience.md)")
	quit()

func _commit_hash() -> String:
	var output := []
	var exit_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], output)
	if exit_code == 0 and not output.is_empty():
		return String(output[0]).strip_edges()
	return "unknown"
