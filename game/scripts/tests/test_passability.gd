extends SceneTree

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_tile_kinds()
	_check_objects()
	_check_dig_rejects_blocked_object()
	_check_footprint_object_blocks_every_tile()
	if _failed:
		quit(1)
		return
	print("test_passability: PASS")
	quit(0)

func _check_tile_kinds() -> void:
	var world := WorldStateType.new(178, 10)
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(2, 1)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(3, 1)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(4, 1)] = WorldStateType.TILE_HAZARD
	world._tiles[world._tile_index(5, 1)] = WorldStateType.TILE_TREE
	_expect(world.passability(1, 1) == {"passable": true, "cost": 1, "is_door": false}, "floor must cost 1")
	_expect(world.passability(2, 1)["passable"] and world.passability(2, 1)["cost"] == 1, "soil must cost 1")
	for x in [3, 4, 5]:
		_expect(not bool(world.passability(x, 1)["passable"]), "rock, hazard, and tree must be impassable")

func _check_objects() -> void:
	var world := WorldStateType.new(179, 10)
	world._tiles[world._tile_index(1, 2)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(2, 2)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(3, 2)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(4, 2)] = WorldStateType.TILE_FLOOR
	world._set_object(1, 2, "chair")
	world._set_object(2, 2, "door")
	world._set_object(3, 2, "wall")
	world._set_object(4, 2, "table")
	var chair := world.passability(1, 2)
	var door := world.passability(2, 2)
	_expect(chair["passable"] and chair["cost"] == 3, "chair must be passable with cost 3")
	_expect(door["passable"] and door["cost"] == 2 and door["is_door"], "door must be passable with cost 2 and is_door")
	_expect(not bool(world.passability(3, 2)["passable"]) and not bool(world.passability(4, 2)["passable"]), "wall and table must be impassable")

func _check_dig_rejects_blocked_object() -> void:
	var world := WorldStateType.new(180, 10)
	world._tiles[world._tile_index(10, 10)] = WorldStateType.TILE_SOIL
	world._set_object(10, 10, "wall")
	var result := world.apply({
		"command_id": "blocked-dig",
		"actor": "player",
		"tick": 0,
		"type": "dig",
		"payload": {"x": 10, "y": 10, "priority": 1}
	})
	_expect(not result["ok"] and result["rejection"]["reason"] == "invalid_target", "dig on a wall must be rejected as invalid_target")

## Issue #405: "test_footprint_crate" (content/objects.json, footprint
## [2, 1], impassable) placed horizontal must make BOTH occupied tiles
## impassable, not just its origin -- passability() reads get_object() per
## tile, which _set_object() must have duplicated the kind onto every
## footprint tile for.
func _check_footprint_object_blocks_every_tile() -> void:
	var world := WorldStateType.new(181, 10)
	world._tiles[world._tile_index(6, 6)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(7, 6)] = WorldStateType.TILE_FLOOR
	world._set_object(6, 6, "test_footprint_crate", "colony", "horizontal")
	_expect(not bool(world.passability(6, 6)["passable"]), "the origin footprint tile must be impassable")
	_expect(not bool(world.passability(7, 6)["passable"]), "the second footprint tile must be impassable")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true
