class_name EntityCodec
extends RefCounted

## StateCodec's "entities" encoding: each actor record and its components (needs, labour
## table, route, work, hands, trapped, combat, health, inventory), JSON-safe both ways.

## Every component field is emitted only when the live dict
## actually carries it -- exactly the per-kind shape ActorTable.spawn()
## produces (colonist: needs/labourTable/hands/heldTool; wolf: needs/
## combat/wild; trader: inventory/visitor) -- never as a colonist-shaped
## {}/""/null default, so a non-colonist entity's wire shape matches
## game-state.schema.json's per-kind required set. "work"/"route" ride along
## for every kind (a spawned actor's own walk/wait uses the same fields a
## colonist's job does), present once spawn()/start_work() actually add them.
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

## Mirrors _encode_entities()'s presence-based rule: a wire entity missing
## "needs"/"labourTable"/"hands"/"heldTool" (any non-colonist kind) decodes
## with that key absent entirely, matching the exact shape
## ActorTable.spawn()'s own generic-actor branch produces, rather than
## backfilling a colonist-shaped default that code elsewhere (_ensure_needs(),
## colonist-ai.md's own accessors) would then treat as "this actor has a
## worker/needs component after all". "factionId"/"health" are
## required on the wire (every save reaching this decoder has already
## migrated through SaveMigrations, which backfills both), but still read
## with a defensive default here, matching every other required-field decoder
## in this file.
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

## The combat component (ActorCombat.build()): attack/damage/cooldown
## tunables plus the per-instance cooldown_remaining (camelCase on the wire).
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

## The inventory component (ActorInventory.build()): {items, tool,
## capacity}; items is copied as-is (empty today: no toil fills it yet).
static func _encode_inventory(inventory: Dictionary) -> Dictionary:
	return {
		"items": (inventory.get("items", []) as Array).duplicate(true),
		"tool": String(inventory.get("tool", "")),
		"capacity": int(inventory.get("capacity", 1)),
	}

## world._colonists' "health" is the health component (ActorHealth.build*(),
## docs/decisions/012-actors-and-components.md): hp/maxHp/dead, already
## camelCase-compatible with the wire shape, so no key renaming is needed
## (unlike needs/labourTable, which only need sorted-key determinism).
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

## world._colonists' "needs" is a plain kind->value Dictionary (colonist-ai.md
## 3.1); sorted keys give a deterministic encoding order, matching every
## other keyed-map encoder in this file.
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

## world._colonists' "labourTable" is a plain kind->level Dictionary
## (colonist-ai.md 3.2); sorted keys give a deterministic encoding order,
## mirroring _encode_needs()/_decode_needs().
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

## "rerouting" is emitted only while a re-route search is actually in
## flight (route.get("rerouting") != null); otherwise the route keeps its 4 keys.
## The live route only carries the search's summary() (ToilExecutor), so the
## persisted value is the live search's full snapshot(), taken here.
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

## state_hash()'s view of the colonists: a colonist whose route.rerouting is
## the live search's summary() is hashed with that search's full snapshot()
## instead, so two in-flight re-routes that differ only in their frontier,
## visited set or parent map never hash equal (the same value a save
## persists). Returns the array itself, uncopied, when nothing is rerouting.
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

## A colonist's "hands" list -- {"kind","count"} per distinct kind
## held, no item id (a pick_up may merge several ground items' units into one
## entry, and place() always mints a fresh id on the way back out) and no x/y
## (a carried item has no ground position, see ToilExecutor.pick_up()/place()).
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

## "trapped": unlike carrying/work (present only for the kinds
## whose own ActorTable.spawn() shape adds them), any actor kind may fall into
## a trench, so this is encoded/decoded unconditionally for every entity,
## mirroring health/route rather than carrying's per-kind presence.
## fromTile is present only alongside
## ticksRemaining -- a trapped hostile's own escape_trench climb-out target --
## since a trapped colonist has no auto-exit to prefer a fallen-from tile for.
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
