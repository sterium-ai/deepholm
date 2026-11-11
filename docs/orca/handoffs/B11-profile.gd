extends SceneTree

## B11 evidence: a timed viewer session, windowed (it needs a real renderer), so the
## frame time of the debug viewer can be split into its parts and memory watched over
## time. The boot scene is built the way bench_viewer_refresh.gd builds it (Boot.new()
## in the tree, _build_ui(), then _replace_world()), so no user save is involved.
##
## Scenarios (--scenario=):
## - default: Boot.build_default_world(), the world a fresh boot shows;
## - a9: BenchCommon.world_with_colonists(42, 128, 128, 1000) plus till orders, the
##   A9 1,000-colonist scene.
##
## The TickDriver keeps its speed (x1 unless --speed=) so the sprite glides read the
## real seconds_per_tick(), but its own _process is disabled: this script runs the same
## accumulator (BASE_TICKS_PER_SECOND x speed, MAX_TICKS_PER_FRAME) and times
## world.tick() and boot._refresh() separately. Vsync is off and the frame rate
## uncapped, so frame times show the headroom under 16.7 ms instead of the vsync wait.
##
## Every --sample= seconds it prints one row:
##   fps, frame ms (mean / p95 / max, from the wall-clock interval between consecutive
##   _process calls, not from `delta`, which the engine may clamp), the largest `delta`
##   seen (delta_max_ms, for comparison), then the frame split by wall clock, each a mean
##   over all frames, ticked or not: tick ms (world.tick()), refresh ms (boot._refresh()),
##   other process ms (from this script's _process to RenderingServer.frame_pre_draw,
##   minus tick and refresh: node _process such as the sprite glides, deferred _draw
##   calls, UI layout), render ms (frame_pre_draw to frame_post_draw) and rest ms (the
##   remainder: present, input, engine idle); then render cpu/gpu ms as the
##   RenderingServer measures them, static memory MiB, object / resource / node counts.
## GDScript has no tracing GC (reference counting only), so "GC pressure" is read as
## object-count and static-memory growth between rows.
##
## Lives outside game/ (not part of the suite). Run, from the repo root:
##   & $env:GODOT --path game --script "$PWD\docs\orca\handoffs\B11-profile.gd" -- --scenario=default --seconds=600
## Optional: --speed=1|2|3 --sample=30 --vsync (keep vsync on, to see the real fps)

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const Boot = preload("res://scripts/boot.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")

var _boot: Node
var _args := {}
var _accumulator := 0.0
var _ticks_per_second := 0.0
var _started_usec := 0
var _sample_started_usec := 0
var _frame_ms: Array[float] = []
var _last_frame_usec := 0
var _delta_max_ms := 0.0
var _tick_usec := 0
var _refresh_usec := 0
var _process_ms := 0.0
var _render_ms := 0.0
var _frame_start_usec := 0
var _frame_tick_usec := 0
var _pre_draw_usec := 0
var _render_cpu_ms := 0.0
var _render_gpu_ms := 0.0
var _ticks := 0
var _viewport_rid: RID
var _ready_to_run := false

func _initialize() -> void:
	_setup.call_deferred()

func _setup() -> void:
	_args = _parse_args()
	root.size = Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")),
		int(ProjectSettings.get_setting("display/window/size/viewport_height")))
	if not _args["vsync"]:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	var world: Variant
	var orders := 0
	if _args["scenario"] == "a9":
		world = BenchCommon.world_with_colonists(42, 128, 128, 1000)
		orders = BenchCommon.submit_till_orders(world, 1000)
	else:
		world = Boot.build_default_world()
	_boot = Boot.new()
	root.add_child(_boot)
	if _boot._map_view == null: # headless _ready() skips the UI
		_boot._build_ui()
	_boot._replace_world(world)
	_boot.tick_driver.process_mode = Node.PROCESS_MODE_DISABLED
	_boot.tick_driver.set_speed(TickDriverType.Speed.X1 + int(_args["speed"]) - 1)
	_ticks_per_second = TickDriverType.BASE_TICKS_PER_SECOND * float(_args["speed"])
	_viewport_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	print(BenchCommon.header("B11-profile"))
	print("B11-profile: scenario=%s colonists=%d orders=%d speed=x%d (%.0f ticks/s) seconds=%d vsync=%s" % [
		_args["scenario"], world.get_colonists().size(), orders, _args["speed"], _ticks_per_second,
		_args["seconds"], _args["vsync"]])
	print("t_s,fps,frame_mean_ms,frame_p95_ms,frame_max_ms,delta_max_ms,tick_ms,refresh_ms,other_process_ms,render_ms,rest_ms,render_cpu_ms,render_gpu_ms,ticks,static_mib,objects,resources,nodes")
	# A few frames so the UI lays out before the clock starts.
	for i in 5:
		await process_frame
	_started_usec = Time.get_ticks_usec()
	_sample_started_usec = _started_usec
	_ready_to_run = true

