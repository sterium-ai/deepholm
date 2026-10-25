extends SceneTree

## R4 hash-coverage probe: adds one entry to one work-progress map at a time on a fresh
## world and prints whether state_hash() changed. Runs unchanged on main (maps on
## WorldState) and on the R4 branch (maps on world._progress_table), so the two printouts
## must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R4.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## The map called `after_r4` on WorkProgress, or `before_r4` on WorldState.
func _map(world, before_r4: String, after_r4: String) -> Dictionary:
	var table = world.get("_progress_table")
	return table.get(after_r4) if table != null else world.get(before_r4)

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	var before: int = world.state_hash()
	mutate.call(world)
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"work_progress": func(w):
			_map(w, "_work_progress", "progress")["3_3"] = 7,
		"work_progress_owner": func(w):
			_map(w, "_work_progress_owner", "owners")["3_3"] = "job_1",
		"suspended_work_progress": func(w):
			_map(w, "_suspended_work_progress", "suspended")["job_1"] = 7,
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
