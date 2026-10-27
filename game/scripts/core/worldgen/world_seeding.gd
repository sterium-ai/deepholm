class_name WorldSeeding
extends RefCounted

## A new world's starting state from WorldGenerator's pure output: the terrain,
## berry-bush objects (written into the ObjectTable, which WorldGenerator has no
## access to) and the spawned colonists. Each step draws from its own seeded
## local RNG, never the simulation stream, in a fixed order, so the same
## size/seed/mapgen always reproduces the same start. A decoded world never
## calls this.

const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")

## {"tiles": Array[String], "colonists": Array[Dictionary], "clearing": Dictionary}.
static func seed_world(geography_seed: int, placement_seed: int, width: int, height: int, mapgen: Dictionary,
		content: ContentRegistry, object_table: ObjectTableType) -> Dictionary:
	var generated := _generate_map(geography_seed, width, height, mapgen)
	var tiles: Array[String] = generated["tiles"]
	var water_tiles: Array[Vector2i] = generated["water_tiles"]
	var berry_bush_tiles: Array[Vector2i] = generated["berry_bush_tiles"]
	var placement := _spawn_colonists(placement_seed, tiles, width, height, mapgen, content, object_table,
		water_tiles, berry_bush_tiles)
	return {"tiles": tiles, "colonists": placement["colonists"], "clearing": placement["clearing"]}

## Terrain in a fixed draw order (rock veins, hazards, tree groves, river, berry
## bush groves), plus the river's water tiles and the bush positions.
static func _generate_map(geography_seed: int, width: int, height: int, mapgen: Dictionary) -> Dictionary:
	var geography_random := RandomNumberGenerator.new()
	geography_random.seed = geography_seed
	return WorldGeneratorType.generate_with_decorations(geography_random, width, height, mapgen)

## WorldGenerator.place_spawn()'s river-aware, resource-validated clearing (ADR 020):
## surviving bush tiles become objects, the chosen positions spawned colonists.
static func _spawn_colonists(placement_seed: int, map: Array[String], width: int, height: int, mapgen: Dictionary,
		content: ContentRegistry, object_table: ObjectTableType, water_tiles: Array[Vector2i], berry_bush_tiles: Array[Vector2i]) -> Dictionary:
	var placement_random := RandomNumberGenerator.new()
	placement_random.seed = placement_seed
	var placement: Dictionary = WorldGeneratorType.place_spawn(placement_random, map, width, height, mapgen,
		water_tiles, berry_bush_tiles, int(mapgen["colonist_count"]))
	for pos in placement["berry_bush_tiles"]:
		object_table.place_generated(pos.x, pos.y, "berry_bush")
	var spawned: Array[Dictionary] = []
	var positions: Array = placement["colonist_positions"]
	for i in positions.size():
		var position: Vector2i = positions[i]
		var colonist := ActorTableType.spawn("colonist", position.x, position.y, content, "colonist_%d" % i)
		# ActorTable.spawn() still builds the legacy "carrying" slot (ADR 012); ADR 037's
		# empty "hands" replaces it (key order does not affect state_hash()).
		colonist.erase("carrying")
		colonist["hands"] = []
		colonist["trapped"] = null # unconditional like health/route
		spawned.append(colonist)
	return {"colonists": spawned, "clearing": placement["clearing"]}
