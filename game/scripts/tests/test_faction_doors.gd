extends SceneTree

## F3 (issue #289): WorldState.passability()'s faction_id parameter, consulted
## only for a door object via ContentRegistry's factions registry (ADR 015).
## Uses DebugScenario.build() (test_debug_scenario_objects.gd already proves
## it seeds at least one door) and the set_faction command (t2, issue #287)
## to change one of its colonists' factionId, then reads that factionId back
## and passes it into passability() -- passability() itself takes an explicit
## faction_id, it does not look an actor up.

const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_faction_doors()
	if _failed:
		quit(1)
		return
	print("test_faction_doors: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _find_door(world: WorldStateType) -> Vector2i:
	for object_entry in world.get_objects():
		if String(object_entry["kind"]) == "door":
			return Vector2i(int(object_entry["x"]), int(object_entry["y"]))
	return Vector2i(-1, -1)

func _set_faction(world: WorldStateType, command_id: String, target: String, faction_id: String) -> Dictionary:
	return world.apply({
		"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "set_faction", "payload": {"target": target, "faction_id": faction_id},
	})

func _check_faction_doors() -> void:
	var world: WorldStateType = DebugScenarioType.build()
	var door := _find_door(world)
	_expect(door != Vector2i(-1, -1), "debug scenario must place at least one door for this test")
	if door == Vector2i(-1, -1):
		return

	# A colony colonist's door passability is unchanged from before this task:
	# both the no-argument call (pre-existing single-arg call sites) and the
	# explicit "colony" argument must behave exactly as before F3.
	var default_result := world.passability(door.x, door.y)
	_expect(default_result["passable"] and default_result["cost"] == 2 and default_result["is_door"],
		"a colony colonist's door passability must be unchanged: passable with cost 2 and is_door")
	var colony_result := world.passability(door.x, door.y, "colony")
	_expect(colony_result == default_result,
		"passability(x, y, \"colony\") must match the no-argument call exactly")

	var colonist_id: String = world.get_colonists()[0]["id"]

	var wildlife_set := _set_faction(world, "set_wildlife", colonist_id, "wildlife")
	_expect(wildlife_set.get("ok", false), "set_faction to wildlife must be accepted")
	var wildlife_faction: String = String(world._find_colonist(colonist_id)["factionId"])
	_expect(wildlife_faction == "wildlife", "the actor's factionId must now be wildlife")
	var wildlife_result := world.passability(door.x, door.y, wildlife_faction)
	_expect(not bool(wildlife_result["passable"]) and wildlife_result["cost"] == 0 and wildlife_result["is_door"],
		"a wildlife-faction actor's door passability must be passable:false, cost 0, is_door true")

	var allies_set := _set_faction(world, "set_allies", colonist_id, "allies")
	_expect(allies_set.get("ok", false), "set_faction to allies must be accepted")
	var allies_faction: String = String(world._find_colonist(colonist_id)["factionId"])
	_expect(allies_faction == "allies", "the actor's factionId must now be allies")
	var allies_result := world.passability(door.x, door.y, allies_faction)
	_expect(allies_result["passable"] and allies_result["cost"] == 2 and allies_result["is_door"],
		"an allies-faction actor's door passability must be passable:true, cost 2, is_door true")
