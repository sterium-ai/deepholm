extends SceneTree

## F5b (ADR 065): the cook labour, the 2x1 kitchen and the meal recipe (F2 machinery), and the
## eat preference for meals, through the real triggers only (craft_* commands, set_labour, ticks).
## - acceptance: a built kitchen, 6 raw food stockpiled, one colonist with cook enabled and
##   "keep 2 meals" -> 2 meals lie in the stockpile, 2 raw food were spent per meal, only the
##   cook colonist ran cook_work, and the same seed reproduces every state_hash();
## - a hungry colonist eats a meal before nearer raw food, and raw food when nothing better is left;
## - save/load mid-fetch and mid-cook continue tick for tick identically;
## - a recorded session replays (A11).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const KITCHEN := Vector2i(10, 5)
const DAY_TICKS := 2200
const COOK := "colonist_0"
const HAULER := "colonist_1"

var _failed := false
var _next_command := 0

func _init() -> void:
	_check_acceptance_two_meals_from_raw_food()
	_check_hungry_colonist_eats_a_meal_before_raw_food()
	_check_save_load_mid_fetch_and_mid_cook_continue_identically()
	_check_recorded_session_replays()
	if _failed:
		quit(1)
		return
	print("test_cooking: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _command(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	return Scenarios.command(world, "cook_test_%d" % _next_command, type, payload)

func _command_ok(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	var result := _command(world, type, payload)
	_expect(bool(result.get("ok", false)), "%s %s must be accepted: %s" % [type, payload, result])
	return result

## A floor map with a 4x2 stockpile at (0, 0), one built kitchen at KITCHEN, water, a berry
## bush and a bed (so needs never stall the run), a cook and a hauler whose cook labour is off,
## and the given raw food in the stockpile.
func _world(seed_value: int, food: int) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	TestAccess.set_tile(world, 14, 12, WorldStateType.TILE_WATER)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.object_table(world).set_object(Vector3i(KITCHEN.x, KITCHEN.y, 0), "kitchen", "colony", "")
	TestAccess.object_table(world).set_object(Vector3i(16, 12, 0), "berry_bush", "colony", "")
	TestAccess.object_table(world).set_object(Vector3i(18, 12, 0), "bed", "colony", "")
	TestAccess.colonists(world).append(Scenarios.idle_colonist(COOK, 5, 3))
	TestAccess.colonists(world).append(Scenarios.idle_colonist(HAULER, 6, 3))
	_command_ok(world, "set_labour", {"colonist": HAULER, "kind": "cook", "level": 0})
	_command_ok(world, "zone_add", {"x": 0, "y": 0, "z": 0, "width": 4, "height": 2})
	if food > 0:
		Scenarios.add_stock(world, "food", food, 0, 0)
	return world

func _acceptance_world(seed_value: int) -> WorldStateType:
	var world := _world(seed_value, 6)
	_command_ok(world, "craft_set_target", {"x": KITCHEN.x, "y": KITCHEN.y, "z": 0, "recipe": "meal", "count": 2})
	return world

func _in_stockpile(x: int, y: int) -> bool:
	return x >= 0 and x < 4 and y >= 0 and y < 2

## Loose units of kind lying in the stockpile.
func _stockpiled(world: WorldStateType, kind: String) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind and _in_stockpile(int(item["x"]), int(item["y"])):
			total += int(item["count"])
	return total

## Every unit of kind in the world: on the ground, in hands, held by a bench bill.
func _total(world: WorldStateType, kind: String) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind:
			total += int(item["count"])
	for actor in TestAccess.colonists(world):
		total += InventoryType.count_of_kind(actor, kind)
	for bench in world.get_crafting_benches():
		if not (bench["bill"] as Dictionary).is_empty():
			for stack in (bench["bill"]["held"] as Array):
				if String(stack["item"]) == kind:
					total += int(stack["quantity"])
	return total

func _kitchen(world: WorldStateType) -> Dictionary:
	for bench in world.get_crafting_benches():
		if Vector2i(int(bench["x"]), int(bench["y"])) == KITCHEN:
			return bench
	return {}

func _workers_of(world: WorldStateType, job_kind: String) -> Array[String]:
	var workers: Array[String] = []
	var assignments := world.get_assignments()
	for worker in assignments:
		if String(world.get_job(String(assignments[worker]["job_id"])).get("kind", "")) == job_kind:
			workers.append(String(worker))
	return workers

## Acceptance (F5b): 2 meals in the stockpile, 2 raw food per meal, cook labour respected,
## deterministic state_hash().
func _check_acceptance_two_meals_from_raw_food() -> void:
	var world := _acceptance_world(650001)
	var twin := _acceptance_world(650001)
	var done_at := -1
	var saw_cook_work := false
	for tick in DAY_TICKS:
		world.tick()
		twin.tick()
		for worker in _workers_of(world, "cook_work"):
			saw_cook_work = true
			_expect(worker == COOK, "only the colonist with cook enabled may run cook_work, saw %s" % worker)
		_expect(_workers_of(world, "craft_work").is_empty(), "the meal recipe must be worked as cook_work, not craft_work")
		if tick % 100 == 0 and world.state_hash() != twin.state_hash():
			_fail("the same seed and commands must give the same state_hash() at tick %d" % world.get_tick())
			break
		if _stockpiled(world, "meal") >= 2:
			done_at = world.get_tick()
			break
	_expect(saw_cook_work, "the kitchen bill must be worked as cook_work")
	_expect(done_at >= 0, "2 meals must be in the stockpile within a day (meals %d)" % _stockpiled(world, "meal"))
	_expect(world.state_hash() == twin.state_hash(), "the twin run must end on the same state_hash()")
	_expect(_total(world, "meal") == 2, "keep 2 meals must make exactly 2, got %d" % _total(world, "meal"))
	_expect(_total(world, "food") == 2, "2 meals of 2 raw food each from 6 must leave 2, got %d" % _total(world, "food"))
	_expect((_kitchen(world)["bill"] as Dictionary).is_empty(), "no bill may remain once the target is met")

## A floor world with no bush and no stockpile: one hungry colonist (the other needs paused),
## raw food next to them and, when meal_x >= 0, one meal further away.
func _hungry_world(seed_value: int, meal_x: int) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	Scenarios.isolate_need(world, "food")
	var colonist := Scenarios.idle_colonist(COOK, 5, 3)
	colonist["needs"] = Scenarios.full_needs({"food": 20})
	TestAccess.colonists(world).append(colonist)
	Scenarios.add_stock(world, "food", 3, 6, 3)
	if meal_x >= 0:
		Scenarios.add_stock(world, "meal", 1, meal_x, 3)
	return world

func _food_need(world: WorldStateType) -> int:
	return int(TestAccess.find_colonist(world, COOK)["needs"]["food"])

## Acceptance (F5b): "a hungry colonist eats a meal before raw food". The meal lies 7 tiles away,
## raw food 1 tile away; the meal goes and restores its satiety. With only raw food left, the
## colonist eats raw food (satiety 40).
func _check_hungry_colonist_eats_a_meal_before_raw_food() -> void:
	var world := _hungry_world(650002, 12)
	for _i in 600:
		world.tick()
		if _total(world, "meal") == 0:
			break
	_expect(_total(world, "meal") == 0, "the hungry colonist must eat the meal")
	_expect(_total(world, "food") == 3, "raw food must be left while a meal is reachable, %d left" % _total(world, "food"))
	_expect(_food_need(world) >= 95, "a meal restores satiety 100, food need is %d" % _food_need(world))
	var raw := _hungry_world(650003, -1)
	for _i in 600:
		raw.tick()
		if _total(raw, "food") < 3:
			break
	_expect(_total(raw, "food") == 2, "with no meal, the hungry colonist must eat one raw food, %d left" % _total(raw, "food"))
	var need := _food_need(raw)
	_expect(need >= 35 and need <= 40, "raw food restores satiety 40, food need is %d" % need)

## Acceptance (F5b): save/load mid-cook continues identically -- once while a craft_fetch carries
## raw food to the kitchen, once while cook_work is under way.
func _check_save_load_mid_fetch_and_mid_cook_continue_identically() -> void:
	var world := _acceptance_world(650004)
	var checked := {}
	for _i in DAY_TICKS:
		world.tick()
		var moment := _moment(world)
		if moment.is_empty() or checked.has(moment):
			continue
		checked[moment] = true
		var restored := WorldStateType.from_save_state(world.to_save_state())
		_expect(restored.state_hash() == world.state_hash(), "%s: the loaded world must hash like the saved one" % moment)
		for step in 300:
			world.tick()
			restored.tick()
			if restored.state_hash() != world.state_hash():
				_fail("%s: the loaded world diverged %d ticks after the load" % [moment, step + 1])
				break
		if checked.size() == 2:
			break
	_expect(checked.has("mid_fetch") and checked.has("mid_cook"), "the run must reach a carrying craft_fetch and a cook_work under way: %s" % [checked])

## "mid_fetch" while a colonist carries a craft_fetch load, "mid_cook" while cook_work has
## progress, else "".
func _moment(world: WorldStateType) -> String:
	var assignments := world.get_assignments()
	for worker in assignments:
		var job := world.get_job(String(assignments[worker]["job_id"]))
		var actor := TestAccess.find_colonist(world, String(worker))
		if String(job.get("kind", "")) == "craft_fetch" and InventoryType.is_carrying(actor) and job.get("cell") != null:
			return "mid_fetch"
		if String(job.get("kind", "")) == "cook_work" and actor.get("work") != null:
			return "mid_cook"
	return ""

## Acceptance (F5b): "replay reproduces it" -- the acceptance session recorded through the
## viewer's CommandRecorder (A11), its commands included, replays every checkpoint.
func _check_recorded_session_replays() -> void:
	var world := _world(650005, 6)
	var recorder := CommandRecorderType.new()
	recorder.start(world, 100, false)
	_command_ok(world, "craft_set_target", {"x": KITCHEN.x + 1, "y": KITCHEN.y, "z": 0, "recipe": "meal", "count": 2})
	for _i in 1500:
		world.tick()
		recorder.observe_tick(world)
	var recording := recorder.stop()
	_expect(_stockpiled(world, "meal") >= 1, "the recorded session must really cook")
	var result := recording.replay()
	_expect(bool(result.get("ok", false)), "the recorded cooking session must replay every checkpoint: %s" % [result])
