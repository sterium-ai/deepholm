class_name ActorHealth
extends RefCounted

## Health component (ADR 012): hp, maxHp, dead; data, validate() and bounds only, no damage.
## Tunables: {"maxHp": int >= 1, "hp": int >= 0 (optional, defaults to maxHp)}.

static func validate(tunables: Dictionary) -> bool:
	if not (tunables.get("maxHp") is int):
		return false
	var max_hp := int(tunables["maxHp"])
	if max_hp < 1:
		return false
	if tunables.has("hp"):
		if not (tunables["hp"] is int) or int(tunables["hp"]) < 0 or int(tunables["hp"]) > max_hp:
			return false
	return true

## {"hp", "maxHp", "dead"}; honours an "hp" tunable below maxHp (colonists use build_full()).
static func build(tunables: Dictionary) -> Dictionary:
	var max_hp := int(tunables.get("maxHp", 1))
	return {"hp": int(tunables.get("hp", max_hp)), "maxHp": max_hp, "dead": false}

## Like build() but always at full hp: a colonist spawns at maxHp whatever content declares.
static func build_full(tunables: Dictionary) -> Dictionary:
	var max_hp := int(tunables.get("maxHp", 1))
	return {"hp": max_hp, "maxHp": max_hp, "dead": false}

## hp in [0, maxHp] (maxHp floored at 1); dead once hp reaches 0 and never un-dead. Idempotent.
## Not clamp(): that would shadow the global clamp().
static func clamp_bounds(health: Dictionary) -> void:
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	health["maxHp"] = max_hp
	health["hp"] = clampi(int(health.get("hp", max_hp)), 0, max_hp)
	health["dead"] = bool(health.get("dead", false)) or int(health["hp"]) <= 0

## Per-tick hook: re-clamps when the actor has "health".
static func apply_tick(actor: Dictionary) -> void:
	var health: Variant = actor.get("health")
	if health is Dictionary:
		clamp_bounds(health)
