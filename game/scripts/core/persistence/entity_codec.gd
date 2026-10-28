class_name EntityCodec
extends RefCounted

## StateCodec's "entities" encoding: each actor record and its components (needs, labour
## table, route, work, hands, trapped, combat, health, inventory), JSON-safe both ways.

## Invariant: a component field is emitted only when the live dict carries it (the per-kind
## shape ActorTable.spawn() produces), never a colonist-shaped default; "work"/"route" ride
## along for every kind once present.
static func _encode_entities(colonists: Array[Dictionary], reroutes: Dictionary) -> Array:
	var entities: Array = []
	for colonist in colonists:
		var entity: Dictionary = {
			"id": colonist["id"], "kind": colonist["kind"],
			"x": colonist["x"], "y": colonist["y"],
			"route": _encode_route_field(colonist.get("route"), reroutes.get(colonist["id"])),
			"factionId": String(colonist.get("factionId", "colony")),
			"health": _encode_health(colonist.get("health", {})),
			"trapped": _encode_trapped_field(colonist.get("trapped")),
		}
		if colonist.has("needs"):
			entity["needs"] = _encode_needs(colonist["needs"])
		if colonist.has("needsAccumulator"):
			entity["needsAccumulator"] = _encode_needs(colonist["needsAccumulator"])
		if colonist.has("labourTable"):
			entity["labourTable"] = _encode_labour_table(colonist["labourTable"])
		if colonist.has("work"):
			entity["work"] = _encode_work_field(colonist["work"])
		if colonist.has("hands"):
			entity["hands"] = _encode_hands_field(colonist["hands"])
		if colonist.has("held_tool"):
			entity["heldTool"] = String(colonist["held_tool"])
		if colonist.has("combat"):
			entity["combat"] = _encode_combat(colonist["combat"])
		if colonist.has("inventory"):
			entity["inventory"] = _encode_inventory(colonist["inventory"])
		if colonist.has("wild"):
			entity["wild"] = true
		if colonist.has("visitor"):
			entity["visitor"] = true
		entities.append(entity)
	return entities

## Same presence rule on the way in: a non-colonist decodes without needs/labourTable/hands/
## heldTool, so NeedsSystem.ensure_needs() never mistakes it for a worker. factionId/health
## are required (migrations backfill them) but read with a default.
static func _decode_entities(entities: Array) -> Array[Dictionary]:
	var colonists: Array[Dictionary] = []
	for entity in entities:
		var colonist: Dictionary = {
			"id": entity["id"], "kind": entity["kind"],
			"x": int(entity["x"]), "y": int(entity["y"]),
			"route": _decode_route_field(entity.get("route")),
			"factionId": String(entity.get("factionId", "colony")),
			"health": _decode_health(entity.get("health", {})),
			"trapped": _decode_trapped_field(entity.get("trapped")),
		}
		if entity.has("needs"):
			colonist["needs"] = _decode_needs(entity["needs"])
		if entity.has("needsAccumulator"):
			colonist["needsAccumulator"] = _decode_needs(entity["needsAccumulator"])
		if entity.has("labourTable"):
			colonist["labourTable"] = _decode_labour_table(entity["labourTable"])
		if entity.has("work"):
			colonist["work"] = _decode_work_field(entity["work"])
		if entity.has("hands"):
			colonist["hands"] = _decode_hands_field(entity["hands"])
		if entity.has("heldTool"):
			colonist["held_tool"] = String(entity["heldTool"])
		if entity.has("combat"):
			colonist["combat"] = _decode_combat(entity["combat"])
		if entity.has("inventory"):
			colonist["inventory"] = _encode_inventory(entity["inventory"])
		if entity.has("wild"):
			colonist["wild"] = true
		if entity.has("visitor"):
			colonist["visitor"] = true
		colonists.append(colonist)
	return colonists

## The combat component (ActorCombat.build()); cooldown_remaining is camelCase on the wire.
static func _encode_combat(combat: Dictionary) -> Dictionary:
	return {
		"attack": int(combat.get("attack", 0)),
		"damage": int(combat.get("damage", 0)),
		"cooldown": int(combat.get("cooldown", 1)),
		"cooldownRemaining": int(combat.get("cooldown_remaining", 0)),
	}

static func _decode_combat(combat: Dictionary) -> Dictionary:
	return {
		"attack": int(combat.get("attack", 0)),
		"damage": int(combat.get("damage", 0)),
		"cooldown": int(combat.get("cooldown", 1)),
		"cooldown_remaining": int(combat.get("cooldownRemaining", 0)),
	}

## The inventory component (ActorInventory.build()); items copied as-is.
static func _encode_inventory(inventory: Dictionary) -> Dictionary:
	return {
		"items": (inventory.get("items", []) as Array).duplicate(true),
		"tool": String(inventory.get("tool", "")),
		"capacity": int(inventory.get("capacity", 1)),
	}

