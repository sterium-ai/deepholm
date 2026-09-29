extends SceneTree

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")
const TILE_SET_PATH := "res://data/tilesets/terrain_tileset.tres"

var _failed := false
var _tile_set: TileSet

func _init() -> void:
	_check_tile_set_and_mappings()
	if _failed:
		quit(1)
		return
	print("test_tile_atlas_map: PASS")
	quit(0)

func _check_tile_set_and_mappings() -> void:
	var tile_set_resource = load(TILE_SET_PATH)
	if tile_set_resource == null or not tile_set_resource is TileSet:
		_fail("could not load TileSet resource at %s" % TILE_SET_PATH)
		return
	_tile_set = tile_set_resource
	# terrain_tileset.tres registers one TileSetAtlasSource per generated
	# sheet/sprite, not a single merged atlas.
	var source_count := _tile_set.get_source_count()
	_expect(source_count > 1, "expected multiple TileSetAtlasSources (one per sheet/sprite), found %d" % source_count)

	var required_kinds := [
		WorldStateType.TILE_ROCK,
		WorldStateType.TILE_SOIL,
		WorldStateType.TILE_FLOOR,
		WorldStateType.TILE_HAZARD,
		WorldStateType.TILE_TREE,
		WorldStateType.TILE_WATER,
		WorldStateType.TILE_PLOWED_SOIL,
		WorldStateType.TILE_PLANTED,
		WorldStateType.TILE_TRENCH,
	]
	for kind in required_kinds:
		_check_mapping(TileAtlasMapType.TILE_ATLAS_MAP, kind)
	# issue #300 Goal: river tiles must already read as water, unambiguously,
	# in art mode -- #299 had TILE_WATER reuse TILE_HAZARD's own cell.
	_expect(not _same_cell(TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_WATER], TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_HAZARD]),
		"TILE_WATER must not share TILE_HAZARD's atlas cell (an unambiguous representation is part of this task's acceptance)")

	var required_object_kinds := ["chair", "door", "wooden_wall", "stone_wall", "table", "berry_bush", "bed"]
	for kind in required_object_kinds:
		_check_mapping(TileAtlasMapType.OBJECT_ATLAS_MAP, kind)
	_check_object_scale_rules()
	_check_wall_crops()

	var required_decor_kinds := [WorldStateType.TILE_HAZARD, WorldStateType.TILE_TREE, WorldStateType.TILE_PLANTED]
	for kind in required_decor_kinds:
		_check_mapping(TileAtlasMapType.TILE_DECOR_MAP, kind)

	# issue #301 Goal: every tile kind AND every object kind gets its own
	# distinct registered cell -- no sharing. Distinctness is keyed by
	# (source_id, coords) together, not coords alone: many single-crop
	# sources legitimately reuse local coords (0,0) for their one tile, so
	# two different (source_id, coords) pairs are what "distinct" means now
	# that each crop lives in its own TileSetAtlasSource (distinct source-plus-coords registration).
	var seen := {}
	for kind in required_kinds:
		_check_unique(seen, TileAtlasMapType.TILE_ATLAS_MAP[kind], "tile kind '%s'" % kind)
	for kind in required_object_kinds:
		_check_unique(seen, TileAtlasMapType.OBJECT_ATLAS_MAP[kind], "object kind '%s'" % kind)
	# Decor sprites (tree canopy/hazard cluster/planted sprout) draw on the
	# same object layer as placed objects and must not collide with them,
	# but MAY legitimately differ in nature from a tile's own base cell
	# (checked separately, not against this `seen` set, since a decor sprite
	# is drawn *over* its tile's base cell, not instead of it).
	var decor_seen := {}
	for kind in required_decor_kinds:
		_check_unique(decor_seen, TileAtlasMapType.TILE_DECOR_MAP[kind], "decor for '%s'" % kind)
		_check_unique(seen, TileAtlasMapType.TILE_DECOR_MAP[kind], "decor for '%s'" % kind)

	# Every grass blob cell (4 edges + 4 convex corners + 4 concave corners)
	# must be its own registered, mutually distinct atlas tile -- and must
	# not collide with any tile/object/decor base cell above (they all live
	# in the same terrain sheet source).
	var directional: Dictionary = {}
	for group in [TileAtlasMapType.GRASS_EDGE_COORDS, TileAtlasMapType.GRASS_CORNER_COORDS, TileAtlasMapType.GRASS_CONCAVE_COORDS]:
		for direction in group:
			var coords: Vector2i = group[direction]
			var entry := {"source_id": TileAtlasMapType.SOURCE_FLOORS, "coords": coords}
			_check_unique(directional, entry, "grass blob cell %s" % direction)
			if not _tile_set.get_source(TileAtlasMapType.SOURCE_FLOORS).has_tile(coords):
				_fail("grass blob coords %s (%s) is not a registered atlas tile" % [coords, direction])
			_check_unique(seen, entry, "grass blob cell %s" % direction)
	_expect(directional.size() == 12, "expected exactly 12 directional grass cells (4 edge + 4 corner + 4 concave), found %d" % directional.size())

	_check_cells_fully_opaque(required_kinds)
	# Every TILE_SOIL prairie variant must itself be a registered atlas tile
	# (issue #301 Goal: hash-selected grass variants, never by frame).
	var variants: Array[Vector2i] = TileAtlasMapType.TILE_SOIL_VARIANTS
	if variants.size() < 2:
		_fail("TILE_SOIL_VARIANTS must offer discrete prairie variation (at least 2), found %d" % variants.size())
	for variant_coords in variants:
		if not _tile_set.get_source(TileAtlasMapType.SOURCE_FLOORS).has_tile(variant_coords):
			_fail("TILE_SOIL_VARIANTS entry %s is not a registered atlas tile" % variant_coords)
	# wolf/trader actor-kind lookup entries (issue #296 acceptance item 5).
	var required_actor_kinds := ["wolf", "trader"]
	for kind in required_actor_kinds:
		_check_mapping(TileAtlasMapType.ACTOR_ATLAS_MAP, kind)
	# Carried-item marker and stockpile-count rendering (issue #189
	# acceptance item 7) both resolve "wood" through this table.
	for kind in ["wood", "stone", "axe", "pick"]:
		_expect(TileAtlasMapType.ITEM_ATLAS_MAP.has(kind), "required item mapping: %s" % kind)
	for kind in TileAtlasMapType.ITEM_ATLAS_MAP:
		_check_mapping(TileAtlasMapType.ITEM_ATLAS_MAP, kind)
		_check_item_pixel_region(kind)
	var wood: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP["wood"]
	_expect(int(wood["source_id"]) == TileAtlasMapType.SOURCE_HAZARD and wood["coords"] == Vector2i(2, 0), "wood must use its own log-pile cell on the resources sheet")
	if TileAtlasMapType.ITEM_ATLAS_MAP.has("stone"):
		_check_unique(seen, TileAtlasMapType.ITEM_ATLAS_MAP["stone"], "stone item")
		_expect(not _same_cell(TileAtlasMapType.ITEM_ATLAS_MAP["stone"], TileAtlasMapType.ITEM_ATLAS_MAP["wood"]), "stone and wood must have distinct icons")
	# Issue #428: axe/pick must each be their own distinct registered cell,
	# not sharing wood's, stone's, or each other's (source_id, coords).
	if TileAtlasMapType.ITEM_ATLAS_MAP.has("axe"):
		_check_unique(seen, TileAtlasMapType.ITEM_ATLAS_MAP["axe"], "axe item")
		_expect(not _same_cell(TileAtlasMapType.ITEM_ATLAS_MAP["axe"], TileAtlasMapType.ITEM_ATLAS_MAP["wood"]), "axe and wood must have distinct icons")
		if TileAtlasMapType.ITEM_ATLAS_MAP.has("stone"):
			_expect(not _same_cell(TileAtlasMapType.ITEM_ATLAS_MAP["axe"], TileAtlasMapType.ITEM_ATLAS_MAP["stone"]), "axe and stone must have distinct icons")
	if TileAtlasMapType.ITEM_ATLAS_MAP.has("pick"):
		_check_unique(seen, TileAtlasMapType.ITEM_ATLAS_MAP["pick"], "pick item")
		_expect(not _same_cell(TileAtlasMapType.ITEM_ATLAS_MAP["pick"], TileAtlasMapType.ITEM_ATLAS_MAP["wood"]), "pick and wood must have distinct icons")
		if TileAtlasMapType.ITEM_ATLAS_MAP.has("stone"):
			_expect(not _same_cell(TileAtlasMapType.ITEM_ATLAS_MAP["pick"], TileAtlasMapType.ITEM_ATLAS_MAP["stone"]), "pick and stone must have distinct icons")
		if TileAtlasMapType.ITEM_ATLAS_MAP.has("axe"):
			_expect(not _same_cell(TileAtlasMapType.ITEM_ATLAS_MAP["pick"], TileAtlasMapType.ITEM_ATLAS_MAP["axe"]), "pick and axe must have distinct icons")
	# Issue #428 rounds 1-3 regression: every registered tool crop must show a
	# head set ACROSS its haft (hammer/hatchet/pick silhouette), never a
	# spike, trowel or scraper blade running along the handle. Rounds 2 and 3
	# once shipped such icons; registration and
	# uniqueness checks cannot see the difference, the pixels can.
	for kind in ["axe", "pick"]:
		if TileAtlasMapType.ITEM_ATLAS_MAP.has(kind):
			_check_tool_head_across_haft(kind)
	_check_grass_blob_orientation()

