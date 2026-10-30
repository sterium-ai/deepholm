extends SceneTree

## F2 (ADR 061): workbench recipes, the craft labour and item groups, through the real
## triggers only (craft_* commands, set_labour, chop, remove_object and ticks).
## - acceptance: one built workbench, 6 wood + 4 stone stockpiled, one colonist with craft
##   enabled, "keep 1 axe" and "planks x2" -> within 2 days an axe and 4 planks lie in the
##   stockpile, the inputs were consumed exactly per recipe, only the craft colonist crafted,
##   and the same seed reproduces every state_hash();
## - the target re-triggers once a colonist takes the axe (a chop order fetches it);
## - an order whose inputs are missing waits without blocking the order behind it;
## - save/load mid-fetch and mid-craft continue tick for tick identically;
## - a recorded session replays (A11);
## - commands are validated (preview agrees), cancelling an order or removing the bench
##   mid-bill drops the held inputs next to the bench;
## - ContentRegistry rejects a recipe naming an unknown item or bench and an item whose kind
##   is not a declared group.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const RecipeBookType = preload("res://scripts/core/crafting/recipe_book.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const BENCH := Vector2i(10, 5)
const DAY_TICKS := 2200
const CRAFTER := "colonist_0"
const HAULER := "colonist_1"
const CONTENT_FIXTURE_DIR := "user://test-crafting-content-fixture"
const HELD_SAVE_PATH := "user://test-crafting-held-cap.json"

var _failed := false
var _next_command := 0

func _init() -> void:
	var world := _check_acceptance_axe_and_planks_within_two_days()
	_check_target_retriggers_when_the_axe_is_taken(world)
	_check_missing_inputs_wait_without_blocking_the_queue()
	_check_target_ignores_an_unreachable_loose_axe()
	_check_target_does_not_recraft_output_waiting_for_its_hauler()
	_check_save_load_mid_fetch_and_mid_craft_continue_identically()
	_check_recorded_session_replays()
	_check_commands_are_validated_and_preview_agrees()
	_check_cancel_order_and_removed_bench_drop_held_inputs()
	_check_content_registry_rejects_bad_recipes_and_groups()
	_check_recipe_and_save_quantity_caps_agree()
	if _failed:
		quit(1)
		return
	print("test_crafting: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _command(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	return Scenarios.command(world, "craft_test_%d" % _next_command, type, payload)

func _command_ok(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	var result := _command(world, type, payload)
	_expect(bool(result.get("ok", false)), "%s %s must be accepted: %s" % [type, payload, result])
	return result

## A floor map with a 4x2 stockpile at (0, 0), one built workbench at BENCH, water, a berry
## bush and a bed (so needs never stall the run), a crafter and a hauler whose craft labour
## is off, and the given stock in the stockpile.
func _world(seed_value: int, wood: int, stone: int) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	TestAccess.set_tile(world, 14, 12, WorldStateType.TILE_WATER)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.object_table(world).set_object(BENCH.x, BENCH.y, "workbench", "colony", "")
	TestAccess.object_table(world).set_object(16, 12, "berry_bush", "colony", "")
	TestAccess.object_table(world).set_object(18, 12, "bed", "colony", "")
	TestAccess.colonists(world).append(Scenarios.idle_colonist(CRAFTER, 5, 3))
	TestAccess.colonists(world).append(Scenarios.idle_colonist(HAULER, 6, 3))
	_command_ok(world, "set_labour", {"colonist": HAULER, "kind": "craft", "level": 0})
	_command_ok(world, "zone_add", {"x": 0, "y": 0, "width": 4, "height": 2})
	if wood > 0:
		Scenarios.add_stock(world, "wood", wood, 0, 0)
	if stone > 0:
		Scenarios.add_stock(world, "stone", stone, 1, 0)
	return world

func _acceptance_world(seed_value: int) -> WorldStateType:
	var world := _world(seed_value, 6, 4)
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 1})
	_command_ok(world, "craft_add_order", {"x": BENCH.x + 1, "y": BENCH.y, "recipe": "planks", "count": 2})
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

