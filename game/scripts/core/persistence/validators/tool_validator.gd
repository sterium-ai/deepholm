class_name ToolValidator
extends SaveCheck

## Save validation for what ToolItemStore and the tool toils persist: "toolItems",
## "toolReservations", "toolFetchExcluded".

## Mirrors _valid_items()/_valid_item(): world._tool_items' wire shape is
## {nextId, list} like the ground-item store, but each entry is
## {id, kind, location} (identity-bearing, colonist-ai.md 2/3.4) rather than
## {id, x, y, kind, count} (stackable).
static func _valid_tool_items(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid toolItems type")
	var tool_items: Dictionary = value
	var check := _require_fields(tool_items, ["nextId", "list"], "toolItems")
	if not check["ok"]:
		return check
	if not _is_int_min(tool_items["nextId"], 1):
		return _fail("invalid toolItems.nextId")
	if not (tool_items["list"] is Array):
		return _fail("invalid toolItems.list type")
	var seen_ids := {}
	for item in tool_items["list"]:
		var item_check := _valid_tool_item(item, map_width, map_height)
		if not item_check["ok"]:
			return item_check
		var item_id: String = (item as Dictionary)["id"]
		if seen_ids.has(item_id):
			return _fail("duplicate toolItems id '%s'" % item_id)
		seen_ids[item_id] = true
	return {"ok": true}

static func _valid_tool_item(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid toolItems entry type")
	var item: Dictionary = value
	var check := _require_fields(item, ["id", "kind", "location"], "toolItems entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(item["id"]):
		return _fail("invalid toolItems entry id")
	if not _matches_id_pattern(item["kind"]):
		return _fail("invalid toolItems entry kind")
	return _valid_tool_location(item["location"], map_width, map_height)

## A tool item's location (StateCodec._encode_tool_location()) is a ground or
## stockpile tile, or a held-by-colonist reference -- never both a tile and a
## colonist id.
static func _valid_tool_location(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid tool location type")
	var location: Dictionary = value
	if not (location.get("type") is String):
		return _fail("invalid tool location type field")
	match String(location["type"]):
		"ground", "stockpile":
			var check := _require_fields(location, ["type", "x", "y"], "tool location")
			if not check["ok"]:
				return check
			if (not _is_int_min(location["x"], 0) or not _is_int_min(location["y"], 0)
					or int(location["x"]) >= map_width or int(location["y"]) >= map_height):
				return _fail("invalid tool location position")
			return {"ok": true}
		"held":
			var check := _require_fields(location, ["type", "colonistId"], "tool location")
			if not check["ok"]:
				return check
			if not _matches_id_pattern(location["colonistId"]):
				return _fail("invalid tool location colonistId")
			return {"ok": true}
		_:
			return _fail("invalid tool location type value")

## world._tool_reservations' wire shape is a plain item id -> job id map
## (ReservationTable.snapshot(), colonist-ai.md 3.4), mirroring "inventory"'s
## additionalProperties/propertyNames style rather than an array of entries.
## Every key must reference a currently-declared tool item: a reservation
## can never outlive the item it targets, let alone the job that holds it.
static func _valid_tool_reservations(value, tool_items_value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid toolReservations type")
	var reservations: Dictionary = value
	var known_ids := {}
	if tool_items_value is Dictionary and (tool_items_value as Dictionary).get("list") is Array:
		for item in ((tool_items_value as Dictionary)["list"] as Array):
			if item is Dictionary and item.get("id") is String:
				known_ids[String(item["id"])] = true
	for item_id in reservations.keys():
		if not _matches_id_pattern(item_id):
			return _fail("invalid toolReservations key")
		if not known_ids.has(String(item_id)):
			return _fail("toolReservations references unknown item '%s'" % item_id)
		if not (reservations[item_id] is String) or not _matches_id_pattern(reservations[item_id]):
			return _fail("invalid toolReservations value")
	return {"ok": true}

## _tool_fetch's per-job excluded-candidate set (ADR 013) is an array of {jobId, toolIds} entries (StateCodec.
## _encode_tool_fetch_excluded()), one per job with at least one candidate
## already proven unreachable this fetch attempt. Every toolId must reference
## a currently-declared tool item, mirroring toolReservations' own cross-check
## -- an excluded candidate can never outlive the item it names.
static func _valid_tool_fetch_excluded(value, tool_items_value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid toolFetchExcluded type")
	var known_ids := {}
	if tool_items_value is Dictionary and (tool_items_value as Dictionary).get("list") is Array:
		for item in ((tool_items_value as Dictionary)["list"] as Array):
			if item is Dictionary and item.get("id") is String:
				known_ids[String(item["id"])] = true
	var seen_jobs := {}
	for entry in (value as Array):
		if not (entry is Dictionary):
			return _fail("invalid toolFetchExcluded entry type")
		var check := _require_fields(entry, ["jobId", "toolIds"], "toolFetchExcluded entry")
		if not check["ok"]:
			return check
		if not _matches_id_pattern(entry["jobId"]):
			return _fail("invalid toolFetchExcluded entry jobId")
		if seen_jobs.has(entry["jobId"]):
			return _fail("duplicate toolFetchExcluded jobId '%s'" % entry["jobId"])
		seen_jobs[entry["jobId"]] = true
		if not (entry["toolIds"] is Array) or (entry["toolIds"] as Array).is_empty():
			return _fail("invalid toolFetchExcluded entry toolIds")
		for tool_id in (entry["toolIds"] as Array):
			if not (tool_id is String) or not _matches_id_pattern(tool_id):
				return _fail("invalid toolFetchExcluded entry toolId")
			if not known_ids.has(String(tool_id)):
				return _fail("toolFetchExcluded references unknown item '%s'" % tool_id)
	return {"ok": true}