## Measures the registered crop's opaque width row by row (outline included)
## and requires the top third of the icon (the head) to be at least twice as
## wide, on every row, as the widest row of the bottom third (the haft). A
## crosswise hammer/pick/hatchet head passes; a blade or spike that tapers
## into a handle of similar width does not. e.g. head rows 7px
## wide over a 3px haft -> pass; (1,4) scraper: 5px over 5px -> fail;
## (1,1) spike: 3px over 5px -> fail; (0,4) sledgehammer: 12px over 6px ->
## pass.
func _check_tool_head_across_haft(kind: String) -> void:
	var entry: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP[kind]
	var source := _tile_set.get_source(int(entry["source_id"]))
	if not source is TileSetAtlasSource:
		return
	var atlas_source: TileSetAtlasSource = source
	var image: Image = atlas_source.texture.get_image()
	if image == null:
		_fail("could not read pixel data for %s's source %d" % [kind, int(entry["source_id"])])
		return
	var region := atlas_source.get_tile_texture_region(entry["coords"])
	var widths: Array[int] = []
	for y in range(region.position.y, region.position.y + region.size.y):
		var width := 0
		for x in range(region.position.x, region.position.x + region.size.x):
			if image.get_pixel(x, y).a > 0.5:
				width += 1
		widths.append(width)
	while not widths.is_empty() and widths[0] == 0:
		widths.pop_front()
	while not widths.is_empty() and widths[widths.size() - 1] == 0:
		widths.pop_back()
	var rows := widths.size()
	if rows < 6:
		_fail("%s tool crop %s is only %d rows tall; expected a head-on-haft icon" % [kind, entry["coords"], rows])
		return
	var band := int(ceil(rows / 3.0))
	var head_min := widths[0]
	for i in range(band):
		head_min = mini(head_min, widths[i])
	var haft_max := 0
	for i in range(rows - band, rows):
		haft_max = maxi(haft_max, widths[i])
	_expect(head_min >= 2 * haft_max,
		"%s tool crop %s must show a head set across its haft: top-third rows are %dpx wide at their narrowest against a %dpx haft (row widths %s); a spike/blade along the handle is not a tool head" % [kind, entry["coords"], head_min, haft_max, widths])

