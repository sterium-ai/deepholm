class_name WorldSeeding
extends RefCounted

## A new world's start from WorldGenerator's pure output: terrain, berry-bush objects and
## colonists. Each step draws from its own seeded local RNG (never the simulation stream) in a
## fixed order, so size/seed/mapgen reproduce the start. A decoded world never calls this.

const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const SkillsType = preload("res://scripts/core/actors/components/skills.gd")

## F3 (ADR 062): mixed into placement_seed for the starting-skill RNG, so the skill draws never
## shift the placement stream (and a world without skills.json places colonists identically).
const SKILL_SEED_SALT := 0x5C11

## {"tiles": Array[String], "colonists": Array[Dictionary], "clearing": Dictionary}. mapgen's
## colonist_count sizes the roster; colonist_definitions[i] (a scenario roster's per-colonist
## {"labour": {kind: level}, "skills": {kind: level}}, ADR 057/062) applies to colonist_i, the rest
## keep actors.json's labour defaults. Every colonist's skills are seeded first (_seed_skills()).
static func seed_world(geography_seed: int, placement_seed: int, width: int, height: int, mapgen: Dictionary,
		content: ContentRegistry, object_table: ObjectTableType, colonist_definitions: Array = []) -> Dictionary:
	var generated := _generate_map(geography_seed, width, height, mapgen)
	var tiles: Array[String] = generated["tiles"]
	var water_tiles: Array[Vector2i] = generated["water_tiles"]
	var berry_bush_tiles: Array[Vector2i] = generated["berry_bush_tiles"]
	var placement := _spawn_colonists(placement_seed, tiles, width, height, mapgen, content, object_table,
		water_tiles, berry_bush_tiles)
	var colonists: Array[Dictionary] = placement["colonists"]
	_seed_skills(placement_seed, colonists, content)
	for i in mini(colonist_definitions.size(), colonists.size()):
		var definition: Dictionary = colonist_definitions[i]
		_apply_colonist_definition(colonists[i], definition)
	return {"tiles": tiles, "colonists": placement["colonists"], "clearing": placement["clearing"]}

## Terrain in a fixed draw order (rock veins, hazards, tree groves, river, berry
## bush groves), plus the river's water tiles and the bush positions.
static func _generate_map(geography_seed: int, width: int, height: int, mapgen: Dictionary) -> Dictionary:
	var geography_random := RandomNumberGenerator.new()
	geography_random.seed = geography_seed
	return WorldGeneratorType.generate_with_decorations(geography_random, width, height, mapgen)

## place_spawn()'s clearing (ADR 020): surviving bushes become objects, positions colonists.
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
		# ADR 037's "hands" replaces spawn()'s legacy "carrying" slot.
		colonist.erase("carrying")
		colonist["hands"] = []
		colonist["trapped"] = null # unconditional like health/route
		spawned.append(colonist)
	return {"colonists": spawned, "clearing": placement["clearing"]}

## Writes each listed labour level into the spawned labourTable in place, so its declared key
## order (state_hash() is key-order-sensitive) never changes; ContentRegistry checked the kinds
## and levels against the colonist's worker tunables.
static func _apply_colonist_definition(colonist: Dictionary, definition: Dictionary) -> void:
	var labour: Dictionary = definition.get("labour", {})
	for kind: String in labour.keys():
		var level: int = labour[kind]
		WorkerType.set_labour_level(colonist, kind, level)
	var skills: Dictionary = definition.get("skills", {})
	for kind: String in skills.keys():
		var skill_level: int = skills[kind]
		SkillsType.set_level(colonist, kind, skill_level)

## F3 (ADR 062): starting skills from their own local RNG (placement_seed ^ SKILL_SEED_SALT),
## colonist_0 first, in the worker's declared labour order; deterministic from the world seed.
static func _seed_skills(placement_seed: int, colonists: Array[Dictionary], content: ContentRegistry) -> void:
	var skill_rules := SkillsType.rules(content)
	var tunables: Dictionary = content.get_entry("actors", "colonist").get("tunables", {})
	var worker_tunables: Dictionary = tunables.get("worker", {})
	var labours: Array = worker_tunables.get("labours", [])
	var skill_random := RandomNumberGenerator.new()
	skill_random.seed = placement_seed ^ SKILL_SEED_SALT
	for colonist in colonists:
		colonist["skills"] = SkillsType.seed_levels(skill_rules, labours, skill_random)
