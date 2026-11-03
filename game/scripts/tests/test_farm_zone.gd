extends SceneTree

## F1 (ADR 059): crops grow through their stage tiles inside the sowing window, ripe crops
## get a harvest job (2 food + 1 seed on the tile, hauled like any item), and a farm zone
## makes colonists till, sow and harvest its tiles with no per-tile orders. Everything is
## driven through apply()/tick(): zone_add commands, per-tile sow orders, and the clock.
## Acceptance checks: the 4x4 / 6-colonist / 6-day scenario; no growth outside the window
## and withering one day after it; save/load mid-growth keeps state_hash() and keeps
## ticking in step; an A11 replay of the scenario reproduces it; zone_add's farm rules.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")

const SEED := 560_001
const MAP_SIZE := 24
const FARM := Rect2i(4, 4, 4, 4)
const STOCKPILE := Rect2i(12, 4, 8, 8)
const START_SEEDS := 16
const COLONISTS := 6
const CROP := "carrot"
const SAVE_PATH := "user://test-farm-zone-mid-growth.json"

var _failed := false
var _day_ticks := 0

func _init() -> void:
	_check_zone_add_farm_rules()
	_check_scenario_save_load_and_replay()
	_check_mid_growth_save_matches_uninterrupted_world()
	_check_no_growth_outside_window_and_wither()
	_check_ripe_crop_waits_and_outside_zone_harvest_job()
	_check_contract_enums_list_every_base_tile_and_job()
	if _failed:
		quit(1)
		return
	print("test_farm_zone: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _labours() -> Dictionary:
	return {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}

## An all-floor world with `count` colonists along x = 1, created without a "needs" key: the
## actor table gives them full needs that decay as content says, and with no food, water or bed
## on the map they go hungry by day 2 (their need searches find nothing; the farm work goes on).
func _world(seed_value: int, count: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, MAP_SIZE, MAP_SIZE)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).clear()
	for i in count:
		TestAccess.colonists(world).append({"id": "colonist_%d" % i, "kind": "colonist", "x": 1, "y": 1 + i, "z": 0,
			"route": null, "work": null, "labourTable": _labours()})
	_day_ticks = TestAccess.calendar(world).day_length_ticks()
	return world

func _zone(world: WorldStateType, id: String, rect: Rect2i, extra: Dictionary = {}) -> Dictionary:
	var payload := {"x": rect.position.x, "y": rect.position.y, "z": 0, "width": rect.size.x, "height": rect.size.y}
	payload.merge(extra)
	return Scenarios.command(world, id, "zone_add", payload)

## Units of `kind` on the ground inside `rect`.
func _units_in(world: WorldStateType, kind: String, rect: Rect2i) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind and rect.has_point(Vector2i(int(item["x"]), int(item["y"]))):
			total += int(item["count"])
	return total

## Sown tiles still holding their seed (one crop record per tile).
func _crops_in_ground(world: WorldStateType) -> int:
	var total := 0
	for y in MAP_SIZE:
		for x in MAP_SIZE:
			if not world.get_crop_at(x, y).is_empty():
				total += 1
	return total