func _stockpiled_tools(world: WorldStateType, kind: String) -> int:
	var total := 0
	for tool_item in world.get_tool_items():
		var location: Dictionary = tool_item["location"]
		if String(tool_item["kind"]) == kind and String(location["type"]) == "stockpile" and _in_stockpile(int(location["x"]), int(location["y"])):
			total += 1
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

func _bench(world: WorldStateType) -> Dictionary:
	for bench in world.get_crafting_benches():
		if Vector2i(int(bench["x"]), int(bench["y"])) == BENCH:
			return bench
	return {}

func _craft_workers(world: WorldStateType) -> Array[String]:
	var workers: Array[String] = []
	var assignments := world.get_assignments()
	for worker in assignments:
		if String(world.get_job(String(assignments[worker]["job_id"])).get("kind", "")) == "craft_work":
			workers.append(String(worker))
	return workers

## Acceptance (F2): an axe and 4 planks in the stockpile within 2 days, exact consumption,
## craft labour respected, deterministic state_hash().
func _check_acceptance_axe_and_planks_within_two_days() -> WorldStateType:
	var world := _acceptance_world(610001)
	var twin := _acceptance_world(610001)
	var done_at := -1
	for tick in 2 * DAY_TICKS:
		world.tick()
		twin.tick()
		for worker in _craft_workers(world):
			_expect(worker == CRAFTER, "only the colonist with craft enabled may run craft_work, saw %s" % worker)
		if tick % 100 == 0 and world.state_hash() != twin.state_hash():
			_fail("the same seed and commands must give the same state_hash() at tick %d" % world.get_tick())
			break
		if done_at < 0 and _stockpiled_tools(world, "axe") >= 1 and _stockpiled(world, "planks") >= 4:
			done_at = world.get_tick()
	_expect(done_at >= 0, "an axe and 4 planks must be in the stockpile within 2 days (axe %d, planks %d)"
		% [_stockpiled_tools(world, "axe"), _stockpiled(world, "planks")])
	_expect(world.state_hash() == twin.state_hash(), "the twin run must end on the same state_hash()")
	_expect(_stockpiled_tools(world, "axe") == 1, "the target keeps exactly 1 axe, got %d" % _stockpiled_tools(world, "axe"))
	_expect(_total(world, "planks") == 4, "planks x2 must make exactly 4 planks, got %d" % _total(world, "planks"))
	_expect(_total(world, "wood") == 1, "3 wood (axe) + 2 wood (planks x2) of 6 must leave 1, got %d" % _total(world, "wood"))
	_expect(_total(world, "stone") == 3, "1 stone (axe) of 4 must leave 3, got %d" % _total(world, "stone"))
	var bench := _bench(world)
	_expect((bench["orders"] as Array).is_empty(), "the planks order must be used up: %s" % [bench["orders"]])
	_expect((bench["bill"] as Dictionary).is_empty(), "no bill may remain once the target and the order are met")
	return world

## Acceptance (F2): "the target re-triggers when the axe is taken by a colonist". A chop order
## makes a colonist fetch the stockpiled axe; with the inputs restocked, a second axe follows.
func _check_target_retriggers_when_the_axe_is_taken(world: WorldStateType) -> void:
	TestAccess.set_tile(world, 20, 8, WorldStateType.TILE_TREE)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	TestAccess.tile_grid(world).rooms = null
	Scenarios.add_stock(world, "wood", 3, 2, 0)
	_command_ok(world, "chop", {"x": 20, "y": 8, "priority": 1})
	var saw_held := false
	var saw_axe_bill_while_held := false
	for _i in DAY_TICKS:
		world.tick()
		var held := false
		for tool_item in world.get_tool_items():
			if String(tool_item["kind"]) == "axe" and String(tool_item["location"]["type"]) == "held":
				held = true
		saw_held = saw_held or held
		var bill: Dictionary = _bench(world).get("bill", {})
		if held and String(bill.get("recipe", "")) == "axe":
			saw_axe_bill_while_held = true
		if saw_axe_bill_while_held and _stockpiled_tools(world, "axe") >= 1:
			break
	_expect(saw_held, "the chop order must make a colonist take the axe")
	_expect(saw_axe_bill_while_held, "with the axe held, the keep-1 target must choose an axe bill again")
	_expect(_stockpiled_tools(world, "axe") == 1, "the re-triggered target must stock a second axe")

