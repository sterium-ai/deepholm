class_name ActorWorker
extends RefCounted

## Worker component (ADR 012): an accessor layer over the colonist's top-level "labourTable" and
## "held_tool" fields (no nested "worker" key). Tunables: {"labours": non-empty Array[String],
## "labour_default" >= 0, "labour_min" >= 0, "labour_max" >= 1}.

static func validate(tunables: Dictionary) -> bool:
	var labours: Variant = tunables.get("labours", [])
	if not (labours is Array) or (labours as Array).is_empty():
		return false
	for labour in (labours as Array):
		if not (labour is String) or String(labour).is_empty():
			return false
	if not (tunables.get("labour_default") is int) or not (tunables.get("labour_min") is int) \
			or not (tunables.get("labour_max") is int):
		return false
	var default_level := int(tunables["labour_default"])
	var min_level := int(tunables["labour_min"])
	var max_level := int(tunables["labour_max"])
	return min_level >= 0 and max_level >= 1 and min_level <= default_level and default_level <= max_level

## Every declared labour at "labour_default", in declared order (state_hash() is key-order-sensitive,
## see NeedsSystem.ensure_needs()).
static func default_labour_table(tunables: Dictionary) -> Dictionary:
	var table: Dictionary = {}
	var default_level := int(tunables.get("labour_default", 0))
	for labour in (tunables.get("labours", []) as Array):
		table[String(labour)] = default_level
	return table

## The single read/write point of the legacy "held_tool" field.
static func get_held_tool(actor: Dictionary) -> String:
	return String(actor.get("held_tool", ""))

static func set_held_tool(actor: Dictionary, item_id: String) -> void:
	actor["held_tool"] = item_id

static func clear_held_tool(actor: Dictionary) -> void:
	actor["held_tool"] = ""

## The single read of a labour-table entry (colonist-ai.md 3.2); a kind the table does not track
## gets default_level, never disabling the job.
static func labour_level(labour_table: Dictionary, labour: String, default_level: int) -> int:
	return int(labour_table.get(labour, default_level))

## The single check of a set_labour value: a declared labour kind and level in [labour_min, labour_max].
static func is_valid_labour_value(tunables: Dictionary, kind: String, level: int) -> bool:
	var labours: Array = tunables.get("labours", [])
	if not labours.has(kind):
		return false
	var min_level := int(tunables.get("labour_min", 0))
	var max_level := int(tunables.get("labour_max", 0))
	return level >= min_level and level <= max_level

## The single write point of a labour-table value (set_labour).
static func set_labour_level(actor: Dictionary, kind: String, level: int) -> void:
	var labour_table: Variant = actor.get("labourTable")
	if not (labour_table is Dictionary):
		labour_table = {}
		actor["labourTable"] = labour_table
	labour_table[kind] = level
