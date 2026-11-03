class_name FaunaSystem
extends RefCounted

## Wild animals (F6b-1, ADR 070): their roster, worldgen placement and the "fauna" tick phase.
## Animals are actor-table actors of kind "animal" (ActorTable.spawn_animal()) kept in their own
## roster: no labours, needs, jobs or combat, so no colonist system ever iterates them. They live on
## the surface only (z = TileGrid.SURFACE). Every random draw comes from this system's own stream,
## seeded from the world seed + SEED_SALT, so fauna never perturbs WorldState's simulation RNG.
##
## Per tick, in roster order (spawn order, so ids ascend): an animal starves once starve_ticks pass
## without a meal; otherwise, on its step tick ((tick + ordinal) % step_ticks == 0) it eats if
## hungry and food is in reach (a grazer's own tile, or prey within Chebyshev 1, which dies), else
## moves one tile (a hungry predator toward the nearest prey in sight, otherwise a random
## neighbour), then tries to breed. Breeding needs a fed adult whose interval has elapsed, another
## adult of its species within the reproduction radius and the species under its cap; the birth
## then lands with probability 1 - count / cap (logistic growth, ADR 070).

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")

const SEED_SALT := 0x0FA0A
const FACTION := "wildlife"
const NEIGHBOURS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
	Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]

var _table: Dictionary
var _tick: Callable # () -> int
var _tile_grid: TileGridType
var _passable: Callable # (Vector3i, faction_id) -> float
var _random := RandomNumberGenerator.new()
var _animals: Array[Dictionary] = []
var _next_id := 0

## Seeds mapgen["animal_counts"] onto open ground outside `clearing` (the colony's spawn rect).
func _init(content: ContentRegistry, day_ticks: int, tick: Callable, tile_grid: TileGridType, passable: Callable, world_seed: int,
		mapgen: Dictionary, clearing: Dictionary) -> void:
	var counts: Dictionary = mapgen.get("animal_counts", {})
	_table = FaunaSpecies.build(content.document("species") as Dictionary, counts, day_ticks, content)
	if not _table["ok"]:
		push_error("FaunaSystem: %s" % _table["message"])
		_table = {"ok": false, "species": {}, "order": [], "grass": {}, "crops": {}}
	_tick = tick
	_tile_grid = tile_grid
	_passable = passable
	_random.seed = world_seed + SEED_SALT
	for species_id: String in _table["order"]:
		_seed_species(species_id, (counts.get(species_id, 0) as int), clearing)

func get_animals() -> Array[Dictionary]: return _animals
func get_species(species_id: String) -> Dictionary: return (_table["species"] as Dictionary).get(species_id, {})
func count_of(species_id: String) -> int:
	var count := 0
	for animal: Dictionary in _animals:
		count += 1 if animal["species"] == species_id else 0
	return count

## Places one adult, just-fed animal of `species_id` at `tile` (worldgen and tests).
func spawn(species_id: String, tile: Vector3i) -> Dictionary:
	var record: Dictionary = _table["species"][species_id]
	var tick: int = _tick.call()
	var animal := ActorTableType.spawn_animal(species_id, record, tile, "animal_%d" % _next_id, tick - (record["adult_ticks"] as int))
	animal["lastMealTick"] = tick
	animal["nextBirthTick"] = tick
	_next_id += 1
	_animals.append(animal)
	return animal

## The "fauna" TickPipeline phase.
func advance() -> void:
	if _animals.is_empty():
		return
	var tick: int = _tick.call()
	var counts := {}
	for animal: Dictionary in _animals:
		counts[animal["species"]] = (counts.get(animal["species"], 0) as int) + 1
	var roster := _animals.duplicate()
	for animal: Dictionary in roster:
		if animal.get("dead", false):
			continue
		var record: Dictionary = _table["species"][animal["species"]]
		if tick - (animal["lastMealTick"] as int) >= (record["starve_ticks"] as int):
			_kill(animal, counts)
			continue
		if (tick + _ordinal(animal)) % (record["step_ticks"] as int) != 0:
			continue
		if tick - (animal["lastMealTick"] as int) < (record["hungry_ticks"] as int):
			_wander(animal)
		elif record["predator"]:
			_hunt(animal, record, tick, counts)
		elif _on_food(animal, record):
			animal["lastMealTick"] = tick
		else:
			_wander(animal)
		_try_breed(animal, record, tick, counts)
	_animals = _animals.filter(func(animal: Dictionary) -> bool: return not animal.get("dead", false))

func _hunt(animal: Dictionary, record: Dictionary, tick: int, counts: Dictionary) -> void:
	var here := TileGridType.tile_of(animal)
	var best: Dictionary = {}
	var best_distance := (record["sight"] as int) + 1
	for other: Dictionary in _animals:
		if other.get("dead", false) or not (record["prey"] as Array).has(other["species"]):
			continue
		var distance := TileGridType.chebyshev(here, TileGridType.tile_of(other))
		if distance < best_distance:
			best = other
			best_distance = distance
	if best.is_empty():
		_wander(animal)
	elif best_distance <= 1:
		_kill(best, counts)
		animal["lastMealTick"] = tick
	else:
		var toward := TileGridType.tile_of(best) - here
		if not _move(animal, Vector2i(signi(toward.x), signi(toward.y))):
			_wander(animal)

