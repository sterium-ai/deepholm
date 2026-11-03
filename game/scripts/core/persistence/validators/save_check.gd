class_name SaveCheck
extends RefCounted

## Shared checks for the per-module save validators (validators/*.gd) and SaveIO.
## A wrong type, range, enum or unexpected field is schema_error; a missing
## required field is no_migration_available (simulation-boundaries.md, ADR 003).

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "code": "schema_error", "message": message}

## A missing required field fails as a migration error, never a silent default
## (simulation-boundaries.md, ADR 003 principle 3).
static func _fail_missing(message: String) -> Dictionary:
	return {"ok": false, "code": "no_migration_available", "message": message}

## Invariant at every depth: an unexpected key is schema_error, a missing required key is the
## migration error. Centralised here so every validator applies it the same way.
static func _require_fields(dict: Dictionary, required: Array, label: String) -> Dictionary:
	if not _keys_allowed(dict, required):
		return _fail("unexpected %s field" % label)
	for key in required:
		if not dict.has(key):
			return _fail_missing("missing %s field '%s'" % [label, key])
	return {"ok": true}

static func _keys_allowed(dict: Dictionary, allowed: Array) -> bool:
	for key in dict.keys():
		if not allowed.has(key):
			return false
	return true

static func _is_int(value) -> bool:
	return typeof(value) == TYPE_INT

static func _is_int_min(value, minimum: int) -> bool:
	return _is_int(value) and int(value) >= minimum

## Matches the schema's `^[a-z0-9_-]+$` id pattern (entities, jobs, queue
## entries, inventory keys).
static func _matches_id_pattern(value) -> bool:
	if not (value is String):
		return false
	var text: String = value
	if text.is_empty():
		return false
	for i in range(text.length()):
		var c := text.unicode_at(i)
		var allowed := (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 95
		if not allowed:
			return false
	return true

## Like _matches_id_pattern but "" is valid (a non-haul job's itemId).
static func _matches_optional_id_pattern(value) -> bool:
	if not (value is String):
		return false
	var text: String = value
	if text.is_empty():
		return true
	return _matches_id_pattern(text)

## Every tile is bounded by the map's declared width/height and layerCount (ADR 045 §5), so a
## corrupted save cannot smuggle in an out-of-map target.
static func _valid_tile(value, map_width: int, map_height: int, layer_count: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid tile type")
	var tile: Dictionary = value
	var check := _require_fields(tile, ["x", "y", "z"], "tile")
	if not check["ok"]:
		return check
	if (not _is_int_min(tile["x"], 0) or not _is_int_min(tile["y"], 0)
			or int(tile["x"]) >= map_width or int(tile["y"]) >= map_height or not _valid_layer(tile["z"], layer_count)):
		return _fail("invalid tile coordinates")
	return {"ok": true}

## A record's "z" (a tile object's or a flat x/y/z record's): 0 <= z < layerCount.
static func _valid_layer(value, layer_count: int) -> bool:
	return _is_int_min(value, 0) and int(value) < layer_count

static func _valid_tile_array(value, map_width: int, map_height: int, layer_count: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid tile array type")
	for tile in value:
		var check := _valid_tile(tile, map_width, map_height, layer_count)
		if not check["ok"]:
			return check
	return {"ok": true}
