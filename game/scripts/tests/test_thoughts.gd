extends SceneTree

## F5c (ADR 066): happiness from the thought table (content/thoughts.json). Every check goes
## through the real triggers: needs decaying on world.tick(), need jobs completing, harvest,
## craft and cook jobs completing, a colonist dying in combat, and the view snapshot the panel reads.
## Acceptance: meal + bed gives > 60 within 2 days; starving + ground gives < 40; thoughts
## expire on schedule; same seed, same state_hash(); save/load and replay give identical results.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const DAY_TICKS := 2200
const ID := "colonist_0"
const BENCH := Vector2i(10, 5)

var _failed := false
var _next_command := 0

func _init() -> void:
	_check_meal_and_bed_raise_happiness_above_60_within_two_days()
	_check_starving_on_the_ground_drops_happiness_below_40()
	_check_thoughts_expire_on_schedule()
	_check_same_seed_same_hash()
	_check_save_load_mid_thought_continues_identically()
	_check_recorded_session_replays()
	_check_harvest_adds_harvested()
	_check_craft_adds_crafted()
	_check_cook_adds_crafted()
	_check_colonist_death_saddens_the_survivors()
	_check_stack_limit_replaces_the_earliest()
	_check_bed_reachability_is_per_region()
	_check_repeated_meal_refreshes_one_instance()
	_check_raw_food_adds_ate_raw()
	if _failed:
		quit(1)
		return
	print("test_thoughts: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _command_ok(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	var result := Scenarios.command(world, "thought_test_%d" % _next_command, type, payload)
	_expect(bool(result.get("ok", false)), "%s %s must be accepted: %s" % [type, payload, result])
	return result

## Happiness and active thought ids as the colonist panel reads them (the view snapshot).
func _happiness(world: WorldStateType, id: String) -> int:
	return int(world.get_view_snapshot([id])["happiness"][id]["value"])

func _thought_ids(world: WorldStateType, id: String) -> Array[String]:
	var ids: Array[String] = []
	for row: Dictionary in world.get_view_snapshot([id])["happiness"][id]["thoughts"]:
		ids.append(String(row["id"]))
	return ids

## A floor world with one colonist low on food and rest (water paused), a meal on the floor
## and, when with_bed, a bed: the colonist eats the meal and sleeps in the bed. Need rates are
## world-local test edits a save or a replay does not carry, so save/load and replay checks pass
## pause_water false and keep the content rates.
func _meal_and_bed_world(seed_value: int, with_bed: bool, pause_water := true) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	if pause_water:
		TestAccess.need_definitions(world)["water"]["rate_per_day"] = 0
	var colonist := Scenarios.idle_colonist(ID, 5, 3)
	colonist["needs"] = Scenarios.full_needs({"food": 20, "rest": 20})
	TestAccess.colonists(world).append(colonist)
	Scenarios.add_stock(world, "meal", 1, 8, 3)
	if with_bed:
		TestAccess.object_table(world).set_object(Vector3i(12, 6, 0), "bed", "colony", "")
	return world

## Acceptance: "meal + bed gives > 60 within 2 days" (50 + ate_meal 10 + slept_bed 8 = 68).
func _check_meal_and_bed_raise_happiness_above_60_within_two_days() -> void:
	var world := _meal_and_bed_world(660001, true)
	_expect(_happiness(world, ID) == 50, "a colonist with no thought starts at the base 50")
	var reached := -1
	for _i in 2 * DAY_TICKS:
		world.tick()
		if _happiness(world, ID) > 60:
			reached = world.get_tick()
			break
	_expect(reached > 0, "meal + bed must give happiness > 60 within 2 days, got %d with %s"
		% [_happiness(world, ID), _thought_ids(world, ID)])
	var ids := _thought_ids(world, ID)
	_expect(ids.has("ate_meal") and ids.has("slept_bed"), "meal + bed must leave ate_meal and slept_bed: %s" % [ids])
	_expect(not ids.has("ate_raw"), "a meal is not raw food: %s" % [ids])

## Acceptance: "starving + ground gives < 40" (50 - hungry 12 - slept_ground 8 = 30).
func _check_starving_on_the_ground_drops_happiness_below_40() -> void:
	var world := Scenarios.empty_floor_world(660002)
	Scenarios.isolate_need(world, "")
	var colonist := Scenarios.idle_colonist(ID, 5, 3)
	colonist["needs"] = Scenarios.full_needs({"food": 0, "rest": 10})
	TestAccess.colonists(world).append(colonist)
	for _i in 20:
		world.tick()
	var ids := _thought_ids(world, ID)
	_expect(ids.has("hungry") and ids.has("slept_ground"), "starving with no bed must think hungry and slept_ground: %s" % [ids])
	_expect(_happiness(world, ID) < 40, "starving + ground must give happiness < 40, got %d" % _happiness(world, ID))
	_expect(_happiness(world, ID) == 30, "50 - 12 - 8 = 30, got %d" % _happiness(world, ID))
	# A bed in reach stops slept_ground being refreshed; hungry stays while food is low.
	TestAccess.object_table(world).set_object(Vector3i(12, 6, 0), "bed", "colony", "")
	TestAccess.tile_grid(world).reset_cells()
	for _i in int(0.5 * DAY_TICKS) + 5:
		world.tick()
		if not _thought_ids(world, ID).has("slept_ground"):
			break
	_expect(not _thought_ids(world, ID).has("slept_ground"), "with a bed in reach slept_ground must not be refreshed")

## Acceptance: "thoughts expire on schedule". ate_meal lasts 1.5 days = 3300 ticks from the tick
## the meal is eaten: still active 3299 ticks later, gone at 3300.
func _check_thoughts_expire_on_schedule() -> void:
	var world := _meal_and_bed_world(660003, false)
	TestAccess.need_definitions(world)["rest"]["rate_per_day"] = 0
	TestAccess.find_colonist(world, ID)["needs"]["rest"] = 100
	var ate_at := -1
	for _i in DAY_TICKS:
		world.tick()
		if _thought_ids(world, ID).has("ate_meal"):
			ate_at = world.get_tick()
			break
	_expect(ate_at > 0, "the hungry colonist must eat the meal")
	if ate_at < 0:
		return
	var until := int(TestAccess.find_colonist(world, ID)["thoughts"][0]["until"])
	var length := until - ate_at
	_expect(length == roundi(1.5 * DAY_TICKS) or length == roundi(1.5 * DAY_TICKS) - 1,
		"ate_meal must last 1.5 days from the tick it was added, got %d" % length)
	TestAccess.find_colonist(world, ID)["needs"]["food"] = 100
	TestAccess.need_definitions(world)["food"]["rate_per_day"] = 0
	while world.get_tick() < until - 1:
		world.tick()
	_expect(_thought_ids(world, ID).has("ate_meal"), "ate_meal must still be active one tick before it expires")
	_expect(_happiness(world, ID) == 60, "ate_meal alone gives 60, got %d" % _happiness(world, ID))
	world.tick()
	_expect(not _thought_ids(world, ID).has("ate_meal"), "ate_meal must be gone at its until tick")
	_expect(_happiness(world, ID) == 50, "back to the base 50 once ate_meal expired, got %d" % _happiness(world, ID))
	_expect(not TestAccess.find_colonist(world, ID).has("thoughts"), "an expired list is erased from the colonist")

## Determinism: two worlds from the same seed reach the same state_hash() at every checkpoint.
func _check_same_seed_same_hash() -> void:
	var a := _meal_and_bed_world(660004, true)
	var b := _meal_and_bed_world(660004, true)
	for step in 2 * DAY_TICKS:
		a.tick()
		b.tick()
		if step % 200 == 0 and a.state_hash() != b.state_hash():
			_fail("same seed must give the same state_hash() at tick %d" % a.get_tick())
			return
	_expect(a.state_hash() == b.state_hash(), "same seed must give the same final state_hash()")
	_expect(TestAccess.find_colonist(a, ID).has("thoughts"), "the determinism run must carry thoughts")

## Save/load mid-thought: the restored world keeps the thoughts and continues identically.
func _check_save_load_mid_thought_continues_identically() -> void:
	var world := _meal_and_bed_world(660005, true, false)
	while not TestAccess.find_colonist(world, ID).has("thoughts") and world.get_tick() < DAY_TICKS:
		world.tick()
	_expect(TestAccess.find_colonist(world, ID).has("thoughts"), "the colonist must have a thought before saving")
	var restored := WorldStateType.from_save_state(world.to_save_state())
	_expect(restored.state_hash() == world.state_hash(), "save/load must keep state_hash() with thoughts")
	_expect(_thought_ids(restored, ID) == _thought_ids(world, ID), "save/load must keep the active thoughts")
	for _i in 2 * DAY_TICKS:
		world.tick()
		restored.tick()
	_expect(restored.state_hash() == world.state_hash(), "the restored world must continue identically")
	_expect(_happiness(restored, ID) == _happiness(world, ID), "the restored world must reach the same happiness")

## Replay: a recorded session with thoughts replays to the same hashes.
func _check_recorded_session_replays() -> void:
	var world := _meal_and_bed_world(660006, true, false)
	var recorder := CommandRecorderType.new()
	recorder.start(world, 100, false)
	_command_ok(world, "set_labour", {"colonist": ID, "kind": "haul", "level": 0})
	for _i in DAY_TICKS:
		world.tick()
		recorder.observe_tick(world)
	_expect(TestAccess.find_colonist(world, ID).has("thoughts"), "the recorded session must carry thoughts")
	var replay: Dictionary = recorder.stop().replay()
	_expect(bool(replay.get("ok", false)), "the recorded session must replay identically: %s" % [replay])

## Harvest: a farm colonist that harvests a ripe crop thinks "harvested" (+2).
func _check_harvest_adds_harvested() -> void:
	var world := WorldStateType.new(660007, 10, 24, 24)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).clear()
	Scenarios.isolate_need(world, "")
	TestAccess.colonists(world).append(Scenarios.idle_colonist(ID, 1, 1))
	TestAccess.set_tile(world, 3, 3, WorldStateType.TILE_PLOWED_SOIL)
	TestAccess.tile_grid(world).reset_cells()
	Scenarios.add_stock(world, "seed", 1, 10, 10)
	_command_ok(world, "sow", {"x": 3, "y": 3, "z": 0, "priority": 1})
	var harvested := false
	for _i in 7 * DAY_TICKS:
		world.tick()
		if _thought_ids(world, ID).has("harvested"):
			harvested = true
			break
	_expect(harvested, "harvesting a ripe crop must add the harvested thought")
	if harvested:
		_expect(_happiness(world, ID) == 52, "harvested alone gives 52, got %d" % _happiness(world, ID))