## ITEM_ATLAS_MAP's direct-draw entries (drawn via
## draw_texture_rect_region()/region_rect, never a TileMapLayer cell) carry
## their own texture_path/rect ALONGSIDE a source_id/coords pair that
## resolves the SAME crop's registered TileSetAtlasSource tile. Field/file
## existence alone would accept a texture_path/rect pointing at a crop that
## has drifted from what source_id/coords actually registers (an incorrect
## or empty crop); this instead re-derives the registered texture and pixel
## region from the TileSet resource itself and asserts they are identical.
func _check_item_pixel_region(kind: String) -> void:
	var entry: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP[kind]
	if not (entry.has("texture_path") and entry.has("rect") and entry.has("source_id") and entry.has("coords")):
		_fail("ITEM_ATLAS_MAP's '%s' entry must carry texture_path/rect/source_id/coords for the direct-draw carried-item marker/stockpile icon" % kind)
		return
	if not ResourceLoader.exists(entry["texture_path"]):
		_fail("ITEM_ATLAS_MAP %s texture_path %s must exist" % [kind, entry["texture_path"]])
		return
	var source_id: int = int(entry["source_id"])
	var coords: Vector2i = entry["coords"]
	var source := _tile_set.get_source(source_id)
	if not source is TileSetAtlasSource:
		_fail("ITEM_ATLAS_MAP %s source %d is not a TileSetAtlasSource" % [kind, source_id])
		return
	var atlas_source: TileSetAtlasSource = source
	var registered_texture_path := atlas_source.texture.resource_path if atlas_source.texture != null else ""
	_expect(registered_texture_path == entry["texture_path"],
		"ITEM_ATLAS_MAP %s texture_path %s must match its registered source %d's own texture %s" % [kind, entry["texture_path"], source_id, registered_texture_path])
	var registered_region := atlas_source.get_tile_texture_region(coords)
	var declared_rect: Rect2 = entry["rect"]
	_expect(Rect2i(declared_rect) == registered_region,
		"ITEM_ATLAS_MAP %s rect %s must match its registered source %d coords %s pixel region %s" % [kind, declared_rect, source_id, coords, registered_region])

