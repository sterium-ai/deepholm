extends SceneTree

## B1 evidence: CPU cost of a large area order on a 256x256 world, through the
## same viewer entry points boot.gd wires (OrderInput.preview_validity() with
## WorldState.preview, OrderInput.commit_rectangle(), MapView's drag preview)
## plus the per-tick reads the viewer makes afterwards. Headless timing only:
## it always prints its numbers and exits 0; it is evidence to quote in
## docs/orca/handoffs/B1.md, not a pass/fail gate. Not named test_*, so
## tools/run_tests.* never pick it up.
##
## Run: godot --headless --path game --script res://scripts/tests/bench_area_orders.gd
## Optional user args (after "--"): max_seconds=<n> skips a size whose cost,
## extrapolated quadratically from the previous size, would exceed n seconds
## (default 120), so a pathological baseline still finishes; only=<a,b,...>
## runs just those sections (ticks, preview, drag, apply, cancel, zone).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const OrderInputType = preload("res://scripts/viewer/order_input.gd")

const WIDTH := 256
const HEIGHT := 256
const SEED := 42
## N = 100 / 1,000 / 10,000 / 65,536 tiles, as rectangles anchored at (0, 0).
const SIZES := [Vector2i(10, 10), Vector2i(40, 25), Vector2i(100, 100), Vector2i(256, 256)]

var _max_seconds := 120.0
var _only: Array = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("max_seconds="):
			_max_seconds = float(arg.trim_prefix("max_seconds="))
		if arg.begins_with("only="):
			_only = Array(arg.trim_prefix("only=").split(","))
	print("bench_area_orders: %dx%d seed=%d commit=%s max_seconds=%.0f" % [WIDTH, HEIGHT, SEED, _commit_hash(), _max_seconds])
	if _runs("ticks"):
		_bench_reference_ticks()
	if _runs("preview"):
		_bench_preview("dig", OrderInputType.Tool.DIG)
	if _runs("drag"):
		_bench_drag("dig", OrderInputType.Tool.DIG)
	if _runs("apply"):
		await _bench_apply("dig", OrderInputType.Tool.DIG)
	if _runs("cancel"):
		_bench_cancel()
	if _runs("zone"):
		await _bench_zone()
	print("bench_area_orders: done")
	quit()

## Tick cost with no order at all: the first tick builds regions lazily, so
## the "first tick" numbers after an order include that one-off cost too.
func _bench_reference_ticks() -> void:
	var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
	var start := Time.get_ticks_usec()
	world.tick()
	var first_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("  no order: first tick %.2f ms, steady tick %.2f ms" % [first_ms, _steady_tick_ms(world)])

## Mean of 5 ticks.
func _steady_tick_ms(world: WorldStateType) -> float:
	var start := Time.get_ticks_usec()
	for i in 5:
		world.tick()
	return (Time.get_ticks_usec() - start) / 5000.0

## preview_validity() of a whole rectangle (what MapView calls whenever the
## drag rectangle changes) on an untouched world.
func _bench_preview(label: String, tool: int) -> void:
	var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
	var orders := OrderInputType.new()
	var map_view := MapViewType.new()
	map_view.set_world(world)
	orders.selected_tool = tool
	var previous_ms := -1.0
	var previous_n := 0
	for size in SIZES:
		var tiles := MapViewType.tiles_in_rectangle(Vector2i.ZERO, size - Vector2i.ONE)
		if _skip(previous_ms, previous_n, tiles.size(), "preview %s" % label):
			continue
		var start := Time.get_ticks_usec()
		var valid := orders.preview_validity(world, world.preview, map_view, tiles)
		var ms := (Time.get_ticks_usec() - start) / 1000.0
		print("  preview %s N=%d: %.2f ms (%d valid)" % [label, tiles.size(), ms, valid.count(true)])
		previous_ms = ms
		previous_n = tiles.size()
	map_view.free()