## Craft: the crafter that finishes an axe thinks "crafted" (+2); the hauler does not.
func _check_craft_adds_crafted() -> void:
	var world := Scenarios.empty_floor_world(660008)
	Scenarios.isolate_need(world, "")
	TestAccess.object_table(world).set_object(Vector3i(BENCH.x, BENCH.y, 0), "workbench", "colony", "")
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 5, 3))
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_1", 6, 3))
	_command_ok(world, "set_labour", {"colonist": "colonist_1", "kind": "craft", "level": 0})
	_command_ok(world, "zone_add", {"x": 0, "y": 0, "z": 0, "width": 4, "height": 2})
	Scenarios.add_stock(world, "wood", 6, 0, 0)
	Scenarios.add_stock(world, "stone", 4, 1, 0)
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "z": 0, "recipe": "axe", "count": 1})
	var crafted := false
	for _i in 2 * DAY_TICKS:
		world.tick()
		if _thought_ids(world, "colonist_0").has("crafted"):
			crafted = true
			break
	_expect(crafted, "finishing a craft job must add the crafted thought")
	_expect(not _thought_ids(world, "colonist_1").has("crafted"), "a colonist that did not craft does not think crafted")

## Cooking counts as crafting (owner, review round 2): a finished cook_work job adds
## "crafted"; the colonist whose cook labour is off does not get it.
func _check_cook_adds_crafted() -> void:
	var world := Scenarios.empty_floor_world(660014)
	Scenarios.isolate_need(world, "")
	TestAccess.object_table(world).set_object(Vector3i(BENCH.x, BENCH.y, 0), "kitchen", "colony", "")
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 5, 3))
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_1", 6, 3))
	_command_ok(world, "set_labour", {"colonist": "colonist_1", "kind": "cook", "level": 0})
	_command_ok(world, "zone_add", {"x": 0, "y": 0, "z": 0, "width": 4, "height": 2})
	Scenarios.add_stock(world, "food", 2, 0, 0)
	_command_ok(world, "craft_set_target", {"x": BENCH.x, "y": BENCH.y, "z": 0, "recipe": "meal", "count": 1})
	var cooked := false
	for _i in 2 * DAY_TICKS:
		world.tick()
		if _thought_ids(world, "colonist_0").has("crafted"):
			cooked = true
			break
	_expect(cooked, "finishing a cook job must add the crafted thought")
	_expect(not _thought_ids(world, "colonist_1").has("crafted"), "a colonist that did not cook does not think crafted")