func _check_zone_add_farm_rules() -> void:
	var world := _world(SEED + 1, 1)
	var unknown := _zone(world, "farm_unknown", FARM, {"kind": "farm", "crop": "no_such_crop"})
	_expect(not unknown.get("ok", true) and unknown["rejection"]["params"].get("detail") == "unknown_crop",
		"a farm zone naming an unknown crop must be rejected unknown_crop: %s" % unknown)
	var no_crop := _zone(world, "farm_no_crop", FARM, {"kind": "farm"})
	_expect(not no_crop.get("ok", true), "a farm zone without a crop must be rejected: %s" % no_crop)
	var stock_crop := _zone(world, "stock_crop", FARM, {"crop": CROP})
	_expect(not stock_crop.get("ok", true), "a stockpile naming a crop must be rejected: %s" % stock_crop)
	var farm := _zone(world, "farm", FARM, {"kind": "farm", "crop": CROP})
	_expect(farm.get("ok", false), "a farm zone with a known crop must be accepted: %s" % farm)
	var zone := world.get_zone(String(farm.get("zone_id", "")))
	_expect(zone.get("kind") == "farm" and zone.get("crop") == CROP, "the farm zone records its kind and crop: %s" % zone)
	var overlap := _zone(world, "overlap", Rect2i(5, 5, 2, 2))
	_expect(not overlap.get("ok", true), "a stockpile overlapping a farm zone must be rejected: %s" % overlap)
	# A farm zone stores nothing: an item on a farm tile is hauled to the stockpile.
	_expect(_zone(world, "stock", STOCKPILE).get("ok", false), "the stockpile zone must be accepted")
	Scenarios.add_stock(world, "wood", 1, 5, 5)
	var hauled := false
	for _i in 600:
		world.tick()
		if _units_in(world, "wood", STOCKPILE) == 1:
			hauled = true
			break
	_expect(hauled, "an item lying on a farm zone tile must be hauled to the stockpile")

## Acceptance: a 4x4 farm zone, START_SEEDS seeds in a stockpile and 6 idle colonists inside
## the window: within 6 days every tile is harvested at least once, the stockpile holds
## >= 2 food per tile, and the seeds are back (stockpiled + still in the ground >= start: the
## owner-approved revision of "stockpile seeds >= start", BACKLOG F1, 2026-10-30, since the zone
## resows every harvested seed while the window is open).
## The A11 replay of the whole run reproduces every checkpoint and the final hash (the mid-growth
## save is _check_mid_growth_save_matches_uninterrupted_world()).
func _check_scenario_save_load_and_replay() -> void:
	var world := _world(SEED, COLONISTS)
	for y in range(FARM.position.y, FARM.end.y):
		for x in range(FARM.position.x, FARM.end.x):
			TestAccess.set_tile(world, x, y, WorldStateType.TILE_SOIL)
	Scenarios.add_stock(world, "seed", START_SEEDS, STOCKPILE.position.x, STOCKPILE.position.y)
	# The bootstrap writes above are the replay's start state; the zones are recorded commands.
	var log := ReplayLogType.begin(world, 100, false)
	world.command_observer = func(command: Variant, result: Dictionary) -> void:
		log.record_command(world.get_tick(), command, result.get("ok", false))
	_expect(_zone(world, "stock", STOCKPILE).get("ok", false), "the stockpile zone must be accepted")
	_expect(_zone(world, "farm", FARM, {"kind": "farm", "crop": CROP}).get("ok", false), "the farm zone must be accepted")
	var harvested: Dictionary = {}
	var saw_stages: Dictionary = {}
	for tick in 6 * _day_ticks:
		world.tick()
		log.observe_tick(world)
		saw_stages[world.get_tile(FARM.position.x, FARM.position.y)] = true
		if tick % 50 == 0:
			for job in world.get_jobs(["harvest"]):
				if String(job["status"]) == "completed":
					harvested[job["target"]] = true
	for job in world.get_jobs(["harvest"]):
		if String(job["status"]) == "completed":
			harvested[job["target"]] = true
	log.finish(world)
	world.command_observer = Callable()
	for stage in ["planted", "crop_grown", "crop_ripe"]:
		_expect(saw_stages.has(stage), "a farm tile must show stage %s on the way (saw %s)" % [stage, saw_stages.keys()])
	var tiles := FARM.size.x * FARM.size.y
	var food := _units_in(world, "food", STOCKPILE)
	var seeds := _units_in(world, "seed", STOCKPILE)
	print("test_farm_zone: scenario day 6: harvested %d/%d tiles, stockpile food %d, stockpile seeds %d, seeds in the ground %d" %
		[harvested.size(), tiles, food, seeds, _crops_in_ground(world)])
	_expect(harvested.size() == tiles, "every farm tile must be harvested at least once within 6 days, got %d of %d" % [harvested.size(), tiles])
	_expect(food >= 2 * tiles, "the stockpile must hold >= %d food after 6 days, got %d" % [2 * tiles, food])
	_expect(seeds + _crops_in_ground(world) >= START_SEEDS,
		"seeds stockpiled + still sown must be >= the %d started with, got %d + %d" % [START_SEEDS, seeds, _crops_in_ground(world)])
	var replayed := log.replay()
	_expect(replayed.get("ok", false) and int(replayed.get("checkpoints", 0)) == 6 * _day_ticks / 100 + 1,
		"the A11 replay of the farm scenario must reproduce every checkpoint and the final hash: %s" % replayed)

