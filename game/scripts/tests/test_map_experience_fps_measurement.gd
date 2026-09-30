extends SceneTree

## 60 real seconds of sustained-load,
## rendered-frame-interval measurement after warmup, on the real Boot scene --
## a 256x256 seed-42 world (mapgen.json's own default colonist_count == 3),
## 30 valid local "till" orders queued up front, alternating pan/zoom every
## frame, at 1920x1080. "till" needs no fetched tool (colonist-ai.md: a
## freshly spawned colonist has no pick/axe, so dig/chop would sit
## blocked_no_tool), so all 30 orders are actually workable by the 3
## colonists while the measurement window runs at real x3 tick speed through
## the real TickDriver -- never advanced by hand.
##
## Also asserts, tied to this exact scenario rather than
## test_map_view_incremental.gd's synthetic one-till case, that no single
## MapView refresh during the whole window reconstructs all 65536 cells.
##
## The rendered frame interval -- wall-clock time between successive
## RenderingServer.frame_post_draw signals, which includes CPU work (tick,
## presentation callbacks) as well as GPU execution, not GPU execution time
## alone -- is measured per frame (matching test_map_experience_seed42_flow.gd's
## own convention) only when run with --capture on a real display; the
## headless run still exercises the whole scenario and always passes, but its
## printed numbers are queue-depth/CPU bound, not the number to quote against
## the >=30 FPS / <=50ms p95 target.
##
## Average FPS and p95 alone do not establish "sustained"
## performance -- a single very long frame is invisible to both. So this
## also buckets frames by the real second they fell in (one bucket's frame
## count is that second's own FPS) and separately lists every individual
## frame over LONG_FRAME_MS, with its offset into the window and how many
## TileMapLayer cells that frame's own refresh touched (to tell a rendering
## stall apart from a terrain-rebuild one). "MET" below requires the average,
## the p95, and the worst single real second's frame count to all clear the
## target -- not average/p95 alone.
##
## godot --headless --path game --script res://scripts/tests/test_map_experience_fps_measurement.gd
## godot --path game --script res://scripts/tests/test_map_experience_fps_measurement.gd -- --capture

const Boot = preload("res://scripts/boot.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")

const SEED := 42
const WIDTH := 256
const HEIGHT := 256
const ORDER_COUNT := 30
const EXPECTED_COLONIST_COUNT := 3
const WARMUP_SECONDS := 3.0
const MEASURE_SECONDS := 60.0
const SAVE_DIR := "user://test-map-experience-fps-measurement-saves"
const TARGET_MIN_AVG_FPS := 30.0
const TARGET_MAX_P95_FRAME_MS := 50.0
## Sustained floor: the worst real one-second bucket's own frame count must
## also clear this, not just the whole window's average.
const TARGET_MIN_SUSTAINED_FPS := 30.0
## A single frame slower than this is reported individually (offset, ms,
## cells touched) regardless of what the average/p95 say.
const LONG_FRAME_MS := 50.0