## Death: a colony colonist killed in combat gives every surviving colony colonist
## "colonist_died" (-15) at the next needs tick (CombatSystem records a pending death, the
## decay loop applies it); the hostile attacker does not think it. The pending death is saved.
func _check_colonist_death_saddens_the_survivors() -> void:
	var world := _combat_world(660009)
	var victim := _spawn(world, "victim", Vector3i(10, 10, 0), "colony")
	_spawn(world, "witness", Vector3i(20, 20, 0), "colony")
	var attacker := _spawn(world, "raider", Vector3i(11, 10, 0), "raiders")
	world.tick()
	victim["health"]["hp"] = 1
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	for _i in 30:
		world.tick()
		if TestAccess.find_colonist(world, "victim").is_empty():
			break
	_expect(TestAccess.find_colonist(world, "victim").is_empty(), "the victim must die in combat")
	_expect(not _thought_ids(world, "witness").has("colonist_died"), "the death is applied at the next needs tick")
	var state := world.to_save_state()
	_expect(int(state.get("pendingColonyDeaths", 0)) == 1, "the pending death must be saved: %s" % [state.get("pendingColonyDeaths")])
	var bad := state.duplicate(true)
	bad["pendingColonyDeaths"] = 0
	_expect(not bool(TestAccess.save_validate_state(bad).get("ok", true)), "pendingColonyDeaths 0 must be rejected (absent means none)")
	var restored := WorldStateType.from_save_state(state)
	_expect(restored.state_hash() == world.state_hash(), "save/load with a pending death keeps state_hash()")
	var forgotten := state.duplicate(true)
	forgotten.erase("pendingColonyDeaths")
	_expect(WorldStateType.from_save_state(forgotten).state_hash() != world.state_hash(), "state_hash() must see the pending death (it changes the next tick's thoughts)")
	Scenarios.isolate_need(restored, "")  # need rates are test-only runtime tuning, not saved
	world.tick()
	restored.tick()
	for w: WorldStateType in [world, restored]:
		_expect(_thought_ids(w, "witness").has("colonist_died"), "a surviving colonist must think colonist_died")
		_expect(_happiness(w, "witness") == 35, "colonist_died alone gives 35, got %d" % _happiness(w, "witness"))
		_expect(not TestAccess.find_colonist(w, "raider").has("thoughts"), "a raider does not mourn a colony colonist")
		_expect(not w.to_save_state().has("pendingColonyDeaths"), "the pending count is cleared once applied")
	_expect(restored.state_hash() == world.state_hash(), "the restored world applies the pending death identically")

