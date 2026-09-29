extends SceneTree

## Issue #299 instrumentation: proves map_view.gd's TileMapLayer refresh does
## NOT clear and rebuild all width*height cells on a tick with no terrain
## change, on a 256x256 world (65536 cells) -- only set_world()'s one-time
## full rebuild touches every cell; an ordinary tick touches zero, and a
## single completed order touches exactly the one cell that actually changed.
## Uses "till" rather than "dig"/"chop": those need a fetched pick/axe tool
## item, and a freshly generated world spawns with none (colonist-ai.md 2/3.4
## -- fetch_tool has nothing to find), so a dig/chop job would sit
## blocked_no_tool forever. "till"'s own toils (reserve, go_to, work,
## release_all) need no tool at all.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const WIDTH := 256
const HEIGHT := 256
const TILL_TICK_BUDGET := 400

var _failed := false

func _init() -> void:
	var world := WorldStateType.new(20260921, 10, WIDTH, HEIGHT)
	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_art_enabled(true)
	map_view.set_world(world)
	var expected_full := WIDTH * HEIGHT + world.get_objects().size()
	_expect(map_view.last_tile_map_cells_touched == expected_full,
		"set_world()'s one-time full rebuild must touch every cell of a %dx%d map (expected %d, got %d)"
			% [WIDTH, HEIGHT, expected_full, map_view.last_tile_map_cells_touched])

	# A tick with no terrain/object change must touch zero cells, never the
	# full 65536 (issue #299's own instrumentation wording).
	world.tick()
	map_view.refresh()
	_expect(map_view.last_tile_map_cells_touched == 0,
		"a tick with no terrain change must touch zero TileMapLayer cells, got %d" % map_view.last_tile_map_cells_touched)
	_expect(map_view.last_tile_map_cells_touched < WIDTH * HEIGHT,
		"a tick with no terrain change must not reconstruct all %d cells" % (WIDTH * HEIGHT))

	var target := _nearest_soil_tile(world)
	_expect(target != Vector2i(-1, -1), "a %dx%d world must have a soil tile reachable from a colonist" % [WIDTH, HEIGHT])
	if target == Vector2i(-1, -1):
		_finish()
		return
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "till_one", "tick": world.get_tick(),
		"type": "till", "payload": {"x": target.x, "y": target.y, "priority": 1},
	})
	_expect(result.get("ok", false), "the till command must be accepted: %s" % result)
	var ticks := 0
	while ticks < TILL_TICK_BUDGET and world.get_tile(target.x, target.y) != "plowed_soil":
		world.tick()
		ticks += 1
	_expect(world.get_tile(target.x, target.y) == "plowed_soil", "the till must actually complete within %d ticks" % TILL_TICK_BUDGET)
	map_view.refresh()
	_expect(map_view.last_tile_map_cells_touched == 1,
		"completing exactly one till across %d ticks must touch exactly one TileMapLayer cell, got %d"
			% [ticks, map_view.last_tile_map_cells_touched])

	_finish()

func _finish() -> void:
	if _failed:
		quit(1)
		return
	print("test_map_view_incremental: PASS")
	quit()

## Nearest soil tile to any spawned colonist, expanding Chebyshev rings out to
## a generous radius -- mirrors debug_scenario.gd's own _nearest_matching_tile()
## search, kept local here since debug_scenario.gd is unrelated to this test.
func _nearest_soil_tile(world: WorldStateType) -> Vector2i:
	var width := world.get_map_width()
	var height := world.get_map_height()
	for colonist in world.get_colonists():
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		for radius in range(0, 40):
			for y in range(origin.y - radius, origin.y + radius + 1):
				if y < 0 or y >= height:
					continue
				for x in range(origin.x - radius, origin.x + radius + 1):
					if x < 0 or x >= width:
						continue
					if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
						continue
					if world.get_tile(x, y) == "soil":
						return Vector2i(x, y)
	return Vector2i(-1, -1)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
