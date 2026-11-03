extends SceneTree

## F6a (ADR 067): a forest zone makes colonists with the farm labour plant saplings
## (plant_sapling, no seed) on its empty soil; a sapling grows through three stage tiles over
## grow_days into a tree; felling stays the manual chop, whose soil the zone replants.
## Everything is driven through apply()/tick(): zone_add commands and the clock.
## Acceptance checks: 3x3 soil + 1 farmer -> 9 saplings within 2 days, trees after ~8 days (a
## ripe sapling waits while a colonist stands on it), a chopped tree replanted within a day and
## regrown into a tree with its wood still on the tile;
## save/load mid-growth keeps state_hash() and ticks in step; an A11 replay reproduces the
## run; the same seed gives the same hash.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")

const SEED := 670_001
const MAP_SIZE := 16
const FOREST := Rect2i(4, 4, 3, 3)
const STAGES := ["sapling_1", "sapling_2", "sapling_3"]
const TREE := "tree"
const GROW_DAYS := 8
const SAVE_PATH := "user://test-forest-zone-mid-growth.json"

var _failed := false
var _day_ticks := 0

func _init() -> void:
	_check_zone_add_forest_rules()
	_check_plant_grow_replant_and_replay()
	_check_mid_growth_save_matches_uninterrupted_world()
	_check_same_seed_same_hash()
	if _failed:
		quit(1)
		return
	print("test_forest_zone: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _labours() -> Dictionary:
	return {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}

## An all-floor world with `count` colonists along x = 1 and the FOREST rectangle as soil.
func _world(seed_value: int, count: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, MAP_SIZE, MAP_SIZE)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).clear()
	for i in count:
		TestAccess.colonists(world).append({"id": "colonist_%d" % i, "kind": "colonist", "x": 1, "y": 1 + i, "z": 0,
			"route": null, "work": null, "labourTable": _labours()})
	for y in range(FOREST.position.y, FOREST.end.y):
		for x in range(FOREST.position.x, FOREST.end.x):
			TestAccess.set_tile(world, x, y, WorldStateType.TILE_SOIL)
	_day_ticks = TestAccess.calendar(world).day_length_ticks()
	return world

func _zone(world: WorldStateType, id: String, rect: Rect2i, extra: Dictionary = {}) -> Dictionary:
	var payload := {"x": rect.position.x, "y": rect.position.y, "z": 0, "width": rect.size.x, "height": rect.size.y}
	payload.merge(extra)
	return Scenarios.command(world, id, "zone_add", payload)

## FOREST tiles whose kind is in kinds.
func _count(world: WorldStateType, kinds: Array) -> int:
	var total := 0
	for y in range(FOREST.position.y, FOREST.end.y):
		for x in range(FOREST.position.x, FOREST.end.x):
			if world.get_tile(x, y) in kinds:
				total += 1
	return total

## A wood item lies on the surface tile at cell.
func _wood_at(world: WorldStateType, cell: Vector2i) -> bool:
	for item in world.get_items():
		var tile := TileGrid.tile_of(item)
		if String(item.get("kind", "")) == "wood" and tile.x == cell.x and tile.y == cell.y:
			return true
	return false

func _tick_until(world: WorldStateType, limit_tick: int, done: Callable, log: ReplayLogType = null) -> bool:
	while world.get_tick() < limit_tick:
		world.tick()
		if log != null:
			log.observe_tick(world)
		if done.call():
			return true
	return false

func _check_zone_add_forest_rules() -> void:
	var world := _world(SEED + 1, 1)
	var with_crop := _zone(world, "forest_crop", FOREST, {"kind": "forest", "crop": "carrot"})
	_expect(not with_crop.get("ok", true), "a forest zone naming a crop must be rejected: %s" % with_crop)
	var unknown_kind := _zone(world, "grove", FOREST, {"kind": "grove"})
	_expect(not unknown_kind.get("ok", true), "an unknown zone kind must be rejected: %s" % unknown_kind)
	var forest := _zone(world, "forest", FOREST, {"kind": "forest"})
	_expect(forest.get("ok", false), "a forest zone must be accepted: %s" % forest)
	var zone := world.get_zone(String(forest.get("zone_id", "")))
	_expect(zone.get("kind") == "forest" and not zone.has("crop"), "the forest zone records its kind and no crop: %s" % zone)
	var overlap := _zone(world, "overlap", Rect2i(5, 5, 2, 2))
	_expect(not overlap.get("ok", true), "a stockpile overlapping a forest zone must be rejected: %s" % overlap)

