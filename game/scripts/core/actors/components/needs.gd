class_name ActorNeeds
extends RefCounted

## F2 needs component. Per-instance state lives at the actor's own "needs"
## key, Dictionary[kind -> int], exactly the shape a pre-F2 colonist has
## always carried, plus a sibling "needsAccumulator" key, Dictionary[kind ->
## int in [0, day_length_ticks)]: a deterministic integer
## sub-point carry so a point-per-day rate need not divide evenly into a
## single tick's decay. Tunables (content/actors.json): {"rates":
## Dictionary[kind -> int >= 0]}, the per-day decay rate for each need kind
## this actor tracks -- duplicated from content/needs.json's own per-kind
## "rate_per_day" field because an actor definition has no other route to it
## without importing the whole needs loader.
##
## Wired into WorldState's own decay path (world_state.gd's _decay_needs()
## calls apply_tick() below, passing "day_length_ticks" alongside "rates" in
## the same tunables Dictionary); see docs/decisions/012-actors-and-components.md
## and docs/decisions/024-needs-decay-points-per-day.md.

static func validate(tunables: Dictionary) -> bool:
	if not tunables.has("rates"):
		return false
	var rates = tunables["rates"]
	if not (rates is Dictionary):
		return false
	for rate in (rates as Dictionary).values():
		if not (rate is int) or rate < 0:
			return false
	return true

## Every declared need kind's own "full" value (content/needs.json), the same
## initial value a pre-F2 colonist's _full_needs() has always produced.
static func build_full_needs(registry) -> Dictionary:
	var needs: Dictionary = {}
	for need in registry.list("needs"):
		needs[String(need["kind"])] = int(need["full"])
	return needs

## Every declared need kind's own fresh accumulator (0), the sibling of
## build_full_needs() above for a freshly spawned actor's "needsAccumulator".
static func build_full_accumulator(registry) -> Dictionary:
	var accumulator: Dictionary = {}
	for need in registry.list("needs"):
		accumulator[String(need["kind"])] = 0
	return accumulator

## Decays every tracked need by its own rate_per_day, applied as a
## deterministic integer accumulator: each tick adds rate_per_day
## to that kind's carry, and while the carry reaches day_length_ticks it is
## reduced by day_length_ticks and the need drops by one point, clamped at 0.
## Integer-only and platform-independent by construction (no float division).
static func apply_tick(actor: Dictionary, tunables: Dictionary) -> void:
	var needs = actor.get("needs")
	if not (needs is Dictionary):
		return
	var accumulator = actor.get("needsAccumulator")
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
