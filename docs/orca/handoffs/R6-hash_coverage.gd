extends SceneTree

## R6 hash-coverage probe: on a fresh world, changes one piece of trench/rescue state at a
## time and prints whether state_hash() changed. Runs unchanged on main (fields on
## WorldState) and on R6 (on world._trench), so the two printouts must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R6.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## TrenchSystem on R6, or WorldState itself on main.
func _owner(world):
	var system = world.get("_trench")
	return system if system != null else world

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	var before: int = world.state_hash()
	mutate.call(world)
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"actor_trapped_colonist": func(w): w._colonists[0]["trapped"] = {"tile": Vector2i(1, 1)},
		"actor_trapped_hostile_ticks": func(w):
			w._colonists[0]["trapped"] = {"tile": Vector2i(1, 1), "ticksRemaining": 40, "fromTile": Vector2i(1, 2)},
		"rescue_victim_assignment": func(w): w._rescue_giver._job_victim["job_99"] = "colonist_1",
		"rescue_status": func(w):
			_owner(w).get("rescue_status" if w.get("_trench") != null else "_rescue_status")["colonist_0"] = "no_rescuer_available",
		"trap_tile_before": func(w):
			_owner(w).set("trap_tile_before" if w.get("_trench") != null else "_trap_tile_before", Vector2i(5, 5)),
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
