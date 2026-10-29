extends SceneTree

## F1 (ADR 059): the crop chosen for a farm zone is what the work does. A content pack adds two
## test crops, each with its own seed, stage tiles and sow/harvest jobs (crops.json sow_job /
## harvest_job, whose jobs.json effects consume that seed, set its first stage and yield its
## produce). Two farm zones, one per crop, are painted with zone_add commands and the world is
## only ticked: each zone is sown with its own seed, goes through its own stages only, and is
## harvested by its own job into its own produce; the base carrot's jobs never run. A pack whose
## crop names a sow job that does not sow it is rejected on load.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const BASE := ContentRegistryType.DEFAULT_CONTENT_DIR
const SCHEMAS := ContentRegistryType.DEFAULT_SCHEMA_DIR
const PACK_DIR := "user://test-farm-two-crops-pack"
const BAD_PACK_DIR := "user://test-farm-two-crops-bad-pack"

const SEED := 560_101
const MAP_SIZE := 24
const TURNIP_FARM := Rect2i(4, 4, 2, 2)
const BEAN_FARM := Rect2i(4, 8, 2, 2)
const STOCKPILE := Rect2i(12, 4, 6, 6)
const START_SEEDS := 4
const COLONISTS := 4
const DAYS := 4

const TURNIP_STAGES: Array[String] = ["turnip_sown", "turnip_ripe"]
const BEAN_STAGES: Array[String] = ["bean_sown", "bean_grown", "bean_ripe"]
const CARROT_STAGES: Array[String] = ["planted", "crop_grown", "crop_ripe"]

var _failed := false

func _init() -> void:
	_check_two_crops_through_commands_and_ticks()
	_check_crop_with_a_foreign_sow_job_fails_construction()
	if _failed:
		quit(1)
		return
	print("test_farm_two_crops: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _tile(id: String) -> Dictionary:
	return {"id": id, "passable": true, "move_cost": 1, "diggable": false, "display": {"label": id}, "move_ticks_per_tile": 4}

func _job(kind: String, effects: Dictionary) -> Dictionary:
	return {"kind": kind, "labour": "farm", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 20, "effects": effects}

func _crop(id: String, sow_job: String, harvest_job: String, grow_days: int, stages: Array[String]) -> Dictionary:
	return {"id": id, "label": id, "seed_item": id + "_seed", "sow_job": sow_job, "harvest_job": harvest_job, "window": "sow",
		"grow_days": grow_days, "stages": stages, "wither_days_after_window": 1, "withered_tile": "plowed_soil"}

## The pack's files: two crops, their seeds and produce, stage tiles and jobs. sow_job_of_bean
## lets the rejection case point the bean at the turnip's sow job.
func _pack_files(sow_job_of_bean: String) -> Dictionary:
	var tiles: Array = []
	for stage: String in TURNIP_STAGES + BEAN_STAGES:
		tiles.append(_tile(stage))
	return {
		"items": {"items": [{"id": "turnip_seed", "kind": "seed"}, {"id": "turnip", "kind": "food"},
			{"id": "bean_seed", "kind": "seed"}, {"id": "bean", "kind": "food"}]},
		"tiles": {"tiles": tiles},
		"jobs": {"jobs": [
			_job("sow_turnip", {"requires_tile": "plowed_soil", "consumes": "turnip_seed", "set_tile": "turnip_sown"}),
			_job("harvest_turnip", {"requires_tile": "turnip_ripe", "set_tile": "plowed_soil",
				"yields": {"placement": "target", "always": ["turnip", "turnip_seed"]}}),
			_job("sow_bean", {"requires_tile": "plowed_soil", "consumes": "bean_seed", "set_tile": "bean_sown"}),
			_job("harvest_bean", {"requires_tile": "bean_ripe", "set_tile": "plowed_soil",
				"yields": {"placement": "target", "always": ["bean", "bean", "bean", "bean_seed"]}}),
		]},
		"crops": {"crops": [_crop("turnip", "sow_turnip", "harvest_turnip", 1, TURNIP_STAGES),
			_crop("bean", sow_job_of_bean, "harvest_bean", 2, BEAN_STAGES)]},
	}

func _world(registry: ContentRegistryType) -> WorldStateType:
	var world := WorldStateType.new(SEED, 10, MAP_SIZE, MAP_SIZE, false, registry)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).clear()
	var labours := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	for i in COLONISTS:
		TestAccess.colonists(world).append({"id": "colonist_%d" % i, "kind": "colonist", "x": 1, "y": 1 + i,
			"route": null, "work": null, "labourTable": labours})
	for farm: Rect2i in [TURNIP_FARM, BEAN_FARM]:
		for y in range(farm.position.y, farm.end.y):
			for x in range(farm.position.x, farm.end.x):
				TestAccess.set_tile(world, x, y, WorldStateType.TILE_SOIL)
	Scenarios.add_stock(world, "turnip_seed", START_SEEDS, STOCKPILE.position.x, STOCKPILE.position.y)
	Scenarios.add_stock(world, "bean_seed", START_SEEDS, STOCKPILE.position.x + 1, STOCKPILE.position.y)
	return world

