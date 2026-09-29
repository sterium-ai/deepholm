extends SceneTree

## F5 "Rooms" (foundation-for-breadth.md §3, issue #293): RoomMapType
## recognises an enclosed region (walls + at least one door) as a room and
## derives size/door_count/has_bed/has_stockpile from it; WorldState wires it
## through get_room_at() and scales a completed sleep job's rest restore by
## needs.json's bedroom_rest_multiplier only when the bed sits inside one.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const RoomMapType = preload("res://scripts/core/map/rooms.gd")

const MAX_TICKS := 400

var _failed := false

func _init() -> void:
	_check_room_map_flood_recognises_enclosure_bed_and_door_removal()
	_check_standalone_outdoor_door_is_not_a_room()
	_check_exterior_of_valid_room_is_not_a_room()
	_check_wall_removal_breaches_enclosure_resealing_restores_it()
	_check_worldstate_recognises_bedroom_and_storeroom_both()
	_check_worldstate_removing_door_command_stops_being_a_room()
	_check_bedroom_bed_gets_rest_multiplier_ordinary_bed_does_not()
	_check_outdoor_bed_gets_no_multiplier()
	_check_multiplier_is_clamped_at_full()
	if _failed:
		quit(1)
		return
	print("test_rooms: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Builds a pure RoomMapType (no WorldState) around a 5x5 walled box (16-tile
## ring, one cell a door on its east side, at (23, 21)) enclosing a 3x3
## interior on a 30x30 map. `blocked`/`doors`/`beds` are the live Dictionary
## instances the returned RoomMapType's callables read, so a caller can
## mutate them and call on_passability_changed() to re-drive the flood, the
## same pattern the original single-function version of this test used.
## `outside` is (24, 21): the open exterior tile immediately across the door
## from `interior` -- orthogonally adjacent to the same door tile, so it
## shares the door's door_count with the interior and only enclosure (not
## door_count alone) can tell the two apart.
func _make_box_room_map() -> Dictionary:
	var blocked: Dictionary = {}
	for x in range(19, 24):
		blocked[Vector2i(x, 19)] = true
		blocked[Vector2i(x, 23)] = true
	blocked[Vector2i(19, 20)] = true
	blocked[Vector2i(19, 21)] = true
	blocked[Vector2i(19, 22)] = true
	blocked[Vector2i(23, 20)] = true
	blocked[Vector2i(23, 22)] = true
	var door := Vector2i(23, 21)
	var doors: Dictionary = {door: true}
	var beds: Dictionary = {}
	var passable := func(x: int, y: int) -> bool: return not blocked.has(Vector2i(x, y))
	var is_door := func(x: int, y: int) -> bool: return doors.has(Vector2i(x, y))
	var has_bed := func(x: int, y: int) -> bool: return beds.has(Vector2i(x, y))
	var is_stockpile := func(x: int, y: int) -> bool: return false
	var rooms := RoomMapType.new(30, 30, passable, is_door, has_bed, is_stockpile)
	return {
		"rooms": rooms, "blocked": blocked, "doors": doors, "beds": beds,
		"interior": Vector2i(21, 21), "door": door, "outside": Vector2i(24, 21),
	}

## A 5x5 walled box (16-tile ring, one cell a door) around a 3x3 interior is
## a recognised room with size 9 and door_count 1; a bed placed on any
## interior tile sets has_bed without needing a passability change; sealing
## the only door back to plain open floor (not a wall -- the real
## remove_object outcome) merges the interior into the vast, unenclosed
## surrounding area, which stops being a room both because it has no door
## and because it is open to the map edge.
func _check_room_map_flood_recognises_enclosure_bed_and_door_removal() -> void:
	var fixture := _make_box_room_map()
	var rooms: RoomMapType = fixture["rooms"]
	var interior: Vector2i = fixture["interior"]
	var door: Vector2i = fixture["door"]
	var doors: Dictionary = fixture["doors"]
	var beds: Dictionary = fixture["beds"]

	var room := rooms.get_room_at(interior.x, interior.y)
	_expect(not room.is_empty(), "a walled box with one door must be a recognised room")
	_expect(int(room.get("size", 0)) == 9, "the 3x3 interior must report size 9 (got %s)" % room.get("size"))
	_expect(int(room.get("door_count", 0)) == 1, "one boundary door must report door_count 1 (got %s)" % room.get("door_count"))
	_expect(not bool(room.get("has_bed", false)), "no bed placed yet must report has_bed false")

	beds[interior] = true
	rooms.on_passability_changed(interior.x, interior.y)
	_expect(bool(rooms.get_room_at(interior.x, interior.y).get("has_bed", false)),
		"placing a bed on an interior tile must set has_bed true even though passability never changed")

	doors.erase(door)
	rooms.on_passability_changed(door.x, door.y)
	_expect(rooms.get_room_at(interior.x, interior.y).is_empty(),
		"removing the only door must stop the enclosure being a recognised room")

## A door with no walls anywhere near it bounds nothing: both of its open
## neighbours belong to the same vast, unenclosed component as the rest of
## the empty map, so neither side of a standalone outdoor door -- nor a bed
## placed on one side of it -- ever resolves to a room.
func _check_standalone_outdoor_door_is_not_a_room() -> void:
	var doors: Dictionary = {Vector2i(10, 10): true}
	var beds: Dictionary = {}
	var passable := func(x: int, y: int) -> bool: return true
	var is_door := func(x: int, y: int) -> bool: return doors.has(Vector2i(x, y))
	var has_bed := func(x: int, y: int) -> bool: return beds.has(Vector2i(x, y))
	var is_stockpile := func(x: int, y: int) -> bool: return false
	var rooms := RoomMapType.new(30, 30, passable, is_door, has_bed, is_stockpile)

	_expect(rooms.get_room_at(9, 10).is_empty(), "open ground beside a lone outdoor door must not be a room")
	_expect(rooms.get_room_at(11, 10).is_empty(), "open ground on the other side of a lone outdoor door must not be a room")

	beds[Vector2i(9, 10)] = true
	rooms.on_passability_changed(9, 10)
	_expect(rooms.get_room_at(9, 10).is_empty(),
		"a bed on open, unenclosed ground next to a lone door must still not resolve to a room")

## The exterior of a real walled box is orthogonally adjacent to the same
## boundary door as the box's own interior, so it would satisfy
## "door_count >= 1" too if enclosure were not separately required; it must
## still resolve to no room, since it is open to the rest of the
## (unenclosed) map.
func _check_exterior_of_valid_room_is_not_a_room() -> void:
	var fixture := _make_box_room_map()
	var rooms: RoomMapType = fixture["rooms"]
	var outside: Vector2i = fixture["outside"]
	_expect(rooms.get_room_at(outside.x, outside.y).is_empty(),
		"the open exterior beside a valid room's own door must not itself be a room")

## Removing one wall tile of an otherwise-valid room (turning it passable,
## not another door) merges the interior into the unenclosed exterior --
## rooms.gd must react to the same on_passability_changed() hook WorldState
## already calls for a wall's removal. Placing the wall back reseals the
## enclosure and the room is recognised again.
func _check_wall_removal_breaches_enclosure_resealing_restores_it() -> void:
	var fixture := _make_box_room_map()
	var rooms: RoomMapType = fixture["rooms"]
	var blocked: Dictionary = fixture["blocked"]
	var interior: Vector2i = fixture["interior"]
	var breach := Vector2i(19, 20)

	_expect(not rooms.get_room_at(interior.x, interior.y).is_empty(),
		"the box must be a recognised room before any wall is removed")

	blocked.erase(breach)
	rooms.on_passability_changed(breach.x, breach.y)
	_expect(rooms.get_room_at(interior.x, interior.y).is_empty(),
		"removing one wall tile while the door remains must breach the enclosure and stop it being a room")

	blocked[breach] = true
	rooms.on_passability_changed(breach.x, breach.y)
	_expect(not rooms.get_room_at(interior.x, interior.y).is_empty(),
		"resealing the breach must make the enclosure a recognised room again")

## An enclosed walls+door+bed room reports has_bed; adding a stockpile zone
## overlapping it also sets has_stockpile without clearing has_bed -- a room
## with both flags reports both, per the task contract.
func _check_worldstate_recognises_bedroom_and_storeroom_both() -> void:
	var world := _build_world(300001)
	var room_coords := _place_room(world, 1, 1)
	_place(world, room_coords["interior"].x, room_coords["interior"].y, "bed")

	var room := world.get_room_at(room_coords["interior"].x, room_coords["interior"].y)
	_expect(not room.is_empty(), "walls + a door + a bed must produce a recognised room")
	_expect(bool(room.get("has_bed", false)), "the placed bed must set has_bed true")
	_expect(not bool(room.get("has_stockpile", false)), "no zone yet must report has_stockpile false")

	var zone_result := _command(world, "zone_add", "zone_add", {
		"x": room_coords["interior"].x - 1, "y": room_coords["interior"].y - 1, "width": 2, "height": 2})
	_expect(zone_result["ok"], "adding a zone overlapping the room must be accepted (got %s)" % zone_result)

	room = world.get_room_at(room_coords["interior"].x, room_coords["interior"].y)
	_expect(bool(room.get("has_bed", false)) and bool(room.get("has_stockpile", false)),
		"an overlapping stockpile zone must add has_stockpile without clearing has_bed")

## remove_object on the room's only door (the real player-facing command,
## not a direct RoomMapType call) must make an interior tile stop resolving
## to a room through WorldState.get_room_at() too.
func _check_worldstate_removing_door_command_stops_being_a_room() -> void:
	var world := _build_world(300002)
	var room_coords := _place_room(world, 1, 1)
	_expect(not world.get_room_at(room_coords["interior"].x, room_coords["interior"].y).is_empty(),
		"the freshly built room must be recognised before the door is removed")

	var door: Vector2i = room_coords["door"]
	var remove_result := _command(world, "remove_door", "remove_object", {"x": door.x, "y": door.y})
	_expect(remove_result["ok"], "removing the door object must be accepted (got %s)" % remove_result)

	_expect(world.get_room_at(room_coords["interior"].x, room_coords["interior"].y).is_empty(),
		"removing the only door via remove_object must stop the enclosure being a recognised room")

## A colonist sleeping in a bed inside a recognised bedroom room restores
## rest by restore * bedroom_rest_multiplier; an otherwise identical
## colonist sleeping in a bed on open floor (no enclosing walls/door)
## restores only the plain restore value. Uses a test-local override of
## _need_definitions["rest"] (restore 60, multiplier 1.5 -> 90, safely below
## the 100 cap so the multiplier's effect is directly observable) rather
## than content/needs.json's own production values, so this proves the
## mechanism itself, not a coincidence of content data -- production's
## restore stays 100 (an ordinary bed must keep its existing restoration;
## see _check_multiplier_is_clamped_at_full() for the clamp path).
func _check_bedroom_bed_gets_rest_multiplier_ordinary_bed_does_not() -> void:
	var bedroom_world := _build_world(300003)
	_isolate_need(bedroom_world, "rest")
	_set_rest_config(bedroom_world, 60, 1.5)
	bedroom_world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))
	var room_coords := _place_room(bedroom_world, 3, 3)
	_place(bedroom_world, room_coords["interior"].x, room_coords["interior"].y, "bed")
	var bedroom_rest := _run_sleep_to_completion(bedroom_world)
	_expect(bedroom_rest == 90, "sleeping in a bedroom bed must apply the test config's bedroom_rest_multiplier (got %s)" % bedroom_rest)

	var ordinary_world := _build_world(300004)
	_isolate_need(ordinary_world, "rest")
	_set_rest_config(ordinary_world, 60, 1.5)
	ordinary_world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))
	var place_result := _command(ordinary_world, "place_bed", "place_object", {"x": 5, "y": 0, "kind": "bed"})
	_expect(place_result["ok"], "placing the ordinary bed fixture must be accepted")
	var ordinary_rest := _run_sleep_to_completion(ordinary_world)
	_expect(ordinary_rest == 60, "sleeping in an ordinary (non-bedroom) bed must restore only the plain test config restore value (got %s)" % ordinary_rest)

