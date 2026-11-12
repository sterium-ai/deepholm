extends SceneTree

## B8 evidence: CPU cost per mouse move of the wall and workbench previews on a
## 200x200 world, through the same viewer entry points boot.gd wires
## (OrderInput.preview_validity() with WorldState.preview, MapView._gui_input()).
## Times each mouse move (_gui_input) and the frame after it (MapView._process()),
## then a world tick with the cursor held still (refresh() + _process()).
## Headless timing only: it prints its numbers and exits 0; the pass/fail gate is
## test_build_preview_budget.gd. Not named test_*, so tools/run_tests.* skip it.
##
## Run: godot --headless --path game --script res://scripts/tests/bench_build_preview.gd

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const OrderInputType = preload("res://scripts/viewer/order_input.gd")

const WIDTH := 200
const HEIGHT := 200
const SEED := 42

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	print("bench_build_preview: %dx%d seed=%d" % [WIDTH, HEIGHT, SEED])
	_bench("wall hover", OrderInputType.Tool.WALL, false)
	_bench("workbench hover", OrderInputType.Tool.BUILD_WORKBENCH, false)
	_bench("wall drag 40x40", OrderInputType.Tool.WALL, true)
	print("bench_build_preview: done")
	quit()

func _bench(label: String, tool: int, drag: bool) -> void:
	var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
	var orders := OrderInputType.new()
	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_world(world)
	map_view.preview_validity = func(tiles: Array[Vector2i]) -> Array[bool]:
		return orders.preview_validity(world, world.preview, map_view, tiles)
	orders.select_tool(world, map_view, tool)
	var origin := Vector2i(80, 80)
	if drag:
		_motion(map_view, origin)
		_mouse(map_view, origin, true)
	var moves := 0
	var move_total := 0
	var move_worst := 0
	var frame_worst := 0
	for step in range(1, 40):
		var tile := origin + Vector2i(step, step) if drag else origin + Vector2i(step, 0)
		var start := Time.get_ticks_usec()
		_motion(map_view, tile)
		var move := Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		map_view._process(0.016)
		frame_worst = maxi(frame_worst, Time.get_ticks_usec() - start)
		moves += 1
		move_total += move
		move_worst = maxi(move_worst, move)
	# The exact check MapView defers until the cursor rests (B8), run now.
	var rest_start := Time.get_ticks_usec()
	map_view.finish_preview_work()
	var rest := Time.get_ticks_usec() - rest_start
	var tick_worst := 0
	for i in 5:
		world.tick()
		var start := Time.get_ticks_usec()
		map_view.refresh()
		map_view._process(0.016)
		tick_worst = maxi(tick_worst, Time.get_ticks_usec() - start)
	# Let deferred work settle, then time a real draw frame.
	for i in 60:
		map_view._process(0.016)
	print("  %s: move avg %d us, worst %d us; frame after move worst %d us; tick frame worst %d us; exact check at rest %d us" % [
		label, move_total / moves, move_worst, frame_worst, tick_worst, rest])
	if drag:
		_mouse(map_view, origin + Vector2i(39, 39), false)
	map_view.queue_free()

func _mouse(map_view: MapViewType, tile: Vector2i, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = (Vector2(tile) + Vector2(0.5, 0.5)) * MapViewType.TILE_SIZE
	map_view._gui_input(event)

func _motion(map_view: MapViewType, tile: Vector2i) -> void:
	var event := InputEventMouseMotion.new()
	event.position = (Vector2(tile) + Vector2(0.5, 0.5)) * MapViewType.TILE_SIZE
	map_view._gui_input(event)
