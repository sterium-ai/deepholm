class_name ActorHealth
extends RefCounted

## F2 health component: hp, maxHp, dead flag. Data + validate() plus bounds
## clamping; no damage behaviour lives here (see docs/decisions/
## 012-actors-and-components.md). Tunables (content/actors.json):
## {"maxHp": int >= 1, "hp": int >= 0 (optional, defaults to maxHp)}.

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

## The per-instance state a freshly spawned actor with this component starts
## with: {"hp", "maxHp", "dead"}. Honors an optional "hp" tunable below maxHp
## (a generic actor may spawn already hurt). A colonist must always spawn at
## full health regardless of this tunable -- see build_full() below.
static func build(tunables: Dictionary) -> Dictionary:
	var max_hp := int(tunables.get("maxHp", 1))
	return {"hp": int(tunables.get("hp", max_hp)), "maxHp": max_hp, "dead": false}

## Same shape as build(), but always starts at hp == maxHp, dead == false,
## ignoring any optional "hp" tunable: a colonist's spawn hp must track
## maxHp even when content declares an "hp" below it.
static func build_full(tunables: Dictionary) -> Dictionary:
	var max_hp := int(tunables.get("maxHp", 1))
	return {"hp": max_hp, "maxHp": max_hp, "dead": false}

## Keeps a health Dictionary's own invariants: hp in [0, maxHp] (maxHp itself
## floored at 1), dead true once hp has reached 0 and permanently true from
## then on (a prior true dead is preserved even if something set hp positive
## again, since death must not un-happen). Idempotent and safe to call after
## any sequence of external hp edits (this component itself applies no
## combat or hazard damage). Named clamp_bounds(), not clamp(), to avoid
## shadowing GDScript's built-in global clamp(value, min, max).
static func clamp_bounds(health: Dictionary) -> void:
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	health["maxHp"] = max_hp
	health["hp"] = clampi(int(health.get("hp", max_hp)), 0, max_hp)
	health["dead"] = bool(health.get("dead", false)) or int(health["hp"]) <= 0

## Per-tick component hook (ADR 012): a no-op when actor declares no "health"
## key. Re-clamps every tick so bounds hold under any future sequence of
## apply_tick() calls even before anything changes hp.
static func apply_tick(actor: Dictionary) -> void:
	var health = actor.get("health")
	if health is Dictionary:
		clamp_bounds(health)
