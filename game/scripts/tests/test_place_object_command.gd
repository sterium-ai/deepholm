extends SceneTree

## Exercises WorldState.apply()'s place_object/remove_object commands: both
## apply immediately (no job queue), validated against the same
## passability()/object storage as test_passability.gd and
## test_object_storage.gd. Also proves end-to-end interaction with the
## passability rule: a wall placed via
## place_object blocks a subsequent dig, mirroring test_passability.gd's
## _check_dig_rejects_blocked_object() but reached through the command path.

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_place_object_valid()
	_check_place_object_rejects_colonist_tile()
	_check_place_object_rejects_tree_tile()
	_check_place_object_rejects_occupied_tile()
	_check_place_object_rejects_out_of_bounds()
	_check_place_object_rejects_unknown_kind()
	_check_remove_object_rejects_empty_tile()
	_check_remove_object_rejects_out_of_bounds()
	_check_remove_object_succeeds()
	_check_place_wall_blocks_dig()
	_check_place_object_footprint_occupies_both_tiles()
	_check_place_object_footprint_rejects_overlap_on_second_tile()
	_check_place_object_footprint_rejects_tree_on_second_tile()
	_check_place_object_footprint_rejects_water_on_second_tile()
	_check_place_object_footprint_rejects_colonist_on_second_tile()
	_check_place_object_footprint_rejects_out_of_bounds()
	_check_place_object_rejects_water_tile()

	if _failed:
		quit(1)
		return
	print("test_place_object_command: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _place_command(world: WorldStateType, command_id: String, x: int, y: int, kind: String, orientation: String = "") -> Dictionary:
	var payload := {"x": x, "y": y, "kind": kind}
	if not orientation.is_empty():
		payload["orientation"] = orientation
	return world.apply({
		"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "place_object", "payload": payload,
	})

func _remove_command(world: WorldStateType, command_id: String, x: int, y: int) -> Dictionary:
	return world.apply({
		"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "remove_object", "payload": {"x": x, "y": y},
	})

## Skips any tile a colonist already stands on: several checks below place an
## object on the returned tile, which place_object always rejects for a
## colonist's own tile (see _check_place_object_rejects_colonist_tile), so a
## tile search for "some placeable tile of this kind" must exclude that case
## rather than returning one at random depending on where map generation put
## the colonists for a given seed.
func _find_tile(world: WorldStateType, kind: String) -> Vector2i:
	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			if world.get_tile(x, y) == kind and not world._colonist_at(x, y):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _check_place_object_valid() -> void:
	if _failed:
		return
	var world := WorldStateType.new(1, 10)
	var tile := _find_tile(world, WorldStateType.TILE_FLOOR)
	var result := _place_command(world, "place_valid", tile.x, tile.y, "chair")
	_expect(result.get("ok", false), "a valid place_object must be accepted")
	_expect(world.get_object(tile.x, tile.y) == "chair", "get_object() must report the placed kind")
	_expect(world.get_object_faction_id(tile.x, tile.y) == "colony",
		"a freshly placed object must default to faction_id 'colony'")
	# get_objects() can also list generator-placed berry_bush
	# entries (ADR 020), so this looks up the specific entry just
	# placed rather than assuming it is the only (or the first) one.
	var placed_entry := {}
	for entry in world.get_objects():
		if int(entry["x"]) == tile.x and int(entry["y"]) == tile.y:
			placed_entry = entry
	_expect(not placed_entry.is_empty() and placed_entry["kind"] == "chair" and placed_entry["faction_id"] == "colony",
		"get_objects() must report the placed object's faction_id as 'colony'")

func _check_place_object_rejects_colonist_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(2, 10)
	var colonist: Dictionary = world.get_colonists()[0]
	var result := _place_command(world, "place_colonist", colonist["x"], colonist["y"], "chair")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object on a colonist's own tile must be rejected invalid_target")

func _check_place_object_rejects_tree_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(3, 10)
	var tile := _find_tile(world, WorldStateType.TILE_TREE)
	var result := _place_command(world, "place_tree", tile.x, tile.y, "chair")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object on a tree tile must be rejected invalid_target")

func _check_place_object_rejects_occupied_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4, 10)
	var tile := _find_tile(world, WorldStateType.TILE_FLOOR)
	var first := _place_command(world, "place_first", tile.x, tile.y, "chair")
	_expect(first.get("ok", false), "the first place_object on an empty tile must be accepted")
	var second := _place_command(world, "place_second", tile.x, tile.y, "table")
	_expect(not second.get("ok", true) and second["rejection"]["reason"] == "invalid_target",
		"place_object on a tile that already holds an object must be rejected invalid_target")