## Acceptance, one run recorded for an A11 replay: 3x3 soil + 1 farmer plants 9 saplings within
## 2 days; by day 8 + 2 every tile is a tree except the one the idle farmer stands on (a ripe
## sapling waits for its tile to be free: the tree is impassable); a chop order (felling is
## manual) sends the farmer for the axe, so that tree grows, and the felled corner's soil is
## replanted within a day of the chop; once a second chop draws the farmer away, that sapling
## grows back into a tree with the chop's wood still lying on its tile (a ground item does not
## hold growth back, only an actor does).
func _check_plant_grow_replant_and_replay() -> void:
	var world := _world(SEED, 1)
	world.spawn_ground_tool_item("axe", 1, 1)
	var log := ReplayLogType.begin(world, 100, false)
	world.command_observer = func(command: Variant, result: Dictionary) -> void:
		log.record_command(world.get_tick(), command, result.get("ok", false))
	_expect(_zone(world, "forest", FOREST, {"kind": "forest"}).get("ok", false), "the forest zone must be accepted")
	var tiles := FOREST.size.x * FOREST.size.y
	var planted := _tick_until(world, 2 * _day_ticks, func() -> bool: return _count(world, STAGES + [TREE]) == tiles, log)
	print("test_forest_zone: planted %d/%d by tick %d" % [_count(world, STAGES), tiles, world.get_tick()])
	_expect(planted, "one farmer must plant all %d forest tiles within 2 days, got %d" % [tiles, _count(world, STAGES)])
	_expect(world.get_jobs(["sow"]).is_empty() and world.get_jobs(["till"]).is_empty(), "a forest zone neither tills nor sows")
	_expect(_count(world, [TREE]) == 0, "no forest tile may be a tree while planting (day %.2f)" % (float(world.get_tick()) / _day_ticks))
	var saw_stages: Dictionary = {}
	var first_tree := {"tick": -1}
	var grown := _tick_until(world, (GROW_DAYS + 2) * _day_ticks, func() -> bool:
		saw_stages[world.get_tile(FOREST.position.x, FOREST.position.y)] = true
		if first_tree["tick"] < 0 and _count(world, [TREE]) > 0:
			first_tree["tick"] = world.get_tick()
		return _count(world, [TREE]) == tiles - 1, log)
	print("test_forest_zone: %d/%d trees by tick %d (day %.2f)" % [_count(world, [TREE]), tiles, world.get_tick(), float(world.get_tick()) / _day_ticks])
	_expect(grown, "every forest tile but the farmer's must be a tree by day %d, got %d" % [GROW_DAYS + 2, _count(world, [TREE])])
	print("test_forest_zone: first tree at tick %d (day %.2f)" % [first_tree["tick"], float(first_tree["tick"]) / _day_ticks])
	_expect(first_tree["tick"] >= GROW_DAYS * _day_ticks, "no sapling may become a tree before %d days, the first did at tick %d" % [GROW_DAYS, first_tree["tick"]])
	for stage in STAGES:
		_expect(saw_stages.has(stage), "a forest tile must show stage %s on the way (saw %s)" % [stage, saw_stages.keys()])
	_tick_until(world, world.get_tick() + 50, func() -> bool: return false, log)
	var farmer := TileGrid.tile_of(world.get_colonists()[0])
	_expect(FOREST.has_point(Vector2i(farmer.x, farmer.y)) and world.get_tile(farmer.x, farmer.y) == STAGES[-1],
		"a ripe sapling under the idle farmer must wait, farmer at %s on %s" % [farmer, world.get_tile(farmer.x, farmer.y)])
	var felled := FOREST.position
	var chop := Scenarios.command(world, "chop_corner", "chop", {"x": felled.x, "y": felled.y, "z": 0, "priority": 1})
	_expect(chop.get("ok", false), "the chop order must be accepted: %s" % chop)
	var chopped := _tick_until(world, world.get_tick() + _day_ticks, func() -> bool: return world.get_tile(felled.x, felled.y) == WorldStateType.TILE_SOIL, log)
	_expect(chopped, "the chop order must fell the corner tree within a day, tile is %s" % world.get_tile(felled.x, felled.y))
	_expect(world.get_tile(farmer.x, farmer.y) == TREE, "the waiting sapling must grow once the farmer has left, got %s" % world.get_tile(farmer.x, farmer.y))
	var replanted := _tick_until(world, world.get_tick() + _day_ticks, func() -> bool: return world.get_tile(felled.x, felled.y) in STAGES, log)
	_expect(replanted, "a chopped forest tile must be replanted within a day, tile is %s" % world.get_tile(felled.x, felled.y))
	_expect(_wood_at(world, felled), "the felled tree's wood must lie on the replanted tile (no stockpile to haul it to)")
	# The farmer idles on the corner it just replanted; a second chop across the zone draws it off,
	# so only the wood is left on the corner while its sapling grows.
	var far := FOREST.end - Vector2i.ONE
	var chop_far := Scenarios.command(world, "chop_far", "chop", {"x": far.x, "y": far.y, "z": 0, "priority": 1})
	_expect(chop_far.get("ok", false), "the second chop order must be accepted: %s" % chop_far)
	var regrown := _tick_until(world, world.get_tick() + (GROW_DAYS + 1) * _day_ticks, func() -> bool: return world.get_tile(felled.x, felled.y) == TREE, log)
	print("test_forest_zone: felled corner regrown=%s by tick %d, wood on it=%s, farmer %s" % [regrown, world.get_tick(), _wood_at(world, felled), TileGrid.tile_of(world.get_colonists()[0])])
	_expect(regrown, "the replanted sapling must grow back into a tree with the wood on its tile, tile is %s" % world.get_tile(felled.x, felled.y))
	_expect(_wood_at(world, felled), "the wood must still lie on the regrown tile (the cycle ran with it there)")
	log.finish(world)
	world.command_observer = Callable()
	var replayed := log.replay()
	_expect(replayed.get("ok", false), "the A11 replay of the forest run must reproduce every checkpoint and the final hash: %s" % replayed)

