class_name EntityValidator
extends SaveCheck

## Save validation for what ActorTable persists: "entities" and their components.

const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

## Entity kind -> the component fields it must carry (the schema's per-kind if/then, i.e.
## what ActorTable.spawn() builds for that kind).
const ENTITY_COMPONENT_FIELDS := {
	"colonist": ["needs", "needsAccumulator", "labourTable", "work", "hands"],
	"wolf": ["needs", "needsAccumulator", "combat", "wild"],
	"trader": ["inventory", "visitor"],
}

## "rerouting" is present only while a re-route is in flight.
static func _valid_entity_route(value, map_width: int, map_height: int) -> Dictionary:
	if value == null:
		return {"ok": true}
	if not (value is Dictionary):
		return _fail("invalid entity route type")
	var route: Dictionary = value
	var required := ["jobId", "path", "step", "moveTicksRemaining"]
	var optional := ["rerouting"]
	if not _keys_allowed(route, required + optional):
		return _fail("unexpected entity route field")
	for key in required:
		if not route.has(key):
			return _fail_missing("missing entity route field '%s'" % key)
	if not (route["jobId"] is String):
		return _fail("invalid entity route jobId")
	var path_check := _valid_tile_array(route["path"], map_width, map_height)
	if not path_check["ok"]:
		return path_check
	if (route["path"] as Array).size() < 1:
		return _fail("entity route path must have at least one tile")
	if not _is_int_min(route["step"], 0) or not _is_int_min(route["moveTicksRemaining"], 0):
		return _fail("invalid entity route step or moveTicksRemaining")
	if route.has("rerouting") and route["rerouting"] != null:
		var rerouting_check := SchedulingValidator._valid_route_state(route["rerouting"], map_width, map_height)
		if not rerouting_check["ok"]:
			return rerouting_check
	return {"ok": true}

