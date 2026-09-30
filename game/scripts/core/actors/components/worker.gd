class_name ActorWorker
extends RefCounted

## F2 worker component: labour table + held tool. Scope-limiting decision
## (docs/decisions/012-actors-and-components.md): a colonist's per-instance
## state stays exactly where it has always lived -- "labourTable" and
## "held_tool" at the top level of the colonist Dictionary -- rather than a
## new nested "worker" key, so this component is an accessor layer over
## existing fields, not a literal nested key. ActorTable.get_component()
## assembles {"labourTable": ..., "held_tool": ...} from those fields.
##
## Tunables (content/actors.json): {"labours": Array[String] (non-empty),
## "labour_default": int >= 0, "labour_min": int >= 0, "labour_max": int >= 1}
## describing the labour kinds a worker actor is spawned with and the default
## level assigned to each.

static func validate(tunables: Dictionary) -> bool:
	var labours = tunables.get("labours", [])
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

## The default labour table a freshly spawned worker actor starts with: every
## declared labour kind at "labour_default", in the tunables' own declared
## order (colonist-shape callers depend on stable Dictionary key insertion
## order for state_hash(), per world_state.gd's _ensure_needs() doc comment).
static func default_labour_table(tunables: Dictionary) -> Dictionary:
	var table: Dictionary = {}
	var default_level := int(tunables.get("labour_default", 0))
	for labour in (tunables.get("labours", []) as Array):
		table[String(labour)] = default_level
	return table

## The single place a colonist's legacy "held_tool" field (ADR
## 012 keeps the field name, not a nested "worker" key) is read/written, so
## ToolItemStore calls into this instead of indexing the field inline in
## more than one place.
static func get_held_tool(actor: Dictionary) -> String:
	return String(actor.get("held_tool", ""))

static func set_held_tool(actor: Dictionary, item_id: String) -> void:
	actor["held_tool"] = item_id

static func clear_held_tool(actor: Dictionary) -> void:
	actor["held_tool"] = ""

## colonist-ai.md 3.2's single read of a labour table entry, defaulting to
## default_level when the table doesn't track that labour kind (never
## disabling a job over a labour kind the table simply doesn't mention) --
## the one place GlobalAssignment's eligibility filter and priority-bracket
## math read a table entry, so neither re-implements the table's own
## key-miss default.
static func labour_level(labour_table: Dictionary, labour: String, default_level: int) -> int:
	return int(labour_table.get(labour, default_level))

## True when kind/level is a value WorldState's set_labour command may
## accept for a colonist with these worker tunables: kind among the
## tunables' own declared labours, level within [labour_min, labour_max] --
## the single place that rule is checked, so command validation and the
## table's own declared shape agree by construction instead of WorldState
## re-declaring its own labour vocabulary/bounds.
static func is_valid_labour_value(tunables: Dictionary, kind: String, level: int) -> bool:
	var labours: Array = tunables.get("labours", [])
	if not labours.has(kind):
		return false
	var min_level := int(tunables.get("labour_min", 0))
	var max_level := int(tunables.get("labour_max", 0))
	return level >= min_level and level <= max_level

## Mutates actor's labourTable entry in place -- the single place a
## colonist's labour-table value is written, so WorldState's set_labour
## command routes through this instead of indexing the field inline.
static func set_labour_level(actor: Dictionary, kind: String, level: int) -> void:
	var labour_table = actor.get("labourTable")
	if not (labour_table is Dictionary):
		labour_table = {}
		actor["labourTable"] = labour_table
	labour_table[kind] = level