## Acceptance: save/load mid-growth continues with an identical state_hash(). The same farm run
## is saved at day 2.5 (growth > 0 and < ripe) through A7's pipeline, read back and decoded; the
## loaded world is then ticked alongside the uninterrupted original to the end of day 6
## (through every harvest and resow), compared every 100 ticks and at the end.
## Needs decay is zeroed in both worlds (content rules, applied equally; not save state): with
## starving colonists and no need source, a load diverges because NeedGiver's no-source backoff
## and searches are not saved (a pre-F1 gap, reported in docs/orca/handoffs/F1.md).
func _check_mid_growth_save_matches_uninterrupted_world() -> void:
	var world := _world(SEED, COLONISTS)
	Scenarios.isolate_need(world, "")
	for y in range(FARM.position.y, FARM.end.y):
		for x in range(FARM.position.x, FARM.end.x):
			TestAccess.set_tile(world, x, y, WorldStateType.TILE_SOIL)
	Scenarios.add_stock(world, "seed", START_SEEDS, STOCKPILE.position.x, STOCKPILE.position.y)
	_expect(_zone(world, "stock", STOCKPILE).get("ok", false), "the stockpile zone must be accepted")
	_expect(_zone(world, "farm", FARM, {"kind": "farm", "crop": CROP}).get("ok", false), "the farm zone must be accepted")
	for _i in _day_ticks * 5 / 2:
		world.tick()
	var loaded := _save_and_load_mid_growth(world)
	if loaded == null:
		return
	Scenarios.isolate_need(loaded, "")
	while world.get_tick() < 6 * _day_ticks:
		world.tick()
		loaded.tick()
		if world.get_tick() % 100 == 0 and loaded.state_hash() != world.state_hash():
			_fail("the loaded mid-growth save must tick in step with the uninterrupted world (diverged by tick %d)" % world.get_tick())
			return
	_expect(loaded.state_hash() == world.state_hash(), "the loaded world must end day 6 with the uninterrupted world's state_hash()")
	_expect(not Scenarios.jobs_of_kind(world, "harvest").is_empty() and _units_in(world, "food", STOCKPILE) > 0,
		"the compared run must go through harvests (food in the stockpile)")