## The health component (ActorHealth, ADR 012): hp/maxHp/dead, already wire-shaped.
static func _encode_health(health: Dictionary) -> Dictionary:
	return {
		"hp": int(health.get("hp", 0)),
		"maxHp": int(health.get("maxHp", 1)),
		"dead": bool(health.get("dead", false)),
	}

static func _decode_health(health: Dictionary) -> Dictionary:
	return {
		"hp": int(health.get("hp", 0)),
		"maxHp": int(health.get("maxHp", 1)),
		"dead": bool(health.get("dead", false)),
	}

## kind -> value (colonist-ai.md 3.1), sorted.
static func _encode_needs(needs: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	var keys := needs.keys()
	keys.sort()
	for key in keys:
		encoded[key] = int(needs[key])
	return encoded

static func _decode_needs(needs: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in needs.keys():
		decoded[key] = int(needs[key])
	return decoded

## kind -> level (colonist-ai.md 3.2), sorted.
static func _encode_labour_table(labour_table: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	var keys := labour_table.keys()
	keys.sort()
	for key in keys:
		encoded[key] = int(labour_table[key])
	return encoded

static func _decode_labour_table(labour_table: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in labour_table.keys():
		decoded[key] = int(labour_table[key])
	return decoded

## "rerouting" only while a re-route is in flight; the live route holds its summary(), the
## save the search's full snapshot().
static func _encode_route_field(route, live_search):
	if route == null:
		return null
	var encoded := {
		"jobId": route["job_id"],
		"path": StateCodec._encode_tile_array(route["path"]),
		"step": route["step"],
		"moveTicksRemaining": route["move_ticks_remaining"],
	}
	var rerouting: Variant = route.get("rerouting")
	if rerouting != null:
		encoded["rerouting"] = SchedulingCodec._encode_route(live_search.snapshot() if live_search != null else rerouting)
	return encoded

## state_hash()'s view: a rerouting colonist is hashed with the search's full snapshot (what
## a save persists), so two re-routes differing in frontier never hash equal.
static func _hash_colonists(colonists: Array[Dictionary], reroutes: Dictionary) -> Array:
	if reroutes.is_empty():
		return colonists
	var hashed: Array = []
	for colonist in colonists:
		var route: Variant = colonist.get("route")
		var search: Variant = reroutes.get(colonist["id"])
		if route == null or route.get("rerouting") == null or search == null:
			hashed.append(colonist)
			continue
		var copy: Dictionary = colonist.duplicate()
		copy["route"] = route.duplicate()
		copy["route"]["rerouting"] = search.snapshot()
		hashed.append(copy)
	return hashed

static func _decode_route_field(route):
	if route == null:
		return null
	return {
		"job_id": route["jobId"],
		"path": StateCodec._decode_tile_array(route["path"]),
		"step": int(route["step"]),
		"move_ticks_remaining": int(route["moveTicksRemaining"]),
		"rerouting": SchedulingCodec._decode_route(route.get("rerouting")),
	}

static func _encode_work_field(work):
	if work == null:
		return null
	return {"jobId": work["job_id"], "ticksRemaining": work["ticks_remaining"]}

static func _decode_work_field(work):
	if work == null:
		return null
	return {"job_id": work["jobId"], "ticks_remaining": int(work["ticksRemaining"])}

## One {"kind","count"} per kind held; no item id (place() mints a fresh one) and no x/y.
static func _encode_hands_field(hands: Array) -> Array:
	var encoded: Array = []
	for entry in hands:
		encoded.append({"kind": entry["kind"], "count": entry["count"]})
	return encoded

static func _decode_hands_field(hands: Array) -> Array:
	var decoded: Array = []
	for entry in hands:
		decoded.append({"kind": entry["kind"], "count": int(entry["count"])})
	return decoded

## "trapped" for any actor kind (anyone can fall into a trench); fromTile only alongside
## ticksRemaining, a trapped hostile's climb-out.
static func _encode_trapped_field(trapped):
	if trapped == null:
		return null
	var encoded := {"tile": StateCodec._encode_tile(trapped["tile"])}
	if trapped.has("ticksRemaining"):
		encoded["ticksRemaining"] = int(trapped["ticksRemaining"])
	if trapped.has("fromTile"):
		encoded["fromTile"] = StateCodec._encode_tile(trapped["fromTile"])
	return encoded

static func _decode_trapped_field(trapped):
	if trapped == null:
		return null
	var decoded := {"tile": StateCodec._decode_tile(trapped["tile"])}
	if trapped.has("ticksRemaining"):
		decoded["ticksRemaining"] = int(trapped["ticksRemaining"])
	if trapped.has("fromTile"):
		decoded["fromTile"] = StateCodec._decode_tile(trapped["fromTile"])
	return decoded
