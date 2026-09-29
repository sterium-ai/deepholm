class_name ActorInventory
extends RefCounted

## F2 inventory component: held items, tool slot. Data + validate() only in
## this task (see docs/decisions/012-actors-and-components.md and task t3).
## Tunables (content/actors.json): {"capacity": int >= 1}.

static func validate(tunables: Dictionary) -> bool:
	return tunables.get("capacity") is int and int(tunables["capacity"]) >= 1

## The per-instance state a freshly spawned actor with this component starts
## with: {"items", "tool", "capacity"}.
static func build(tunables: Dictionary) -> Dictionary:
	return {"items": [], "tool": "", "capacity": int(tunables.get("capacity", 1))}

## Issue #402 (docs/decisions/035): a colonist's single-slot "carrying" field
## (ADR 006/012) is replaced by "hands", a list of {"kind","count"} entries --
## at most one entry per distinct kind actually held, every entry's count
## >= 1, the sum of every entry's count never exceeding HANDS_CAPACITY. This
## is the single place a colonist's hands are read/written, so ToilExecutor
## and WorldState call into this instead of indexing "hands" inline in more
## than one place, mirroring the discipline ADR 012 already established for
## the field it replaces.
const HANDS_CAPACITY := 4

## True while actor holds at least one unit of anything.
static func is_carrying(actor: Dictionary) -> bool:
	return not (actor.get("hands", []) as Array).is_empty()

## True while actor holds at least one unit of kind.
static func has_kind(actor: Dictionary, kind: String) -> bool:
	for entry in (actor.get("hands", []) as Array):
		if String(entry["kind"]) == kind:
			return true
	return false

## The number of units of kind actor currently holds (0 when none).
static func count_of_kind(actor: Dictionary, kind: String) -> int:
	for entry in (actor.get("hands", []) as Array):
		if String(entry["kind"]) == kind:
			return int(entry["count"])
	return 0

## HANDS_CAPACITY minus the sum of every hands entry's count -- how many more
## units actor's hands can still take, of any kind.
static func free_capacity(actor: Dictionary) -> int:
	var used := 0
	for entry in (actor.get("hands", []) as Array):
		used += int(entry["count"])
	return HANDS_CAPACITY - used

## Adds count units of kind to actor's hands, merging into an existing
## same-kind entry or creating a new one. Callers (ToilExecutor.pick_up()) are
## responsible for never requesting more than free_capacity() allows.
static func add_to_hands(actor: Dictionary, kind: String, count: int) -> void:
	var hands: Array = actor.get("hands", [])
	for entry in hands:
		if String(entry["kind"]) == kind:
			entry["count"] = int(entry["count"]) + count
			actor["hands"] = hands
			return
	hands.append({"kind": kind, "count": count})
	actor["hands"] = hands

## Removes count units of kind from actor's hands (assumed already present in
## at least that amount -- callers check has_kind()/count_of_kind() first),
## dropping the entry entirely once its count reaches zero.
static func remove_from_hands(actor: Dictionary, kind: String, count: int) -> void:
	var hands: Array = actor.get("hands", [])
	for i in hands.size():
		var entry: Dictionary = hands[i]
		if String(entry["kind"]) != kind:
			continue
		var remaining := int(entry["count"]) - count
		if remaining > 0:
			entry["count"] = remaining
		else:
			hands.remove_at(i)
		actor["hands"] = hands
		return

## A snapshot ({"kind","count"} per distinct kind held, in hands order) a
## caller may iterate safely while this actor's own hands are mutated (e.g.
## ToilExecutor.place() draining every entry in one call).
static func hands_snapshot(actor: Dictionary) -> Array:
	var snapshot: Array = []
	for entry in (actor.get("hands", []) as Array):
		snapshot.append({"kind": entry["kind"], "count": entry["count"]})
	return snapshot

## Empties actor's hands entirely.
static func clear_hands(actor: Dictionary) -> void:
	actor["hands"] = []
