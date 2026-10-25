extends SceneTree

## R2 hash-coverage probe: perturbs one field at a time on a fresh world and prints
## whether state_hash() changed. Runs unchanged on main (fields on WorldState) and on
## the R2 branch (fields on world._item_table), so the two printouts must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R2.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## The object that owns the item fields: the R2 module when present, else the world.
func _items_owner(world) -> Object:
	return world.get("_item_table") if world.get("_item_table") != null else world

func _field(owner: Object, before_r2: String, after_r2: String) -> String:
	return after_r2 if owner.get(after_r2) != null else before_r2

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	world._ensure_object_health()
	var before: int = world.state_hash()
	mutate.call(world)
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"items": func(w):
			var o := _items_owner(w)
			(o.get(_field(o, "_items", "items")) as Dictionary)["probe"] = {"id": "probe", "x": 1, "y": 1, "kind": "wood", "count": 1},
		"next_item_id": func(w):
			var o := _items_owner(w)
			var f := _field(o, "_next_item_id", "next_item_id")
			o.set(f, int(o.get(f)) + 5),
		"dig_find_rng": func(w):
			var o := _items_owner(w)
			(o.get(_field(o, "_dig_find_random", "dig_find_random")) as RandomNumberGenerator).randi(),
		"item_factions": func(w):
			var o := _items_owner(w)
			(o.get(_field(o, "_item_factions", "item_factions")) as Dictionary)["item_1"] = "wolves",
		"ground_berries": func(w):
			var o := _items_owner(w)
			(o.get(_field(o, "_ground_berries", "ground_berries")) as Dictionary)["3_3"] = 4,
		"ground_berries_factions": func(w):
			var o := _items_owner(w)
			(o.get(_field(o, "_ground_berries_factions", "ground_berries_factions")) as Dictionary)["3_3"] = "colony",
		"pending_dig_finds": func(w):
			var o := _items_owner(w)
			(o.get(_field(o, "_pending_dig_finds", "pending_dig_finds")) as Array).append({"job_id": "job_1", "x": 1, "y": 1}),
		"object_health": func(w):
			(w._object_health as Dictionary)["9_9"] = {"hp": 1, "maxHp": 10},
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
