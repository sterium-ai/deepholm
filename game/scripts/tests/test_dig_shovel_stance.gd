extends SceneTree

## B9: dig needs a shovel (content/jobs.json's needs_tool), and dig/mine/chop are worked
## from an adjacent tile. A dig with no shovel anywhere blocks with blocked_no_tool and
## remedy craft_or_find:shovel, even when a pick lies at hand; a digger, miner and
## chopper stand at Chebyshev distance 1 from the target (never on it) for every tick
## of their work toil, including a digger ordered to dig the tile it stands on, and a digger
## stepping off a tile to dig it never steps into the trench it dug a moment before.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

var _failed := false

func _init() -> void:
	_check_dig_without_shovel_blocks_even_with_a_pick()
	_check_shovel_is_a_workbench_recipe()
	_check_digger_works_from_adjacent_tile(Vector2i(3, 0), "a dig two tiles away")
	_check_digger_works_from_adjacent_tile(Vector2i(0, 0), "a dig under the digger's feet")
	_check_miner_works_from_adjacent_tile()
	_check_consecutive_digs_never_step_into_a_trench()
	if _failed:
		quit(1)
		return
	print("test_dig_shovel_stance: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## A 6x1 soil corridor with one colonist at its west end.
func _corridor_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 6):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "z": 0, "route": null, "work": null})
	return world

func _check_dig_without_shovel_blocks_even_with_a_pick() -> void:
	var world := _corridor_world(9001)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 3, "y": 0, "z": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig must be accepted with no shovel anywhere")
	var job_id := String(submitted.get("job_id", ""))
	var blocked := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, job_id)
		if String(job.get("reason", "")) == "blocked_no_tool":
			blocked = true
			_expect(String(job.get("remedy", "")) == "craft_or_find:shovel",
				"blocked dig must carry remedy craft_or_find:shovel, got '%s'" % job.get("remedy"))
			break
	_expect(blocked, "a dig with only a pick at hand must block with blocked_no_tool")
	_expect(world.get_tile(3, 0) == WorldStateType.TILE_SOIL, "a blocked dig must not dig the tile")

func _check_shovel_is_a_workbench_recipe() -> void:
	var recipes: Array = JSON.parse_string(FileAccess.get_file_as_string("res://content/recipes.json"))["recipes"]
	var found := false
	for recipe in recipes:
		if String(recipe.get("id", "")) == "shovel":
			found = String(recipe.get("bench", "")) == "workbench" and String(recipe["outputs"][0]["item"]) == "shovel"
	_expect(found, "recipes.json must declare a workbench shovel recipe")

## Runs the dig to completion and checks the digger's stance on every work tick.
func _check_digger_works_from_adjacent_tile(target: Vector2i, label: String) -> void:
	var world := _corridor_world(9002 + target.x)
	world.spawn_ground_tool_item("shovel", 0, 0)
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": target.x, "y": target.y, "z": 0, "priority": 1})
	_expect(submitted.get("ok", false), "%s must be accepted" % label)
	var job_id := String(submitted.get("job_id", ""))
	var work_ticks := _run_and_check_stance(world, job_id, target, label)
	_expect(work_ticks > 0, "%s must spend at least one tick in its work toil" % label)
	_expect(String(Scenarios.find_job(world, job_id).get("status", "")) == "completed", "%s must complete" % label)
	_expect(world.get_tile(target.x, target.y) == WorldStateType.TILE_TRENCH, "%s must leave a trench" % label)

## mine's rock target is impassable: the miner already stood adjacent before B9; pinned here.
func _check_miner_works_from_adjacent_tile() -> void:
	var world := _corridor_world(9010)
	world.spawn_ground_tool_item("pick", 0, 0)
	var target := Vector2i(6, 0)
	var submitted := Scenarios.command(world, "mine_1", "mine", {"x": target.x, "y": target.y, "z": 0, "priority": 1})
	_expect(submitted.get("ok", false), "mine must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	_expect(_run_and_check_stance(world, job_id, target, "mine") > 0, "mine must spend at least one tick in its work toil")

## Ticks until the job is terminal; returns how many ticks colonist_0 spent in its work toil.
func _run_and_check_stance(world: WorldStateType, job_id: String, target: Vector2i, label: String) -> int:
	var work_ticks := 0
	for _i in 200:
		world.tick()
		var colonist: Dictionary = TestAccess.colonists(world)[0]
		var work = colonist.get("work")
		if work != null and String(work.get("job_id", "")) == job_id:
			work_ticks += 1
			var offset := Vector2i(int(colonist["x"]), int(colonist["y"])) - target
			_expect(maxi(absi(offset.x), absi(offset.y)) == 1,
				"%s: the worker must stand adjacent to the target during work, at offset %s" % [label, offset])
		if String(Scenarios.find_job(world, job_id).get("status", "")) in ["completed", "failed", "cancelled"]:
			break
	return work_ticks

## Digs (0,0) then (1,0): after the first dig the digger stands on (1,0) next to the fresh
## trench at (0,0); stepping off (1,0) must pick (2,0), not the trench (which traps it and
## cancels the dig). Both digs complete and the digger is never trapped.
func _check_consecutive_digs_never_step_into_a_trench() -> void:
	var world := _corridor_world(9020)
	world.spawn_ground_tool_item("shovel", 0, 0)
	for x in 2:
		var submitted := Scenarios.command(world, "dig_%d" % x, "dig", {"x": x, "y": 0, "z": 0, "priority": 1})
		_expect(submitted.get("ok", false), "dig %d must be accepted" % x)
		var job_id := String(submitted.get("job_id", ""))
		_run_and_check_stance(world, job_id, Vector2i(x, 0), "consecutive dig %d" % x)
		var job := Scenarios.find_job(world, job_id)
		_expect(String(job.get("status", "")) == "completed",
			"consecutive dig %d must complete, got %s/%s" % [x, job.get("status"), job.get("reason")])
		_expect(TestAccess.colonists(world)[0].get("trapped") == null, "consecutive dig %d must not trap the digger" % x)
