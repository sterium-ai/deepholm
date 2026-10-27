class_name ItemValidator
extends SaveCheck

## Save validation for what ItemTable persists: "items", "groundBerries", "digFindRng",
## plus the top-level "inventory" map.

static func _valid_items(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid items type")
	var items: Dictionary = value
	var check := _require_fields(items, ["nextId", "list"], "items")
	if not check["ok"]:
		return check
	if not _is_int_min(items["nextId"], 1):
		return _fail("invalid items.nextId")
	if not (items["list"] is Array):
		return _fail("invalid items.list type")
	var seen_ids := {}
	for item in items["list"]:
		var item_check := _valid_item(item, map_width, map_height)
		if not item_check["ok"]:
			return item_check
		var item_id: String = (item as Dictionary)["id"]
		if seen_ids.has(item_id):
			return _fail("duplicate item id '%s'" % item_id)
		seen_ids[item_id] = true
	return {"ok": true}

## map_width/map_height bound every position field below, in addition
## to the non-negative check -- an entity/item/object/zone at or
## beyond the map's own declared width/height is rejected the same way a
## negative one is.
static func _valid_item(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid item type")
	var item: Dictionary = value
	var check := _require_fields(item, ["id", "x", "y", "kind", "count", "factionId"], "item")
	if not check["ok"]:
		return check
	if not _is_int_min(item["x"], 0) or not _is_int_min(item["y"], 0) or int(item["x"]) >= map_width or int(item["y"]) >= map_height:
		return _fail("invalid item position")
	if not _matches_id_pattern(item["id"]):
		return _fail("invalid item id")
	if not _matches_id_pattern(item["kind"]):
		return _fail("invalid item kind")
	if not _is_int_min(item["count"], 1):
		return _fail("invalid item count")
	if not _matches_id_pattern(item["factionId"]):
		return _fail("invalid item factionId")
	return {"ok": true}

## Mirrors _valid_zones()/_valid_zone(): ItemTable.ground_berries's wire shape is
## an array of {target, berries, factionId} entries (see StateCodec._encode_ground_berries()),
## each a simple per-tile counter, not a first-class item with an id. factionId
## is required (ADR 047).
static func _valid_ground_berries(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid groundBerries type")
	for entry in (value as Array):
		var entry_check := _valid_ground_berries_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
	return {"ok": true}

static func _valid_ground_berries_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid groundBerries entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["target", "berries", "factionId"], "groundBerries entry")
	if not check["ok"]:
		return check
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _is_int_min(entry["berries"], 1):
		return _fail("invalid groundBerries entry berries")
	if not _matches_id_pattern(entry["factionId"]):
		return _fail("invalid groundBerries entry factionId")
	return {"ok": true}

## world._dig_find_random's own continuation (ADR 026,
## StateCodec._encode()'s "digFindRng"): the same {seed, state} shape as
## top-level "rng"; optional at the top level (SaveIO.OPTIONAL_TOP_LEVEL_FIELDS).
static func _valid_dig_find_rng(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid digFindRng type")
	var rng: Dictionary = value
	if not _keys_allowed(rng, ["seed", "state"]):
		return _fail("unexpected digFindRng field")
	if not rng.has("seed") or not rng.has("state"):
		return _fail_missing("missing digFindRng field")
	if not _is_int(rng["seed"]) or not _is_int(rng["state"]):
		return _fail("invalid digFindRng fields")
	return {"ok": true}

static func _valid_inventory(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid inventory type")
	for key in value.keys():
		if not _matches_id_pattern(key):
			return _fail("invalid inventory key")
		if not _is_int_min(value[key], 0):
			return _fail("invalid inventory value")
	return {"ok": true}
