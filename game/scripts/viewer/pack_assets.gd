extends RefCounted

## Presentation-only loader for the Pixel Crawler pack sheets (docs/art/style.md,
## "Pack art and placeholders"). The pack may not be redistributed, so its PNGs
## live only in the git-ignored DEFAULT_ROOT, copied there by
## tools/sync_pack_assets.ps1. Every function returns null when a sheet is
## missing, and callers then keep the generated placeholder: CI, tests and a
## clone without the pack run exactly as if this file did not exist.
##
## A *_pack.json under data/sprite_frames/ maps viewer animation names to
## sheets; its numbers are measured from the real sheets
## (docs/orca/handoffs/B2-measure_pack_frames.py), never typed by hand.

const DEFAULT_ROOT := "res://assets/pack/"
const COLONIST_FRAMES_JSON := "res://data/sprite_frames/colonist_pack.json"
## Terrain, props, trees, walls, ground items and the non-colonist actors (B3),
## written by docs/orca/handoffs/B3-measure_pack_world.py.
const WORLD_JSON := "res://data/sprite_frames/world_pack.json"

## The sheet's texture, or null if `root` does not hold it. An imported
## texture (after `godot --import`, and in an exported build) is preferred; a
## raw PNG copied in after the last import is read directly so a fresh sync
## works without a re-import.
static func load_texture(relative_path: String, root: String = DEFAULT_ROOT) -> Texture2D:
	var path := root + relative_path
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)

## The parsed mapping at `json_path`, or {} if it is absent or not an object.
static func read_mapping(json_path: String) -> Dictionary:
	if not FileAccess.file_exists(json_path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	return parsed if parsed is Dictionary else {}

## SpriteFrames for every animation in `mapping` (a *_pack.json), each a
## looping horizontal strip of square frames, or null unless ALL sheets are
## present at `root` with the measured size -- never a mix of pack and
## placeholder art, and never a pack version whose layout the JSON does not
## describe.
static func build_sprite_frames(mapping: Dictionary, root: String = DEFAULT_ROOT) -> SpriteFrames:
	var animations: Dictionary = mapping.get("animations", {})
	if animations.is_empty():
		return null
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	for animation_name: String in animations:
		var entry: Dictionary = animations[animation_name]
		var sheet := load_texture(String(entry.get("sheet", "")), root)
		var sheet_size: Array = entry.get("sheet_size", [])
		if sheet == null or sheet_size.size() != 2 \
				or sheet.get_size() != Vector2(float(sheet_size[0]), float(sheet_size[1])):
			return null
		var count := int(entry.get("frames", 0))
		var frame_size := float(sheet_size[1])
		if count <= 0 or count * frame_size != float(sheet_size[0]):
			return null
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, true)
		frames.set_animation_speed(animation_name, float(entry.get("fps", 1.0)))
		for index in count:
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(index * frame_size, 0, frame_size, frame_size)
			frames.add_frame(animation_name, atlas)
	return frames

## The colonist SpriteFrames from the pack, or null to keep the placeholder.
## Also null when the measured frame size or feet row differs from the
## renderer's grounding constants (`frame_size`, `feet_y`), so a pack update
## can never silently float or sink the colonists.
static func colonist_frames(frame_size: float, feet_y: float, root: String = DEFAULT_ROOT) -> SpriteFrames:
	var mapping := read_mapping(COLONIST_FRAMES_JSON)
	var measured: Array = mapping.get("frame_size", [])
	if measured.size() != 2 or float(measured[0]) != frame_size or float(measured[1]) != frame_size \
			or float(mapping.get("feet_y", -1)) != feet_y:
		return null
	return build_sprite_frames(mapping, root)

## The world TileSet with the pack's art, or null to keep `placeholder`. Every
## source world_pack.json maps gets a texture composed from the pack sheets,
## laid out on the placeholder's own source ids and atlas coords (so
## tile_atlas_map.gd's tables are unchanged): each sprite's measured rect is
## bottom-centred in a `cell_size` cell, and a grounded sprite gets the
## placeholder's texture_origin rule, (cell height - grounded_on) / 2. Sources
## the mapping does not list (its "placeholder" kinds) are copied from
## `placeholder` as they are. All or nothing: one missing sheet, or a sheet
## whose size differs from the measured one, returns null.
static func world_tile_set(placeholder: TileSet, root: String = DEFAULT_ROOT, json_path: String = WORLD_JSON) -> TileSet:
	var mapping := read_mapping(json_path)
	var sources: Array = mapping.get("sources", [])
	if sources.is_empty() or placeholder == null:
		return null
	var pack_sources := {}
	for entry: Dictionary in sources:
		var source := _compose_source(entry, root)
		if source == null:
			return null
		pack_sources[int(entry["source_id"])] = source
	var tile_set := TileSet.new()
	tile_set.tile_size = placeholder.tile_size
	for index in placeholder.get_source_count():
		var source_id := placeholder.get_source_id(index)
		var source: TileSetSource = pack_sources.get(source_id, null)
		if source == null:
			source = placeholder.get_source(source_id).duplicate(true)
		tile_set.add_source(source, source_id)
	return tile_set

