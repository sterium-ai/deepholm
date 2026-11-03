class_name CombatTargeting
extends RefCounted

## Combat targeting, static and stateless: the nearest adjacent hostile for the attack rule and
## the nearest hostile actor for the flee direction. Hostility is relations.relation() on each
## side's runtime "factionId", never Relations.is_hostile() (it reads content's "faction_id").

## Cardinals first, then diagonals: resolves "nearest" adjacent without float distances.
const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(0, -1, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(-1, -1, 0), Vector3i(1, -1, 0), Vector3i(-1, 1, 0), Vector3i(1, 1, 0),
]

static func actor_faction(actor: Dictionary) -> String:
	return String(actor.get("factionId", "colony"))

static func _is_hostile(relations, a_faction: String, b_faction: String) -> bool:
	return relations.relation(a_faction, b_faction) == "hostile"

static func _is_dead(actor: Dictionary) -> bool:
	return bool((actor.get("health", {}) as Dictionary).get("dead", false))

## Living actors with health by tile (arrays: tiles are not exclusive), built once per pass (A4).
## Valid while no actor moves; one that dies afterwards is skipped at lookup.
static func actors_by_tile(actors: Array) -> Dictionary:
	var by_tile: Dictionary = {}
	for other: Dictionary in actors:
		if _is_dead(other) or not other.has("health"):
			continue
		var tile := TileGrid.tile_of(other)
		if not by_tile.has(tile):
			by_tile[tile] = []
		(by_tile[tile] as Array).append(other)
	return by_tile

## The nearest adjacent hostile actor or object with health, {} when none. `by_tile` must be
## actors_by_tile() built after the last move; object callables are ObjectTable/WorldState lookups.
static func nearest_adjacent_hostile(actor: Dictionary, by_tile: Dictionary, relations,
		object_at: Callable, object_health_at: Callable, object_faction_at: Callable) -> Dictionary:
	var own_tile := TileGrid.tile_of(actor)
	var own_faction := actor_faction(actor)
	for offset in NEIGHBOR_OFFSETS:
		var tile := own_tile + offset
		var occupants: Array = by_tile.get(tile, [])
		if not occupants.is_empty():
			var other := _pick_hostile_occupant(occupants, relations, own_faction)
			if not other.is_empty():
				return {"type": "actor", "x": tile.x, "y": tile.y, "z": tile.z, "actor": other}
		if not String(object_at.call(tile)).is_empty():
			var health: Dictionary = object_health_at.call(tile)
			if not health.is_empty() and _is_hostile(relations, own_faction, String(object_faction_at.call(tile))):
				return {"type": "object", "x": tile.x, "y": tile.y, "z": tile.z}
	return {}

## The hostile occupant with the smallest id (actors may share a tile); {} when none.
static func _pick_hostile_occupant(occupants: Array, relations, own_faction: String) -> Dictionary:
	var best: Dictionary = {}
	for occupant: Dictionary in occupants:
		if _is_dead(occupant):
			continue
		if not _is_hostile(relations, own_faction, actor_faction(occupant)):
			continue
		if best.is_empty() or String(occupant["id"]) < String(best["id"]):
			best = occupant
	return best

## The nearest living hostile actor anywhere (Manhattan, ties by id); {} when none.
static func nearest_hostile_actor(actor: Dictionary, actors: Array, relations) -> Dictionary:
	var own_faction := actor_faction(actor)
	var own_tile := TileGrid.tile_of(actor)
	var best: Dictionary = {}
	var best_distance := -1
	for other in actors:
		if other == actor or _is_dead(other) or not other.has("health"):
			continue
		if not _is_hostile(relations, own_faction, actor_faction(other)):
			continue
		var distance := TileGrid.manhattan(TileGrid.tile_of(other), own_tile)
		if best.is_empty() or distance < best_distance or (distance == best_distance and String(other["id"]) < String(best["id"])):
			best = other
			best_distance = distance
	return best
