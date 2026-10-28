class_name SaveCheck
extends RefCounted

## Shared checks for the per-module save validators (validators/*.gd) and SaveIO.
## A wrong type, range, enum or unexpected field is schema_error; a missing
## required field is no_migration_available (simulation-boundaries.md, ADR 003).

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "code": "schema_error", "message": message}

## docs/architecture/simulation-boundaries.md's persistence boundary and ADR
## 003 principle 3 both require a missing required field to fail with a
## migration error, never a silent default. Reuse the migration stub's own
## code: from the reader's view a missing field is exactly what a migration
## would need to backfill, and none is available yet.
static func _fail_missing(message: String) -> Dictionary:
	return {"ok": false, "code": "no_migration_available", "message": message}

## Shared shape check for every nested object in the tree: an unexpected key
## is a schema_error (the producer wrote something this schema never
## declared), but any absent required key -- at any nesting depth -- is a
## missing-field migration error, never schema_error. Centralizing this here
## is what keeps that rule uniform across every nested validator below,
## instead of re-deciding it per call site.
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

## Matches the schema's `^[a-z0-9_-]*$` job.itemId pattern: like
## _matches_id_pattern but an empty string is valid (a non-haul job's
## harmless default, see JobQueue.submit_dig()).
static func _matches_optional_id_pattern(value) -> bool:
	if not (value is String):
		return false
	var text: String = value
	if text.is_empty():
		return true
	return _matches_id_pattern(text)

## Every persisted tile coordinate is bounds-checked against the map's own declared width/height, not just non-negative -- a
## job target/cell, route/search tile, or scheduling entry naming a
## coordinate outside the live map can never be smuggled in through a
## hand-edited or corrupted save (docs/architecture/save-system.md).
static func _valid_tile(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid tile type")
	var tile: Dictionary = value
	var check := _require_fields(tile, ["x", "y"], "tile")
	if not check["ok"]:
		return check
	if (not _is_int_min(tile["x"], 0) or not _is_int_min(tile["y"], 0)
			or int(tile["x"]) >= map_width or int(tile["y"]) >= map_height):
		return _fail("invalid tile coordinates")
	return {"ok": true}

static func _valid_tile_array(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid tile array type")
	for tile in value:
		var check := _valid_tile(tile, map_width, map_height)
		if not check["ok"]:
			return check
	return {"ok": true}