func _units_in(world: WorldStateType, kind: String, rect: Rect2i) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind and rect.has_point(Vector2i(int(item["x"]), int(item["y"]))):
			total += int(item["count"])
	return total

## Every tile kind seen inside rect while ticking (into seen).
func _note_tiles(world: WorldStateType, rect: Rect2i, seen: Dictionary) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			seen[world.get_tile(x, y)] = true

func _check_two_crops_through_commands_and_ticks() -> void:
	_write_pack(PACK_DIR, _pack_files("sow_bean"))
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_DIR] as Array[String])
	_cleanup_dir(PACK_DIR)
	_expect(registry.is_valid(), "a pack with two crops and their jobs must load: %s" % registry.get_error())
	if not registry.is_valid():
		return
	var world := _world(registry)
	_expect(Scenarios.command(world, "stock", "zone_add", {"x": STOCKPILE.position.x, "y": STOCKPILE.position.y,
		"width": STOCKPILE.size.x, "height": STOCKPILE.size.y}).get("ok", false), "the stockpile zone must be accepted")
	for entry: Array in [["turnip", TURNIP_FARM], ["bean", BEAN_FARM]]:
		var rect: Rect2i = entry[1]
		var result := Scenarios.command(world, "farm_" + String(entry[0]), "zone_add", {"x": rect.position.x, "y": rect.position.y,
			"width": rect.size.x, "height": rect.size.y, "kind": "farm", "crop": entry[0]})
		_expect(result.get("ok", false), "the %s farm zone must be accepted: %s" % [entry[0], result])
	var turnip_tiles: Dictionary = {}
	var bean_tiles: Dictionary = {}
	var job_kinds: Dictionary = {}
	var day_ticks := TestAccess.calendar(world).day_length_ticks()
	for tick in DAYS * day_ticks:
		world.tick()
		_note_tiles(world, TURNIP_FARM, turnip_tiles)
		_note_tiles(world, BEAN_FARM, bean_tiles)
		if tick % 10 == 0:
			for job in world.get_jobs():
				job_kinds[String(job["kind"])] = true
	for stage in TURNIP_STAGES:
		_expect(turnip_tiles.has(stage), "the turnip zone must show its stage '%s', saw %s" % [stage, turnip_tiles.keys()])
	for stage in BEAN_STAGES:
		_expect(bean_tiles.has(stage), "the bean zone must show its stage '%s', saw %s" % [stage, bean_tiles.keys()])
	for stage in BEAN_STAGES + CARROT_STAGES:
		_expect(not turnip_tiles.has(stage), "the turnip zone must never show '%s'" % stage)
	for stage in TURNIP_STAGES + CARROT_STAGES:
		_expect(not bean_tiles.has(stage), "the bean zone must never show '%s'" % stage)
	for kind in ["till", "sow_turnip", "harvest_turnip", "sow_bean", "harvest_bean"]:
		_expect(job_kinds.has(kind), "a '%s' job must have been submitted, saw %s" % [kind, job_kinds.keys()])
	for kind in ["sow", "harvest"]:
		_expect(not job_kinds.has(kind), "the base carrot's '%s' job must never run for these zones" % kind)
	var turnips := _units_in(world, "turnip", STOCKPILE)
	var beans := _units_in(world, "bean", STOCKPILE)
	print("test_farm_two_crops: day %d: stockpile turnip %d, bean %d, food %d" % [DAYS, turnips, beans, _units_in(world, "food", STOCKPILE)])
	_expect(turnips >= TURNIP_FARM.get_area(), "every turnip tile harvested at least once yields >= %d turnips, got %d"
		% [TURNIP_FARM.get_area(), turnips])
	_expect(beans >= 3 * BEAN_FARM.get_area(), "every bean tile harvested at least once yields >= %d beans, got %d"
		% [3 * BEAN_FARM.get_area(), beans])
	_expect(_units_in(world, "food", STOCKPILE) == 0, "no carrot harvest may have yielded base food")

## A crop whose sow_job does not consume its seed and set its first stage fails construction.
func _check_crop_with_a_foreign_sow_job_fails_construction() -> void:
	_write_pack(BAD_PACK_DIR, _pack_files("sow_turnip"))
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [BAD_PACK_DIR] as Array[String])
	_cleanup_dir(BAD_PACK_DIR)
	_expect(not registry.is_valid(), "a bean crop sown by the turnip's sow job must not load")
	var error: Dictionary = registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE and String(error.get("file", "")) == "crops.json"
		and String(error.get("message", "")).contains("sow_job"), "the failure must name crops.json's sow_job: %s" % error)

func _write_pack(dir: String, files: Dictionary) -> void:
	_cleanup_dir(dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_write_text(dir + "/pack.json", JSON.stringify({"id": "test_two_crops", "version": "1"}))
	for kind: String in files:
		_write_text("%s/%s.json" % [dir, kind], JSON.stringify(files[kind]))

func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
