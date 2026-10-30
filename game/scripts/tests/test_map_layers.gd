extends SceneTree

## L2 (ADR 045 §1, §2, §5, §6): tiles are Vector3i(x, y, z) with one flat index across layers,
## z outermost, so layer 0 keeps its row-major indices and its String key formats; a deeper
## layer's keys carry the layer. At the command boundary a payload without "z" means the
## surface, and an out-of-range "z" is rejected like an out-of-map x/y (invalid_target, preview
## agreeing with apply()). A save whose "z" or layerCount does not fit the map is a schema_error.

const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _failed := false
var _next_command := 0

func _init() -> void:
	_check_flat_index_across_layers()
	_check_keys_carry_deeper_layers()
	_check_missing_z_means_the_surface()
	_check_out_of_range_z_is_an_out_of_map_tile()
	_check_save_rejects_tiles_off_the_layers()
	if _failed:
		quit(1)
		return
	print("test_map_layers: PASS")
	quit()

## index = z * width * height + y * width + x; coord_of() inverts it on every layer, and
## contains() admits exactly 0 <= z < layer_count.
func _check_flat_index_across_layers() -> void:
	var grid := TileGridType.new(7, 5, Callable(), Callable())
	grid.layer_count = 3
	_expect(grid.layer_size() == 35, "layer_size() = %d, want 35" % grid.layer_size())
	for z in 3:
		for y in 5:
			for x in 7:
				var tile := Vector3i(x, y, z)
				var index := grid.index_of(tile)
				_expect(index == z * 35 + y * 7 + x, "index_of(%s) = %d, want %d" % [tile, index, z * 35 + y * 7 + x])
				_expect(grid.coord_of(index) == tile, "coord_of(%d) = %s, want %s" % [index, grid.coord_of(index), tile])
				_expect(grid.contains(tile), "%s must be a map tile" % tile)
	_expect(grid.index_of(Vector3i(6, 4, 0)) == TileGridType.flat_index(6, 4, 7), "layer 0 must keep its row-major indices")
	_expect(grid.bounds_max() == Vector3i(6, 4, 2), "bounds_max() = %s, want (6, 4, 2)" % grid.bounds_max())
	for outside: Vector3i in [Vector3i(0, 0, 3), Vector3i(0, 0, -1), Vector3i(7, 0, 0), Vector3i(0, 5, 1)]:
		_expect(not grid.contains(outside), "%s must not be a map tile" % outside)

## Surface keys are byte for byte L1's; a deeper tile appends its layer, and the inverses read both.
func _check_keys_carry_deeper_layers() -> void:
	var surface := Vector3i(12, 3, 0)
	var deep := Vector3i(12, 3, 2)
	_expect(TileGridType.coord_key(surface) == "12_3" and TileGridType.coord_key(deep) == "12_3_2",
		"coord_key() = %s / %s" % [TileGridType.coord_key(surface), TileGridType.coord_key(deep)])
	_expect(TileGridType.target_key(deep) == "tile:12,3,2" and TileGridType.cell_key(deep) == "cell:12,3,2",
		"target_key()/cell_key() of a deeper tile = %s / %s" % [TileGridType.target_key(deep), TileGridType.cell_key(deep)])
	_expect(TileGridType.comma_key(surface) == "12,3" and TileGridType.comma_key(deep) == "12,3,2",
		"comma_key() = %s / %s" % [TileGridType.comma_key(surface), TileGridType.comma_key(deep)])
	for tile: Vector3i in [surface, deep]:
		_expect(TileGridType.coord_of_key(TileGridType.coord_key(tile)) == tile, "coord_of_key() must invert coord_key() for %s" % tile)
		_expect(TileGridType.coord_of_comma_key(TileGridType.comma_key(tile)) == tile,
			"coord_of_comma_key() must invert comma_key() for %s" % tile)
	_expect(TileGridType.coord_key(surface) != TileGridType.coord_key(deep), "two layers must never share a key")

## A dig without "z" is a surface order: the job's target is Vector3i(x, y, 0), the command
## carries the filled "z", and preview() agrees with apply().
func _check_missing_z_means_the_surface() -> void:
	var world := _world()
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
	var command := _command(world, "dig", {"x": 2, "y": 0, "priority": 1})
	var preview := world.preview(command.duplicate(true))
	var result := world.apply(command)
	_expect(preview.get("ok", false) and result.get("ok", false), "a dig without z must be accepted: %s / %s" % [preview, result])
	_expect(int(command["payload"].get("z", -1)) == TileGridType.SURFACE, "the boundary must fill the missing z with the surface")
	var targets: Array = []
	for job in world.get_jobs():
		targets.append(job["target"])
	_expect(targets == [Vector3i(2, 0, 0)], "the dig's target must be the surface tile, got %s" % [targets])

