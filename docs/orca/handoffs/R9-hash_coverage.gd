extends SceneTree

## R9 hash-coverage probe: on a fresh world, changes one piece of combat state at a time and
## prints whether state_hash() changed. Runs unchanged on main (WorldState._combat_status)
## and on R9 (world._combat_system.combat_status), so the two printouts must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R9.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## CombatSystem's field on R9, WorldState's own "_"-prefixed field on main.
func _combat_status(world) -> Dictionary:
	var system = world.get("_combat_system")
	return system.combat_status if system != null else world.get("_combat_status")

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	var before: int = world.state_hash()
	mutate.call(world)
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"colonist_hp": func(w): w._colonists[0]["health"]["hp"] = 42,
		"colonist_combat_cooldown": func(w): w._colonists[0]["combat"]["cooldown_remaining"] = 5,
		"combat_status": func(w): _combat_status(w)["colonist_0"] = "fighting",
		# ensure_health()/ensure_combat() run inside state_hash() / tick(): a removed
		# component is backfilled before hashing.
		"health_removed_then_backfilled": func(w): (w._colonists[0] as Dictionary).erase("health"),
		"faction_removed_then_backfilled": func(w): (w._colonists[0] as Dictionary).erase("factionId"),
		"trapped_removed_then_backfilled": func(w): (w._colonists[0] as Dictionary).erase("trapped"),
		"combat_removed_not_backfilled_by_hash": func(w): (w._colonists[0] as Dictionary).erase("combat"),
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
