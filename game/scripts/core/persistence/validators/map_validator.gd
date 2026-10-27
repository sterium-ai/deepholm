class_name MapValidator
extends SaveCheck

## Save validation for what TileGrid persists: "map" (dimensions, tiles, generatorVersion).

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")

static func _valid_map(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid map type")
	var map: Dictionary = value
	if not _keys_allowed(map, ["width", "height", "tiles", "generatorVersion"]):
		return _fail("unexpected map field")
	for key in ["width", "height", "tiles", "generatorVersion"]:
		if not map.has(key):
			return _fail_missing("missing map field '%s'" % key)
	if not _is_int_min(map.get("width"), 1) or not _is_int_min(map.get("height"), 1):
		return _fail("invalid map dimensions")
	# A saved map keeps its exact size on load (no re-clamp to the 16-tile new-game
	# minimum), so only the upper bound WorldGenerator can produce applies.
	var max_world_size := int(ContentRegistryType.new().document("mapgen").get("max_world_size", WorldGeneratorType.DEFAULT_MAX_WORLD_SIZE))
	if int(map["width"]) > max_world_size or int(map["height"]) > max_world_size:
		return _fail("map dimensions exceed the supported maximum")
	if not _is_int_min(map.get("generatorVersion"), 1):
		return _fail("invalid map generatorVersion")
	if not (map.get("tiles") is Array):
		return _fail("invalid map tiles type")
	for tile in map["tiles"]:
		if not (tile is String) or not ["rock", "soil", "floor", "plowed_soil", "planted", "hazard", "tree", "water", "trench"].has(tile):
			return _fail("invalid map tile")
	var map_width := int(map["width"])
	var map_height := int(map["height"])
	# A truncated or hand-edited tile list is rejected here, not indexed out of bounds later.
	if (map["tiles"] as Array).size() != map_width * map_height:
		return _fail("map tiles length does not match width*height")
	return {"ok": true}
