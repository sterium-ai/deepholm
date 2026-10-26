extends SceneTree

## R8 hash-coverage probe: on a fresh world, changes one piece of needs state at a time and
## prints whether state_hash() changed. Runs unchanged on main (fields on WorldState) and on
## R8 (on world._needs_system), so the two printouts must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R8.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## NeedsSystem's field on R8, WorldState's own "_"-prefixed field on main.
func _field(world, name: String) -> Dictionary:
	var system = world.get("_needs_system")
	return system.get(name) if system != null else world.get("_" + name)

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	var before: int = world.state_hash()
	mutate.call(world)
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"colonist_need_value": func(w): w._colonists[0]["needs"]["food"] = 42,
		"colonist_needs_accumulator": func(w): w._colonists[0]["needsAccumulator"]["water"] = 7,
		"need_pending_assignment": func(w): w._need_giver._pending["colonist_0"] = "job_99",
		"paused_jobs": func(w): _field(w, "paused_jobs")["colonist_0"] = "job_99",
		"need_status": func(w): _field(w, "need_status")["colonist_0"] = "need_unmet:food",
		# ensure_needs() runs inside state_hash(): a removed need is backfilled before hashing.
		"need_key_removed_then_backfilled": func(w): (w._colonists[0]["needs"] as Dictionary).erase("rest"),
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