## A drag that grows the rectangle from (0,0) to the full size one tile per
## mouse-move along the diagonal, through MapView's real _gui_input path:
## reports the worst single mouse-move (one frame's work) and the total, plus
## any preview work MapView left for later frames (finish_preview_work(),
## where it exists).
func _bench_drag(label: String, tool: int) -> void:
	var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
	var orders := OrderInputType.new()
	var map_view := MapViewType.new()
	map_view.set_world(world)
	map_view.preview_validity = func(tiles: Array[Vector2i]) -> Array[bool]:
		return orders.preview_validity(world, world.preview, map_view, tiles)
	orders.select_tool(world, map_view, tool)
	var previous_ms := -1.0
	var previous_n := 0
	for size in SIZES:
		var n: int = size.x * size.y
		if _skip(previous_ms, previous_n, n, "drag %s" % label):
			continue
		_mouse(map_view, Vector2i.ZERO, true, true)
		var worst := 0.0
		var total_start := Time.get_ticks_usec()
		var steps := maxi(size.x, size.y)
		for step in range(1, steps):
			var corner := Vector2i(mini(step, size.x - 1), mini(step, size.y - 1))
			var start := Time.get_ticks_usec()
			_motion(map_view, corner)
			worst = maxf(worst, (Time.get_ticks_usec() - start) / 1000.0)
		var total_ms := (Time.get_ticks_usec() - total_start) / 1000.0
		var rest_start := Time.get_ticks_usec()
		if map_view.has_method("finish_preview_work"):
			map_view.finish_preview_work()
		var rest_ms := (Time.get_ticks_usec() - rest_start) / 1000.0
		var shown: int = map_view._preview_tiles.size()
		map_view.cancel_selection()
		print("  drag %s to N=%d: worst mouse-move %.2f ms, %d moves, total %.2f ms, deferred preview work %.2f ms (%d tiles shown)"
			% [label, n, worst, steps - 1, total_ms, rest_ms, shown])
		previous_ms = total_ms
		previous_n = n
	map_view.free()

## commit_rectangle() (mouse release) of the rectangle on a fresh world, then
## the first tick() after it and the viewer's per-tick reads of the result.
func _bench_apply(label: String, tool: int) -> void:
	var previous_ms := -1.0
	var previous_n := 0
	for size in SIZES:
		var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
		var orders := OrderInputType.new()
		var map_view := MapViewType.new()
		map_view.set_world(world)
		orders.selected_tool = tool
		var tiles := MapViewType.tiles_in_rectangle(Vector2i.ZERO, size - Vector2i.ONE)
		if _skip(previous_ms, previous_n, tiles.size(), "apply %s" % label):
			map_view.free()
			continue
		var start := Time.get_ticks_usec()
		var rejected := orders.commit_rectangle(world, map_view, tiles)
		var apply_ms := (Time.get_ticks_usec() - start) / 1000.0
		var jobs := world.get_jobs().size()
		print("  apply %s N=%d: %.2f ms (%d jobs, %d rejected)" % [label, tiles.size(), apply_ms, jobs, rejected.size()])
		await _bench_after(world, map_view, label, tiles.size())
		previous_ms = apply_ms
		previous_n = tiles.size()
		map_view.free()