## Stack limit: colonist_died stacks to 3; a fourth death restarts the instance that expires
## first, so the three kept instances are the three latest deaths.
func _check_stack_limit_replaces_the_earliest() -> void:
	var world := _combat_world(660013)
	var attacker := _spawn(world, "raider", Vector3i(10, 10, 0), "raiders")
	var spots := [Vector3i(9, 10, 0), Vector3i(11, 10, 0), Vector3i(10, 9, 0), Vector3i(10, 11, 0)]
	for i in spots.size():
		_spawn(world, "victim_%d" % i, spots[i], "colony")
	_spawn(world, "witness", Vector3i(40, 40, 0), "colony")
	world.tick()
	attacker["combat"]["damage"] = 999
	attacker["health"]["hp"] = 99999
	var seen: Array[int] = []
	for _i in 600:
		world.tick()
		for record: Dictionary in TestAccess.find_colonist(world, "witness").get("thoughts", []):
			if String(record["id"]) == "colonist_died" and not seen.has(int(record["until"])):
				seen.append(int(record["until"]))
		if seen.size() >= 4:
			break
	_expect(seen.size() == 4, "four deaths at different ticks give four instances over time, saw %s" % [seen])
	if seen.size() < 4:
		return
	var kept: Array[int] = []
	for record: Dictionary in TestAccess.find_colonist(world, "witness")["thoughts"]:
		if String(record["id"]) == "colonist_died":
			kept.append(int(record["until"]))
	seen.sort()
	_expect(kept == seen.slice(1), "the earliest-expiring instance is the one replaced: kept %s of %s" % [kept, seen])
	_expect(_happiness(world, "witness") == 5, "three colonist_died give 50 - 45 = 5, got %d" % _happiness(world, "witness"))