var failures: Array[String] = []
var boot: Node
var _gesture_frame := 0
var _max_cells_touched := 0

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
	root.size = Vector2i(1920, 1080)

	boot._seed_input.text = str(SEED)
	boot._on_new_game_pressed()
	boot._on_new_game_confirmed()
	boot._new_game_confirm.hide()
	await process_frame

	_expect(boot.world.get_map_width() == WIDTH and boot.world.get_map_height() == HEIGHT,
		"the scenario requires a %dx%d world, got %dx%d" % [WIDTH, HEIGHT, boot.world.get_map_width(), boot.world.get_map_height()])
	_expect(boot.world.get_colonists().size() == EXPECTED_COLONIST_COUNT,
		"the scenario requires exactly %d colonists (mapgen.json colonist_count), got %d" % [EXPECTED_COLONIST_COUNT, boot.world.get_colonists().size()])

	var targets := _local_soil_tiles(boot.world, ORDER_COUNT)
	_expect(targets.size() == ORDER_COUNT, "must find %d local valid soil tiles to till, found %d" % [ORDER_COUNT, targets.size()])
	var accepted := 0
	for i in targets.size():
		var t: Vector2i = targets[i]
		var result: Dictionary = boot.world.apply({
			"actor": "test", "command_id": "fps_measurement_till_%d" % i, "tick": boot.world.get_tick(),
			"type": "till", "payload": {"x": t.x, "y": t.y, "priority": 1},
		})
		if result.get("ok", false):
			accepted += 1
	_expect(accepted == targets.size(), "all %d local till orders must be accepted, got %d" % [targets.size(), accepted])

	# set_world()'s own one-time full rebuild (New Game above) leaves
	# last_tile_map_cells_touched at width*height+objects; consume it with an
	# explicit refresh before tracking so the loop below only sees cells
	# touched by actual gameplay ticks, never that legitimate one-time count.
	boot._map_view.refresh()

	var camera: Control = boot._map_viewport
	var graphical := "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"

	boot.tick_driver.set_speed(TickDriverType.Speed.X3)

	# Warmup (shader compile, caches) -- unmeasured.
	var warmup_start := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - warmup_start) / 1000000.0 < WARMUP_SECONDS:
		_alternate_pan_zoom(camera)
		await process_frame
		if graphical:
			await RenderingServer.frame_post_draw
		_max_cells_touched = maxi(_max_cells_touched, boot._map_view.last_tile_map_cells_touched)

	# Measurement window: 60 real seconds, alternating pan/zoom every frame,
	# while the 3 colonists work through the 30 queued orders via the real
	# scheduler/tick_driver.
	var frame_records: Array = []  # [{"offset_sec": float, "ms": float, "cells": int}]
	var measure_start := Time.get_ticks_usec()
	var elapsed := 0.0
	while elapsed < MEASURE_SECONDS:
		var frame_start := Time.get_ticks_usec()
		_alternate_pan_zoom(camera)
		await process_frame
		if graphical:
			await RenderingServer.frame_post_draw
		var cells: int = boot._map_view.last_tile_map_cells_touched
		frame_records.append({
			"offset_sec": (frame_start - measure_start) / 1000000.0,
			"ms": (Time.get_ticks_usec() - frame_start) / 1000.0,
			"cells": cells,
		})
		_max_cells_touched = maxi(_max_cells_touched, cells)
		elapsed = (Time.get_ticks_usec() - measure_start) / 1000000.0

	boot.tick_driver.pause()

	_expect(_max_cells_touched < WIDTH * HEIGHT,
		"no single MapView refresh during the 60s scenario may reconstruct all %d cells, touched up to %d" % [WIDTH * HEIGHT, _max_cells_touched])

	var stats := _frame_stats(frame_records, elapsed)
	print("test_map_experience_fps_measurement: hardware=%s renderer=%s resolution=%s commit=%s seed=%d colonists=%d orders=%d"
		% [OS.get_processor_name(), _renderer_description(), root.size, _commit_hash(), SEED, boot.world.get_colonists().size(), targets.size()])
	print("  frames measured: %d over %.2f s" % [frame_records.size(), elapsed])
	print("  avg FPS: %.2f, worst-single-frame FPS: %.2f, p95 frame time: %.2f ms" % [stats["avg_fps"], stats["worst_frame_fps"], stats["p95_ms"]])
	print("  per-second FPS (frame count per real second, %d buckets): %s" % [stats["per_second_fps"].size(), str(stats["per_second_fps"])])
	print("  min per-second FPS (sustained floor): %.2f" % stats["min_second_fps"])
	print("  long frames (> %.0f ms): %d" % [LONG_FRAME_MS, stats["long_frames"].size()])
	for lf in stats["long_frames"]:
		print("    at +%.2f s: %.2f ms, %d/%d cells touched that frame" % [lf["offset_sec"], lf["ms"], lf["cells"], WIDTH * HEIGHT])
	print("  max TileMapLayer cells touched in a single refresh during measurement: %d / %d" % [_max_cells_touched, WIDTH * HEIGHT])
	if graphical:
		var sustained_met: bool = (stats["avg_fps"] >= TARGET_MIN_AVG_FPS
			and stats["p95_ms"] <= TARGET_MAX_P95_FRAME_MS
			and stats["min_second_fps"] >= TARGET_MIN_SUSTAINED_FPS)
		print("  target >= %.0f FPS sustained (every real second) and p95 frame time <= %.0f ms: %s"
			% [TARGET_MIN_AVG_FPS, TARGET_MAX_P95_FRAME_MS, "MET" if sustained_met else "NOT MET"])
	else:
		print("  headless run: no real display active -- not the number to quote for the target; re-run with --capture on a real display")

	boot.queue_free()
	await process_frame
	_cleanup_save_dir()
	if failures.is_empty():
		print("test_map_experience_fps_measurement: PASS")
		quit()
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

