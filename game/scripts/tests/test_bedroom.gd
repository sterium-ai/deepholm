extends SceneTree

## Closing proof for #278: construct a bedroom through the player-facing build
## command and shared haul/work toils, then compare sleep with an open bed.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MAX_TICKS := 500
const ROOM_ORIGIN := Vector2i(3, 3)
const ROOM_INTERIOR := Vector2i(5, 5)
const ROOM_DOOR := Vector2i(7, 5)

var _failed := false

func _init() -> void:
	var bedroom_world := _build_world(307001)
	var bedroom_rest := _build_fixture(bedroom_world, true)
	var bedroom := bedroom_world.get_room_at(ROOM_INTERIOR.x, ROOM_INTERIOR.y)
	_expect(not bedroom.is_empty(), "completed walls and door must enclose a recognised room")
	_expect(int(bedroom.get("door_count", 0)) >= 1, "recognised bedroom must have a boundary door")
	_expect(bool(bedroom.get("has_bed", false)), "recognised bedroom must contain the completed bed")
	_expect(bedroom_rest == 90, "bedroom sleep must restore 60 * 1.5 = 90 (got %d)" % bedroom_rest)

	var open_world := _build_world(307002)
	var open_rest := _build_fixture(open_world, false)
	_expect(open_world.get_room_at(ROOM_INTERIOR.x, ROOM_INTERIOR.y).is_empty(),
		"the open bed must not be reported as being in a room")
	_expect(open_rest == 60, "an open bed must restore only 60 (got %d)" % open_rest)
	_expect(bedroom_rest > open_rest, "bedroom rest must be better than open-bed rest")

	if _failed:
		quit(1)
		return
	print("test_bedroom: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._objects.clear()
	return world

func _colonist() -> Dictionary:
	return {"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 20},
		"route": null, "work": null, "carrying": null}

func _command(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": command_type, "payload": payload})

func _command_ok(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	var result := _command(world, command_id, command_type, payload)
	_expect(bool(result.get("ok", false)), "%s must be accepted: %s" % [command_id, result])
	return result

func _build_fixture(world: WorldStateType, bedroom: bool) -> int:
	world._colonists.append(_colonist())
	_command_ok(world, "stockpile", "zone_add", {"x": 0, "y": 0, "width": 1, "height": 1})
	var total_wood := 0
	for kind in ["wooden_wall", "door", "bed"]:
		for cost_entry in (world._object_definitions[kind]["build_cost"] as Array):
			total_wood += int(cost_entry["quantity"])
	if bedroom:
		for cost_entry in (world._object_definitions["wooden_wall"]["build_cost"] as Array):
			total_wood += int(cost_entry["quantity"]) * 14
	# Build completion deposits an unused remainder on the builder's tile,
	# outside the stockpile. Supply one stockpiled unit per order so every
	# subsequent build command still resolves through the real stockpile gate.
	for item_index in range(total_wood):
		var item_id := "item_%d" % (item_index + 1)
		world._items[item_id] = {"id": item_id, "x": 0, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = total_wood + 1

	if bedroom:
		# Establish the opening first so the final wall never seals the only
		# route and the builder can keep using the shared reachability rules.
		if not _complete_build(world, "door", ROOM_DOOR):
			return -1
		var sites: Array[Vector2i] = []
		for x in range(ROOM_ORIGIN.x, ROOM_ORIGIN.x + 5):
			sites.append(Vector2i(x, ROOM_ORIGIN.y))
			sites.append(Vector2i(x, ROOM_ORIGIN.y + 4))
		for y in range(ROOM_ORIGIN.y + 1, ROOM_ORIGIN.y + 4):
			sites.append(Vector2i(ROOM_ORIGIN.x, y))
			if y != ROOM_DOOR.y:
				sites.append(Vector2i(ROOM_ORIGIN.x + 4, y))
		for site in sites:
			if not _complete_build(world, "wooden_wall", site):
				return -1
		if not _complete_build(world, "bed", ROOM_INTERIOR):
			return -1
	else:
		if not _complete_build(world, "bed", ROOM_INTERIOR):
			return -1

	world._need_definitions["rest"]["restore"] = 60
	world._need_definitions["rest"]["bedroom_rest_multiplier"] = 1.5
	for kind in world._need_definitions:
		if kind != "rest":
			world._need_definitions[kind]["rate_per_day"] = 0
	return _run_sleep(world)

## issue #406: `build` no longer names a single job to track through
## "completed" -- it creates a persistent construction site instead
## (ConstructionGiver submits its own fetch/work jobs on its own schedule).
## Completion is instead observed the same way get_construction_sites()'s own
## acceptance criteria do: the site record disappears and the declared object
## occupies the tile.
func _complete_build(world: WorldStateType, kind: String, site: Vector2i) -> bool:
	var result := _command(world, "build_%s_%d_%d" % [kind, site.x, site.y], "build",
		{"kind": kind, "x": site.x, "y": site.y})
	if not result.get("ok", false):
		_fail("build command for %s at %s was rejected: %s" % [kind, site, result])
		return false
	var saw_work := false
	for _tick in MAX_TICKS:
		world.tick()
		if world._colonists[0].get("work") != null:
			saw_work = true
		if world.get_construction_site(site.x, site.y).is_empty():
			if world.get_object(site.x, site.y) != kind:
				_fail("%s build's site vanished without placing the declared object (got '%s')" % [kind, world.get_object(site.x, site.y)])
				return false
			_expect(saw_work, "%s build must execute its timed work toil" % kind)
			return true
	_fail("%s build did not complete within the tick budget" % kind)
	return false

func _run_sleep(world: WorldStateType) -> int:
	for _tick in MAX_TICKS:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "sleep" and String(job.get("status", "")) == "completed":
				return int(world._colonists[0]["needs"]["rest"])
	_fail("sleep job did not complete within the tick budget")
	return -1
