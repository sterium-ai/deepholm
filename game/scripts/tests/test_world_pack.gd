extends SceneTree

## B3: terrain, props, trees, walls, ground items and non-colonist actors from
## the Pixel Crawler pack (pack_assets.gd's world_tile_set()/item_icons()/
## actor_frames(), map_view.gd, actor_sprites.gd). Like test_pack_assets.gd it
## never depends on the real pack: the pack path runs on fixture sheets written
## to user:// at the sizes world_pack.json measured, the fallback on a root
## that does not exist.
##
## godot --headless --path game --script res://scripts/tests/test_world_pack.gd

const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const ActorSpritesType = preload("res://scripts/viewer/actor_sprites.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const MISSING_ROOT := "user://no_pack_here/"
const FIXTURE_ROOT := "user://world_pack_fixture/"
const ViewSnapshotStub = preload("res://scripts/tests/support/view_snapshot_stub.gd")

class FakeWorld:
	extends RefCounted
	var colonists: Array = []
	var actors: Array = []
	func get_colonists() -> Array: return colonists
	func get_actors_with_health() -> Array: return actors
	# WorldState.get_view_snapshot() (A9): the columns actor_sprites.gd reads; every
	# actor here stands for one with health (get_actors_with_health() returned them all).
	func get_view_snapshot(_detail_ids: Array = []) -> Dictionary:
		var worker_ids := {}
		for colonist: Dictionary in colonists:
			worker_ids[String(colonist["id"])] = true
		var with_health: Array = []
		for actor: Dictionary in actors:
			var entry := actor.duplicate()
			entry["health"] = {"hp": 1, "maxHp": 1}
			with_health.append(entry)
		return ViewSnapshotStub.columns(with_health, worker_ids)

class FakeDriver:
	extends RefCounted
	var seconds := 0.5
	func seconds_per_tick() -> float: return seconds

var _failed := false
var _mapping: Dictionary
var _placeholder: TileSet

func _init() -> void:
	_mapping = PackAssetsType.read_mapping(PackAssetsType.WORLD_JSON)
	_placeholder = load(MapViewType.TILE_SET_PATH)
	_check_content_coverage()
	_check_mapping_shape()
	_check_missing_pack_falls_back()
	_write_fixture(FIXTURE_ROOT)
	_check_fixture_tile_set()
	_check_map_view_uses_pack()
	_check_actor_sprites()
	_check_partial_and_wrong_size_fall_back()
	_remove_dir(FIXTURE_ROOT)
	_remove_dir("user://world_pack_partial/")
	_remove_dir("user://world_pack_wrong_size/")
	if _failed:
		quit(1)
		return
	print("test_world_pack: PASS")
	quit()

func _fail(message: String) -> void:
	push_error("test_world_pack: FAIL: " + message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _content(file: String, list_key: String, id_key: String) -> Array:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://content/%s.json" % file))
	var ids := []
	for entry in parsed[list_key]:
		ids.append(String(entry[id_key]))
	return ids

## True when world_pack.json maps the TileSet cell (source_id, coords).
func _mapped(atlas: Dictionary) -> bool:
	for source: Dictionary in _mapping.get("sources", []):
		if int(source["source_id"]) != int(atlas["source_id"]):
			continue
		for tile: Dictionary in source["tiles"]:
			if Vector2i(int(tile["coords"][0]), int(tile["coords"][1])) == atlas["coords"]:
				return true
	return false

## Every tile, object, actor and item kind in content has pack art or an
## explicit placeholder entry with a reason -- never both, never neither.
func _check_content_coverage() -> void:
	var placeholder: Dictionary = _mapping.get("placeholder", {})
	for kind: String in _content("tiles", "tiles", "id"):
		var atlas: Dictionary = TileAtlasMapType.TILE_ATLAS_MAP.get(kind, {})
		_expect(not atlas.is_empty() and _mapped(atlas), "tile %s: base cell has no pack mapping" % kind)
		var decor: Dictionary = TileAtlasMapType.TILE_DECOR_MAP.get(kind, {})
		_expect(decor.is_empty() or _mapped(decor), "tile %s: decor has no pack mapping" % kind)
	var object_kinds := _content("objects", "objects", "kind")
	object_kinds.append("workbench_vertical")
	for kind: String in object_kinds:
		_check_one("object", kind, TileAtlasMapType.OBJECT_ATLAS_MAP.get(kind, {}), placeholder.get("objects", {}))
	for kind: String in _content("items", "items", "id"):
		_check_one("item", kind, TileAtlasMapType.ITEM_ATLAS_MAP.get(kind, {}), placeholder.get("items", {}))
	var colonist_pack := PackAssetsType.read_mapping(PackAssetsType.COLONIST_FRAMES_JSON)
	var actors: Dictionary = _mapping.get("actors", {})
	for kind: String in _content("actors", "actors", "id"):
		var in_pack: bool = actors.has(kind) or (kind == "colonist" and not colonist_pack.get("animations", {}).is_empty())
		var listed: bool = placeholder.get("actors", {}).has(kind)
		_expect(in_pack != listed, "actor %s: pack %s, placeholder entry %s" % [kind, in_pack, listed])
	_expect(actors.has("raider"), "raiders (wolf-def actors of faction raiders) have pack art")

func _check_one(label: String, kind: String, atlas: Dictionary, listed: Dictionary) -> void:
	var in_pack := not atlas.is_empty() and _mapped(atlas)
	_expect(in_pack != listed.has(kind), "%s %s: pack %s, placeholder entry %s" % [label, kind, in_pack, listed.has(kind)])
	if listed.has(kind):
		_expect(not String(listed[kind]).strip_edges().is_empty(), "%s %s: placeholder entry gives no reason" % [label, kind])

## The mapping keeps the placeholder's layout (ids and coords), names only
## sheets the sync script copies, and keeps props inside the owner's ceilings.
func _check_mapping_shape() -> void:
	var listed: Array = PackAssetsType.read_mapping("res://data/sprite_frames/pack_manifest.json").get("files", [])
	var sources: Array = _mapping.get("sources", [])
	_expect(sources.size() >= 10, "world_pack.json maps the world's sources")
	for source: Dictionary in sources:
		var source_id := int(source["source_id"])
		_expect(_placeholder.has_source(source_id), "source %d exists in the placeholder TileSet" % source_id)
		var placeholder_source := _placeholder.get_source(source_id) as TileSetAtlasSource
		var cell := Vector2i(int(source["cell_size"][0]), int(source["cell_size"][1]))
		for tile: Dictionary in source["tiles"]:
			var coords := Vector2i(int(tile["coords"][0]), int(tile["coords"][1]))
			# The only cells the placeholder lacks are the extra tree sizes,
			# which map_view.gd picks by hash next to the placeholder's (0, 0).
			var tree_size: bool = source_id == TileAtlasMapType.SOURCE_TREE and coords.y == 0
			_expect(placeholder_source != null and (placeholder_source.has_tile(coords) or tree_size),
				"%s: coords %s are a placeholder cell" % [tile["label"], coords])
			_expect(listed.has(tile["sheet"]), "%s: sheet not in pack_manifest.json" % tile["label"])
			_expect(int(tile["rect"][2]) <= cell.x and int(tile["rect"][3]) <= cell.y, "%s fits its cell" % tile["label"])
		var grounded_on = source.get("grounded_on")
		if grounded_on != null and source_id != TileAtlasMapType.SOURCE_TREE:
			var ceiling := TileAtlasMapType.PROP_MAX_SIZE_2X1 if source_id == TileAtlasMapType.SOURCE_WORKBENCH else TileAtlasMapType.PROP_MAX_SIZE_1X1
			_expect(cell.x <= ceiling.x and cell.y <= ceiling.y, "%s: %s within the prop ceiling %s" % [source["name"], cell, ceiling])
	for key: String in _mapping.get("actors", {}):
		for animation: String in ["idle", "walk"]:
			var entry: Dictionary = _mapping["actors"][key]["animations"].get(animation, {})
			_expect(listed.has(entry.get("sheet", "")), "%s %s: sheet in pack_manifest.json" % [key, animation])
			_expect(int(entry.get("frames", 0)) * int(entry["sheet_size"][1]) == int(entry["sheet_size"][0]),
				"%s %s: frames * height == width" % [key, animation])

func _check_missing_pack_falls_back() -> void:
	_expect(PackAssetsType.world_tile_set(_placeholder, MISSING_ROOT) == null, "no pack -> no pack TileSet")
	_expect(PackAssetsType.actor_frames(MISSING_ROOT).is_empty(), "no pack -> no actor frames")
	var map_view = MapViewType.new(MISSING_ROOT)
	_expect(map_view._tile_map_layer.tile_set == _placeholder, "no pack -> the placeholder TileSet, unchanged")
	_expect(not map_view.is_pack_art(), "no pack -> placeholder item icons")
	map_view.free()
	_expect(PackAssetsType.world_pack(_placeholder, MISSING_ROOT).is_empty(), "no pack -> no world pack")
	_expect(not _map_view_has_actor_art(MISSING_ROOT), "no pack -> map_view draws no actor sprites")
	var actors := ActorSpritesType.new()
	var world := FakeWorld.new()
	world.actors = [{"id": "wolf_1", "kind": "wolf", "x": 3, "y": 3, "z": 0, "factionId": "predators"}]
	actors.set_world(world)
	_expect(actors.get_child_count() == 0, "no pack -> no actor sprites (as before B3)")
	actors.free()

func _check_fixture_tile_set() -> void:
	var tile_set := PackAssetsType.world_tile_set(_placeholder, FIXTURE_ROOT)
	_expect(tile_set != null, "a complete pack builds the TileSet")
	if tile_set == null:
		return
	_expect(tile_set.get_source_count() == _placeholder.get_source_count(), "same source count as the placeholder")
	_expect(tile_set.tile_size == _placeholder.tile_size, "same tile size")
	var mapped_ids := {}
	for source: Dictionary in _mapping["sources"]:
		var source_id := int(source["source_id"])
		mapped_ids[source_id] = true
		var atlas := tile_set.get_source(source_id) as TileSetAtlasSource
		var cell := Vector2i(int(source["cell_size"][0]), int(source["cell_size"][1]))
		_expect(atlas.texture_region_size == cell, "%s: region size %s == cell %s" % [source["name"], atlas.texture_region_size, cell])
		_expect(atlas.get_tiles_count() == source["tiles"].size(), "%s: one tile per mapped cell" % source["name"])
		for tile: Dictionary in source["tiles"]:
			var coords := Vector2i(int(tile["coords"][0]), int(tile["coords"][1]))
			_expect(atlas.has_tile(coords), "%s: tile %s" % [tile["label"], coords])
			if not atlas.has_tile(coords):
				continue
			var grounded_on = source.get("grounded_on")
			var origin := Vector2i(0, (cell.y - int(grounded_on)) / 2) if grounded_on != null else Vector2i.ZERO
			_expect(atlas.get_tile_data(coords, 0).texture_origin == origin, "%s: texture_origin %s" % [tile["label"], origin])
			# The fixture sheets are opaque, so the sprite's own rect is opaque
			# and the padding around it (if any) transparent.
			var rect := PackAssetsType.content_rect(coords, cell, Vector2i(int(tile["rect"][2]), int(tile["rect"][3])))
			var image := atlas.texture.get_image()
			_expect(image.get_pixelv(rect.position).a == 1.0 and image.get_pixelv(rect.end - Vector2i.ONE).a == 1.0,
				"%s: pixels blitted bottom-centred" % tile["label"])
			if rect.position.y > coords.y * cell.y:
				_expect(image.get_pixel(rect.position.x, coords.y * cell.y).a == 0.0, "%s: padding above is transparent" % tile["label"])
	_expect((tile_set.get_source(TileAtlasMapType.SOURCE_TREE) as TileSetAtlasSource).get_tiles_count() == 3, "three tree sizes")
	for index in _placeholder.get_source_count():
		var source_id := _placeholder.get_source_id(index)
		if mapped_ids.has(source_id):
			continue
		var kept := tile_set.get_source(source_id) as TileSetAtlasSource
		var original := _placeholder.get_source(source_id) as TileSetAtlasSource
		_expect(kept.texture == original.texture and kept.texture_region_size == original.texture_region_size
			and kept.get_tile_data(Vector2i.ZERO, 0).texture_origin == original.get_tile_data(Vector2i.ZERO, 0).texture_origin,
			"unmapped source %d keeps its placeholder art and grounding" % source_id)
	var icons := PackAssetsType.item_icons(tile_set, TileAtlasMapType.ITEM_ATLAS_MAP)
	for kind: String in ["wood", "stone", "pick", "axe"]:
		_expect(icons.has(kind), "pack icon for " + kind)
	var resources: Dictionary = _source_entry(TileAtlasMapType.SOURCE_HAZARD)
	var log_rect: Array = resources["tiles"][2]["rect"]
	var cell := Vector2i(int(resources["cell_size"][0]), int(resources["cell_size"][1]))
	_expect(icons.get("wood", {}).get("rect") == Rect2(PackAssetsType.content_rect(Vector2i(2, 0), cell, Vector2i(int(log_rect[2]), int(log_rect[3])))),
		"the wood icon is the log's own pixels, not its padded cell")

func _source_entry(source_id: int) -> Dictionary:
	for source: Dictionary in _mapping["sources"]:
		if int(source["source_id"]) == source_id:
			return source
	return {}

## map_view.gd swaps in the pack TileSet and icons, and spreads trees over the
## three sizes by hash, deterministically.
func _check_map_view_uses_pack() -> void:
	var map_view = MapViewType.new(FIXTURE_ROOT)
	_expect(map_view.is_pack_art(), "pack present -> pack item icons")
	_expect(map_view._actor_sprites.has_pack_art(), "pack present -> map_view draws the actors")
	_expect(map_view._tile_map_layer.tile_set != _placeholder, "pack present -> the pack TileSet")
	_expect(map_view._colonist_sprites._pack_icons.has("axe"), "colonist badges use the pack icons")
	var decor: Dictionary = TileAtlasMapType.TILE_DECOR_MAP[WorldStateType.TILE_TREE]
	var seen := {}
	for x in 12:
		var coords: Vector2i = map_view._decor_variant_coords(x, 5, decor)
		_expect(coords == map_view._decor_variant_coords(x, 5, decor), "tree size is a pure function of the tile")
		seen[coords] = true
	_expect(seen.size() == 3, "trees use all three sizes along a row")
	var hazard: Dictionary = TileAtlasMapType.TILE_DECOR_MAP[WorldStateType.TILE_HAZARD]
	for x in 6:
		_expect(map_view._decor_variant_coords(x, 2, hazard) == hazard["coords"], "hazard decor never takes an item cell")
	_expect(MapViewType.fit_rect(Rect2(0, 0, 10, 10), Vector2(16, 32)) == Rect2(2.5, 0, 5, 10), "fit_rect keeps proportions")
	map_view.free()
	var placeholder_view = MapViewType.new(MISSING_ROOT)
	_expect(placeholder_view._decor_variant_coords(4, 4, decor) == decor["coords"], "placeholder tree keeps its one cell")
	placeholder_view.free()

func _check_actor_sprites() -> void:
	var actors := ActorSpritesType.new(PackAssetsType.actor_frames(FIXTURE_ROOT))
	_expect(actors.has_pack_art(), "pack present -> actor frames")
	var driver := FakeDriver.new()
	actors.set_tick_driver(driver)
	var world := FakeWorld.new()
	world.colonists = [{"id": "colonist_0", "x": 1, "y": 1, "z": 0}]
	world.actors = [
		{"id": "colonist_0", "kind": "colonist", "x": 1, "y": 1, "z": 0, "factionId": "colony"},
		{"id": "wolf_1", "kind": "wolf", "x": 5, "y": 5, "z": 0, "factionId": "predators"},
		{"id": "wolf_2", "kind": "wolf", "x": 7, "y": 5, "z": 0, "factionId": "raiders"},
		{"id": "trader_1", "kind": "trader", "x": 9, "y": 5, "z": 0, "factionId": "traders"},
	]
	actors.set_world(world)
	_expect(actors.sprite_for("colonist_0") == null, "colonists are colonist_sprites.gd's, not drawn twice")
	var raider_idle: Array = _mapping["actors"]["raider"]["animations"]["idle"]["sheet_size"]
	var raider := actors.sprite_for("wolf_2")
	_expect(raider != null and raider.sprite_frames.get_frame_texture("idle", 0).get_size().y == float(raider_idle[1]),
		"a raiders-faction wolf gets the raider (Orc) frames")
	_expect(ActorSpritesType.art_key(world.actors[2]) == "raider", "a raiders-faction wolf is drawn as a raider")
	_expect(ActorSpritesType.art_key(world.actors[1]) == "wolf", "a predator wolf is drawn as a wolf")
	_expect(actors.sprite_for("trader_1") != null, "a trader is drawn")
	var wolf := actors.sprite_for("wolf_1")
	var feet := PackAssetsType.actor_feet_y("wolf", "idle")
	var frame_size := wolf.sprite_frames.get_frame_texture("idle", 0).get_size()
	_expect(wolf.position == Vector2(5 * 16 + 8 - frame_size.x / 2.0, 5 * 16 + 16 - feet), "wolf grounded on its tile's feet line")
	_expect(wolf.animation == "idle" and not wolf.flip_h, "standing wolf idles")
	world.actors[1]["x"] = 4
	actors.refresh()
	_expect(wolf.animation == "walk" and wolf.flip_h, "a step left walks, flipped")
	actors.advance(0.5)
	var frame := wolf.frame
	driver.seconds = 0.0
	actors.advance(1.0)
	_expect(wolf.frame == frame, "paused -> frame frozen")
	actors.refresh()
	_expect(wolf.animation == "idle", "back to idle once the tile stops changing")
	world.actors.remove_at(3)
	actors.refresh()
	_expect(actors.sprite_for("trader_1") == null, "a departed actor's sprite is removed")
	actors.free()

## One missing sheet, or one of the wrong size, keeps the whole world on the
## placeholder (never a mix): terrain/prop sheets and actor sheets alike, and
## either group failing turns off the other too.
func _check_partial_and_wrong_size_fall_back() -> void:
	var terrain_sheet := String(_mapping["sources"][0]["tiles"][0]["sheet"])
	var wolf_idle: Dictionary = _mapping["actors"]["wolf"]["animations"]["idle"]
	var actor_sheet := String(wolf_idle["sheet"])
	var partial := "user://world_pack_partial/"
	_write_fixture(partial)
	DirAccess.remove_absolute(partial + terrain_sheet)
	_expect(PackAssetsType.world_tile_set(_placeholder, partial) == null, "a partial pack keeps the placeholder TileSet")
	_expect(not PackAssetsType.actor_frames(partial).is_empty(), "the actor sheets alone still build")
	_expect_whole_placeholder(partial, "missing terrain sheet")
	_write_fixture(partial)
	DirAccess.remove_absolute(partial + actor_sheet)
	_expect(PackAssetsType.world_tile_set(_placeholder, partial) != null, "the terrain sheets alone still compose")
	_expect(PackAssetsType.actor_frames(partial).is_empty(), "a missing wolf sheet -> no actor frames")
	_expect_whole_placeholder(partial, "missing actor sheet")
	var wrong := "user://world_pack_wrong_size/"
	_write_fixture(wrong)
	_write_sheet(wrong + terrain_sheet, _sheet_size(terrain_sheet) - Vector2i(16, 0))
	_expect(PackAssetsType.world_tile_set(_placeholder, wrong) == null, "a wrong-size sheet keeps the placeholder TileSet")
	_expect_whole_placeholder(wrong, "resized terrain sheet")
	_write_fixture(wrong)
	_write_sheet(wrong + actor_sheet, Vector2i(int(wolf_idle["sheet_size"][0]) - 64, int(wolf_idle["sheet_size"][1])))
	_expect(PackAssetsType.actor_frames(wrong).is_empty(), "a resized wolf sheet -> no actor frames")
	_expect_whole_placeholder(wrong, "resized actor sheet")

## world_pack() and map_view.gd at `root` show no pack art at all: placeholder
## TileSet and icons, no actor sprites.
func _expect_whole_placeholder(root: String, label: String) -> void:
	_expect(PackAssetsType.world_pack(_placeholder, root).is_empty(), label + ": no world pack")
	var map_view = MapViewType.new(root)
	_expect(not map_view.is_pack_art() and map_view._tile_map_layer.tile_set == _placeholder,
		label + ": map_view keeps the placeholder TileSet and icons")
	_expect(not map_view._actor_sprites.has_pack_art(), label + ": map_view draws no actor sprites")
	map_view.free()

func _map_view_has_actor_art(root: String) -> bool:
	var map_view = MapViewType.new(root)
	var has_art: bool = map_view._actor_sprites.has_pack_art()
	map_view.free()
	return has_art

func _sheet_size(sheet: String) -> Vector2i:
	for source: Dictionary in _mapping["sources"]:
		for tile: Dictionary in source["tiles"]:
			if String(tile["sheet"]) == sheet:
				return Vector2i(int(tile["sheet_size"][0]), int(tile["sheet_size"][1]))
	return Vector2i.ZERO

func _write_sheet(path: String, sheet_size: Vector2i) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var image := Image.create(sheet_size.x, sheet_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_OLIVE_GREEN)
	_expect(image.save_png(path) == OK, "fixture sheet written: " + path)

func _write_fixture(root: String) -> void:
	var sizes := {}
	for source: Dictionary in _mapping["sources"]:
		for tile: Dictionary in source["tiles"]:
			sizes[tile["sheet"]] = tile["sheet_size"]
	for key: String in _mapping["actors"]:
		for animation: Dictionary in _mapping["actors"][key]["animations"].values():
			sizes[animation["sheet"]] = animation["sheet_size"]
	for sheet: String in sizes:
		_write_sheet(root + sheet, Vector2i(int(sizes[sheet][0]), int(sizes[sheet][1])))

func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_dir(path.path_join(sub))
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
