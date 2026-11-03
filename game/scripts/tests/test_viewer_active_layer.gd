extends SceneTree

## L4 (ADR 045 §7, ADR 069): the viewer draws one active layer. A headless two-layer world
## renders the surface slice on layer 0 and the deeper slice on layer 1 (tiles and colonists);
## switching is viewer state only, so state_hash() never moves; commands built while a layer is
## active carry that layer as their z; set_active_layer() clamps and emits layer_changed.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const OrderInputType = preload("res://scripts/viewer/order_input.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

const SIZE := 16

var _failed := false
var _emitted: Array[int] = []

func _init() -> void:
	var world := _two_layer_world()
	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_world(world)
	map_view.layer_changed.connect(func(z: int): _emitted.append(z))
	var hash_before := world.state_hash()

	_expect(map_view.layer_count() == 2, "a two-layer world must report two layers, got %d" % map_view.layer_count())
	_expect(map_view.active_layer == 0, "set_world() must start on the surface")
	_check_slice(map_view, world, 0)
	var colonists := _colonist_ids(world)
	var deep_id: String = colonists[0]
	_expect(not _drawn_colonists(map_view).has(deep_id), "a colonist on layer 1 must not be drawn on layer 0")
	_expect(_drawn_colonists(map_view).has(colonists[1]), "a surface colonist must be drawn on layer 0")

	map_view.set_active_layer(1)
	_expect(map_view.active_layer == 1, "set_active_layer(1) must switch to layer 1")
	_check_slice(map_view, world, 1)
	_expect(_drawn_colonists(map_view).keys() == [deep_id], "only the layer-1 colonist must be drawn on layer 1, got %s" % [_drawn_colonists(map_view).keys()])
	_expect(world.state_hash() == hash_before, "switching layers must not change state_hash()")

	var dig := OrderInputType.command_for_tile(world, map_view, OrderInputType.Tool.DIG, Vector2i(3, 3))
	_expect(int(dig.get("payload", {}).get("z", -1)) == 1, "a command built on layer 1 must carry z 1, got %s" % [dig])

	map_view.step_layer(1)
	_expect(map_view.active_layer == 1, "stepping past the last layer must clamp")
	map_view.set_active_layer(-5)
	_expect(map_view.active_layer == 0, "a negative layer must clamp to the surface")
	_check_slice(map_view, world, 0)
	_expect(world.state_hash() == hash_before, "switching back must not change state_hash()")
	_expect(_emitted == [1, 0], "layer_changed must fire once per actual switch, got %s" % [_emitted])

	map_view.set_active_layer(1)
	map_view.set_world(_two_layer_world())
	_expect(map_view.active_layer == 0, "a new world must reset the active layer to the surface")

	map_view.queue_free()
	_finish()

## The default small world with a second layer of rock (a 4x4 floor room at (2..5, 2..5)) and
## its first colonist moved down to (3, 3, 1).
func _two_layer_world() -> WorldStateType:
	var state := WorldStateType.new(451_002, 10, SIZE, SIZE).to_save_state()
	state["map"]["layerCount"] = 2
	var deep: Array = []
	for y in SIZE:
		for x in SIZE:
			deep.append(WorldStateType.TILE_FLOOR if x >= 2 and x <= 5 and y >= 2 and y <= 5 else WorldStateType.TILE_ROCK)
	(state["map"]["tiles"] as Array).append_array(deep)
	for entity: Dictionary in state["entities"]:
		if String(entity.get("kind", "")) == "colonist":
			entity["x"] = 3
			entity["y"] = 3
			entity["z"] = 1
			break
	var world = WorldStateType.from_save_state(state)
	_expect(world != null and world is WorldStateType, "the two-layer save must load")
	return world

## Every drawn cell of layer `z` matches that layer's tile in get_tiles().
func _check_slice(map_view: MapViewType, world: WorldStateType, z: int) -> void:
	var layer = map_view.get("_tile_map_layer")
	var tiles: Array[String] = world.get_tiles()
	var mismatches := 0
	for y in SIZE:
		for x in SIZE:
			var kind := tiles[z * SIZE * SIZE + y * SIZE + x]
			var atlas = TileAtlasMapType.TILE_ATLAS_MAP.get(kind)
			var cell := Vector2i(x, y)
			var ok: bool
			if atlas == null:
				ok = layer.get_cell_source_id(cell) == -1
			elif kind == WorldStateType.TILE_SOIL:
				# Soil is a hash-picked variant, or an edge transition next to water/rock (any drawn cell).
				ok = layer.get_cell_source_id(cell) != -1
			else:
				ok = layer.get_cell_source_id(cell) == int(atlas["source_id"]) and layer.get_cell_atlas_coords(cell) == atlas["coords"]
			if not ok:
				mismatches += 1
	_expect(mismatches == 0, "layer %d: %d drawn cells do not match the layer's tiles" % [z, mismatches])

func _colonist_ids(world: WorldStateType) -> Array:
	var ids := []
	for colonist in world.get_colonists():
		ids.append(String(colonist["id"]))
	ids.sort()
	var deep := ""
	for colonist in world.get_colonists():
		if int(colonist.get("z", 0)) == 1:
			deep = String(colonist["id"])
	_expect(deep != "" and ids.size() >= 2, "the fixture needs one deep colonist and a surface one")
	ids.erase(deep)
	ids.push_front(deep)
	return ids

func _drawn_colonists(map_view: MapViewType) -> Dictionary:
	return (map_view.get("_colonist_sprites") as Node).get("_sprites")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _finish() -> void:
	print("test_viewer_active_layer: %s" % ("FAIL" if _failed else "PASS"))
	quit(1 if _failed else 0)
