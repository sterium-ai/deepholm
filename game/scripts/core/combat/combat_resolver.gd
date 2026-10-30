class_name CombatResolver
extends RefCounted

## Combat resolution (ADR 021), all static, driven by the tick counter. Rule 1: an actor with
## `combat` deals `damage` every `cooldown` ticks to the nearest adjacent hostile; rule 4: below
## `flee_hp_fraction` it stops fighting. Reports deaths for CombatSystem to apply; never moves anyone.

const TargetingType = preload("res://scripts/core/combat/combat_targeting.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")

## Additions to orders-and-movement.md's vocabulary: `attacked_by` event (once per hit) and the
## per-tick `fighting` reason.
const EVENT_ATTACKED_BY := "attacked_by"

## Defaults to 0.0 (never flee). Read from the definition's tunables: the runtime component only
## carries attack/damage/cooldown/cooldown_remaining.
static func _flee_hp_fraction(actor: Dictionary, content) -> float:
	var definition: Dictionary = content.get_entry("actors", String(actor.get("kind", "")))
	var combat_tunables: Dictionary = (definition.get("tunables", {}) as Dictionary).get("combat", {})
	return float(combat_tunables.get("flee_hp_fraction", 0.0))

static func _hp_fraction(actor: Dictionary) -> float:
	var health: Dictionary = actor.get("health", {})
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	return float(int(health.get("hp", 0))) / float(max_hp)

## Once per tick before the scheduler: decrements every cooldown each tick (elapsed ticks, not
## ticks engaged), attacks at zero, and returns {"dead_actors", "fighting"} for the caller to apply.
## Object damage (rule 3) is applied at once through `damage_object` (ObjectTable clears a
## destroyed object).
static func resolve_tick(actors: Array[Dictionary], content, relations, tick: int, priority: int,
		object_at: Callable, object_health_at: Callable, object_faction_at: Callable, damage_object: Callable,
		insert_event: Callable, next_sequence: Callable) -> Dictionary:
	var dead_actors: Array[Dictionary] = []
	var fighting: Array[String] = []
	var by_tile := TargetingType.actors_by_tile(actors) # nothing moves during resolution
	for actor in actors:
		if not (actor.get("combat") is Dictionary):
			continue
		var health: Dictionary = actor.get("health", {})
		if bool(health.get("dead", false)):
			continue
		var combat: Dictionary = actor["combat"]
		var was_cooling := int(combat.get("cooldown_remaining", 0)) > 0
		if was_cooling:
			combat["cooldown_remaining"] = int(combat["cooldown_remaining"]) - 1
		if _hp_fraction(actor) < _flee_hp_fraction(actor, content):
			continue # rule 4: strictly below its own flee threshold, this actor stops fighting
		var target := TargetingType.nearest_adjacent_hostile(actor, by_tile, relations, object_at, object_health_at, object_faction_at)
		if target.is_empty():
			continue
		var attacker_id := String(actor["id"])
		fighting.append(attacker_id)
		if was_cooling:
			continue
		combat["cooldown_remaining"] = int(combat.get("cooldown", 1)) - 1
		var damage := int(combat.get("damage", 0))
		if String(target["type"]) == "actor":
			var victim: Dictionary = target["actor"]
			var victim_health: Dictionary = victim["health"]
			victim_health["hp"] = maxi(0, int(victim_health.get("hp", 0)) - damage)
			HealthType.clamp_bounds(victim_health)
			insert_event.call(_attacked_by_event(tick, priority, String(victim["id"]), int(next_sequence.call()), attacker_id, damage))
			if bool(victim_health.get("dead", false)):
				dead_actors.append(victim)
		else:
			var x := int(target["x"])
			var y := int(target["y"])
			damage_object.call(x, y, damage)
			insert_event.call(_attacked_by_event(tick, priority, TileGrid.coord_key(x, y), int(next_sequence.call()), attacker_id, damage))
	return {"dead_actors": dead_actors, "fighting": fighting}

static func _attacked_by_event(tick: int, priority: int, entity_id: String, sequence: int, attacker_id: String, damage: int) -> Dictionary:
	return {
		"type": EVENT_ATTACKED_BY, "tick": tick, "system_priority": priority, "entity_id": entity_id,
		"sequence": sequence, "data": {"attacker_id": attacker_id, "damage": damage},
	}