## An outdoor bed merely sharing a map with an unrelated, unenclosing door
## (nothing walls either of them in) must not receive the bedroom multiplier
## -- the regression this guards is get_room_at() recognising the entire
## unenclosed open map as one giant "room" just because some door somewhere
## touches it.
func _check_outdoor_bed_gets_no_multiplier() -> void:
	var world := _build_world(300005)
	_isolate_need(world, "rest")
	_set_rest_config(world, 60, 1.5)
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))
	var stray_door := _command(world, "place_stray_door", "place_object", {"x": 10, "y": 10, "kind": "door"})
	_expect(stray_door["ok"], "placing a standalone door on open, unwalled ground must be accepted")
	var place_result := _command(world, "place_outdoor_bed", "place_object", {"x": 5, "y": 0, "kind": "bed"})
	_expect(place_result["ok"], "placing the outdoor bed fixture must be accepted")
	var rest := _run_sleep_to_completion(world)
	_expect(rest == 60, "a bed on open ground sharing a map with an unrelated stray door must not receive the bedroom multiplier (got %s)" % rest)

## restore * bedroom_rest_multiplier exceeding the need's `full` value must
## clamp there rather than overshoot -- the same clamp _apply_need_effect()
## already applies to a plain restore, exercised here with a multiplier
## large enough to prove it actually fires (90 * 2.0 = 180, clamped to the
## production full value of 100).
func _check_multiplier_is_clamped_at_full() -> void:
	var world := _build_world(300006)
	_isolate_need(world, "rest")
	_set_rest_config(world, 90, 2.0)
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))
	var room_coords := _place_room(world, 1, 1)
	_place(world, room_coords["interior"].x, room_coords["interior"].y, "bed")
	var rest := _run_sleep_to_completion(world)
	_expect(rest == 100, "restore * bedroom_rest_multiplier exceeding full must clamp at full (got %s)" % rest)