func _check_wall_crops() -> void:
	_expect(not TileAtlasMapType.OBJECT_ATLAS_MAP.has("wall"), "legacy wall key must remain renamed to wooden_wall")
	for kind in ["wooden_wall", "stone_wall"]:
		var entry: Dictionary = TileAtlasMapType.OBJECT_ATLAS_MAP[kind]
		var source := _tile_set.get_source(int(entry["source_id"])) as TileSetAtlasSource
		if source == null:
			_fail("wall source missing: " + kind)
			continue
		_expect(source.texture_region_size == Vector2i(16, 16), kind + " must register exactly 16x16 native pixels")
		_expect(source.get_tile_texture_region(entry["coords"]) == Rect2i(0, 0, 16, 16), kind + " ghost and finished cell must sample the same zero-margin crop")
		_expect(source.get_tile_data(entry["coords"], 0).texture_origin == Vector2i.ZERO, kind + " must stay on its one-cell footprint")
		var pixels := source.texture.get_image()
		_expect(pixels.get_size() == Vector2i(16, 16) and not pixels.has_mipmaps(), kind + " must be a native crop with mipmaps disabled")
	# The two wall materials must read differently.
	var wooden := (_tile_set.get_source(TileAtlasMapType.SOURCE_WALL) as TileSetAtlasSource).texture.get_image()
	var stone := (_tile_set.get_source(TileAtlasMapType.SOURCE_STONE_WALL) as TileSetAtlasSource).texture.get_image()
	var differing := 0
	for y in 16:
		for x in 16:
			if wooden.get_pixel(x, y) != stone.get_pixel(x, y):
				differing += 1
	_expect(differing > 128, "wooden and stone walls must be visually distinct")

