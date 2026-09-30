extends SceneTree

## A game created through boot.gd's New Game
## control (not a hand-built WorldState) must be able to actually complete
## dig and chop through real ticks -- both require a fetched tool
## (jobs.json's needs_tool), and a bare WorldState with an empty tool store
## leaves them blocked_no_tool indefinitely. Proves the
## new-game initialization/content boundary (boot.gd's _spawn_starting_tools())
## provides real, fetchable starting tools without bypassing the work engine:
## dig/chop still go through fetch_tool -> reserve -> go_to -> work exactly
## like any other order.
##
## Also proves New Game starts paused with no auto-submitted
## dig queue (never the debug scenario's own), then drives the player
## choosing real dig/chop orders, resuming, and completing them with real
## fetched tools.

const BootScenePath := "res://scenes/boot.tscn"
const NEW_GAME_SEED := 555001
const TICK_BUDGET := 1500
const SEARCH_RADIUS := 15

var _failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

## boot.gd builds `world` in _init() but save_manager/autosave_trigger (which
## _start_new_game() needs) in _ready(), which has not fired yet synchronously
## after add_child() in a SceneTree script's own _init() (see test_order_input.gd's
## header comment) -- awaiting a process frame here lets _ready() run first.
func _run() -> void:
	var boot_scene: PackedScene = load(BootScenePath)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	await process_frame
	boot_node._start_new_game(NEW_GAME_SEED)
	var world = boot_node.get("world")
	_expect(world != null, "New Game must produce a world")
	if world == null:
		_finish(boot_node)
		return

	# The normal new game starts paused and without the
	# debug scenario's random dig orders -- checked here,
	# before any order is chosen, then the rest of this test drives the
	# player choosing dig/chop orders, resuming (ticking), and completing them
	# with real fetched tools.
	var tick_driver = boot_node.get("tick_driver")
	_expect(tick_driver != null and tick_driver.speed == tick_driver.Speed.PAUSED,
		"New Game must start paused")
	_expect(world.get_jobs().is_empty(), "New Game must start with no auto-submitted dig orders")

	var origin: Vector2i = _colonist_origin(world)
	var dig_target := _nearest_tile(world, origin, "soil")
	_expect(dig_target != Vector2i(-1, -1), "New Game world must have a soil tile near spawn")
	var chop_target := _nearest_tile(world, origin, "tree")
	_expect(chop_target != Vector2i(-1, -1), "New Game world must have a tree tile near spawn")

	if dig_target != Vector2i(-1, -1):
		_run_and_verify(world, "dig", dig_target, "trench")
	if chop_target != Vector2i(-1, -1):
		_run_and_verify(world, "chop", chop_target, "floor")

	_finish(boot_node)

## expected_tile: dig's own completion effect turns its target into "trench"
## (ADR 026, docs/decisions/026-trench-trapped-actor-and-rescue.md), never
## "floor"; chop is unaffected and still produces "floor".
func _run_and_verify(world, job_type: String, target: Vector2i, expected_tile: String) -> void:
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "%s_new_game" % job_type, "tick": world.get_tick(),
		"type": job_type, "payload": {"x": target.x, "y": target.y, "priority": 1},
	})
	_expect(result.get("ok", false), "%s command on a New Game world must be accepted: %s" % [job_type, result])
	var ticks := 0
	while ticks < TICK_BUDGET and world.get_tile(target.x, target.y) != expected_tile:
		# Keeps needs topped up so this check exercises only what it claims to
		# -- dig/chop actually completing through the new-game tool-fetch path
		# -- without also fighting the (separately tested) need-decay system
		# for one of only mapgen.json's default 3 colonists: with real need
		# decay, colonists spend so much time servicing recurring eat/drink/
		# sleep jobs that an ordinary-priority order can sit queued for
		# thousands of ticks before ever being picked up.
		for colonist in world._colonists:
			var needs: Dictionary = colonist["needs"]
			for kind in needs.keys():
				needs[kind] = 100
		world.tick()
		ticks += 1
	_expect(world.get_tile(target.x, target.y) == expected_tile,
		"%s at (%d, %d) must complete within %d ticks on a New Game world with a real starting tool"
			% [job_type, target.x, target.y, TICK_BUDGET])
	if job_type == "dig":
		_expect(_has_sand_near(world, target),
			"a completed dig at (%d, %d) must spawn a sand item on or adjacent to the trench" % [target.x, target.y])

func _has_sand_near(world, target: Vector2i) -> bool:
	for item in world.get_items():
		if String(item["kind"]) == "sand" and maxi(absi(int(item["x"]) - target.x), absi(int(item["y"]) - target.y)) <= 1:
			return true
	return false

func _colonist_origin(world) -> Vector2i:
	var colonists: Array = world.get_colonists()
	if colonists.is_empty():
		return Vector2i(-1, -1)
	var first: Dictionary = colonists[0]
	return Vector2i(int(first["x"]), int(first["y"]))

func _nearest_tile(world, origin: Vector2i, kind: String) -> Vector2i:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	for radius in range(0, SEARCH_RADIUS + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if world.get_tile(x, y) == kind and world.get_object(x, y) == "":
					return Vector2i(x, y)
	return Vector2i(-1, -1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _finish(boot_node: Node) -> void:
	root.remove_child(boot_node)
	boot_node.free()
	if _failures.is_empty():
		print("test_new_game_dig_chop: PASS")
		quit()
		return
	for failure in _failures:
		push_error("test_new_game_dig_chop: " + failure)
	quit(1)