func _check_place_object_rejects_out_of_bounds() -> void:
	if _failed:
		return
	var world := WorldStateType.new(5, 10)
	var result := _place_command(world, "place_oob", -1, 0, "chair")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object out of bounds must be rejected invalid_target")

func _check_place_object_rejects_unknown_kind() -> void:
	if _failed:
		return
	var world := WorldStateType.new(6, 10)
	var tile := _find_tile(world, WorldStateType.TILE_FLOOR)
	var result := _place_command(world, "place_unknown", tile.x, tile.y, "spaceship")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"place_object with an unknown kind must be rejected invalid_payload")

func _check_remove_object_rejects_empty_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(7, 10)
	var tile := _find_tile(world, WorldStateType.TILE_FLOOR)
	var result := _remove_command(world, "remove_empty", tile.x, tile.y)
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"remove_object on an empty tile must be rejected invalid_target")

func _check_remove_object_rejects_out_of_bounds() -> void:
	if _failed:
		return
	var world := WorldStateType.new(75, 10)
	var result := _remove_command(world, "remove_oob", -1, 0)
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"remove_object out of bounds must be rejected invalid_target")

func _check_remove_object_succeeds() -> void:
	if _failed:
		return
	var world := WorldStateType.new(8, 10)
	var tile := _find_tile(world, WorldStateType.TILE_FLOOR)
	var place_result := _place_command(world, "remove_setup", tile.x, tile.y, "chair")
	_expect(place_result.get("ok", false), "setup place_object must succeed")
	var remove_result := _remove_command(world, "remove_success", tile.x, tile.y)
	_expect(remove_result.get("ok", false), "remove_object on a placed object must be accepted")
	_expect(world.get_object(tile.x, tile.y) == "", "get_object() must return \"\" after removal")

func _check_place_wall_blocks_dig() -> void:
	if _failed:
		return
	var world := WorldStateType.new(9, 10)
	var tile := _find_tile(world, WorldStateType.TILE_SOIL)
	var place_result := _place_command(world, "wall_setup", tile.x, tile.y, "wooden_wall")
	_expect(place_result.get("ok", false), "placing a wall on a soil tile must be accepted")
	var dig_result: Dictionary = world.apply({
		"actor": "player", "command_id": "dig_after_wall", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": tile.x, "y": tile.y, "priority": 1},
	})
	_expect(not dig_result.get("ok", true) and dig_result["rejection"]["reason"] == "invalid_target",
		"dig on a tile with a placed wall must be rejected invalid_target")

## Two adjacent TILE_FLOOR tiles with no colonist standing on either, for the
## footprint checks below -- content/objects.json's "test_footprint_crate"
## (footprint [2, 1], rotatable, impassable) placed "horizontal" needs an
## origin tile and its +x neighbour both free.
func _find_floor_pair(world: WorldStateType) -> Vector2i:
	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH - 1:
			if (world.get_tile(x, y) == WorldStateType.TILE_FLOOR and world.get_tile(x + 1, y) == WorldStateType.TILE_FLOOR
					and not world._colonist_at(x, y) and not world._colonist_at(x + 1, y)):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## A [2, 1] footprint placed "horizontal" must occupy both its
## origin and its +x neighbour, each independently impassable and each
## reporting the placed kind from get_object().
func _check_place_object_footprint_occupies_both_tiles() -> void:
	if _failed:
		return
	var world := WorldStateType.new(10, 10)
	var origin := _find_floor_pair(world)
	var result := _place_command(world, "footprint_valid", origin.x, origin.y, "test_footprint_crate", "horizontal")
	_expect(result.get("ok", false), "a valid footprint place_object must be accepted")
	_expect(world.get_object(origin.x, origin.y) == "test_footprint_crate", "get_object() must report the placed kind at the origin tile")
	_expect(world.get_object(origin.x + 1, origin.y) == "test_footprint_crate", "get_object() must report the placed kind at the second footprint tile")
	_expect(not bool(world.passability(origin.x, origin.y)["passable"]), "the origin footprint tile must be impassable")
	_expect(not bool(world.passability(origin.x + 1, origin.y)["passable"]), "the second footprint tile must be impassable")