## z = layer_count or z < 0 fails like x = -1: invalid_target, before the command's own rules,
## and preview() rejects with the same reason; a non-int z is invalid_payload. build_line tiles
## and zones are checked the same way.
func _check_out_of_range_z_is_an_out_of_map_tile() -> void:
	var cases := [
		["dig", {"x": 2, "y": 0, "z": 1, "priority": 1}, "invalid_target"],
		["dig", {"x": 2, "y": 0, "z": -1, "priority": 1}, "invalid_target"],
		["dig", {"x": 2, "y": 0, "z": "0", "priority": 1}, "invalid_payload"],
		["zone_add", {"x": 1, "y": 1, "z": 1, "width": 2, "height": 2}, "invalid_target"],
		["place_object", {"x": 1, "y": 1, "z": 3, "kind": "chair"}, "invalid_target"],
		["build_line", {"kind": "wooden_wall", "tiles": [{"x": 1, "y": 1}, {"x": 2, "y": 1, "z": 1}]}, "invalid_target"],
	]
	for case: Array in cases:
		var world := _world()
		TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
		var hash_before := world.state_hash()
		var command := _command(world, case[0], case[1])
		var preview := world.preview(command.duplicate(true))
		var result := world.apply(command)
		var reason := String(result.get("rejection", {}).get("reason", ""))
		var preview_reason := String(preview.get("rejection", {}).get("reason", ""))
		_expect(not result.get("ok", true) and reason == case[2],
			"%s %s must be rejected as %s, got %s" % [case[0], case[1], case[2], result])
		_expect(not preview.get("ok", true) and preview_reason == reason,
			"preview() of %s %s must agree with apply(), got %s" % [case[0], case[1], preview])
		_expect(world.get_jobs().is_empty() and world.get_zones().is_empty() and world.get_object(1, 1).is_empty(),
			"a rejected %s must change nothing" % case[0])
		_expect(world.state_hash() == hash_before, "a rejected %s must keep the state_hash" % case[0])
	var oob := _world()
	var off_map := oob.apply(_command(oob, "dig", {"x": -1, "y": 0, "z": 0, "priority": 1}))
	_expect(String(off_map.get("rejection", {}).get("reason", "")) == "invalid_target",
		"an out-of-map x is the invalid_target an out-of-range z mirrors, got %s" % off_map)

## SaveIO's validator bounds every z by map.layerCount and the tile count by every layer.
func _check_save_rejects_tiles_off_the_layers() -> void:
	var world := _world()
	var state := StateCodecType.encode(world)
	_expect(SaveIOType._validate_state(state)["ok"], "a fresh one-layer state must validate")
	_expect(int(state["map"]["layerCount"]) == 1, "a fresh world must save one layer")
	var deep_actor := state.duplicate(true)
	deep_actor["entities"][0]["z"] = 1
	_expect_schema_error(deep_actor, "an entity on layer 1 of a one-layer map")
	var deep_zone := state.duplicate(true)
	deep_zone["zones"] = [{"id": "zone_1", "x": 0, "y": 0, "z": 1, "width": 1, "height": 1}]
	deep_zone["nextZoneId"] = 2
	_expect_schema_error(deep_zone, "a zone on layer 1 of a one-layer map")
	var no_z := state.duplicate(true)
	no_z["objects"] = [{"target": {"x": 0, "y": 0}, "kind": "chair", "factionId": "colony"}]
	_expect(not SaveIOType._validate_state(no_z)["ok"], "a tile without z must not validate")
	var short_layers := state.duplicate(true)
	short_layers["map"]["layerCount"] = 2
	_expect_schema_error(short_layers, "layerCount 2 with one layer of tiles")
	var two_layers := state.duplicate(true)
	two_layers["map"]["layerCount"] = 2
	(two_layers["map"]["tiles"] as Array).append_array(state["map"]["tiles"])
	_expect(SaveIOType._validate_state(two_layers)["ok"], "layerCount 2 with two layers of tiles must validate")

func _expect_schema_error(state: Dictionary, label: String) -> void:
	var result := SaveIOType._validate_state(state)
	_expect(not result["ok"] and String(result.get("code", "")) == "schema_error", "%s must be a schema_error, got %s" % [label, result])

func _world() -> WorldStateType:
	return WorldStateType.new(451_002, 10, 16, 16)

func _command(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	return {"actor": "player", "command_id": "l2_%d" % _next_command, "tick": world.get_tick(), "type": type,
		"payload": payload}

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error("test_map_layers: " + message)
		_failed = true