## Acceptance (F2): "a recipe whose materials are missing waits without blocking the queue".
func _check_missing_inputs_wait_without_blocking_the_queue() -> void:
	var world := _world(610002, 1, 0)
	_command_ok(world, "craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "pick", "count": 1})
	_command_ok(world, "craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "planks", "count": 1})
	for _i in DAY_TICKS:
		world.tick()
		_expect(String(_bench(world)["bill"].get("recipe", "")) != "pick", "pick has no stone: it must never take the bench")
		if _stockpiled(world, "planks") >= 2:
			break
	_expect(_stockpiled(world, "planks") == 2, "planks queued behind the waiting pick must still be crafted")
	var orders: Array = _bench(world)["orders"]
	_expect(orders.size() == 1 and String(orders[0]["recipe"]) == "pick", "the pick order must still wait: %s" % [orders])
	Scenarios.add_stock(world, "wood", 2, 2, 1)
	Scenarios.add_stock(world, "stone", 2, 3, 1)
	for _i in DAY_TICKS:
		world.tick()
		if _stockpiled_tools(world, "pick") >= 1:
			break
	_expect(_stockpiled_tools(world, "pick") == 1, "once its inputs are stocked, the waiting pick order must be crafted")
	_expect((_bench(world)["orders"] as Array).is_empty(), "the pick order must be used up")

## Design (F2): a target counts the colony's *stockpiled* units. A loose axe no colonist can
## reach (walled in by rock, its haul blocked) is not in stock, so "keep 1 axe" still makes one.
func _check_target_ignores_an_unreachable_loose_axe() -> void:
	var world := _world(610007, 3, 1)
	var walled := Vector2i(25, 15)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx != 0 or dy != 0:
				TestAccess.set_tile(world, walled.x + dx, walled.y + dy, WorldStateType.TILE_ROCK)
	TestAccess.tile_grid(world).reset_cells()
	Scenarios.add_stock(world, "axe", 1, walled.x, walled.y)
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 1})
	for _i in DAY_TICKS:
		world.tick()
		if _stockpiled_tools(world, "axe") >= 1:
			break
	_expect(_stockpiled_tools(world, "axe") == 1, "an unreachable loose axe is not stock: the keep-1 target must craft one")
	_expect(_total(world, "wood") == 0 and _total(world, "stone") == 0, "exactly one axe's inputs must be spent")

## Design (F2): output lying next to the bench while its haul is under way counts as stock, so
## "keep 2 planks" makes one batch (1 wood -> 2 planks), not one per tick until it is hauled.
func _check_target_does_not_recraft_output_waiting_for_its_hauler() -> void:
	var world := _world(610008, 5, 0)
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "planks", "count": 2})
	var stocked_at := -1
	for _i in 2 * DAY_TICKS:
		world.tick()
		if stocked_at < 0 and _stockpiled(world, "planks") >= 2:
			stocked_at = world.get_tick()
		if stocked_at >= 0 and world.get_tick() >= stocked_at + 600:
			break
	_expect(stocked_at >= 0, "the keep-2 planks target must stock its planks")
	_expect(_total(world, "planks") == 2 and _stockpiled(world, "planks") == 2, "exactly one batch of planks: %d made" % _total(world, "planks"))
	_expect(_total(world, "wood") == 4, "exactly one wood must be spent, %d left" % _total(world, "wood"))

