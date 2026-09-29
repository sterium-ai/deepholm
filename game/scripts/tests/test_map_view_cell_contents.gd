extends SceneTree

## Issue #299 round 1 review: proves the TileMapLayer renderer (the default
## production presentation path since this round, see map_view.gd's
## _art_enabled doc comment) actually reflects dig/chop/build in its rendered
## cell contents, not just an internal touch counter, and that replacing the
## attached world invalidates any stale cell content from the world just
## replaced instead of leaving it on screen.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

const SEED_A := 424242
const SEED_B := 909191
const TICK_BUDGET := 600

var _failed := false

func _init() -> void:
	_check_ground_item_counts()
	var world := WorldStateType.new(SEED_A)
	_give_starting_tools(world)
	var map_view := MapViewType.new()
	root.add_child(map_view)
	_expect(map_view.is_art_enabled(), "map_view.gd's TileMapLayer renderer must be enabled by default (issue #299 round 1: production presentation, not an instrumentation-only opt-in)")
	map_view.set_world(world)

	var colonist_tiles: Array[Vector2i] = []
	for colonist in world.get_colonists():
		colonist_tiles.append(Vector2i(int(colonist["x"]), int(colonist["y"])))

	var dig_target := _find_tile(world, "soil", colonist_tiles)
	_expect(dig_target != Vector2i(-1, -1), "fixture must have a soil tile to dig")
	var chop_target := _find_tile(world, "tree", colonist_tiles)
	_expect(chop_target != Vector2i(-1, -1), "fixture must have a tree tile to chop")
	var build_excluded: Array[Vector2i] = colonist_tiles.duplicate()
	build_excluded.append(dig_target)
	build_excluded.append(chop_target)
	var build_target := _find_tile(world, "floor", build_excluded, true)
	_expect(build_target != Vector2i(-1, -1), "fixture must have a free floor tile to build on")
	if dig_target == Vector2i(-1, -1) or chop_target == Vector2i(-1, -1) or build_target == Vector2i(-1, -1):
		_finish()
		return

	_run_job_to_completion(world, "dig", dig_target)
	_expect(world.get_tile(dig_target.x, dig_target.y) == "trench", "a completed dig must turn its target to trench")
	map_view.refresh()
	# ADR 025 presentation extension: trench now has its own atlas mapping; the
	# rendered cell must update instead of leaving stale soil content behind.
	_assert_tile_cell_matches(map_view, dig_target, "trench")

	_run_job_to_completion(world, "chop", chop_target)
	_expect(world.get_tile(chop_target.x, chop_target.y) == "floor", "a completed chop must turn its target to floor")
	map_view.refresh()
	_assert_tile_cell_matches(map_view, chop_target, "floor")

	# issue #449: content/objects.json's "wall" row (this test's own former
	# build target) was replaced by "wooden_wall"/"stone_wall";
	# tile_atlas_map.gd's OBJECT_ATLAS_MAP now maps "wooden_wall" onto the
	# same SOURCE_WALL art the retired "wall" id used, so this assertion
	# keeps exercising the real wall crop rather than switching targets.
	var build_result: Dictionary = world.apply({
		"actor": "test", "command_id": "build_wall", "tick": world.get_tick(),
		"type": "place_object", "payload": {"x": build_target.x, "y": build_target.y, "kind": "wooden_wall"},
	})
	_expect(build_result.get("ok", false), "place_object on a free floor tile must be accepted: %s" % build_result)
	_expect(world.get_object(build_target.x, build_target.y) == "wooden_wall", "a committed place_object must place the object on the world")
	map_view.refresh()
	_assert_object_cell_matches(map_view, build_target, "wooden_wall")

	# Replacing the world must invalidate every stale cell the previous world
	# left behind, not just bump a touch counter (round 1 review): the cells
	# this test just dug/chopped/built on must reflect the newly attached
	# world's own actual terrain/object at those same coordinates, whatever
	# that happens to be, rather than the replaced world's leftover content.
	var world_b := WorldStateType.new(SEED_B)
	map_view.set_world(world_b)
	var expected_full := world_b.get_map_width() * world_b.get_map_height() + world_b.get_objects().size()
	_expect(map_view.last_tile_map_cells_touched == expected_full,
		"set_world() on a replacement world must fully rebuild every cell (expected %d, got %d)"
			% [expected_full, map_view.last_tile_map_cells_touched])
	_assert_tile_cell_matches(map_view, dig_target, world_b.get_tile(dig_target.x, dig_target.y))
	_assert_tile_cell_matches(map_view, chop_target, world_b.get_tile(chop_target.x, chop_target.y))
	_assert_object_cell_matches(map_view, build_target, world_b.get_object(build_target.x, build_target.y))

	_finish()

