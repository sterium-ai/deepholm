extends SceneTree

## R3 hash-coverage probe: perturbs one field at a time on a fresh world and prints
## whether state_hash() changed. Runs unchanged on main (fields on WorldState) and on
## the R3 branch (fields on world._tile_grid/_object_table/_zone_table), so the two
## printouts must match.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R3.md:
##   godot --headless --path game --script <abs path to this file>

const WorldStateType = preload("res://scripts/core/world_state.gd")

## (owner, field) for a moved field: the R3 module when present, else the world itself.
func _at(world, module: String, before_r3: String, after_r3: String) -> Array:
	var owner = world.get(module)
	return [owner, after_r3] if owner != null else [world, before_r3]

func _field_of(world, module: String, before_r3: String, after_r3: String):
	var at := _at(world, module, before_r3, after_r3)
	return (at[0] as Object).get(at[1])

func _changes(mutate: Callable) -> bool:
	var world = WorldStateType.new(777)
	world.get_room_at(0, 0) # build regions/rooms first, so the cache rows below have something to perturb
	var before: int = world.state_hash()
	mutate.call(world)
	return world.state_hash() != before

func _init() -> void:
	var rows := {
		"tiles": func(w):
			(_field_of(w, "_tile_grid", "_tiles", "tiles") as Array)[0] = "water",
		"width": func(w):
			var at := _at(w, "_tile_grid", "_width", "width")
			(at[0] as Object).set(at[1], int((at[0] as Object).get(at[1])) + 1),
		"objects": func(w):
			(_field_of(w, "_object_table", "_objects", "objects") as Dictionary)["9_9"] = "chair",
		"object_health": func(w):
			(_field_of(w, "_object_table", "_object_health", "object_health") as Dictionary)["9_9"] = {"hp": 1, "maxHp": 10},
		"zones": func(w):
			(_field_of(w, "_zone_table", "_zones", "zones") as Dictionary)["zone_9"] = {"id": "zone_9", "x": 1, "y": 1, "width": 1, "height": 1},
		"next_zone_id": func(w):
			var at := _at(w, "_zone_table", "_next_zone_id", "next_zone_id")
			(at[0] as Object).set(at[1], int((at[0] as Object).get(at[1])) + 5),
		"object_factions": func(w):
			var objects: Dictionary = _field_of(w, "_object_table", "_objects", "objects")
			(_field_of(w, "_object_table", "_object_factions", "object_factions") as Dictionary)[objects.keys()[0]] = "wolves",
		"object_origin": func(w):
			(_field_of(w, "_object_table", "_object_origin", "object_origin") as Dictionary)["9_9"] = Vector2i(8, 9),
		"object_orientation": func(w):
			(_field_of(w, "_object_table", "_object_orientation", "object_orientation") as Dictionary)["9_9"] = "vertical",
		"dirty_cells": func(w):
			(_field_of(w, "_tile_grid", "_dirty_cells", "dirty_cells") as Array).append(Vector2i(3, 3)),
		"water_tile_cache": func(w):
			(_field_of(w, "_tile_grid", "_water_tile_cache", "water_tile_cache") as Array).append(Vector2i(3, 3)),
		"regions_rooms": func(w):
			var at := _at(w, "_tile_grid", "_regions", "regions")
			(at[0] as Object).set(at[1], null)
			var rooms_at := _at(w, "_tile_grid", "_rooms", "rooms")
			(rooms_at[0] as Object).set(rooms_at[1], null),
	}
	for name in rows:
		print("hash_coverage: %s changes_hash=%s" % [name, _changes(rows[name])])
	quit(0)