## Where `rect`'s pixels land in a composed source texture: bottom-centred in
## the `cell` at `coords`.
static func content_rect(coords: Vector2i, cell: Vector2i, rect_size: Vector2i) -> Rect2i:
	var origin := coords * cell
	return Rect2i(origin + Vector2i((cell.x - rect_size.x) / 2, cell.y - rect_size.y), rect_size)

static func _compose_source(entry: Dictionary, root: String) -> TileSetAtlasSource:
	var cell := _vector2i(entry.get("cell_size", []))
	var tiles: Array = entry.get("tiles", [])
	if cell.x <= 0 or cell.y <= 0 or tiles.is_empty():
		return null
	var grid := Vector2i.ONE
	for tile: Dictionary in tiles:
		grid = grid.max(_vector2i(tile["coords"]) + Vector2i.ONE)
	var image := Image.create_empty(grid.x * cell.x, grid.y * cell.y, false, Image.FORMAT_RGBA8)
	for tile: Dictionary in tiles:
		var sheet := _sheet_image(String(tile.get("sheet", "")), tile.get("sheet_size", []), root)
		if sheet == null:
			return null
		var rect: Array = tile["rect"]
		var source_rect := Rect2i(int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3]))
		var target := content_rect(_vector2i(tile["coords"]), cell, source_rect.size)
		image.blit_rect(sheet, source_rect, target.position)
	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(image)
	source.texture_region_size = cell
	var grounded_on = entry.get("grounded_on")
	for tile: Dictionary in tiles:
		var coords := _vector2i(tile["coords"])
		source.create_tile(coords)
		if grounded_on != null:
			source.get_tile_data(coords, 0).texture_origin = Vector2i(0, (cell.y - int(grounded_on)) / 2)
	return source

## The sheet as an RGBA8 image, or null when it is missing or not the size
## the mapping measured.
static func _sheet_image(relative_path: String, sheet_size: Array, root: String) -> Image:
	var texture := load_texture(relative_path, root)
	if texture == null or sheet_size.size() != 2 \
			or texture.get_size() != Vector2(float(sheet_size[0]), float(sheet_size[1])):
		return null
	var image := texture.get_image()
	if image == null or image.is_empty():
		return null
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	return image

static func _vector2i(pair: Array) -> Vector2i:
	return Vector2i(int(pair[0]), int(pair[1])) if pair.size() == 2 else Vector2i.ZERO

## Ground/cargo/tool icons from a world_tile_set() result: kind ->
## {"texture", "rect"}, the rect being the sprite's own pixels in the composed
## texture (not the padded cell), for every `item_map` kind (tile_atlas_map.gd's
## ITEM_ATLAS_MAP) whose source/coords the mapping covers. {} for null.
static func item_icons(tile_set: TileSet, item_map: Dictionary, json_path: String = WORLD_JSON) -> Dictionary:
	var icons := {}
	if tile_set == null:
		return icons
	var mapping := read_mapping(json_path)
	for entry: Dictionary in mapping.get("sources", []):
		var source_id := int(entry["source_id"])
		var cell := _vector2i(entry["cell_size"])
		for kind: String in item_map:
			var atlas: Dictionary = item_map[kind]
			if int(atlas["source_id"]) != source_id:
				continue
			for tile: Dictionary in entry["tiles"]:
				if _vector2i(tile["coords"]) != atlas["coords"]:
					continue
				var rect: Array = tile["rect"]
				var source := tile_set.get_source(source_id) as TileSetAtlasSource
				icons[kind] = {"texture": source.texture,
					"rect": Rect2(content_rect(atlas["coords"], cell, Vector2i(int(rect[2]), int(rect[3]))))}
	return icons

## The whole world from the pack, or {} to keep the placeholder everywhere:
## {"tile_set": world_tile_set(), "actor_frames": actor_frames()} only when
## BOTH are complete, so one missing or resized sheet (terrain, prop or actor)
## never leaves the map half pack, half placeholder.
static func world_pack(placeholder: TileSet, root: String = DEFAULT_ROOT, json_path: String = WORLD_JSON) -> Dictionary:
	var tile_set := world_tile_set(placeholder, root, json_path)
	if tile_set == null:
		return {}
	var frames := actor_frames(root, json_path)
	if frames.is_empty():
		return {}
	return {"tile_set": tile_set, "actor_frames": frames}

## SpriteFrames per non-colonist actor art key ("wolf", "raider", "trader"),
## each with "idle" and "walk", or {} to keep the placeholder (which draws no
## sprite for them). All or nothing across the three, like the colonists.
static func actor_frames(root: String = DEFAULT_ROOT, json_path: String = WORLD_JSON) -> Dictionary:
	var actors: Dictionary = read_mapping(json_path).get("actors", {})
	var frames := {}
	for key: String in actors:
		var built := build_sprite_frames(actors[key], root)
		if built == null:
			return {}
		frames[key] = built
	return frames

## The feet row of `animation` for actor art `key` (from world_pack.json), or
## -1 when unknown: actor_sprites.gd grounds each frame on it.
static func actor_feet_y(key: String, animation: String, json_path: String = WORLD_JSON) -> int:
	var actors: Dictionary = read_mapping(json_path).get("actors", {})
	return int(actors.get(key, {}).get("animations", {}).get(animation, {}).get("feet_y", -1))