## Acceptance: save/load mid-growth continues with an identical state_hash(). Saved at day 4
## (every sapling between planted and grown) through A7's pipeline, read back and decoded, then
## ticked alongside the uninterrupted world to day 11, compared every 100 ticks and at the end.
func _check_mid_growth_save_matches_uninterrupted_world() -> void:
	var world := _world(SEED, 1)
	Scenarios.isolate_need(world, "")
	_expect(_zone(world, "forest", FOREST, {"kind": "forest"}).get("ok", false), "the forest zone must be accepted")
	while world.get_tick() < 4 * _day_ticks:
		world.tick()
	_expect(_count(world, STAGES) == FOREST.size.x * FOREST.size.y, "the save must be taken mid-growth")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	var written := SaveIOType.begin_write(SAVE_PATH, world.to_save_state()).wait()
	_expect(written.get("ok", false), "the mid-growth save must write: %s" % written)
	var read := SaveIOType.read(SAVE_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(read.get("ok", false), "the mid-growth save must read: %s" % read)
	if not read.get("ok", false):
		return
	var saplings: Array = read["state"].get("saplings", [])
	_expect(saplings.size() == FOREST.size.x * FOREST.size.y, "the save must record every sapling's growth: %d" % saplings.size())
	var loaded := StateCodecType.decode(read["state"])
	_expect(loaded.state_hash() == world.state_hash(), "a mid-growth save must load with the same state_hash()")
	Scenarios.isolate_need(loaded, "")
	while world.get_tick() < (GROW_DAYS + 3) * _day_ticks:
		world.tick()
		loaded.tick()
		if world.get_tick() % 100 == 0 and loaded.state_hash() != world.state_hash():
			_fail("the loaded mid-growth save must tick in step with the uninterrupted world (diverged by tick %d)" % world.get_tick())
			return
	_expect(loaded.state_hash() == world.state_hash(), "the loaded world must end with the uninterrupted world's state_hash()")
	_expect(_count(world, [TREE]) >= FOREST.size.x * FOREST.size.y - 1, "the compared run must grow every tree the farmer is not standing on")

func _check_same_seed_same_hash() -> void:
	var hashes: Array[int] = []
	for _run in 2:
		var world := _world(SEED + 2, 2)
		_zone(world, "forest", FOREST, {"kind": "forest"})
		while world.get_tick() < 3 * _day_ticks:
			world.tick()
		hashes.append(world.state_hash())
	_expect(hashes[0] == hashes[1], "the same seed and commands must give the same state_hash(): %s" % [hashes])