## Saves world mid-growth through A7's pipeline, reads it back and decodes it. null on a failure.
func _save_and_load_mid_growth(world: WorldStateType) -> WorldStateType:
	var growing := world.get_crop_at(FARM.position.x, FARM.position.y)
	_expect(not growing.is_empty() and int(growing["growth"]) > 0 and int(growing["growth"]) < int(growing["ripe_growth"]),
		"the save must be taken mid-growth: %s" % growing)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	# A7's off-thread write: one pack + stringify here, the file work on the worker.
	var written := SaveIOType.begin_write(SAVE_PATH, world.to_save_state()).wait()
	_expect(written.get("ok", false), "the mid-growth save must write: %s" % written)
	var raw_crops: Array = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))["state"]["crops"]
	_expect(raw_crops.size() == FARM.size.x * FARM.size.y + 1 and (raw_crops[0] as Dictionary).has("$keys")
		and raw_crops[1] is Array, "the file must hold crops as a SaveWire record table: %s" % [raw_crops.slice(0, 2)])
	var read := SaveIOType.read(SAVE_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(read.get("ok", false), "the mid-growth save must read: %s" % read)
	if not read.get("ok", false):
		return null
	_expect((read["state"]["crops"] as Array).size() == FARM.size.x * FARM.size.y, "the save must record every sown tile's growth")
	var loaded := StateCodecType.decode(read["state"])
	_expect(loaded.state_hash() == world.state_hash(), "a mid-growth save must load with the same state_hash()")
	_expect(loaded.get_zone("zone_2") == world.get_zone("zone_2"), "the farm zone must survive the save")
	return loaded

## Sown late in the window (day 18), a crop cannot ripen by day 20: on day 21 it no longer
## grows, and at the start of day 22 (window end + 1 day) it withers back to plowed soil. A
## farm zone does not sow outside the window, but still tills.
func _check_no_growth_outside_window_and_wither() -> void:
	var world := _world(SEED + 2, 1)
	TestAccess.set_tile(world, 3, 3, WorldStateType.TILE_PLOWED_SOIL)
	Scenarios.add_stock(world, "seed", 4, 10, 10)
	TestAccess.clock(world).tick = 17 * _day_ticks
	_expect(Scenarios.command(world, "sow_late", "sow", {"x": 3, "y": 3, "z": 0, "priority": 1}).get("ok", false), "the day-18 sow order must be accepted")
	while world.get_tick() < 20 * _day_ticks:
		world.tick()
	var at_close := world.get_crop_at(3, 3)
	_expect(not at_close.is_empty() and int(at_close["growth"]) < int(at_close["ripe_growth"]),
		"a crop sown on day 18 must still be unripe when the window closes: %s" % at_close)
	var tile_at_close := world.get_tile(3, 3)
	_expect(_zone(world, "late_farm", Rect2i(6, 6, 2, 1), {"kind": "farm", "crop": CROP}).get("ok", false), "a farm zone must be accepted on day 21")
	TestAccess.set_tile(world, 6, 6, WorldStateType.TILE_PLOWED_SOIL)
	TestAccess.set_tile(world, 7, 6, WorldStateType.TILE_SOIL)
	while world.get_tick() < 21 * _day_ticks - 1:
		world.tick()
	var day_21_end := world.get_crop_at(3, 3)
	_expect(day_21_end.get("growth") == at_close.get("growth") and world.get_tile(3, 3) == tile_at_close,
		"outside the window a crop must not grow: %s -> %s" % [at_close, day_21_end])
	_expect(world.get_tile(6, 6) == WorldStateType.TILE_PLOWED_SOIL and world.get_jobs(["sow"]).filter(
		func(job: Dictionary) -> bool: return job["target"] == Vector3i(6, 6, 0)).is_empty(),
		"a farm zone must not sow outside the window")
	_expect(world.get_tile(7, 6) == WorldStateType.TILE_PLOWED_SOIL, "a farm zone still tills outside the window")
	world.tick()
	_expect(world.get_tick() == 21 * _day_ticks and world.get_tile(3, 3) == WorldStateType.TILE_PLOWED_SOIL and world.get_crop_at(3, 3).is_empty(),
		"an unripe crop must wither to plowed soil at the start of day 22 (tick %d), got %s" % [world.get_tick(), world.get_tile(3, 3)])

## A ripe crop never withers: it waits for its harvest. A ripe tile sown by a per-tile order
## (no farm zone) gets a harvest job too.
func _check_ripe_crop_waits_and_outside_zone_harvest_job() -> void:
	var world := _world(SEED + 3, 1)
	TestAccess.set_tile(world, 3, 3, WorldStateType.TILE_PLOWED_SOIL)
	Scenarios.add_stock(world, "seed", 1, 10, 10)
	_expect(Scenarios.command(world, "sow", "sow", {"x": 3, "y": 3, "z": 0, "priority": 1}).get("ok", false), "the sow order must be accepted")
	for _i in 200:
		world.tick()
	_expect(world.apply({"actor": "player", "command_id": "farm_off", "tick": world.get_tick(), "type": "set_labour",
		"payload": {"colonist": "colonist_0", "kind": "farm", "level": 0}}).get("ok", false), "farm labour must switch off")
	while world.get_tick() < 5 * _day_ticks:
		world.tick()
	_expect(world.get_tile(3, 3) == "crop_ripe", "the crop must be ripe after 4 in-window days, got %s" % world.get_tile(3, 3))
	var harvests := world.get_jobs(["harvest"]).filter(func(job: Dictionary) -> bool:
		return job["target"] == Vector3i(3, 3, 0) and job["status"] == "queued")
	_expect(harvests.size() == 1, "a ripe tile outside any farm zone must get exactly one harvest job, got %s" % [harvests])
	TestAccess.clock(world).tick = 23 * _day_ticks
	for _i in 10:
		world.tick()
	_expect(world.get_tile(3, 3) == "crop_ripe", "a ripe crop must not wither after the window, got %s" % world.get_tile(3, 3))
	_expect(world.apply({"actor": "player", "command_id": "farm_on", "tick": world.get_tick(), "type": "set_labour",
		"payload": {"colonist": "colonist_0", "kind": "farm", "level": 3}}).get("ok", false), "farm labour must switch on")
	for _i in 400:
		world.tick()
	_expect(world.get_tile(3, 3) == WorldStateType.TILE_PLOWED_SOIL, "the harvest must return the tile to plowed soil")
	var on_tile := world.get_items().filter(func(item: Dictionary) -> bool: return int(item["x"]) == 3 and int(item["y"]) == 3)
	var food := 0
	var seeds := 0
	for item in on_tile:
		food += int(item["count"]) if item["kind"] == "food" else 0
		seeds += int(item["count"]) if item["kind"] == "seed" else 0
	_expect(food == 2 and seeds == 1, "a harvest must leave 2 food and 1 seed on the tile (no stockpile here), got %s" % [on_tile])

## The save contract (docs/architecture/contracts/game-state.schema.json, outside the Godot
## project: read through the repo checkout) enumerates the base bundle's tile ids and job kinds:
## both enums must list every tiles.json and jobs.json id (the job enum also keeps "craft", a
## recipe job kind), so a farm save (crop_grown / crop_ripe tiles, harvest jobs) validates. The full JSON Schema validation of
## populated farm saves is docs/orca/handoffs/F1-schema-saves.gd + B1-schema-check.py.
func _check_contract_enums_list_every_base_tile_and_job() -> void:
	var contract_path := ProjectSettings.globalize_path("res://").path_join("../docs/architecture/contracts/game-state.schema.json")
	_expect(FileAccess.file_exists(contract_path), "the save contract must be readable at %s" % contract_path)
	if not FileAccess.file_exists(contract_path):
		return
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(contract_path))
	var properties: Dictionary = contract["properties"]
	var tile_enum: Array = properties["map"]["properties"]["tiles"]["items"]["enum"]
	var job_enum: Array = properties["jobs"]["items"]["properties"]["kind"]["enum"]
	var content := ContentRegistry.new()
	var tile_ids: Array = content.list("tiles").map(func(tile: Dictionary) -> String: return tile["id"])
	var job_kinds: Array = content.list("jobs").map(func(job: Dictionary) -> String: return job["kind"])
	for pair: Array in [[tile_enum, tile_ids, "map.tiles"], [job_enum, job_kinds, "jobs[].kind"]]:
		var listed: Array = pair[0]
		for id: String in (pair[1] as Array):
			_expect(listed.has(id), "the contract's %s enum must list the base id '%s'" % [pair[2], id])
	_expect(tile_enum.has("crop_grown") and tile_enum.has("crop_ripe") and job_enum.has("harvest"),
		"the contract must accept F1's stage tiles and harvest jobs")
