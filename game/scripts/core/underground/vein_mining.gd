class_name VeinMining
extends RefCounted

const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")

## Ore from a mined vein (F4, ADR 071): the "vein_ore" work effect of the mine job.
## Invariants:
## - A vein is an object whose definition has "vein": {"ore", "layer", ...}; mining its rock
##   tile spawns one "ore" item on the tile and clears the vein, in the same tick as the
##   rock's own yields. A rock tile without a vein yields no ore.
## - Pure function of the object and item tables: no RNG, no state of its own.

## Called by ToilBindings.apply_work_effects() before the tile's other yields.
static func yield_ore(target: Vector3i, object_table: ObjectTableType, item_table: ItemTableType) -> void:
	var kind := object_table.get_object(target)
	if kind.is_empty():
		return
	var definition: Dictionary = object_table._object_definitions.get(kind, {})
	var vein: Variant = definition.get("vein")
	if not vein is Dictionary:
		return
	var ore: String = (vein as Dictionary).get("ore", "")
	object_table.set_object(target, "")
	item_table.spawn_item(ore, target)