## labourTable (colonist-ai.md 3.2): the fixed 7 kinds, each level an int 0..4.
static func _valid_labour_table(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity labourTable type")
	var labour_kinds := ["mine", "chop", "farm", "haul", "build", "craft", "cook"]
	var check := _require_fields(value, labour_kinds, "entity labourTable")
	if not check["ok"]:
		return check
	for kind in labour_kinds:
		if not _is_int(value[kind]) or int(value[kind]) < 0 or int(value[kind]) > 4:
			return _fail("invalid entity labourTable level '%s'" % kind)
	return {"ok": true}

## "trapped" is validated for every kind (anyone can fall into a trench).
static func _valid_entity_trapped(value, map_width: int, map_height: int) -> Dictionary:
	if value == null:
		return {"ok": true}
	if not (value is Dictionary):
		return _fail("invalid entity trapped type")
	var trapped: Dictionary = value
	if not _keys_allowed(trapped, ["tile", "ticksRemaining", "fromTile"]) or not trapped.has("tile"):
		return _fail_missing("invalid entity trapped fields")
	var tile_check := _valid_tile(trapped["tile"], map_width, map_height)
	if not tile_check["ok"]:
		return tile_check
	if trapped.has("ticksRemaining") and not _is_int_min(trapped["ticksRemaining"], 1):
		return _fail("invalid entity trapped ticksRemaining")
	if trapped.has("fromTile"):
		var from_tile_check := _valid_tile(trapped["fromTile"], map_width, map_height)
		if not from_tile_check["ok"]:
			return from_tile_check
	return {"ok": true}

static func _valid_entity_work(value) -> Dictionary:
	if value == null:
		return {"ok": true}
	if not (value is Dictionary):
		return _fail("invalid entity work type")
	var work: Dictionary = value
	var check := _require_fields(work, ["jobId", "ticksRemaining"], "entity work")
	if not check["ok"]:
		return check
	if not (work["jobId"] is String) or not _is_int_min(work["ticksRemaining"], 0):
		return _fail("invalid entity work fields")
	return {"ok": true}

## The health component; always present, never null.
static func _valid_entity_health(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity health type")
	var health: Dictionary = value
	var check := _require_fields(health, ["hp", "maxHp", "dead"], "entity health")
	if not check["ok"]:
		return check
	if not _is_int_min(health["hp"], 0):
		return _fail("invalid entity health hp")
	if not _is_int_min(health["maxHp"], 1):
		return _fail("invalid entity health maxHp")
	if not (health["dead"] is bool):
		return _fail("invalid entity health dead")
	return {"ok": true}

## Mirrors the schema's "combat" $def (ActorCombat.build()).
static func _valid_entity_combat(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity combat type")
	var check := _require_fields(value, ["attack", "damage", "cooldown", "cooldownRemaining"], "entity combat")
	if not check["ok"]:
		return check
	if (not _is_int_min(value["attack"], 0) or not _is_int_min(value["damage"], 0)
			or not _is_int_min(value["cooldown"], 1) or not _is_int_min(value["cooldownRemaining"], 0)):
		return _fail("invalid entity combat fields")
	return {"ok": true}

## items array, tool id (or ""), capacity >= 1.
static func _valid_entity_inventory(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity inventory type")
	var check := _require_fields(value, ["items", "tool", "capacity"], "entity inventory")
	if not check["ok"]:
		return check
	if not (value["items"] is Array) or not (value["tool"] is String) or not _matches_optional_id_pattern(value["tool"]):
		return _fail("invalid entity inventory fields")
	if not _is_int_min(value["capacity"], 1):
		return _fail("invalid entity inventory capacity")
	return {"ok": true}

## At most one entry per kind, each count >= 1, total <= ActorInventory.HANDS_CAPACITY.
static func _valid_entity_hands(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid entity hands type")
	var hands: Array = value
	var seen_kinds := {}
	var total := 0
	for raw_entry in hands:
		if not (raw_entry is Dictionary):
			return _fail("invalid entity hands entry type")
		var entry: Dictionary = raw_entry
		var check := _require_fields(entry, ["kind", "count"], "entity hands entry")
		if not check["ok"]:
			return check
		if not _matches_id_pattern(entry["kind"]):
			return _fail("invalid entity hands entry kind")
		if not _is_int_min(entry["count"], 1):
			return _fail("invalid entity hands entry count")
		if seen_kinds.has(entry["kind"]):
			return _fail("duplicate entity hands entry kind")
		seen_kinds[entry["kind"]] = true
		total += int(entry["count"])
	if total > InventoryType.HANDS_CAPACITY:
		return _fail("entity hands total count exceeds capacity")
	return {"ok": true}

static func _valid_entities(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid entities type")
	for entity in value:
		var entity_check := _valid_entity(entity, map_width, map_height)
		if not entity_check["ok"]:
			return entity_check
	return {"ok": true}

static func _valid_entity(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity type")
	var entity: Dictionary = value
	if not _keys_allowed(entity, ["id", "kind", "x", "y", "factionId", "health", "trapped", "needs", "needsAccumulator", "labourTable", "route", "work", "hands", "heldTool", "combat", "inventory", "wild", "visitor"]):
		return _fail("unexpected entity field")
	if (not entity.has("id") or not entity.has("kind") or not entity.has("x") or not entity.has("y")
			or not entity.has("factionId") or not entity.has("health") or not entity.has("route") or not entity.has("trapped")):
		return _fail_missing("missing entity field")
	if not _matches_id_pattern(entity["id"]) or not ENTITY_COMPONENT_FIELDS.has(entity["kind"]):
		return _fail("invalid entity id or kind")
	# Each kind carries exactly its own component fields (game-state.schema.json's per-kind if/then).
	for field in ENTITY_COMPONENT_FIELDS[entity["kind"]]:
		if not entity.has(field):
			return _fail_missing("missing entity field '%s'" % field)
	if (not _is_int_min(entity["x"], 0) or not _is_int_min(entity["y"], 0)
			or int(entity["x"]) >= map_width or int(entity["y"]) >= map_height):
		return _fail("invalid entity position")
	if not _matches_id_pattern(entity["factionId"]):
		return _fail("invalid entity factionId")
	var health_check := _valid_entity_health(entity["health"])
	if not health_check["ok"]:
		return health_check
	var needs_check := _valid_entity_needs(entity)
	if not needs_check["ok"]:
		return needs_check
	if entity.has("labourTable"):
		var labour_table_check := _valid_labour_table(entity["labourTable"])
		if not labour_table_check["ok"]:
			return labour_table_check
	var route_check := _valid_entity_route(entity["route"], map_width, map_height)
	if not route_check["ok"]:
		return route_check
	var trapped_check := _valid_entity_trapped(entity["trapped"], map_width, map_height)
	if not trapped_check["ok"]:
		return trapped_check
	if entity.has("work"):
		var work_check := _valid_entity_work(entity["work"])
		if not work_check["ok"]:
			return work_check
	if entity.has("hands"):
		var hands_check := _valid_entity_hands(entity["hands"])
		if not hands_check["ok"]:
			return hands_check
	if entity.has("heldTool") and (not (entity["heldTool"] is String) or not _matches_optional_id_pattern(entity["heldTool"])):
		return _fail("invalid entity heldTool")
	if entity.has("combat"):
		var combat_check := _valid_entity_combat(entity["combat"])
		if not combat_check["ok"]:
			return combat_check
	if entity.has("inventory"):
		var inventory_check := _valid_entity_inventory(entity["inventory"])
		if not inventory_check["ok"]:
			return inventory_check
	for flag in ["wild", "visitor"]:
		if entity.has(flag) and entity[flag] != true:
			return _fail("invalid entity %s" % flag)
	return {"ok": true}

## "needs" and "needsAccumulator", each present only for the kinds that declare them.
static func _valid_entity_needs(entity: Dictionary) -> Dictionary:
	if entity.has("needs"):
		var needs: Variant = entity["needs"]
		if not (needs is Dictionary):
			return _fail("invalid entity needs type")
		var needs_check := _require_fields(needs, ["food", "water", "rest"], "entity needs")
		if not needs_check["ok"]:
			return needs_check
		for need_key in ["food", "water", "rest"]:
			if not _is_int(needs[need_key]) or int(needs[need_key]) < 0 or int(needs[need_key]) > 100:
				return _fail("invalid entity need '%s'" % need_key)
	if entity.has("needsAccumulator"):
		var accumulator: Variant = entity["needsAccumulator"]
		if not (accumulator is Dictionary):
			return _fail("invalid entity needsAccumulator type")
		var accumulator_check := _require_fields(accumulator, ["food", "water", "rest"], "entity needsAccumulator")
		if not accumulator_check["ok"]:
			return accumulator_check
		for need_key in ["food", "water", "rest"]:
			if not _is_int(accumulator[need_key]) or int(accumulator[need_key]) < 0:
				return _fail("invalid entity needsAccumulator '%s'" % need_key)
	return {"ok": true}
