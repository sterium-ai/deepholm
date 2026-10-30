class_name MapValidator
extends SaveCheck

## Save validation for what TileGrid persists: "map" (dimensions, layerCount, tiles,
## generatorVersion).
## The tile ids and the size cap come from the session registry (SaveIO.content_rules()).

static func _valid_map(value, tile_ids: Array[String], max_world_size: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid map type")
	var map: Dictionary = value
	if not _keys_allowed(map, ["width", "height", "layerCount", "tiles", "generatorVersion"]):
		return _fail("unexpected map field")
	for key in ["width", "height", "layerCount", "tiles", "generatorVersion"]:
		if not map.has(key):
			return _fail_missing("missing map field '%s'" % key)
	if not _is_int_min(map.get("width"), 1) or not _is_int_min(map.get("height"), 1):
		return _fail("invalid map dimensions")
	# A saved map keeps its exact size on load (no re-clamp to the 16-tile new-game
	# minimum), so only the upper bound WorldGenerator can produce applies.
	if int(map["width"]) > max_world_size or int(map["height"]) > max_world_size:
		return _fail("map dimensions exceed the supported maximum")
	if not _is_int_min(map.get("layerCount"), 1) or int(map["layerCount"]) > TileGrid.MAX_LAYER_COUNT:
		return _fail("invalid map layerCount")
	if not _is_int_min(map.get("generatorVersion"), 1):
		return _fail("invalid map generatorVersion")
	if not (map.get("tiles") is Array):
		return _fail("invalid map tiles type")
	var known_tiles: Dictionary = {}
	for tile_id in tile_ids:
		known_tiles[tile_id] = true
	for tile in map["tiles"]:
		if not (tile is String) or not known_tiles.has(tile):
			return _fail("invalid map tile")
	var map_width := int(map["width"])
	var map_height := int(map["height"])
	# A truncated or hand-edited tile list is rejected here, not indexed out of bounds later.
	if (map["tiles"] as Array).size() != map_width * map_height * int(map["layerCount"]):
		return _fail("map tiles length does not match width*height*layerCount")
	return {"ok": true}
