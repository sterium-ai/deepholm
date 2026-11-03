class_name FarmValidator
extends SaveCheck

## Save validation for what FarmSystem persists: "crops" (F1, ADR 059), a list of
## {target, crop, growth}, one entry per tile, crop a crops.json id, growth >= 0; and
## "saplings" (F6a, ADR 067), the same shape with "forest", a forests.json id.

static func _valid_crops(value: Variant, map_width: int, map_height: int, layer_count: int, crop_ids: Array[String]) -> Dictionary:
	return _valid_growth_records(value, "crops", "crop", map_width, map_height, layer_count, crop_ids)

static func _valid_saplings(value: Variant, map_width: int, map_height: int, layer_count: int, forest_ids: Array[String]) -> Dictionary:
	return _valid_growth_records(value, "saplings", "forest", map_width, map_height, layer_count, forest_ids)

## One growth list: name is its save field, id_field the content id each entry names.
static func _valid_growth_records(value: Variant, name: String, id_field: String, map_width: int, map_height: int,
		layer_count: int, ids: Array[String]) -> Dictionary:
	if not (value is Array):
		return _fail("invalid %s type" % name)
	var seen := {}
	for item: Variant in (value as Array):
		if not (item is Dictionary):
			return _fail("invalid %s entry type" % name)
		var entry: Dictionary = item
		var check := _require_fields(entry, ["target", id_field, "growth"], "%s entry" % name)
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
		if not ids.has(entry[id_field]):
			return _fail("%s entry names an unknown %s" % [name, id_field])
		if typeof(entry["growth"]) != TYPE_INT:
			return _fail("invalid %s entry growth" % name)
		var growth: int = entry["growth"]
		if growth < 0:
			return _fail("invalid %s entry growth" % name)
		var key := TileGrid.comma_key(Vector3i(x, y, z))
		if seen.has(key):
			return _fail("duplicate %s entry target %s" % [name, key])
		seen[key] = true
	return {"ok": true}
