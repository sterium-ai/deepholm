extends SceneTree

## R5 hash-coverage probe: on a world holding one workbench site, changes one piece of
## construction state at a time and prints whether state_hash() changed. Runs unchanged on
## main (fields on WorldState) and on R5 (on world._construction), so the two printouts
## must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R5.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## The site table on R5, or WorldState's own field on main.
func _table(world):
	var system = world.get("_construction")
	return system.site_table if system != null else world.get("_sites")

func _cache(world, before_r5: String, after_r5: String) -> Dictionary:
	var system = world.get("_construction")
	return system.get(after_r5) if system != null else world.get(before_r5)

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	var c0: Dictionary = world.get_colonists()[0]
	var result: Dictionary = {}
	# The first origin, scanning outward from colonist 0, where a workbench is accepted.
	for r in range(2, 10):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if result.get("ok", false):
					break
				var command := {"actor": "player", "command_id": "c1", "tick": 0, "type": "build",
					"payload": {"kind": "workbench", "x": int(c0["x"]) + dx, "y": int(c0["y"]) + dy}}
				if world.preview(command).get("ok", false):
					result = world.apply(command)
	assert(result.get("ok", false))
	var before: int = world.state_hash()
	mutate.call(world, String(result["site_id"]))
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"site_held_materials": func(w, id): _table(w).deposit(id, "wood", 1),
		"site_progress": func(w, id): _table(w).add_progress(id, 1),
		"site_builder_ids": func(w, id): _table(w).add_builder(id, "job_99"),
		"site_removed": func(w, id): _table(w).remove(id),
		"site_fetch_source_retargeted": func(w, _id):
			_cache(w, "_site_fetch_source_retargeted", "site_fetch_source_retargeted")["job_99"] = true,
		"site_fetch_picked_kind": func(w, _id):
			_cache(w, "_site_fetch_picked_kind", "site_fetch_picked_kind")["job_99"] = "wood",
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