## frame_records: [{"offset_sec": float, "ms": float, "cells": int}], in
## capture order. measured_seconds is the real window length they span.
func _frame_stats(frame_records: Array, measured_seconds: float) -> Dictionary:
	var count := frame_records.size()
	if count == 0:
		return {
			"avg_fps": 0.0, "worst_frame_fps": 0.0, "p95_ms": 0.0,
			"per_second_fps": [], "min_second_fps": 0.0, "long_frames": [],
		}
	var total_ms := 0.0
	var ms_values: Array = []
	for r in frame_records:
		total_ms += float(r["ms"])
		ms_values.append(float(r["ms"]))
	var avg_frame_ms := total_ms / float(count)
	var avg_fps := 1000.0 / avg_frame_ms if avg_frame_ms > 0.0 else 0.0
	var sorted_ms: Array = ms_values.duplicate()
	sorted_ms.sort()
	var worst_ms: float = sorted_ms[-1]
	var worst_frame_fps := 1000.0 / worst_ms if worst_ms > 0.0 else 0.0
	var p95_index := clampi(int(ceil(count * 0.95)) - 1, 0, count - 1)
	var p95_ms: float = sorted_ms[p95_index]

	# Bucket by the real second each frame started in: a bucket's own frame
	# count is that second's FPS, so the worst bucket is the sustained floor
	# a single long frame (invisible to avg/p95) would otherwise hide. Uses
	# floor, not ceil: the loop that fills frame_records stops as soon as
	# elapsed crosses measured_seconds, so the trailing fractional second is
	# never fully sampled -- ceil would add a near-empty final bucket that
	# looks like a stall but is really just the window's own edge. Any
	# frame that started in that trailing fraction folds into the last full
	# bucket instead of being dropped or faking a low-FPS second.
	var second_count := maxi(int(floor(measured_seconds)), 1)
	var per_second_fps: Array = []
	per_second_fps.resize(second_count)
	per_second_fps.fill(0)
	for r in frame_records:
		var bucket := clampi(int(float(r["offset_sec"])), 0, second_count - 1)
		per_second_fps[bucket] += 1
	var min_second_fps: float = float(per_second_fps[0])
	for v in per_second_fps:
		min_second_fps = minf(min_second_fps, float(v))

	var long_frames: Array = []
	for r in frame_records:
		if float(r["ms"]) > LONG_FRAME_MS:
			long_frames.append(r)

	return {
		"avg_fps": avg_fps, "worst_frame_fps": worst_frame_fps, "p95_ms": p95_ms,
		"per_second_fps": per_second_fps, "min_second_fps": min_second_fps,
		"long_frames": long_frames,
	}

## Every frame, alternates a small pan step with a zoom oscillating between
## the 0.5x/3x bounds, never both in the same frame, so each gesture's cost
## is measured independently.
func _alternate_pan_zoom(camera: Control) -> void:
	_gesture_frame += 1
	if _gesture_frame % 2 == 0:
		camera.pan_by(Vector2(sin(_gesture_frame * 0.05) * 6.0, cos(_gesture_frame * 0.05) * 4.0))
	else:
		var t := float(_gesture_frame % 120) / 120.0
		var zoom := lerpf(0.5, 3.0, (sin(t * TAU) + 1.0) / 2.0)
		camera.zoom_at(Vector2(root.size) * 0.5, zoom)

## Expanding Chebyshev-ring search, round-robin across colonists, for the
## nearest `count` empty soil tiles local to spawn -- never the far corner.
func _local_soil_tiles(world, count: int) -> Array:
	var found: Array = []
	var seen := {}
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	for colonist in world.get_colonists():
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		for radius in range(0, 60):
			if found.size() >= count:
				break
			for y in range(origin.y - radius, origin.y + radius + 1):
				if y < 0 or y >= height:
					continue
				for x in range(origin.x - radius, origin.x + radius + 1):
					if x < 0 or x >= width:
						continue
					if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
						continue
					var key := Vector2i(x, y)
					if seen.has(key):
						continue
					if world.get_tile(x, y) == "soil" and world.get_object(x, y) == "":
						seen[key] = true
						found.append(key)
						if found.size() >= count:
							return found
	return found

func _renderer_description() -> String:
	if DisplayServer.get_name() == "headless":
		return "headless (no renderer)"
	return "%s / %s" % [RenderingServer.get_video_adapter_name(), ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")]

func _commit_hash() -> String:
	var output := []
	var exit_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], output, true)
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