## Acceptance (F2): "save/load mid-craft continues identically" -- once while a craft_fetch
## carries an input to the bench, once while craft_work is under way.
func _check_save_load_mid_fetch_and_mid_craft_continue_identically() -> void:
	var world := _acceptance_world(610003)
	var checked := {}
	for _i in 2 * DAY_TICKS:
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
	_expect(checked.has("mid_fetch") and checked.has("mid_craft"), "the run must reach a carrying craft_fetch and a craft_work under way: %s" % [checked])

## "mid_fetch" while a colonist carries a craft_fetch load, "mid_craft" while craft_work has
## progress, else "".
func _moment(world: WorldStateType) -> String:
	var assignments := world.get_assignments()
	for worker in assignments:
		var job := world.get_job(String(assignments[worker]["job_id"]))
		var actor := TestAccess.find_colonist(world, String(worker))
		if String(job.get("kind", "")) == "craft_fetch" and InventoryType.is_carrying(actor) and job.get("cell") != null:
			return "mid_fetch"
		if String(job.get("kind", "")) == "craft_work" and actor.get("work") != null:
			return "mid_craft"
	return ""

## Acceptance (F2): "replay reproduces it" -- the acceptance session recorded through the
## viewer's CommandRecorder (A11), its commands included, replays every checkpoint.
func _check_recorded_session_replays() -> void:
	var world := _world(610004, 6, 4)
	var recorder := CommandRecorderType.new()
	recorder.start(world, 100, false)
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 1})
	_command_ok(world, "craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "planks", "count": 2})
	var cancelled := false
	for _i in 1500:
		world.tick()
		recorder.observe_tick(world)
		if not cancelled and world.get_tick() >= 300 and not (_bench(world)["orders"] as Array).is_empty():
			_command_ok(world, "craft_cancel_order", {"x": BENCH.x, "y": BENCH.y, "order_id": "order_1"})
			cancelled = true
	var recording := recorder.stop()
	_expect(cancelled, "the session must really cancel the planks order mid-run")
	var types: Array[String] = []
	for entry: Dictionary in recording.commands:
		if bool(entry["ok"]):
			types.append(String(entry["command"]["type"]))
	_expect(types.has("craft_set_target") and types.has("craft_add_order") and types.has("craft_cancel_order"),
		"the target, the order and the cancellation must all be recorded as accepted: %s" % [types])
	var result := recording.replay()
	_expect(bool(result.get("ok", false)), "the recorded crafting session must replay every checkpoint: %s" % [result])

func _reason_detail(result: Dictionary) -> String:
	var rejection: Dictionary = result.get("rejection", {})
	return "%s/%s" % [rejection.get("reason", ""), (rejection.get("params", {}) as Dictionary).get("detail", "")]

## The craft_* rules, the same through preview() and apply(), and a fresh order id per order.
func _check_commands_are_validated_and_preview_agrees() -> void:
	var world := _world(610005, 0, 0)
	var cases := [
		["craft_set_target", {"x": 30, "y": 30, "recipe": "axe", "count": 1}, "invalid_target/not_a_workbench"],
		["craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "boat", "count": 1}, "invalid_payload/unknown_recipe"],
		["craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": -1}, "invalid_payload/craft_count_out_of_range"],
		["craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 0}, "invalid_payload/craft_count_out_of_range"],
		["craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe"}, "invalid_payload/craft_payload"],
		["craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 1, "extra": 1}, "invalid_payload/craft_extra_field"],
		["craft_cancel_order", {"x": BENCH.x, "y": BENCH.y, "order_id": "order_9"}, "invalid_target/unknown_craft_order"],
	]
	for case in cases:
		var preview := world.preview({"actor": "test", "command_id": "p", "tick": world.get_tick(), "type": case[0], "payload": case[1]})
		_expect(_reason_detail(preview) == case[2], "preview %s %s must reject %s, got %s" % [case[0], case[1], case[2], preview])
		var result := _command(world, case[0], case[1])
		_expect(_reason_detail(result) == case[2], "apply %s %s must reject %s, got %s" % [case[0], case[1], case[2], result])
	var first := _command_ok(world, "craft_add_order", {"x": BENCH.x + 1, "y": BENCH.y, "recipe": "axe", "count": 2})
	var second := _command_ok(world, "craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "pick", "count": 1})
	_expect(String(first.get("order_id", "")) == "order_1" and String(second.get("order_id", "")) == "order_2",
		"orders must get fresh ids in command order: %s, %s" % [first.get("order_id"), second.get("order_id")])
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "planks", "count": 5})
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "recipe": "planks", "count": 0})
	_expect((_bench(world)["targets"] as Dictionary).is_empty(), "a target set to 0 must be removed")
	_command_ok(world, "craft_cancel_order", {"x": BENCH.x, "y": BENCH.y, "order_id": "order_1"})
	var orders: Array = _bench(world)["orders"]
	_expect(orders.size() == 1 and String(orders[0]["id"]) == "order_2", "cancel must remove exactly that order: %s" % [orders])

