class_name FarmValidator
extends SaveCheck

## Save validation for what FarmSystem persists (F1, ADR 059): "crops", a list of
## {target, crop, growth}, one entry per tile, crop a crops.json id, growth >= 0.

static func _valid_crops(value: Variant, map_width: int, map_height: int, layer_count: int, crop_ids: Array[String]) -> Dictionary:
	if not (value is Array):
		return _fail("invalid crops type")
	var seen := {}
	for item: Variant in (value as Array):
		if not (item is Dictionary):
			return _fail("invalid crops entry type")
		var entry: Dictionary = item
		var check := _require_fields(entry, ["target", "crop", "growth"], "crops entry")
		if not check["ok"]:
			return check
		# The tile and growth rules of _valid_tile()/_is_int_min(), on typed values.
		if not (entry["target"] is Dictionary):
			return _fail("invalid tile type")
		var tile: Dictionary = entry["target"]
		var tile_check := _require_fields(tile, ["x", "y", "z"], "tile")
		if not tile_check["ok"]:
			return tile_check
		if typeof(tile["x"]) != TYPE_INT or typeof(tile["y"]) != TYPE_INT or typeof(tile["z"]) != TYPE_INT:
			return _fail("invalid tile coordinates")
		var x: int = tile["x"]
		var y: int = tile["y"]
		var z: int = tile["z"]
		if x < 0 or y < 0 or x >= map_width or y >= map_height or z < 0 or z >= layer_count:
			return _fail("invalid tile coordinates")
		if not crop_ids.has(entry["crop"]):
			return _fail("crops entry names an unknown crop")
		if typeof(entry["growth"]) != TYPE_INT:
			return _fail("invalid crops entry growth")
		var growth: int = entry["growth"]
		if growth < 0:
			return _fail("invalid crops entry growth")
		var key := TileGrid.comma_key(Vector3i(x, y, z))
		if seen.has(key):
			return _fail("duplicate crops entry target %s" % key)
		seen[key] = true
	return {"ok": true}