## Mirrors boot.gd's _spawn_starting_tools() at test scale: every job kind
## needing a tool gets one placed at a real colonist's own starting tile (not
## the map origin -- issue #300: the spawn clearing is chosen dynamically,
## see docs/decisions/020, and need not be anywhere near (0, 0)) so dig/chop
## can actually run to completion here instead of sitting blocked_no_tool or
## spending the whole tick budget just walking to fetch a tool.
func _give_starting_tools(world: WorldStateType) -> void:
	var colonist: Dictionary = world.get_colonists()[0]
	world.spawn_ground_tool_item("pick", int(colonist["x"]), int(colonist["y"]))
	world.spawn_ground_tool_item("axe", int(colonist["x"]), int(colonist["y"]))

func _run_job_to_completion(world: WorldStateType, job_type: String, target: Vector2i) -> void:
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "%s_%d_%d" % [job_type, target.x, target.y], "tick": world.get_tick(),
		"type": job_type, "payload": {"x": target.x, "y": target.y, "priority": 1},
	})
	_expect(result.get("ok", false), "%s command must be accepted: %s" % [job_type, result])
	var ticks := 0
	while ticks < TICK_BUDGET and world.get_tile(target.x, target.y) not in ["floor", "trench"]:
		# Keeps needs topped up so this stays a test of rendered cell content,
		# not of need-decay pressure: with real decay, colonists spend so much
		# time servicing recurring eat/drink/sleep jobs that an ordinary
		# order can sit queued for thousands of ticks (see test_save_dimensions.gd's
		# far-edge check for the same fixture behavior spelled out in full).
		for colonist in world._colonists:
			var needs: Dictionary = colonist["needs"]
			for kind in needs.keys():
				needs[kind] = 100
		world.tick()
		ticks += 1
	_expect(ticks < TICK_BUDGET, "%s at (%d, %d) must complete within %d ticks" % [job_type, target.x, target.y, TICK_BUDGET])

func _assert_tile_cell_matches(map_view: MapViewType, tile: Vector2i, kind: String) -> void:
	var atlas = TileAtlasMapType.TILE_ATLAS_MAP.get(kind)
	var layer = map_view.get("_tile_map_layer")
	if atlas == null:
		_expect(layer.get_cell_source_id(tile) == -1, "tile (%d, %d) with no atlas mapping must be an empty cell" % [tile.x, tile.y])
		return
	# issue #301: TILE_SOIL renders one of several hash-selected prairie
	# variants (never the single fixed default), so a soil tile only needs
	# to match ONE registered variant, not TILE_ATLAS_MAP's own default entry.
	if kind == WorldStateType.TILE_SOIL:
		var rendered_coords: Vector2i = layer.get_cell_atlas_coords(tile)
		_expect(layer.get_cell_source_id(tile) == int(atlas["source_id"]) and rendered_coords in TileAtlasMapType.TILE_SOIL_VARIANTS,
			"rendered soil tile at (%d, %d) must match one of TILE_SOIL_VARIANTS, got source %d coords %s"
				% [tile.x, tile.y, layer.get_cell_source_id(tile), rendered_coords])
		return
	_expect(layer.get_cell_source_id(tile) == int(atlas["source_id"]) and layer.get_cell_atlas_coords(tile) == atlas["coords"],
		"rendered tile cell at (%d, %d) must match the '%s' atlas mapping, got source %d coords %s"
			% [tile.x, tile.y, kind, layer.get_cell_source_id(tile), layer.get_cell_atlas_coords(tile)])

