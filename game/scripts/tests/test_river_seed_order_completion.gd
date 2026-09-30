extends SceneTree

## Headless check that, for the verification seeds 1337 and 20260919 (ADR
## 020), a new game lets the colonists locate nearby food and water and
## complete a player-selected initial order. test_new_game_forage_chop.gd
## covers order completion under real need decay for a different seed
## (555002), and test_river_map_capture.gd never submits an order.
##
## For each seed this boots
## the real New Game path (boot.gd's own _start_new_game(), same as
## test_new_game_forage_chop.gd), independently re-verifies the food/water
## accessibility contract for that exact generated map (a real BFS through
## world.passability(), never reused from test_river_generation.gd or
## WorldGenerator's own distance fields), then submits and drives to
## completion one real player-selected forage order, submitted directly
## through WorldState.apply(). Recognizing the river visually and operating
## the mouse are not covered here; test_river_seed_viewer_interaction.gd
## drives the same check through the running viewer's input path.

const BootScenePath := "res://scenes/boot.tscn"
const SEEDS := [1337, 20260919]
const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const WATER_STEP_LIMIT := 40
const FOOD_STEP_LIMIT := 40
const ORDER_TICK_BUDGET := 6000

var _failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for seed_value in SEEDS:
		await _check_seed(seed_value)

	if _failures.is_empty():
		print("test_river_seed_order_completion: PASS")
		quit()
		return
	for failure in _failures:
		push_error(failure)
	quit(1)

func _check_seed(seed_value: int) -> void:
	var boot_scene: PackedScene = load(BootScenePath)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	await process_frame
	boot_node._start_new_game(seed_value)
	var world = boot_node.get("world")
	_expect(world != null, "seed %d: New Game must produce a world" % seed_value)
	if world == null:
		root.remove_child(boot_node)
		boot_node.free()
		return

	var colonists: Array = world.get_colonists()
	_expect(colonists.size() == 3, "seed %d: New Game must spawn exactly 3 colonists, found %d" % [seed_value, colonists.size()])

	# Locate nearby food and water: an independent real-route BFS per
	# colonist, against the documented step bounds.
	for colonist in colonists:
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var colonist_id: String = String(colonist["id"])
		var water_steps := _bfs_route_distance(world, start, func(x, y): return world.get_tile(x, y) == "water")
		var food_steps := _bfs_route_distance(world, start, func(x, y): return world.get_object(x, y) == "berry_bush")
		_expect(water_steps != -1 and water_steps <= WATER_STEP_LIMIT,
			"seed %d colonist %s must locate water within %d steps, got %d" % [seed_value, colonist_id, WATER_STEP_LIMIT, water_steps])
		_expect(food_steps != -1 and food_steps <= FOOD_STEP_LIMIT,
			"seed %d colonist %s must locate food within %d steps, got %d" % [seed_value, colonist_id, FOOD_STEP_LIMIT, food_steps])

	# Complete a player-selected initial order: one real forage order,
	# assignee-restricted so the fair scheduler cannot hand it
	# to a different colonist, driven to completion under the real work engine.
	if not colonists.is_empty():
		var origin := Vector2i(int(colonists[0]["x"]), int(colonists[0]["y"]))
		var bush := _bfs_nearest_object(world, origin, "berry_bush")
		_expect(bush != Vector2i(-1, -1), "seed %d: colonist_0 must have a reachable berry bush to order a forage against" % seed_value)
		if bush != Vector2i(-1, -1):
			var result: Dictionary = world.apply({
				"actor": "test", "command_id": "forage_seed_%d" % seed_value, "tick": world.get_tick(),
				"type": "forage", "payload": {"x": bush.x, "y": bush.y, "priority": 1, "assignee": String(colonists[0]["id"])},
			})
			_expect(result.get("ok", false), "seed %d: forage order must be accepted: %s" % [seed_value, result])
			var completed := false
			var ticks := 0
			while ticks < ORDER_TICK_BUDGET and not completed:
				world.tick()
				ticks += 1
				if world.get_object(bush.x, bush.y) != "berry_bush":
					completed = true
			_expect(completed, "seed %d: the player-selected forage order must complete within %d ticks" % [seed_value, ORDER_TICK_BUDGET])

	root.remove_child(boot_node)
	boot_node.free()
	await process_frame

## Single-source BFS from `start`, expanding only through world.passability()
## -- an independent implementation, never reused from test_river_generation.gd
## or WorldGenerator's own distance fields -- to the nearest neighbour
## `is_target` accepts (the walk to reach it, plus one interaction step).
func _bfs_route_distance(world, start: Vector2i, is_target: Callable) -> int:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start]
	visited[start.y * width + start.x] = 0
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var distance: int = visited[current.y * width + current.x]
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			if is_target.call(nx, ny):
				return distance + 1
			var nindex := ny * width + nx
			if not visited.has(nindex) and bool(world.passability(nx, ny)["passable"]):
				visited[nindex] = distance + 1
				queue.append(Vector2i(nx, ny))
	return -1

## Nearest real-route object of `kind`, expanding only through
## world.passability() (never a Chebyshev-ring geometric search, which could
## pick a closer-as-the-crow-flies object across the river that a colonist can
## never actually walk to, stalling the order forever). Vector2i(-1, -1) when
## none is reachable.
func _bfs_nearest_object(world, start: Vector2i, kind: String) -> Vector2i:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start]
	visited[start.y * width + start.x] = true
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			if world.get_object(nx, ny) == kind:
				return Vector2i(nx, ny)
			var nindex := ny * width + nx
			if not visited.has(nindex) and bool(world.passability(nx, ny)["passable"]):
				visited[nindex] = true
				queue.append(Vector2i(nx, ny))
	return Vector2i(-1, -1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
