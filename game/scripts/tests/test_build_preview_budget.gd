extends SceneTree

## B8: with the wall or workbench tool on a 200x200 world, a mouse move must cost
## under BUDGET_USEC: MapView only lays out the hovered footprint or dragged
## rectangle and defers the exact check (whose enclosure flood fill scans the
## whole map) to _process() once the cursor rests. Drives the same entry points
## boot.gd wires (OrderInput.preview_validity() with WorldState.preview,
## MapView._gui_input()). Also proves the deferred result is the exact one: after
## finish_preview_work() the preview equals a direct preview_validity() call, and
## a tick with the cursor held still does not re-run the check synchronously.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const OrderInputType = preload("res://scripts/viewer/order_input.gd")

const BUDGET_USEC := 2000

var _failed := false
var _validity_calls := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_check("wall hover", OrderInputType.Tool.WALL, false)
	_check("workbench hover", OrderInputType.Tool.BUILD_WORKBENCH, false)
	_check("wall drag 40x40", OrderInputType.Tool.WALL, true)
	if _failed:
		quit(1)
		return
	print("test_build_preview_budget: PASS")
	quit(0)

func _check(label: String, tool: int, drag: bool) -> void:
	var world := WorldStateType.new(42, 10, 200, 200)
	var orders := OrderInputType.new()
	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_world(world)
	map_view.preview_validity = func(tiles: Array[Vector2i]) -> Array[bool]:
		_validity_calls += 1
		return orders.preview_validity(world, world.preview, map_view, tiles)
	orders.select_tool(world, map_view, tool)
	var origin := Vector2i(80, 80)
	if drag:
		_motion(map_view, origin)
		_mouse(map_view, origin, true)
	# Best of three per move, so a scheduler hiccup on a loaded machine is not
	# mistaken for the old flood fill (~180 ms per move before B8). Each attempt
	# changes the hovered tile (a move within one tile does no preview work).
	var worst := 0
	for step in range(1, 40):
		var tile := origin + Vector2i(step, step) if drag else origin + Vector2i(step, 0)
		var best := 1 << 30
		for attempt in 3:
			var start := Time.get_ticks_usec()
			_motion(map_view, tile + Vector2i(0, attempt % 2))
			best = mini(best, Time.get_ticks_usec() - start)
		worst = maxi(worst, best)
	_expect(worst < BUDGET_USEC, "%s: a mouse move must cost under %d us, worst best-of-3 was %d us" % [label, BUDGET_USEC, worst])

	map_view.finish_preview_work()
	var tiles: Array[Vector2i] = map_view._preview_tiles.duplicate()
	_expect(not tiles.is_empty(), "%s: the preview must lay out the hovered/dragged tiles" % label)
	if drag:
		_expect(tiles.size() == 40 * 40, "%s: the drag preview must cover the 40x40 rectangle, got %d tiles" % [label, tiles.size()])
	var exact: Array[bool] = orders.preview_validity(world, world.preview, map_view, tiles)
	_expect(map_view._preview_valid == exact, "%s: after finish_preview_work() the preview must hold the exact validity" % label)

	# A tick that changes no tile or designation: no recheck at all.
	var calls := _validity_calls
	map_view.refresh()
	map_view._process(0.016)
	map_view.finish_preview_work()
	_expect(_validity_calls == calls, "%s: a refresh with no world change must not re-run the exact check" % label)
	_expect(map_view._preview_valid == exact, "%s: a refresh with no world change must keep the exact validity" % label)
	# A designation elsewhere advances the change log: the recheck is deferred, not run
	# on the tick, and then runs exactly once.
	var designations := int(world.get_designation_changes(-1)["next"])
	_designate_far(world)
	_expect(int(world.get_designation_changes(-1)["next"]) > designations, "%s: the far designation must advance the change log" % label)
	world.tick()
	map_view.refresh()
	map_view._process(0.016)
	_expect(_validity_calls == calls, "%s: a tick with the cursor held still must not re-run the exact check synchronously" % label)
	_expect(map_view._preview_valid == exact, "%s: a tick must keep showing the last exact validity until its recheck" % label)
	map_view.finish_preview_work()
	_expect(_validity_calls == calls + 1, "%s: the recheck after a world change must run the exact check once" % label)

	if drag:
		_mouse(map_view, origin + Vector2i(39, 39), false)
	root.remove_child(map_view)
	map_view.free()

## One accepted designation (a dig or mine order) well away from the previewed area.
func _designate_far(world: WorldStateType) -> void:
	for x in range(5, 60):
		var result: Dictionary = world.apply({"actor": "player", "command_id": "far%d" % x, "tick": world.get_tick(),
			"type": "dig" if x % 2 == 0 else "mine", "payload": {"x": x, "y": 5, "z": 0, "priority": 1}})
		if result.get("ok", false):
			return

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true

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