func _assert_object_cell_matches(map_view: MapViewType, tile: Vector2i, kind: String) -> void:
	var layer = map_view.get("_object_tile_map_layer")
	if kind.is_empty():
		_expect(layer.get_cell_source_id(tile) == -1, "object cell at (%d, %d) with no object must be empty" % [tile.x, tile.y])
		return
	var atlas = TileAtlasMapType.OBJECT_ATLAS_MAP.get(kind)
	_expect(atlas != null, "test fixture object kind '%s' must have an atlas mapping" % kind)
	if atlas == null:
		return
	_expect(layer.get_cell_source_id(tile) == int(atlas["source_id"]) and layer.get_cell_atlas_coords(tile) == atlas["coords"],
		"rendered object cell at (%d, %d) must match the '%s' atlas mapping, got source %d coords %s"
			% [tile.x, tile.y, kind, layer.get_cell_source_id(tile), layer.get_cell_atlas_coords(tile)])

## `reverse` searches from the far corner inward (used for build_target, kept
## away from the spawn area colonists actually move around in during the
## dig/chop ticking above, to avoid a colonist wandering onto it before the
## place_object command runs) -- distance from spawn is irrelevant there since
## place_object applies instantly, no travel/job involved.
##
## The non-reverse search instead expands in Chebyshev rings from a real
## colonist's own tile (issue #300: the spawn clearing is chosen dynamically,
## not always near the map origin -- docs/decisions/020), so a dig/chop target
## this test then runs to completion under TICK_BUDGET stays a short,
## reliable walk regardless of where on the map spawn actually landed.
func _find_tile(world: WorldStateType, kind: String, excluded: Array[Vector2i] = [], reverse: bool = false) -> Vector2i:
	var width := world.get_map_width()
	var height := world.get_map_height()
	if reverse:
		for y in range(height - 1, -1, -1):
			for x in range(width - 1, -1, -1):
				var tile := Vector2i(x, y)
				if world.get_tile(x, y) == kind and world.get_object(x, y) == "" and not excluded.has(tile):
					return tile
		return Vector2i(-1, -1)
	var origin := Vector2i(int(world.get_colonists()[0]["x"]), int(world.get_colonists()[0]["y"]))
	var max_radius := maxi(width, height)
	for radius in range(0, max_radius + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				var tile := Vector2i(x, y)
				if world.get_tile(x, y) == kind and world.get_object(x, y) == "" and not excluded.has(tile):
					return tile
	return Vector2i(-1, -1)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _finish() -> void:
	if _failed:
		quit(1)
		return
	print("test_map_view_cell_contents: PASS")
	quit()

## Multiple stacks and kinds at one cell must aggregate independently; cargo
## lives on the colonist and is excluded from the ground-item snapshot.
func _check_ground_item_counts() -> void:
	var world := WorldStateType.new(SEED_A, 10)
	world._items.clear()
	world._items["wood_a"] = {"id": "wood_a", "x": 2, "y": 3, "kind": "wood", "count": 2}
	world._items["wood_b"] = {"id": "wood_b", "x": 2, "y": 3, "kind": "wood", "count": 3}
	world._items["stone_a"] = {"id": "stone_a", "x": 2, "y": 3, "kind": "stone", "count": 4}
	world._items["stone_b"] = {"id": "stone_b", "x": 4, "y": 3, "kind": "stone", "count": 7}
	world._colonists[0]["carrying"] = {"id": "cargo", "kind": "stone", "count": 9}
	var view := MapViewType.new()
	view.set_world(world)
	var before := world.state_hash()
	for art_enabled in [true, false]:
		view.set_art_enabled(art_enabled)
		var counts: Dictionary = view._ground_item_counts()
		_expect(counts[Vector2i(2, 3)] == {"wood": 5, "stone": 4}, "mixed-cell stacks must sum separately by item kind")
		_expect(counts[Vector2i(4, 3)] == {"stone": 7}, "stone in another cell must stay separate")
		_expect(counts.size() == 2, "carried cargo must not become a ground count")
	_expect(world.state_hash() == before, "item rendering and art toggles must not mutate simulation")
	_expect(MapViewType.GROUND_ITEM_COLORS["stone"] != MapViewType.GROUND_ITEM_COLORS["wood"], "flat diagnostic stone must be distinct from wood")
	view.free()
