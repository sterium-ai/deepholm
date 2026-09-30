extends SceneTree

## "Headless test: same seed, same map -> same tile
## variants after pan, zoom, save and load; the simulation hash does not
## change with art enabled or disabled."
##
## Covers, for the same seeded world: (1) prairie-variant atlas coords are
## unchanged after panning and zooming the viewport; (2) the same coords
## reappear after a real save/StateCodec-decode/load round trip; (3)
## WorldState.state_hash() is bit-identical whether the TileMapLayer art
## renderer is enabled or disabled, since decoration must never touch
## simulation state.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const MapViewportType = preload("res://scripts/viewer/map_viewport.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")

const SEED := 42
const WIDTH := 64
const HEIGHT := 64
const SAVE_DIR := "user://test-tile-variant-stability-saves"

var _failed := false

func _init() -> void:
	var world := WorldStateType.new(SEED, 10, WIDTH, HEIGHT)
	var map_view := MapViewType.new()
	var viewport := MapViewportType.new()
	root.add_child(viewport)
	viewport.size = Vector2(800, 600)
	viewport.attach(map_view)
	map_view.set_art_enabled(true)
	map_view.set_world(world)

	var soil_positions := _soil_positions(world)
	_expect(soil_positions.size() > 0, "setup: seed %d must generate at least one soil tile" % SEED)
	var before := _capture_coords(map_view, soil_positions)

	# 1. Pan and zoom the real MapViewport, then re-read the same cells.
	viewport.zoom_at(Vector2(400, 300), 2.0)
	viewport.pan_by(Vector2(137, -59))
	viewport.zoom_at(Vector2(200, 150), 0.6)
	map_view.refresh()
	var after_pan_zoom := _capture_coords(map_view, soil_positions)
	_expect(after_pan_zoom == before, "prairie-variant atlas coords must not change after panning/zooming the viewport")

	# 2. Save, decode a fresh WorldState from the encoded state, and compare.
	var save_manager := SaveManagerType.new(SAVE_DIR)
	var save_result := save_manager.save_manual(world, 0)
	_expect(save_result.get("ok", false), "setup: save_manual must succeed: %s" % save_result)
	var load_result := save_manager.load_best()
	_expect(load_result.get("ok", false), "setup: load_best must succeed: %s" % load_result)
	if save_result.get("ok", false) and load_result.get("ok", false):
		var loaded_world: WorldStateType = StateCodecType.decode(load_result["state"])
		var map_view_loaded := MapViewType.new()
		root.add_child(map_view_loaded)
		map_view_loaded.set_art_enabled(true)
		map_view_loaded.set_world(loaded_world)
		var after_load := _capture_coords(map_view_loaded, soil_positions)
		_expect(after_load == before, "prairie-variant atlas coords must be identical after a save/load round trip for the same seed and map")

	# 3. The simulation hash must be unaffected by the art toggle.
	var hash_art_on := world.state_hash()
	map_view.set_art_enabled(false)
	var hash_art_off := world.state_hash()
	map_view.set_art_enabled(true)
	var hash_art_on_again := world.state_hash()
	_expect(hash_art_on == hash_art_off, "state_hash() must not change when art is disabled")
	_expect(hash_art_on == hash_art_on_again, "state_hash() must not change when art is re-enabled")

	_finish()

func _soil_positions(world: WorldStateType) -> Array[Vector2i]:
	var positions: Array[Vector2i] = []
	var tiles: Array = world.get_tiles()
	var width := world.get_map_width()
	for i in tiles.size():
		if tiles[i] == WorldStateType.TILE_SOIL:
			positions.append(Vector2i(i % width, i / width))
			if positions.size() >= 200:
				break
	return positions

func _capture_coords(map_view: MapViewType, positions: Array[Vector2i]) -> Dictionary:
	var tile_map: TileMapLayer = map_view.get("_tile_map_layer")
	var captured := {}
	for pos in positions:
		captured[pos] = tile_map.get_cell_atlas_coords(pos)
	return captured

func _finish() -> void:
	if _failed:
		quit(1)
		return
	print("test_tile_variant_stability: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
