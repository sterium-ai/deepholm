class_name ObjectValidator
extends SaveCheck

## Save validation for what ObjectTable, ConstructionSystem, ZoneTable and AreaOrders persist:
## "objects", "constructionSites", "zones", "nextZoneId", "areaOrders".

## The optional "health" key is present only for an object whose kind
## declares "max_health", mirroring how "rerouting" is optional on
## an entity's route (EntityValidator._valid_entity_route()) -- allowed via the
## required+optional union passed to _keys_allowed(), not through
## _require_fields() (whose single "required" array doubles as the exhaustive
## allowed set, which would reject "health" outright as unexpected). The
## optional "orientation" key is this same union's other member:
## "horizontal", "vertical", "" or absent, with "" and absent both meaning
## "no rotation" (the schema and codec must accept an explicit ""
## identically to the key's absence, since either represents the default
## orientation of every footprint-[1,1] kind).
static func _valid_object(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid objects entry type")
	var object_entry: Dictionary = value
	var required := ["target", "kind", "factionId"]
	var optional := ["health", "orientation"]
	if not _keys_allowed(object_entry, required + optional):
		return _fail("unexpected objects entry field")
	for key in required:
		if not object_entry.has(key):
			return _fail_missing("missing objects entry field '%s'" % key)
	var target_check := _valid_tile(object_entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _matches_id_pattern(object_entry["kind"]):
		return _fail("invalid objects entry kind")
	if not _matches_id_pattern(object_entry["factionId"]):
		return _fail("invalid objects entry factionId")
	if object_entry.has("orientation") and not (object_entry["orientation"] == "" or object_entry["orientation"] == "horizontal" or object_entry["orientation"] == "vertical"):
		return _fail("invalid objects entry orientation")
	if not object_entry.has("health"):
		return {"ok": true}
	return _valid_object_health(object_entry["health"])

## Mirrors the schema's "object.health" $def. Optional at the
## objects-entry level -- the key's absence is allowed (checked by the caller
## above) for a bare/non-damageable object, exactly like route.rerouting
## (EntityValidator._valid_entity_route());
## present only for an object whose kind declares "max_health"
## (content/objects.json), same as world._object_health. Once the key is
## present, though, its value must be a valid Dictionary: an explicit
## `"health": null` is rejected here, not waved through as
## "absent" -- the schema's object $def has no null variant, and
## StateCodec._decode_objects() assigns item["health"] straight into a typed
## Dictionary variable the instant item.has("health") is true, which errors
## on null rather than failing gracefully.
static func _valid_object_health(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid objects entry health type")
	var health: Dictionary = value
	var check := _require_fields(health, ["hp", "maxHp"], "objects entry health")
	if not check["ok"]:
		return check
	if not _is_int_min(health["hp"], 0):
		return _fail("invalid objects entry health hp")
	if not _is_int_min(health["maxHp"], 1):
		return _fail("invalid objects entry health maxHp")
	return {"ok": true}

## Mirrors the schema's "constructionSite" $def -- one record per
## active construction site, structurally independent of any job.
static func _valid_construction_site(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid constructionSites entry type")
	var site: Dictionary = value
	var required := ["id", "kind", "origin", "orientation", "requiredMaterials", "heldMaterials", "progress", "buildTicks", "maxBuilders", "builderIds"]
	if not _keys_allowed(site, required):
		return _fail("unexpected constructionSites entry field")
	for key in required:
		if not site.has(key):
			return _fail_missing("missing constructionSites entry field '%s'" % key)
	if not _matches_id_pattern(site["id"]):
		return _fail("invalid constructionSites entry id")
	if not _matches_id_pattern(site["kind"]):
		return _fail("invalid constructionSites entry kind")
	var origin_check := _valid_tile(site["origin"], map_width, map_height)
	if not origin_check["ok"]:
		return origin_check
	if not (site["orientation"] == "" or site["orientation"] == "horizontal" or site["orientation"] == "vertical"):
		return _fail("invalid constructionSites entry orientation")
	if not (site["requiredMaterials"] is Array):
		return _fail("invalid constructionSites entry requiredMaterials type")
	for entry in site["requiredMaterials"]:
		var material_check := _valid_material_entry(entry)
		if not material_check["ok"]:
			return material_check
	if not (site["heldMaterials"] is Array):
		return _fail("invalid constructionSites entry heldMaterials type")
	for entry in site["heldMaterials"]:
		var held_check := _valid_material_entry(entry)
		if not held_check["ok"]:
			return held_check
	if not _is_int_min(site["progress"], 0):
		return _fail("invalid constructionSites entry progress")
	if not _is_int_min(site["buildTicks"], 1):
		return _fail("invalid constructionSites entry buildTicks")
	if not _is_int_min(site["maxBuilders"], 1):
		return _fail("invalid constructionSites entry maxBuilders")
	if not (site["builderIds"] is Array):
		return _fail("invalid constructionSites entry builderIds type")
	for id in site["builderIds"]:
		if not _matches_id_pattern(id):
			return _fail("invalid constructionSites entry builderIds")
	return {"ok": true}

static func _valid_material_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid constructionSites entry material type")
	var check := _require_fields(value, ["item", "quantity"], "constructionSites entry material")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(value["item"]):
		return _fail("invalid constructionSites entry material item")
	if not _is_int_min(value["quantity"], 0):
		return _fail("invalid constructionSites entry material quantity")
	return {"ok": true}

static func _valid_zones(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid zones type")
	var seen_ids := {}
	for zone in (value as Array):
		var zone_check := _valid_zone(zone, map_width, map_height)
		if not zone_check["ok"]:
			return zone_check
		var zone_id: String = (zone as Dictionary)["id"]
		if seen_ids.has(zone_id):
			return _fail("duplicate zone id '%s'" % zone_id)
		seen_ids[zone_id] = true
	return {"ok": true}

static func _valid_zone(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid zone type")
	var zone: Dictionary = value
	var check := _require_fields(zone, ["id", "x", "y", "width", "height"], "zone")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(zone["id"]):
		return _fail("invalid zone id")
	if not _is_int_min(zone["x"], 0) or not _is_int_min(zone["y"], 0):
		return _fail("invalid zone position")
	if not _is_int_min(zone["width"], 1) or not _is_int_min(zone["height"], 1):
		return _fail("invalid zone dimensions")
	if int(zone["x"]) + int(zone["width"]) > map_width or int(zone["y"]) + int(zone["height"]) > map_height:
		return _fail("invalid zone bounds")
	return {"ok": true}

## "areaOrders" (ADR 044): {nextId, list, created}, each
## list entry one pending area_order expansion as AreaOrders.encode() writes
## it -- a known order kind, a non-empty in-map rectangle, a next tile index
## inside it and distinct "done" indexes from next on; each "created" entry a
## [first, end, order id] job-number range, ascending and disjoint.
static func _valid_area_orders(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid areaOrders type")
	if not _keys_allowed(value, ["nextId", "list", "created"]):
		return _fail("unexpected areaOrders field")
	for key in ["nextId", "list", "created"]:
		if not value.has(key):
			return _fail_missing("missing areaOrders field '%s'" % key)
	if not _is_int_min(value["nextId"], 1) or not (value["list"] is Array) or not (value["created"] is Array):
		return _fail("invalid areaOrders nextId, list or created")
	var range_end := 0
	for created in value["created"]:
		if not (created is Array) or created.size() != 3 or not _is_int(created[0]) or not _is_int(created[1]) or not _is_int(created[2]):
			return _fail("invalid areaOrders created range")
		if int(created[0]) < range_end or int(created[1]) <= int(created[0]) or int(created[2]) < 1 or int(created[2]) >= int(value["nextId"]):
			return _fail("invalid areaOrders created range")
		range_end = int(created[1])
	var fields := ["id", "order", "actor", "commandId", "x", "y", "width", "height", "priority", "next", "done", "jobLimit", "siteLimit"]
	for entry in value["list"]:
		if not (entry is Dictionary) or not _keys_allowed(entry, fields):
			return _fail("invalid areaOrders entry")
		for key in fields:
			if not entry.has(key):
				return _fail_missing("missing areaOrders entry field '%s'" % key)
		for key in ["order", "actor", "commandId"]:
			if not (entry[key] is String) or str(entry[key]).is_empty():
				return _fail("invalid areaOrders entry %s" % key)
		if not AreaOrders.ORDERS.has(str(entry["order"])):
			return _fail("invalid areaOrders entry order")
		for key in ["id", "x", "y", "width", "height", "priority", "next", "jobLimit", "siteLimit"]:
			if not _is_int(entry[key]):
				return _fail("invalid areaOrders entry %s" % key)
		var rect := Rect2i(int(entry["x"]), int(entry["y"]), int(entry["width"]), int(entry["height"]))
		if not rect.has_area() or not Rect2i(0, 0, map_width, map_height).encloses(rect):
			return _fail("invalid areaOrders entry rectangle")
		if int(entry["next"]) < 0 or int(entry["next"]) >= rect.get_area() or int(entry["id"]) >= int(value["nextId"]):
			return _fail("invalid areaOrders entry next or id")
		if not (entry["done"] is Array):
			return _fail("invalid areaOrders entry done")
		var seen := {}
		for index in entry["done"]:
			if not _is_int(index) or int(index) < int(entry["next"]) or int(index) >= rect.get_area() or seen.has(int(index)):
				return _fail("invalid areaOrders entry done")
			seen[int(index)] = true
	return {"ok": true}

static func _valid_objects(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid objects type")
	for object_entry in value:
		var object_check := _valid_object(object_entry, map_width, map_height)
		if not object_check["ok"]:
			return object_check
	return {"ok": true}

static func _valid_construction_sites(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid constructionSites type")
	for site_entry in value:
		var site_check := _valid_construction_site(site_entry, map_width, map_height)
		if not site_check["ok"]:
			return site_check
	return {"ok": true}