## Beds are per region: with a rock wall splitting the map, only the tired colonist cut off
## from the bed thinks slept_ground.
func _check_bed_reachability_is_per_region() -> void:
	var world := Scenarios.empty_floor_world(660010)
	Scenarios.isolate_need(world, "")
	for y in TestAccess.tile_grid(world).height:
		TestAccess.set_tile(world, 15, y, WorldStateType.TILE_ROCK)
	TestAccess.object_table(world).set_object(Vector3i(5, 8, 0), "bed", "colony", "")
	TestAccess.tile_grid(world).reset_cells()
	for spec: Array in [["near", 3], ["cut_off", 20]]:
		var colonist := Scenarios.idle_colonist(String(spec[0]), int(spec[1]), 3)
		colonist["needs"] = Scenarios.full_needs({"rest": 10})
		TestAccess.colonists(world).append(colonist)
	for _i in 5:
		world.tick()
	_expect(_thought_ids(world, "cut_off").has("slept_ground"), "a tired colonist with no bed in its region thinks slept_ground")
	_expect(not _thought_ids(world, "near").has("slept_ground"), "a tired colonist with a bed in its region does not")

## Two meals: ate_meal is "refresh", so the second meal restarts its one instance.
func _check_repeated_meal_refreshes_one_instance() -> void:
	var world := _meal_and_bed_world(660011, false)
	TestAccess.need_definitions(world)["rest"]["rate_per_day"] = 0
	TestAccess.find_colonist(world, ID)["needs"]["rest"] = 100
	Scenarios.add_stock(world, "meal", 1, 9, 3)
	var first := _wait_for_until(world, "ate_meal", -1)
	_expect(first > 0, "the hungry colonist must eat the first meal")
	TestAccess.find_colonist(world, ID)["needs"]["food"] = 20
	var second := _wait_for_until(world, "ate_meal", first)
	_expect(second > first, "the second meal restarts ate_meal later: %d then %d" % [first, second])
	var count := 0
	for record: Dictionary in TestAccess.find_colonist(world, ID)["thoughts"]:
		count += 1 if String(record["id"]) == "ate_meal" else 0
	_expect(count == 1, "a refreshed thought keeps one instance, got %d" % count)

## Raw food: eating the "food" item (not in meal_items) gives ate_raw, which weighs 0.
func _check_raw_food_adds_ate_raw() -> void:
	var world := Scenarios.empty_floor_world(660012)
	Scenarios.isolate_need(world, "food")
	TestAccess.need_definitions(world)["food"]["rate_per_day"] = 0
	var colonist := Scenarios.idle_colonist(ID, 5, 3)
	colonist["needs"] = Scenarios.full_needs({"food": 20})
	TestAccess.colonists(world).append(colonist)
	Scenarios.add_stock(world, "food", 1, 8, 3)
	_expect(_wait_for_until(world, "ate_raw", -1) > 0, "eating raw food must add ate_raw")
	_expect(not _thought_ids(world, ID).has("ate_meal"), "raw food is not a meal")
	# hungry (0.1 day) was refreshed until the colonist ate; once it lapses only ate_raw is left.
	for _i in int(0.1 * DAY_TICKS) + 2:
		world.tick()
	_expect(_thought_ids(world, ID).size() == 1 and _thought_ids(world, ID).has("ate_raw"), "only ate_raw is left: %s" % [_thought_ids(world, ID)])
	_expect(_happiness(world, ID) == 50, "ate_raw weighs 0, got %d" % _happiness(world, ID))

## Ticks until id's instance has an until later than after; returns it, or -1 within a day.
func _wait_for_until(world: WorldStateType, id: String, after: int) -> int:
	for _i in DAY_TICKS:
		world.tick()
		for record: Dictionary in TestAccess.find_colonist(world, ID).get("thoughts", []):
			if String(record["id"]) == id and int(record["until"]) > after:
				return int(record["until"])
	return -1

func _combat_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).clear()
	Scenarios.isolate_need(world, "")
	return world

func _spawn(world: WorldStateType, id: String, at: Vector3i, faction: String) -> Dictionary:
	var actor: Dictionary = ActorTableType.spawn("colonist", at, TestAccess.content(world), id)
	actor.erase("carrying")
	actor["hands"] = []
	actor["factionId"] = faction
	TestAccess.append_colonist(world, actor)
	return actor