func _set_rest_config(world: WorldStateType, restore: int, multiplier: float) -> void:
	world._need_definitions["rest"]["restore"] = restore
	world._need_definitions["rest"]["bedroom_rest_multiplier"] = multiplier

func _run_sleep_to_completion(world: WorldStateType) -> int:
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "sleep" and String(job["status"]) == "completed":
				completed = true
		if completed:
			break
	_expect(completed, "the sleep job must complete within the tick budget")
	return int(_colonist_by_id(world, "colonist_0")["needs"]["rest"])

## Places a 5x5 walled box (15 walls + 1 door on its east side) with origin
## (ox, oy), leaving a 3x3 interior open for a bed. Returns the interior
## centre and door coordinates.
func _place_room(world: WorldStateType, ox: int, oy: int) -> Dictionary:
	for x in range(ox, ox + 5):
		_place(world, x, oy, "wooden_wall")
		_place(world, x, oy + 4, "wooden_wall")
	_place(world, ox, oy + 1, "wooden_wall")
	_place(world, ox, oy + 2, "wooden_wall")
	_place(world, ox, oy + 3, "wooden_wall")
	_place(world, ox + 4, oy + 1, "wooden_wall")
	_place(world, ox + 4, oy + 3, "wooden_wall")
	var door := Vector2i(ox + 4, oy + 2)
	_place(world, door.x, door.y, "door")
	return {"interior": Vector2i(ox + 2, oy + 2), "door": door}

func _place(world: WorldStateType, x: int, y: int, kind: String) -> void:
	var result := _command(world, "place_%s_%d_%d" % [kind, x, y], "place_object", {"x": x, "y": y, "kind": kind})
	_expect(result["ok"], "placing %s at (%d, %d) must be accepted (got %s)" % [kind, x, y, result])

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	return world

## Mirrors test_need_jobs.gd's own helper: zeroes every need kind's decay
## rate except `kind`, so a scenario built around rest is never disturbed by
## food/water crossing their own "urgent" threshold first.
func _isolate_need(world: WorldStateType, kind: String) -> void:
	for other in world._need_definitions.keys():
		if other != kind:
			world._need_definitions[other]["rate_per_day"] = 0

func _colonist(id: String, x: int, y: int, needs: Dictionary) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "needs": needs.duplicate(),
		"route": null, "work": null, "carrying": null}

func _full_needs(overrides: Dictionary = {}) -> Dictionary:
	var needs := {"food": 100, "water": 100, "rest": 100}
	for kind in overrides:
		needs[kind] = overrides[kind]
	return needs

func _command(world: WorldStateType, command_id: String, type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": payload})

func _colonist_by_id(world: WorldStateType, id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == id:
			return colonist
	return {}