## An object already occupying the second footprint tile (not the
## origin) must still reject the whole placement invalid_target -- the exact
## reason single-tile placement already uses for an occupied tile.
func _check_place_object_footprint_rejects_overlap_on_second_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(11, 10)
	var origin := _find_floor_pair(world)
	var setup := _place_command(world, "footprint_overlap_setup", origin.x + 1, origin.y, "chair")
	_expect(setup.get("ok", false), "setup place_object on the second footprint tile must succeed")
	var result := _place_command(world, "footprint_overlap", origin.x, origin.y, "test_footprint_crate", "horizontal")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object whose second footprint tile is already occupied must be rejected invalid_target")

## A tree on the second footprint tile must reject the whole
## placement invalid_target, the exact reason single-tile placement already
## uses for a tree tile. A map-generation search for a
## naturally-occurring floor/tree pair could silently find none and skip this
## case entirely, so this forces the fixture deterministically instead --
## _find_floor_pair() guarantees an adjacent floor pair, then the second tile
## is overwritten to TILE_TREE directly (the same world._tiles[...] pattern
## test_build.gd already uses to force terrain for a fixture).
func _check_place_object_footprint_rejects_tree_on_second_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(12, 10)
	var origin := _find_floor_pair(world)
	world._tiles[world._tile_index(origin.x + 1, origin.y)] = WorldStateType.TILE_TREE
	var result := _place_command(world, "footprint_tree", origin.x, origin.y, "test_footprint_crate", "horizontal")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object whose second footprint tile is a tree must be rejected invalid_target")

## Water on the second footprint tile must
## reject the whole placement invalid_target, the exact reason single-tile
## placement uses for a water tile (_check_place_object_rejects_water_tile
## below). Forces the fixture deterministically like the tree case above,
## rather than searching this seed's map for a naturally-occurring pair.
func _check_place_object_footprint_rejects_water_on_second_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(15, 10)
	var origin := _find_floor_pair(world)
	world._tiles[world._tile_index(origin.x + 1, origin.y)] = WorldStateType.TILE_WATER
	var result := _place_command(world, "footprint_water", origin.x, origin.y, "test_footprint_crate", "horizontal")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object whose second footprint tile is water must be rejected invalid_target")

## A single-tile place_object directly on a
## water tile must be rejected invalid_target, the same reason a tree or
## occupied tile already uses -- water is never a valid place_object target.
## Forces the fixture deterministically (a floor tile from _find_tile()
## overwritten to TILE_WATER) rather than depending on this seed's map
## containing a water tile.
func _check_place_object_rejects_water_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(16, 10)
	var tile := _find_tile(world, WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(tile.x, tile.y)] = WorldStateType.TILE_WATER
	var result := _place_command(world, "place_water", tile.x, tile.y, "chair")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object on a water tile must be rejected invalid_target")

## A colonist standing on the second footprint
## tile must reject the whole placement invalid_target, the exact reason
## single-tile placement already uses for a colonist's own tile. Forces the
## fixture deterministically -- _find_floor_pair() guarantees an adjacent
## floor pair, then the first colonist is moved onto the second tile
## directly (the same world._colonists[0]["x"]/["y"] pattern
## test_colonist_sprites.gd already uses) -- rather than depending on this
## seed's colonist already standing next to a floor tile.
func _check_place_object_footprint_rejects_colonist_on_second_tile() -> void:
	if _failed:
		return
	var world := WorldStateType.new(13, 10)
	var origin := _find_floor_pair(world)
	world._colonists[0]["x"] = origin.x + 1
	world._colonists[0]["y"] = origin.y
	var result := _place_command(world, "footprint_colonist", origin.x, origin.y, "test_footprint_crate", "horizontal")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"place_object whose second footprint tile holds a colonist must be rejected invalid_target")

## A footprint that would extend past the map's right edge must
## reject the whole placement invalid_target, the exact reason single-tile
## placement already uses for an out-of-bounds tile.
func _check_place_object_footprint_rejects_out_of_bounds() -> void:
	if _failed:
		return
	var world := WorldStateType.new(14, 10)
	var result := _place_command(world, "footprint_oob", WorldStateType.MAP_WIDTH - 1, 0, "test_footprint_crate", "horizontal")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"a footprint place_object that would extend out of bounds must be rejected invalid_target")