func _try_breed(animal: Dictionary, record: Dictionary, tick: int, counts: Dictionary) -> void:
	var species_id: String = animal["species"]
	var count := (counts.get(species_id, 0) as int)
	if tick < (animal["nextBirthTick"] as int) or count >= (record["cap"] as int) or not _is_adult(animal, record, tick) \
			or tick - (animal["lastMealTick"] as int) >= (record["hungry_ticks"] as int):
		return
	var here := TileGridType.tile_of(animal)
	var partner := false
	for other: Dictionary in _animals:
		if other != animal and other["species"] == species_id and not other.get("dead", false) \
				and _is_adult(other, record, tick) and TileGridType.chebyshev(here, TileGridType.tile_of(other)) <= (record["radius"] as int):
			partner = true
			break
	if not partner:
		return
	animal["nextBirthTick"] = tick + (record["birth_ticks"] as int)
	if _random.randf() >= 1.0 - float(count) / (record["cap"] as float):
		return
	var child := ActorTableType.spawn_animal(species_id, record, here, "animal_%d" % _next_id, tick)
	_next_id += 1
	_animals.append(child)
	counts[species_id] = count + 1

func _wander(animal: Dictionary) -> void:
	_move(animal, NEIGHBOURS[_random.randi_range(0, NEIGHBOURS.size() - 1)])

## One surface step; false (and no move) onto an out-of-bounds or impassable tile.
func _move(animal: Dictionary, step: Vector2i) -> bool:
	var target := TileGridType.tile_of(animal) + Vector3i(step.x, step.y, 0)
	if not _tile_grid.contains(target) or (_passable.call(target, FACTION) as float) <= 0.0:
		return false
	TileGridType.write_tile(animal, target)
	return true

func _on_food(animal: Dictionary, record: Dictionary) -> bool:
	var tile_id := _tile_grid.tile_at(TileGridType.tile_of(animal))
	return ((record["eats"] as Array).has("grass") and (_table["grass"] as Dictionary).has(tile_id)) \
		or ((record["eats"] as Array).has("crops") and (_table["crops"] as Dictionary).has(tile_id))

func _kill(animal: Dictionary, counts: Dictionary) -> void:
	animal["dead"] = true
	counts[animal["species"]] = (counts[animal["species"]] as int) - 1

func _is_adult(animal: Dictionary, record: Dictionary, tick: int) -> bool:
	return tick - (animal["bornTick"] as int) >= (record["adult_ticks"] as int)

func _ordinal(animal: Dictionary) -> int:
	return (animal["id"] as String).trim_prefix("animal_").to_int()

## Random grass tiles on the surface, passable to wildlife and outside the clearing; gives up
## after 64 draws per animal so a map without open ground places fewer.
func _seed_species(species_id: String, count: int, clearing: Dictionary) -> void:
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * 64:
		attempts += 1
		var tile := Vector3i(_random.randi_range(0, _tile_grid.width - 1), _random.randi_range(0, _tile_grid.height - 1),
			TileGridType.SURFACE)
		if _in_clearing(tile, clearing) or not (_table["grass"] as Dictionary).has(_tile_grid.tile_at(tile)) \
				or (_passable.call(tile, FACTION) as float) <= 0.0:
			continue
		spawn(species_id, tile)
		placed += 1

static func _in_clearing(tile: Vector3i, clearing: Dictionary) -> bool:
	if clearing.is_empty():
		return false
	return tile.x >= (clearing["x"] as int) and tile.x < (clearing["x"] as int) + (clearing["width"] as int) \
		and tile.y >= (clearing["y"] as int) and tile.y < (clearing["y"] as int) + (clearing["height"] as int)

## Save fields; {} for a world that never had an animal (its stream is untouched and rebuilt from the seed).
func encode() -> Dictionary:
	if _next_id == 0:
		return {}
	return {"fauna": {"animals": _animals.duplicate(true), "nextAnimalId": _next_id,
		"rng": {"seed": _random.seed, "state": _random.state}}}

## Replaces the worldgen roster with the saved one; an absent "fauna" field leaves an empty roster.
func decode(state: Dictionary) -> void:
	_animals = []
	_next_id = 0
	var fauna: Dictionary = state.get("fauna", {})
	if fauna.is_empty():
		return
	for animal: Dictionary in fauna["animals"]:
		var copy := animal.duplicate(true)
		for field: String in ["x", "y", "z", "bornTick", "lastMealTick", "nextBirthTick", "health"]:
			copy[field] = (copy[field] as int)
		_animals.append(copy)
	_next_id = (fauna["nextAnimalId"] as int)
	_random.seed = (fauna["rng"]["seed"] as int)
	_random.state = (fauna["rng"]["state"] as int)

func hash_into(snapshot: Dictionary) -> void:
	if _next_id > 0:
		snapshot["fauna"] = {"animals": _animals, "next_id": _next_id, "rng": {"seed": _random.seed, "state": _random.state}}
