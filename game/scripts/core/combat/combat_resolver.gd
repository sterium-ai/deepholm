class_name CombatResolver
extends RefCounted

## F5 combat resolution (ADR 021). Plain, scene-independent GDScript
## (AGENTS.md): every method is
## static, driven by WorldState.tick()'s own explicit tick counter, with no
## scene/node/rendering/wall-clock/global-RNG dependency. Resolves rule (1)
## (an actor with a `combat` component deals its `damage` every `cooldown`
## ticks to the nearest adjacent hostile target) and rule (4) (an actor
## strictly below its own `flee_hp_fraction` stops fighting), and reports rule (2)/(3)'s
## consequences (a dead actor, a damaged/destroyed object) for WorldState to
## apply against its own owned state -- per ADR 011, WorldState calls this,
## never implements it. `combat_giver.gd` is the separate job-giver module
## that turns rule (4)'s "stops fighting" into the actual "paths away" -- this
## module only ever decides whether an attack lands, never drives movement.

const TargetingType = preload("res://scripts/core/combat/combat_targeting.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")

## docs/architecture/orders-and-movement.md's typed event/reason vocabulary,
## extended here with two entries: `attacked_by` (an event,
## recorded once per landed hit) and `fighting` (a per-tick reason exposed
## through WorldState.get_actor_combat_reason(), mirroring
## get_colonist_need_reason()'s "need_unmet:"/"rerouting" pattern).
const EVENT_ATTACKED_BY := "attacked_by"

## flee_hp_fraction defaults to 0.0 (never flee) for any actor definition that
## does not declare one -- content, not this module, opts an actor kind in
## (via its "combat" tunables in content/actors.json). Read from the actor
## *definition's* tunables, not the per-instance "combat" component dict:
## ActorCombat.build() (docs/decisions/012-actors-and-components.md) only
## carries attack/damage/cooldown/cooldown_remaining into runtime state, so
## any other combat tunable has nowhere to round-trip on the instance
## itself.
static func _flee_hp_fraction(actor: Dictionary, content) -> float:
	var definition: Dictionary = content.get_entry("actors", String(actor.get("kind", "")))
	var combat_tunables: Dictionary = (definition.get("tunables", {}) as Dictionary).get("combat", {})
	return float(combat_tunables.get("flee_hp_fraction", 0.0))

static func _hp_fraction(actor: Dictionary) -> float:
	var health: Dictionary = actor.get("health", {})
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	return float(int(health.get("hp", 0))) / float(max_hp)

## Runs once per WorldState.tick(), before the fair scheduler sees any
## colonist (the same "before layer 5's work" ordering need_giver/haul_giver
## already use): decrements every combat actor's cooldown by one on every
## applicable tick -- independent of whether it currently has an adjacent
## target or is below its own flee threshold, since the rule is elapsed
## ticks, not ticks spent engaged (an actor that attacks, disengages for
## longer than its own cooldown, then re-engages must not still wait out
## the stale remaining value) -- attacks once the cooldown
## reaches zero, and reports every actor that reached 0 hp this call for the
## caller to apply (rule 2: dead, removed from scheduling, drops inventory).
## Object damage/destruction (rule 3) is applied immediately through
## `damage_object`, since -- unlike an actor -- an object has no dict of its
## own for this module to hand back to the caller; WorldState's own
## `_damage_object()` already owns clearing a destroyed object back to
## no-object (a wall becomes floor).
## `object_at`/`object_health_at`/`object_faction_at`/`damage_object` must be
## WorldState's own get_object/_object_health_at/get_object_faction_id/
## _damage_object. `insert_event`/`next_sequence` must be WorldState's own
## event log writers. Returns {"dead_actors": Array[Dictionary], "fighting":
## Array[String]}.
static func resolve_tick(actors: Array[Dictionary], content, relations, tick: int, priority: int,
		object_at: Callable, object_health_at: Callable, object_faction_at: Callable, damage_object: Callable,
		insert_event: Callable, next_sequence: Callable) -> Dictionary:
	var dead_actors: Array[Dictionary] = []
	var fighting: Array[String] = []
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
		var target := TargetingType.nearest_adjacent_hostile(actor, actors, relations, object_at, object_health_at, object_faction_at)
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
			insert_event.call(_attacked_by_event(tick, priority, "%d_%d" % [x, y], int(next_sequence.call()), attacker_id, damage))
	return {"dead_actors": dead_actors, "fighting": fighting}

static func _attacked_by_event(tick: int, priority: int, entity_id: String, sequence: int, attacker_id: String, damage: int) -> Dictionary:
	return {
		"type": EVENT_ATTACKED_BY, "tick": tick, "system_priority": priority, "entity_id": entity_id,
		"sequence": sequence, "data": {"attacker_id": attacker_id, "damage": damage},
	}
