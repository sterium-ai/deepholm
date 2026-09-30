extends SceneTree

## Covers foraging content: content/objects.json declares berry_bush and bed;
## WorldState generates TILE_WATER deterministically; a forage order against a
## berry_bush object completes like chop against a tree (colonist-ai.md
## section 3), turning the tile to floor and leaving one ground berry.

const WorldType = preload("res://scripts/core/world_state.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const OBJECTS_CONTENT_PATH := "res://content/objects.json"
const JOBS_CONTENT_PATH := "res://content/jobs.json"

const MAX_TICKS := 400

var _failed := false

func _init() -> void:
	_check_objects_content_file()
	_check_jobs_content_file_declares_forage()
	_check_water_generated_deterministically()
	_check_forage_walk_and_work()
	_check_forage_save_round_trip()

	if _failed:
		quit(1)
		return
	print("test_forage_content: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## game/content/objects.json must declare berry_bush (impassable) and bed
## (declared like the existing chair/door/wall/table object kinds).
func _check_objects_content_file() -> void:
	var file := FileAccess.open(OBJECTS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % OBJECTS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("objects")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'objects' array" % OBJECTS_CONTENT_PATH)
		return
	var by_kind: Dictionary = {}
	for entry in parsed["objects"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			by_kind[entry["kind"]] = entry

	var berry_bush = by_kind.get("berry_bush")
	_expect(berry_bush != null and berry_bush.get("passable") == false
		and berry_bush.has("move_cost") and typeof(berry_bush.get("is_door")) == TYPE_BOOL,
		"berry_bush must be declared impassable with move_cost and is_door fields")

	var bed = by_kind.get("bed")
	_expect(bed != null and typeof(bed.get("passable")) == TYPE_BOOL
		and bed.has("move_cost") and typeof(bed.get("is_door")) == TYPE_BOOL,
		"bed must be declared with passable/move_cost/is_door fields")

## game/content/jobs.json must declare a forage kind using the same
## reserve/go_to/work/release_all toils as chop.
func _check_jobs_content_file_declares_forage() -> void:
	var file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % JOBS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("jobs")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'jobs' array" % JOBS_CONTENT_PATH)
		return
	var forage = null
	for entry in parsed["jobs"]:
		if typeof(entry) == TYPE_DICTIONARY and String(entry.get("kind", "")) == "forage":
			forage = entry
	_expect(forage != null, "jobs.json must declare a 'forage' kind")
	if forage == null:
		return
	_expect(typeof(forage.get("toils")) == TYPE_ARRAY, "forage toils must be an array")
	for toil in forage.get("toils", []):
		_expect(ToilExecutorType.is_known_toil(String(toil)), "forage declares unknown toil '%s'" % toil)
	_expect(forage["toils"] == ["reserve", "go_to", "work", "release_all"],
		"forage must use the same reserve/go_to/work/release_all toils as chop")

## A fresh WorldState's own map generation must place at least one TILE_WATER
## tile for a fixed seed, and passability() must report it impassable with
## cost 0 purely through the unmodified "everything else is impassable"
## fallback (no water-specific branch was added to passability()).
func _check_water_generated_deterministically() -> void:
	var world := WorldType.new(20260918)
	var found_water := false
	for y in WorldType.MAP_HEIGHT:
		for x in WorldType.MAP_WIDTH:
			if world.get_tile(x, y) == WorldType.TILE_WATER:
				found_water = true
				var result := world.passability(x, y)
				_expect(result["passable"] == false and result["cost"] == 0,
					"a water tile at (%d, %d) must be impassable with cost 0" % [x, y])
	_expect(found_water, "map generation must place at least one water tile for seed 20260918")

func _command(world: WorldType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

## A single row corridor: colonist starts at (0,0); (0,0)-(3,0) are soil, a
## berry_bush object sits on (4,0) (mirrors test_movement_and_work.gd's
## dig/chop corridor). Everything else is rock, so the router has exactly one
## path to the bush.
func _build_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	for x in range(0, 5):
		world._tiles[world._tile_index(x, 0)] = WorldType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var place_result := _command(world, "place_bush", "place_object", {"x": 4, "y": 0, "kind": "berry_bush"})
	_expect(place_result["ok"], "placing the berry_bush fixture object must be accepted")
	return world

## Submitting forage against a berry_bush queues/activates/completes exactly
## like chop against a tree: the bush's passability is impassable (adjacent-
## only routing), the tile becomes floor on completion, the object clears,
## and ground berries at that tile increments by one.
func _check_forage_walk_and_work() -> void:
	var world := _build_world(2020918)
	var bush := Vector2i(4, 0)
	_expect(world.get_object(bush.x, bush.y) == "berry_bush", "fixture must place a berry_bush at the target")
	var passability := world.passability(bush.x, bush.y)
	_expect(passability["passable"] == false, "a berry_bush tile must be impassable")

	# Foraging a tile with no berry_bush must be rejected invalid_target.
	var bad_result := _command(world, "forage_bad", "forage", {"x": 0, "y": 0, "priority": 1})
	_expect(not bad_result["ok"] and bad_result["rejection"]["reason"] == "invalid_target",
		"forage against a non-berry_bush tile must be rejected invalid_target")

	var forage_result := _command(world, "forage_1", "forage", {"x": bush.x, "y": bush.y, "priority": 1})
	_expect(forage_result["ok"], "forage order against a berry_bush must be accepted")

	var ticks := 0
	var completed := false
	while ticks < MAX_TICKS and not completed:
		world.tick()
		ticks += 1
		for job in world.get_jobs():
			if job["kind"] == "forage" and job["status"] == "completed":
				completed = true
	_expect(completed, "the forage order must complete within the tick budget")
	if not completed:
		return

	_expect(world.get_tile(bush.x, bush.y) == WorldType.TILE_FLOOR, "forage target must become floor")
	_expect(world.get_object(bush.x, bush.y) == "", "forage must clear the berry_bush object")
	_expect(world.get_ground_berries(bush.x, bush.y) == 1, "forage target must leave exactly one ground berry")

## to_save_state()/from_save_state() must round-trip ground berries produced
## by a completed forage job.
func _check_forage_save_round_trip() -> void:
	var world := _build_world(3030918)
	var bush := Vector2i(4, 0)
	var forage_result := _command(world, "forage_1", "forage", {"x": bush.x, "y": bush.y, "priority": 1})
	_expect(forage_result["ok"], "forage order against a berry_bush must be accepted")

	var ticks := 0
	var completed := false
	while ticks < MAX_TICKS and not completed:
		world.tick()
		ticks += 1
		for job in world.get_jobs():
			if job["kind"] == "forage" and job["status"] == "completed":
				completed = true
	_expect(completed, "the forage order must complete within the tick budget")
	if not completed:
		return
	_expect(world.get_ground_berries(bush.x, bush.y) == 1, "forage target must leave exactly one ground berry before saving")

	var saved := world.to_save_state()
	_expect(int(saved["schemaVersion"]) == StateCodecType.SCHEMA_VERSION,
		"to_save_state() must report the current schema version")
	var restored := WorldType.from_save_state(saved)
	_expect(restored.get_ground_berries(bush.x, bush.y) == 1,
		"from_save_state() must round-trip ground berries")
