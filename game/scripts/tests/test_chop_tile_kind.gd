extends SceneTree

## B4: a completed chop turns its tree tile back into the terrain it grew on. Trees only
## generate on TILE_SOIL (world_generator.gd), the only natural ground terrain in
## content/tiles.json (there is no sand or dirt tile kind; "sand" is an item), so the
## chopped tile must be TILE_SOIL -- never TILE_FLOOR, the built floor the starting
## clearing uses, which the viewer draws as stone bricks. Goes through the real trigger
## (a chop command, a fetched axe, ticks) on several seeds, and checks the tile behaves
## as soil afterwards (a till order on it is accepted).

const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEEDS := [424242, 20260915, 555001]
const TICK_BUDGET := 1500

var _failed := false

func _init() -> void:
	for world_seed in SEEDS:
		_check_chop_leaves_soil(world_seed)
	if _failed:
		quit(1)
		return
	print("test_chop_tile_kind: PASS")
	quit(0)

func _check_chop_leaves_soil(world_seed: int) -> void:
	var world := WorldStateType.new(world_seed)
	var colonist: Dictionary = world.get_colonists()[0]
	var origin := TileGrid.tile_of(colonist)
	world.spawn_ground_tool_item("axe", origin.x, origin.y)
	var tree := _nearest_tree(world, origin)
	_expect(tree != Vector3i(-1, -1, 0), "seed %d: the generated map must have a tree" % world_seed)
	if tree == Vector3i(-1, -1, 0):
		return
	var result: Dictionary = world.apply({"actor": "test", "command_id": "chop_%d" % world_seed,
		"tick": world.get_tick(), "type": "chop", "payload": {"x": tree.x, "y": tree.y, "z": 0, "priority": 1}})
	_expect(bool(result.get("ok", false)), "seed %d: chop must be accepted: %s" % [world_seed, result])
	var ticks := 0
	while ticks < TICK_BUDGET and world.get_tile(tree.x, tree.y) == WorldStateType.TILE_TREE:
		# Needs topped up so only the chop order runs (see test_new_game_dig_chop.gd).
		for actor in TestAccess.colonists(world):
			for kind in (actor["needs"] as Dictionary).keys():
				actor["needs"][kind] = 100
		world.tick()
		ticks += 1
	var after := world.get_tile(tree.x, tree.y)
	_expect(after == WorldStateType.TILE_SOIL,
		"seed %d: chopped tree at (%d, %d) must become soil, got '%s' after %d ticks" % [world_seed, tree.x, tree.y, after, ticks])
	_expect(world.get_ground_wood(tree.x, tree.y) == 1, "seed %d: chop must still leave exactly one ground wood" % world_seed)
	_expect((world.get_dirty_cells_since(0)["cells"] as Array).has(tree), "seed %d: the chopped tile must be marked dirty so the viewer repaints it" % world_seed)
	var till: Dictionary = world.apply({"actor": "test", "command_id": "till_%d" % world_seed,
		"tick": world.get_tick(), "type": "till", "payload": {"x": tree.x, "y": tree.y, "z": 0, "priority": 1}})
	_expect(bool(till.get("ok", false)), "seed %d: a chopped tile is soil, so till on it must be accepted: %s" % [world_seed, till])

## Nearest tree to `from` in Chebyshev rings (ties by row-major order).
func _nearest_tree(world: WorldStateType, from: Vector3i) -> Vector3i:
	for radius in range(0, maxi(world.get_map_width(), world.get_map_height())):
		for y in range(from.y - radius, from.y + radius + 1):
			for x in range(from.x - radius, from.x + radius + 1):
				if maxi(absi(x - from.x), absi(y - from.y)) != radius:
					continue
				if x < 0 or y < 0 or x >= world.get_map_width() or y >= world.get_map_height():
					continue
				if world.get_tile(x, y) == WorldStateType.TILE_TREE:
					return Vector3i(x, y, 0)
	return Vector3i(-1, -1, 0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
