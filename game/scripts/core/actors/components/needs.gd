class_name ActorNeeds
extends RefCounted

## Needs component (ADR 012/024): "needs" is Dictionary[kind -> int]; the sibling
## "needsAccumulator" is Dictionary[kind -> int in [0, day_length_ticks)], an integer sub-point
## carry. Tunables: {"rates": Dictionary[kind -> int >= 0]} per day (duplicated from needs.json).
## NeedsSystem.decay_needs() calls apply_tick() with "day_length_ticks" in the tunables.

static func validate(tunables: Dictionary) -> bool:
	if not tunables.has("rates"):
		return false
	var rates: Variant = tunables["rates"]
	if not (rates is Dictionary):
		return false
	for rate in (rates as Dictionary).values():
		if not (rate is int) or rate < 0:
			return false
	return true

## Every declared need kind at its "full" value (content/needs.json).
static func build_full_needs(registry) -> Dictionary:
	var needs: Dictionary = {}
	for need in registry.list("needs"):
		needs[String(need["kind"])] = int(need["full"])
	return needs

## Every declared need kind's fresh accumulator (0).
static func build_full_accumulator(registry) -> Dictionary:
	var accumulator: Dictionary = {}
	for need in registry.list("needs"):
		accumulator[String(need["kind"])] = 0
	return accumulator

## Adds rate_per_day to each carry; each full day_length_ticks drops the need one point (clamped at
## 0). Integer-only, so platform-independent.
static func apply_tick(actor: Dictionary, tunables: Dictionary) -> void:
	var needs: Variant = actor.get("needs")
	if not (needs is Dictionary):
		return
	var accumulator: Variant = actor.get("needsAccumulator")
	if not (accumulator is Dictionary):
		return
	var rates: Dictionary = tunables.get("rates", {})
	var day_length_ticks := maxi(1, int(tunables.get("day_length_ticks", 1)))
	for kind in (needs as Dictionary).keys():
		var rate := int(rates.get(kind, 0))
		if rate <= 0:
			continue
		var carry := int(accumulator.get(kind, 0)) + rate
		while carry >= day_length_ticks:
			carry -= day_length_ticks
			needs[kind] = maxi(0, int(needs[kind]) - 1)
		accumulator[kind] = carry