## Cancelling the order a bill serves, and removing the bench, both end the bill's jobs and
## drop its held inputs next to the bench (nothing is lost); the removed bench's record goes.
func _check_cancel_order_and_removed_bench_drop_held_inputs() -> void:
	for removal: String in ["cancel_order", "remove_object"]:
		var world := _world(610006, 3, 1)
		var order := _command_ok(world, "craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 1})
		var holding := false
		for _i in DAY_TICKS:
			world.tick()
			var bill: Dictionary = _bench(world).get("bill", {})
			for stack in (bill.get("held", []) as Array):
				holding = holding or int(stack["quantity"]) > 0
			if holding:
				break
		_expect(holding, "%s: the axe bill must hold an input before the removal" % removal)
		if removal == "cancel_order":
			_command_ok(world, "craft_cancel_order", {"x": BENCH.x, "y": BENCH.y, "order_id": String(order["order_id"])})
		else:
			_command_ok(world, "remove_object", {"x": BENCH.x, "y": BENCH.y})
			world.tick()
		for kind: String in ["wood", "stone"]:
			_expect(_total(world, kind) == (3 if kind == "wood" else 1), "%s: no %s may be lost" % [removal, kind])
		for job in world.get_jobs([], false):
			_expect(String(job["kind"]) not in ["craft_fetch", "craft_work"], "%s: no craft job may outlive it: %s" % [removal, job])
		if removal == "remove_object":
			_expect(_bench(world).is_empty() and world.get_crafting_benches().is_empty(), "a removed bench must leave no record")
			_expect((world.to_save_state()["crafting"]["benches"] as Array).is_empty(), "the save must forget the removed bench")

## ADR 061 content checks: dangling recipe references and an item kind outside the groups.
func _check_content_registry_rejects_bad_recipes_and_groups() -> void:
	var base := ContentRegistryType.new()
	_expect(base.is_valid(), "the shipped content must load: %s" % base.get_error())
	_expect(base.list("recipes").size() == 4, "the base bundle ships four recipes")
	var dangling := ContentRegistryType.ERROR_DANGLING_REFERENCE
	var violation := ContentRegistryType.ERROR_SCHEMA_VIOLATION
	var axe_inputs := "[{\"item\": \"wood\", \"quantity\": 3}, {\"item\": \"stone\", \"quantity\": 1}]"
	var too_many := "\"item\": \"wood\", \"quantity\": %d" % (RecipeBookType.MAX_COUNT + 1)
	var cases := {
		"recipes.json": ["\"item\": \"planks\", \"quantity\": 2", "\"item\": \"plank\", \"quantity\": 2", "unknown item id 'plank'", dangling],
		"recipes.json#bench": ["\"bench\": \"workbench\", \"inputs\": [{\"item\": \"stone\", \"quantity\": 2}]", "\"bench\": \"anvil\", \"inputs\": [{\"item\": \"stone\", \"quantity\": 2}]", "bench 'anvil' names an unknown object kind", dangling],
		# Two wood entries: each delivery would be credited to both (the reviewer's 2 -> 4 refund).
		"recipes.json#duplicate": [axe_inputs, "[{\"item\": \"wood\", \"quantity\": 1}, {\"item\": \"wood\", \"quantity\": 1}]", "item 'wood' twice or over", violation],
		"recipes.json#quantity": ["\"item\": \"wood\", \"quantity\": 3", too_many, "item 'wood' twice or over", violation],
		"items.json": ["\"id\": \"coal\", \"kind\": \"material\"", "\"id\": \"coal\", \"kind\": \"fuel\"", "undeclared group", dangling],
	}
	for key: String in cases:
		var file := key.split("#")[0]
		_write_fixture(file, cases[key][0], cases[key][1])
		var registry := ContentRegistryType.new(CONTENT_FIXTURE_DIR)
		_expect(not registry.is_valid(), "%s: the edited bundle must be rejected" % key)
		var error: Dictionary = registry.get_error()
		_expect(String(error.get("code", "")) == String(cases[key][3]) and String(error.get("message", "")).contains(cases[key][2]),
			"%s: expected %s naming %s, got %s" % [key, cases[key][3], cases[key][2], error])
	_write_fixture("recipes.json", "\"item\": \"wood\", \"quantity\": 3", "\"item\": \"wood\", \"quantity\": %d" % RecipeBookType.MAX_COUNT)
	var at_cap := ContentRegistryType.new(CONTENT_FIXTURE_DIR)
	_expect(at_cap.is_valid(), "a recipe quantity of exactly MAX_COUNT must load: %s" % at_cap.get_error())

## The recipe cap is the save cap: a bill holding MAX_COUNT units of an input (what the largest
## recipe the registry accepts can hold) is written and read back through SaveIO; one more is
## refused by the save validator.
func _check_recipe_and_save_quantity_caps_agree() -> void:
	var world := _world(610009, 3, 1)
	_command_ok(world, "craft_add_order", {"x": BENCH.x, "y": BENCH.y, "recipe": "axe", "count": 1})
	for _i in DAY_TICKS:
		world.tick()
		if not (_bench(world)["bill"] as Dictionary).is_empty():
			break
	for held: int in [RecipeBookType.MAX_COUNT, RecipeBookType.MAX_COUNT + 1]:
		var state := StateCodecType.encode(world)
		var bench: Dictionary = state["crafting"]["benches"][0]
		_expect(bench["bill"] != null, "the axe bill must be open before the save")
		if bench["bill"] == null:
			return
		bench["bill"]["held"] = [{"item": "wood", "quantity": held}]
		DirAccess.remove_absolute(ProjectSettings.globalize_path(HELD_SAVE_PATH))
		var written := SaveIOType.write_atomic(HELD_SAVE_PATH, state)
		var read := SaveIOType.read(HELD_SAVE_PATH) if bool(written.get("ok", false)) else written
		if held == RecipeBookType.MAX_COUNT:
			_expect(bool(read.get("ok", false)), "a bill holding MAX_COUNT units must save and load: %s" % [read])
		else:
			_expect(not bool(read.get("ok", false)), "a bill holding more than MAX_COUNT units must be refused: %s" % [read])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(HELD_SAVE_PATH))

## Copies res://content to CONTENT_FIXTURE_DIR with one text replacement in `file`.
func _write_fixture(file: String, find: String, replace: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTENT_FIXTURE_DIR))
	var dir := DirAccess.open("res://content")
	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var text := FileAccess.get_file_as_string("res://content/" + name)
		if name == file:
			_expect(text.contains(find), "fixture edit: %s must contain %s" % [name, find])
			text = text.replace(find, replace)
		var out := FileAccess.open(CONTENT_FIXTURE_DIR + "/" + name, FileAccess.WRITE)
		out.store_string(text)
		out.close()