## The first tick after the order and the viewer's refresh (map view +
## designation overlay) plus the get_jobs()/get_events() reads the info
## panels make on every tick.
func _bench_after(world: WorldStateType, map_view: MapViewType, label: String, n: int) -> void:
	var start := Time.get_ticks_usec()
	world.tick()
	var tick_ms := (Time.get_ticks_usec() - start) / 1000.0
	var steady_ms := _steady_tick_ms(world)
	start = Time.get_ticks_usec()
	map_view.refresh()
	var refresh_ms := (Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	var job_count := world.get_jobs().size()
	var jobs_ms := (Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	var event_count := world.get_events().size()
	var events_ms := (Time.get_ticks_usec() - start) / 1000.0
	var redraw_ms: float = await _redraw_ms(map_view)
	print("    after %s N=%d: first tick %.2f ms, steady tick %.2f ms, map_view.refresh %.2f ms, map redraw frame %.2f ms, full get_jobs %.2f ms (%d), full get_events %.2f ms (%d)"
		% [label, n, tick_ms, steady_ms, refresh_ms, redraw_ms, jobs_ms, job_count, events_ms, event_count])

## The CPU time of map_view's draw callbacks (its _draw(), its overlay's and
## its other children's) in one headless frame: siblings draw in tree order and
## children after their parent, so a marker drawn just before map_view and one
## just after it bracket exactly that work. Cheapest of 3 redraws.
func _redraw_ms(map_view: MapViewType) -> float:
	var stamps := {}
	var before := Node2D.new()
	var after := Node2D.new()
	before.draw.connect(func() -> void: stamps["before"] = Time.get_ticks_usec())
	after.draw.connect(func() -> void: stamps["after"] = Time.get_ticks_usec())
	root.add_child(before)
	root.add_child(map_view)
	root.add_child(after)
	await process_frame
	var best := INF
	for i in 3:
		stamps.clear()
		before.queue_redraw()
		map_view.queue_redraw()
		map_view._designation_overlay.queue_redraw()
		after.queue_redraw()
		await process_frame
		if stamps.has("before") and stamps.has("after"):
			best = minf(best, (int(stamps["after"]) - int(stamps["before"])) / 1000.0)
	root.remove_child(before)
	root.remove_child(map_view)
	root.remove_child(after)
	before.free()
	after.free()
	return best

## Cancel over a rectangle full of queued dig jobs: preview, then apply.
func _bench_cancel() -> void:
	var previous_ms := -1.0
	var previous_n := 0
	for size in SIZES:
		var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
		var orders := OrderInputType.new()
		var map_view := MapViewType.new()
		map_view.set_world(world)
		var tiles := MapViewType.tiles_in_rectangle(Vector2i.ZERO, size - Vector2i.ONE)
		if _skip(previous_ms, previous_n, tiles.size(), "cancel"):
			map_view.free()
			continue
		orders.selected_tool = OrderInputType.Tool.DIG
		var setup_start := Time.get_ticks_usec()
		orders.commit_rectangle(world, map_view, tiles)
		var setup_ms := (Time.get_ticks_usec() - setup_start) / 1000.0
		orders.selected_tool = OrderInputType.Tool.CANCEL
		var start := Time.get_ticks_usec()
		var valid := orders.preview_validity(world, world.preview, map_view, tiles)
		var preview_ms := (Time.get_ticks_usec() - start) / 1000.0
		start = Time.get_ticks_usec()
		orders.commit_rectangle(world, map_view, tiles)
		var apply_ms := (Time.get_ticks_usec() - start) / 1000.0
		var pending := 0
		for job in world.get_jobs():
			if String(job["status"]) in ["queued", "active"]:
				pending += 1
		print("  cancel N=%d: preview %.2f ms (%d valid), apply %.2f ms (%d pending left; dig setup %.2f ms)"
			% [tiles.size(), preview_ms, valid.count(true), apply_ms, pending, setup_ms])
		previous_ms = setup_ms + preview_ms + apply_ms
		previous_n = tiles.size()
		map_view.free()

## Zone: one zone_add per drag; preview, apply, then a map redraw (the
## stockpile draw used to walk every zone tile).
func _bench_zone() -> void:
	for size in SIZES:
		var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
		var orders := OrderInputType.new()
		var map_view := MapViewType.new()
		map_view.set_world(world)
		orders.selected_tool = OrderInputType.Tool.ZONE
		var tiles := MapViewType.tiles_in_rectangle(Vector2i.ZERO, size - Vector2i.ONE)
		var start := Time.get_ticks_usec()
		var valid := orders.preview_validity(world, world.preview, map_view, tiles)
		var preview_ms := (Time.get_ticks_usec() - start) / 1000.0
		start = Time.get_ticks_usec()
		var result := world.apply({"actor": "player", "command_id": "bench_zone", "tick": world.get_tick(), "type": "zone_add",
			"payload": {"x": 0, "y": 0, "width": size.x, "height": size.y}})
		var apply_ms := (Time.get_ticks_usec() - start) / 1000.0
		map_view.refresh()
		var redraw_ms: float = await _redraw_ms(map_view)
		print("  zone N=%d: preview %.2f ms (%d valid), apply %.2f ms (ok=%s), map redraw frame %.2f ms"
			% [tiles.size(), preview_ms, valid.count(true), apply_ms, str(result.get("ok", false)), redraw_ms])
		map_view.free()

func _runs(section: String) -> bool:
	return _only.is_empty() or section in _only

func _skip(previous_ms: float, previous_n: int, n: int, label: String) -> bool:
	if previous_ms < 0.0:
		return false
	var ratio := float(n) / float(previous_n)
	var estimate := previous_ms * ratio * ratio / 1000.0
	if estimate <= _max_seconds:
		return false
	print("  %s N=%d: skipped (quadratic extrapolation %.0f s > max_seconds)" % [label, n, estimate])
	return true

func _mouse(map_view: MapViewType, tile: Vector2i, pressed: bool, _start: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = (Vector2(tile) + Vector2(0.5, 0.5)) * MapViewType.TILE_SIZE
	map_view._gui_input(event)

func _motion(map_view: MapViewType, tile: Vector2i) -> void:
	var event := InputEventMouseMotion.new()
	event.position = (Vector2(tile) + Vector2(0.5, 0.5)) * MapViewType.TILE_SIZE
	map_view._gui_input(event)

func _commit_hash() -> String:
	var output := []
	if OS.execute("git", ["rev-parse", "--short", "HEAD"], output) == 0 and not output.is_empty():
		return String(output[0]).strip_edges()
	return "unknown"