func _check_object_scale_rules() -> void:
	for kind in ["chair", "door", "wooden_wall", "stone_wall", "table", "berry_bush", "bed"]:
		var entry: Dictionary = TileAtlasMapType.OBJECT_ATLAS_MAP[kind]
		var source := _tile_set.get_source(int(entry["source_id"])) as TileSetAtlasSource
		var size := source.texture_region_size
		_expect(size.x <= TileAtlasMapType.PROP_MAX_SIZE_1X1.x and size.y <= TileAtlasMapType.PROP_MAX_SIZE_1X1.y,
			"1x1 object '%s' registered region %s exceeds %s" % [kind, size, TileAtlasMapType.PROP_MAX_SIZE_1X1])
	var workbench := _tile_set.get_source(TileAtlasMapType.SOURCE_WORKBENCH) as TileSetAtlasSource
	_expect(workbench.texture_region_size.x <= TileAtlasMapType.PROP_MAX_SIZE_2X1.x and workbench.texture_region_size.y <= TileAtlasMapType.PROP_MAX_SIZE_2X1.y,
		"2x1 workbench registered region exceeds %s" % TileAtlasMapType.PROP_MAX_SIZE_2X1)
	var icon_size: float = load("res://scripts/viewer/map_view.gd").GROUND_ITEM_ICON_SIZE
	_expect(icon_size >= TileAtlasMapType.GROUND_ITEM_ICON_MIN_SIZE and icon_size <= TileAtlasMapType.GROUND_ITEM_ICON_MAX_SIZE,
		"ground-item icon size %s must be between 8 and 10 px" % icon_size)

func _same_cell(a: Dictionary, b: Dictionary) -> bool:
	return int(a["source_id"]) == int(b["source_id"]) and a["coords"] == b["coords"]

func _check_unique(seen: Dictionary, entry: Dictionary, label: String) -> void:
	var key := "%d:%s" % [int(entry["source_id"]), entry["coords"]]
	if seen.has(key):
		_fail("%s shares its (source_id, coords) registration with %s (%s)" % [label, seen[key], key])
	else:
		seen[key] = label

func _check_mapping(atlas_map: Dictionary, kind: String) -> void:
	if not atlas_map.has(kind):
		_fail("missing atlas mapping for kind '%s'" % kind)
		return
	var mapping: Dictionary = atlas_map[kind]
	if not mapping.has("source_id") or not mapping.has("coords"):
		_fail("mapping for '%s' must contain source_id and coords" % kind)
		return
	var source_id: int = int(mapping["source_id"])
	var coords: Vector2i = mapping["coords"]
	if not _tile_set.has_source(source_id):
		_fail("mapping for '%s' references missing source %d" % [kind, source_id])
		return
	var source := _tile_set.get_source(source_id)
	if not source is TileSetAtlasSource:
		_fail("source %d is not a TileSetAtlasSource" % source_id)
		return
	if not source.has_tile(coords):
		_fail("mapping for '%s' references missing atlas tile %s" % [kind, coords])

## Every tile-kind BASE cell (TILE_ATLAS_MAP + its
## TILE_SOIL_VARIANTS) must be fully opaque -- no terrain cell can ever
## expose the viewport background, no matter which renderer draws it. Object
## cells (OBJECT_ATLAS_MAP) and decor cells (TILE_DECOR_MAP, the grass blob)
## are excluded on purpose: they draw *over* their tile's own already-opaque
## base cell, so a transparent margin around them is the intended look.
func _check_cells_fully_opaque(required_kinds: Array) -> void:
	var coords_to_check: Array[Dictionary] = []
	for kind in required_kinds:
		coords_to_check.append(TileAtlasMapType.TILE_ATLAS_MAP[kind])
	for variant_coords in TileAtlasMapType.TILE_SOIL_VARIANTS:
		coords_to_check.append({"source_id": TileAtlasMapType.SOURCE_FLOORS, "coords": variant_coords})
	for entry in coords_to_check:
		var source_id: int = int(entry["source_id"])
		var coords: Vector2i = entry["coords"]
		var source := _tile_set.get_source(source_id)
		if not source is TileSetAtlasSource:
			continue
		var atlas_source: TileSetAtlasSource = source
		var region := atlas_source.get_tile_texture_region(coords)
		var image: Image = atlas_source.texture.get_image()
		if image == null:
			_fail("could not read pixel data for source %d" % source_id)
			continue
		for y in range(region.position.y, region.position.y + region.size.y):
			for x in range(region.position.x, region.position.x + region.size.x):
				if image.get_pixel(x, y).a < 1.0:
					_fail("source %d coords %s has a non-opaque pixel at (%d,%d) -- terrain base cells must never expose the viewport background" % [source_id, coords, x, y])
					return

