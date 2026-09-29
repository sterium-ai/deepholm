extends SceneTree

## Exercises WorldState's per-tile object storage (mirrors _ground_items):
## adding/querying an object per tile, get_object()'s "" default, detached
## copies from get_objects()/get_object(), and state_hash() reacting to an
## object being added. Also checks game/content/objects.json declares the
## object kinds docs/architecture/colonist-ai.md section 3.5 requires.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const OBJECTS_CONTENT_PATH := "res://content/objects.json"

var _failed := false

func _init() -> void:
	_check_objects_content_file()
	_check_default_is_empty()
	_check_add_and_query_per_tile()
	_check_get_objects_snapshot()
	_check_detached_copies()
	_check_state_hash_changes_on_add()
	_check_footprint_object_occupies_every_tile()
	_check_footprint_object_rotates_with_orientation()
	_check_clearing_any_footprint_tile_clears_the_whole_object()
	_check_footprint_object_shares_one_health_pool()

	if _failed:
		quit(1)
		return
	print("test_object_storage: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## game/content/objects.json must declare at least chair (passable,
## move_cost 3), door (passable, move_cost 2, is_door true), wooden_wall/
## stone_wall (impassable) and table (impassable).
func _check_objects_content_file() -> void:
	if _failed:
		return
	var file := FileAccess.open(OBJECTS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_fail("could not open %s" % OBJECTS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("objects")) != TYPE_ARRAY:
		_fail("%s must contain a top-level 'objects' array" % OBJECTS_CONTENT_PATH)
		return
	var by_kind: Dictionary = {}
	for entry in parsed["objects"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			by_kind[entry["kind"]] = entry

	var chair = by_kind.get("chair")
	_expect(chair != null and chair.get("passable") == true and int(chair.get("move_cost", -1)) == 3,
		"chair must be passable with move_cost 3")

	var door = by_kind.get("door")
	_expect(door != null and door.get("passable") == true and int(door.get("move_cost", -1)) == 2
		and door.get("is_door") == true, "door must be passable, move_cost 2, is_door true")

	var wooden_wall = by_kind.get("wooden_wall")
	_expect(wooden_wall != null and wooden_wall.get("passable") == false, "wooden_wall must be impassable")
	var stone_wall = by_kind.get("stone_wall")
	_expect(stone_wall != null and stone_wall.get("passable") == false, "stone_wall must be impassable")

	var table = by_kind.get("table")
	_expect(table != null and table.get("passable") == false, "table must be impassable")

## get_object() defaults to "" ("none") for a tile with no object.
func _check_default_is_empty() -> void:
	if _failed:
		return
	var world := WorldStateType.new(1, 10)
	_expect(world.get_object(0, 0) == "", "get_object() must default to \"\" for an empty tile")
	# issue #300: a freshly generated world now places berry_bush objects (the
	# food need's only source, docs/decisions/020) as part of terrain
	# generation, so "freshly generated" no longer means zero objects -- it
	# means no object kind the generator itself never places.
	for entry in world.get_objects():
		_expect(String(entry["kind"]) == "berry_bush",
			"a freshly generated world's only objects must be generator-placed berry_bush, found '%s'" % entry["kind"])

## At most one object per tile: adding a second kind on the same tile
## replaces the first, matching _ground_items' single-slot key.
func _check_add_and_query_per_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(2, 10)
	world._set_object(3, 4, "chair")
	_expect(world.get_object(3, 4) == "chair", "get_object() must report the added object's kind")
	_expect(world.get_object(0, 0) == "", "an untouched tile must still report \"\"")

	world._set_object(3, 4, "door")
	_expect(world.get_object(3, 4) == "door", "setting a new kind on the same tile must replace it")

	world._set_object(3, 4, "")
	_expect(world.get_object(3, 4) == "", "setting an empty kind must clear the object")

## get_objects() returns every occupied tile as {x, y, kind}.
func _check_get_objects_snapshot() -> void:
	if _failed:
		return
	# issue #300: a freshly generated world can already carry generator-placed
	# berry_bush objects (docs/decisions/020), so this checks the two placed
	# entries are present and correct rather than assuming get_objects()'s
	# total count is exactly these two.
	var world := WorldStateType.new(3, 10)
	var before_count := world.get_objects().size()
	world._set_object(1, 1, "wooden_wall")
	world._set_object(2, 5, "table")
	var objects := world.get_objects()
	_expect(objects.size() == before_count + 2, "get_objects() must report exactly the placed objects, plus whatever generation already placed")
	var by_kind: Dictionary = {}
	for entry in objects:
		by_kind["%d_%d" % [entry["x"], entry["y"]]] = entry["kind"]
	_expect(by_kind.get("1_1") == "wooden_wall", "get_objects() must report (1,1) as wooden_wall")
	_expect(by_kind.get("2_5") == "table", "get_objects() must report (2,5) as table")

## Mutating a get_objects() return value must never affect WorldState's own
## state, mirroring the snapshot isolation the other get_*() accessors give.
func _check_detached_copies() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4, 10)
	var before_count := world.get_objects().size()
	world._set_object(6, 6, "chair")

	var objects := world.get_objects()
	objects.append({"x": 9, "y": 9, "kind": "bogus"})
	for entry in objects:
		if int(entry["x"]) == 6 and int(entry["y"]) == 6:
			entry["kind"] = "mutated"
	_expect(world.get_objects().size() == before_count + 1, "mutating get_objects() result must not affect world state")
	_expect(world.get_object(6, 6) == "chair", "mutating a get_objects() entry must not affect world state")

## Adding an object must change state_hash(), the same way ground items do.
func _check_state_hash_changes_on_add() -> void:
	if _failed:
		return
	var world := WorldStateType.new(5, 10)
	var before := world.state_hash()
	world._set_object(10, 10, "door")
	var after := world.state_hash()
	_expect(before != after, "state_hash() must change when an object is added")

## Issue #405: content/objects.json's "test_footprint_crate" declares
## footprint [2, 1] and rotatable true. Placed "horizontal" at an origin
## tile, it must occupy both that tile and its +x neighbour identically
## (same kind), each independently impassable, and both entries must show up
## in get_objects().
func _check_footprint_object_occupies_every_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(6, 10)
	world._set_object(20, 20, "test_footprint_crate", "colony", "horizontal")
	_expect(world.get_object(20, 20) == "test_footprint_crate", "the origin footprint tile must report the placed kind")
	_expect(world.get_object(21, 20) == "test_footprint_crate", "the second footprint tile must report the same kind")
	_expect(not bool(world.passability(20, 20)["passable"]), "the origin footprint tile must be impassable")
	_expect(not bool(world.passability(21, 20)["passable"]), "the second footprint tile must be impassable")
	var matching := 0
	for entry in world.get_objects():
		if String(entry["kind"]) == "test_footprint_crate":
			matching += 1
			_expect(String(entry["faction_id"]) == "colony", "each footprint tile must report the placed object's faction_id")
	_expect(matching == 2, "get_objects() must list both footprint tiles")

## A rotatable kind's "vertical" orientation swaps its declared [w, h]: the
## same test_footprint_crate ([2, 1]) placed vertical occupies its origin and
## its +y neighbour, not its +x neighbour.
func _check_footprint_object_rotates_with_orientation() -> void:
	if _failed:
		return
	var world := WorldStateType.new(7, 10)
	world._set_object(25, 25, "test_footprint_crate", "colony", "vertical")
	_expect(world.get_object(25, 25) == "test_footprint_crate", "the origin footprint tile must report the placed kind")
	_expect(world.get_object(25, 26) == "test_footprint_crate", "vertical orientation must occupy the +y neighbour")
	_expect(world.get_object(26, 25) == "", "vertical orientation must not occupy the +x neighbour")

## Clearing at ANY footprint tile -- not only the origin -- must clear the
## whole logical object, since a remove_object command may target either one.
func _check_clearing_any_footprint_tile_clears_the_whole_object() -> void:
	if _failed:
		return
	var world := WorldStateType.new(8, 10)
	world._set_object(30, 30, "test_footprint_crate", "colony", "horizontal")
	world._set_object(31, 30, "")
	_expect(world.get_object(30, 30) == "", "clearing via a non-origin footprint tile must clear the origin tile too")
	_expect(world.get_object(31, 30) == "", "clearing via a non-origin footprint tile must clear that tile")

## Issue #405 round-6 review: a multi-tile object is one *logical* object, so
## every footprint tile must share one canonical health pool, not carry an
## independent copy. test_footprint_crate declares max_health 20; damage
## applied through its non-origin tile must be visible from every footprint
## tile (including the origin), and destroying it via any footprint tile must
## clear the whole footprint, not just the tile that took the killing blow.
func _check_footprint_object_shares_one_health_pool() -> void:
	if _failed:
		return
	var world := WorldStateType.new(9, 10)
	world._set_object(40, 40, "test_footprint_crate", "colony", "horizontal")
	var origin_hp := int(world._object_health_at(40, 40)["hp"])
	var second_hp := int(world._object_health_at(41, 40)["hp"])
	_expect(origin_hp == 20 and second_hp == 20, "both footprint tiles must start at the kind's full health")

	world._damage_object(41, 40, 5)
	origin_hp = int(world._object_health_at(40, 40)["hp"])
	second_hp = int(world._object_health_at(41, 40)["hp"])
	_expect(origin_hp == 15, "damage applied via the non-origin tile must reduce the shared pool, visible from the origin tile")
	_expect(second_hp == 15, "damage applied via the non-origin tile must be visible from that same tile")
	_expect(origin_hp == second_hp, "every footprint tile must report the same hp: one shared pool, not one per tile")

	world._damage_object(41, 40, 100)
	_expect(world.get_object(40, 40) == "", "destroying the object via a non-origin tile must clear the whole footprint, including the origin")
	_expect(world.get_object(41, 40) == "", "destroying the object via a non-origin tile must clear that tile too")
