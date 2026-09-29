class_name CombatTargeting
extends RefCounted

## F5/#302 combat targeting: finds the nearest hostile target for the attack
## rule (adjacent only) and the nearest hostile actor for the flee giver's own
## away-direction pick (unbounded). Plain, scene-independent GDScript
## (AGENTS.md): every method is static and stateless.
##
## Reads hostility via `relations.relation(a_faction, b_faction)` with each
## side's own runtime "factionId" field (camelCase) threaded explicitly,
## rather than `Relations.is_hostile(actor_a, actor_b)` -- that helper reads
## content's "faction_id" key (docs/decisions/015-factions-and-relations.md),
## never the runtime field every live actor/object actually carries, so
## calling it here would silently resolve every pair to the "neutral"
## fallback instead of the real relation.

## Cardinal neighbours first (Euclidean distance 1), diagonals after
## (distance sqrt(2)): a fixed scan order that resolves "nearest" among every
## adjacent candidate without floating-point distance comparisons.
const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
]

static func actor_faction(actor: Dictionary) -> String:
	return String(actor.get("factionId", "colony"))

static func _is_hostile(relations, a_faction: String, b_faction: String) -> bool:
	return relations.relation(a_faction, b_faction) == "hostile"

static func _is_dead(actor: Dictionary) -> bool:
	return bool((actor.get("health", {}) as Dictionary).get("dead", false))

## The nearest adjacent (Chebyshev distance 1) hostile target with a health
## component -- an actor or a placed object -- for `actor`'s own attack rule.
## {} when none. `object_at(x,y)->String`, `object_health_at(x,y)->Dictionary`
## ({} for no health) and `object_faction_at(x,y)->String` must be
## WorldState's own get_object/_object_health_at/get_object_faction_id.
static func nearest_adjacent_hostile(actor: Dictionary, actors: Array, relations,
		object_at: Callable, object_health_at: Callable, object_faction_at: Callable) -> Dictionary:
	var ax := int(actor["x"])
	var ay := int(actor["y"])
	var own_faction := actor_faction(actor)
	# Array per tile, not a single overwritten entry (round-1 review): movement
	# does not enforce exclusive actor occupancy, so a friendly actor appended
	# after an adjacent enemy must never hide that enemy from targeting.
	var actors_by_pos: Dictionary = {}
	for other in actors:
		if other == actor or _is_dead(other) or not other.has("health"):
			continue
		var key := "%d_%d" % [int(other["x"]), int(other["y"])]
		if not actors_by_pos.has(key):
			actors_by_pos[key] = []
		(actors_by_pos[key] as Array).append(other)
	for offset in NEIGHBOR_OFFSETS:
		var x := ax + offset.x
		var y := ay + offset.y
		var key := "%d_%d" % [x, y]
		if actors_by_pos.has(key):
			var other := _pick_hostile_occupant(actors_by_pos[key] as Array, relations, own_faction)
			if not other.is_empty():
				return {"type": "actor", "x": x, "y": y, "actor": other}
		if not String(object_at.call(x, y)).is_empty():
			var health: Dictionary = object_health_at.call(x, y)
			if not health.is_empty() and _is_hostile(relations, own_faction, String(object_faction_at.call(x, y))):
				return {"type": "object", "x": x, "y": y}
	return {}

## Among every actor occupying one tile, the hostile one with the
## lexicographically smallest id -- a stable, deterministic tie-break
## independent of insertion order, since two actors of any hostility mix can
## legally share a tile today. {} when none of the occupants are hostile.
static func _pick_hostile_occupant(occupants: Array, relations, own_faction: String) -> Dictionary:
	var best: Dictionary = {}
	for occupant in occupants:
		if not _is_hostile(relations, own_faction, actor_faction(occupant)):
			continue
		if best.is_empty() or String(occupant["id"]) < String(best["id"]):
			best = occupant
	return best

## The nearest living hostile actor anywhere on the map (Manhattan distance,
## ties broken by ascending id), for the flee giver's own away-direction pick
## -- unbounded, unlike the adjacency-only attack target above. {} when none.
static func nearest_hostile_actor(actor: Dictionary, actors: Array, relations) -> Dictionary:
	var own_faction := actor_faction(actor)
	var ax := int(actor["x"])
	var ay := int(actor["y"])
	var best: Dictionary = {}
	var best_distance := -1
	for other in actors:
		if other == actor or _is_dead(other) or not other.has("health"):
			continue
		if not _is_hostile(relations, own_faction, actor_faction(other)):
			continue
		var distance := absi(int(other["x"]) - ax) + absi(int(other["y"]) - ay)
		if best.is_empty() or distance < best_distance or (distance == best_distance and String(other["id"]) < String(best["id"])):
			best = other
			best_distance = distance
	return best