## Shore-join tests must verify actual rendered
## geometry, not trust the coordinate tables. Re-derives each grass edge/
## corner/concave cell's real grass (opaque) distribution directly from
## the terrain sheet's own pixels and asserts the named direction/quadrant has
## LESS grass coverage than its opposite -- i.e. that direction is really
## where a foreign neighbour's material would show through.
func _check_grass_blob_orientation() -> void:
	var source := _tile_set.get_source(TileAtlasMapType.SOURCE_FLOORS)
	if not source is TileSetAtlasSource:
		_fail("SOURCE_FLOORS is not a TileSetAtlasSource")
		return
	var atlas_source: TileSetAtlasSource = source
	var img: Image = atlas_source.texture.get_image()
	if img == null:
		_fail("could not read pixel data from the terrain sheet source for orientation checks")
		return
	var band_of_direction := {"N": "top", "S": "bottom", "E": "right", "W": "left"}
	var opposite_band := {"N": "bottom", "S": "top", "E": "left", "W": "right"}
	for direction in TileAtlasMapType.GRASS_EDGE_COORDS:
		var coords: Vector2i = TileAtlasMapType.GRASS_EDGE_COORDS[direction]
		var bands := _measure_bands(img, atlas_source.get_tile_texture_region(coords))
		var named: float = bands[band_of_direction[direction]]
		var opposite: float = bands[opposite_band[direction]]
		if not (named < opposite):
			_fail("grass edge '%s' at %s: measured band grass-coverage (named=%s, opposite=%s) does not match the claimed direction" % [direction, coords, named, opposite])
	var opposite_quad := {"NE": "SW", "NW": "SE", "SE": "NW", "SW": "NE"}
	for group in [TileAtlasMapType.GRASS_CORNER_COORDS, TileAtlasMapType.GRASS_CONCAVE_COORDS]:
		for direction in group:
			var coords: Vector2i = group[direction]
			var quads := _measure_quads(img, atlas_source.get_tile_texture_region(coords))
			var named: float = quads[direction]
			var opposite: float = quads[opposite_quad[direction]]
			if not (named < opposite):
				_fail("grass corner/concave '%s' at %s: measured quadrant grass-coverage (named=%s, opposite=%s) does not match the claimed direction" % [direction, coords, named, opposite])

func _measure_bands(img: Image, region: Rect2i) -> Dictionary:
	var top := 0; var bottom := 0; var left := 0; var right := 0
	var ox := region.position.x
	var oy := region.position.y
	for y in region.size.y:
		for x in region.size.x:
			if img.get_pixel(ox + x, oy + y).a > 0.5:
				if y < 4: top += 1
				if y >= region.size.y - 4: bottom += 1
				if x < 4: left += 1
				if x >= region.size.x - 4: right += 1
	return {"top": top, "bottom": bottom, "left": left, "right": right}

func _measure_quads(img: Image, region: Rect2i) -> Dictionary:
	var quad := {"NW": 0, "NE": 0, "SW": 0, "SE": 0}
	var ox := region.position.x
	var oy := region.position.y
	var half_w := region.size.x / 2
	var half_h := region.size.y / 2
	for y in region.size.y:
		for x in region.size.x:
			if img.get_pixel(ox + x, oy + y).a > 0.5:
				if x < half_w and y < half_h: quad["NW"] += 1
				if x >= half_w and y < half_h: quad["NE"] += 1
				if x < half_w and y >= half_h: quad["SW"] += 1
				if x >= half_w and y >= half_h: quad["SE"] += 1
	return quad

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