func _process(delta: float) -> bool:
	if not _ready_to_run:
		return false
	_frame_start_usec = Time.get_ticks_usec()
	if _last_frame_usec > 0:
		_frame_ms.append((_frame_start_usec - _last_frame_usec) / 1000.0)
	_last_frame_usec = _frame_start_usec
	_delta_max_ms = maxf(_delta_max_ms, delta * 1000.0)
	# The measured render time is last frame's.
	_render_cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
	_render_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
	_accumulator += delta * _ticks_per_second
	var ran := 0
	while _accumulator >= 1.0 and ran < TickDriverType.MAX_TICKS_PER_FRAME:
		_accumulator -= 1.0
		ran += 1
		var start := Time.get_ticks_usec()
		_boot.world.tick()
		var mid := Time.get_ticks_usec()
		_boot._refresh()
		_tick_usec += mid - start
		_refresh_usec += Time.get_ticks_usec() - mid
	_frame_tick_usec = Time.get_ticks_usec() - _frame_start_usec
	if ran == TickDriverType.MAX_TICKS_PER_FRAME:
		_accumulator -= floorf(_accumulator)
	_ticks += ran
	var now := Time.get_ticks_usec()
	if now - _sample_started_usec >= int(_args["sample"]) * 1_000_000 and not _frame_ms.is_empty():
		_print_row(now)
	if now - _started_usec >= int(_args["seconds"]) * 1_000_000:
		print("B11-profile: done")
		_ready_to_run = false
		quit(0)
	return false

func _on_pre_draw() -> void:
	_pre_draw_usec = Time.get_ticks_usec()
	if _frame_start_usec > 0:
		_process_ms += (_pre_draw_usec - _frame_start_usec - _frame_tick_usec) / 1000.0

func _on_post_draw() -> void:
	if _frame_start_usec > 0:
		_render_ms += (Time.get_ticks_usec() - _pre_draw_usec) / 1000.0

func _print_row(now: int) -> void:
	var frames := _frame_ms.size()
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var mean := 0.0
	for ms in _frame_ms:
		mean += ms
	mean /= frames
	var tick_ms := _tick_usec / 1000.0 / frames
	var refresh_ms := _refresh_usec / 1000.0 / frames
	var process_ms := _process_ms / frames
	var render_ms := _render_ms / frames
	print("%d,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.1f,%d,%d,%d" % [
		(now - _started_usec) / 1_000_000, frames / ((now - _sample_started_usec) / 1_000_000.0),
		mean, sorted[int(frames * 0.95)], sorted[frames - 1], _delta_max_ms, tick_ms, refresh_ms,
		process_ms, render_ms, mean - tick_ms - refresh_ms - process_ms - render_ms, _render_cpu_ms / frames, _render_gpu_ms / frames,
		_ticks, Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	_frame_ms.clear()
	_delta_max_ms = 0.0
	_tick_usec = 0
	_refresh_usec = 0
	_process_ms = 0.0
	_render_ms = 0.0
	_render_cpu_ms = 0.0
	_render_gpu_ms = 0.0
	_ticks = 0
	_sample_started_usec = now

func _parse_args() -> Dictionary:
	var parsed := {"scenario": "default", "seconds": 600, "speed": 1, "sample": 30, "vsync": false}
	for arg in OS.get_cmdline_user_args():
		if arg == "--vsync":
			parsed["vsync"] = true
		elif arg.begins_with("--scenario="):
			parsed["scenario"] = arg.trim_prefix("--scenario=")
		elif arg.begins_with("--seconds="):
			parsed["seconds"] = int(arg.trim_prefix("--seconds="))
		elif arg.begins_with("--speed="):
			parsed["speed"] = clampi(int(arg.trim_prefix("--speed=")), 1, 3)
		elif arg.begins_with("--sample="):
			parsed["sample"] = maxi(1, int(arg.trim_prefix("--sample=")))
	return parsed
