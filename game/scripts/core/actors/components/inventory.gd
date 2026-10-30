class_name ActorInventory
extends RefCounted

## F2 inventory component: held items, tool slot, plus the colonist hands
## helpers below (see docs/decisions/012-actors-and-components.md).
## Tunables (content/actors.json): {"capacity": int >= 1}.

static func validate(tunables: Dictionary) -> bool:
	return tunables.get("capacity") is int and int(tunables["capacity"]) >= 1

## The per-instance state a freshly spawned actor with this component starts
## with: {"items", "tool", "capacity"}.
static func build(tunables: Dictionary) -> Dictionary:
	return {"items": [], "tool": "", "capacity": int(tunables.get("capacity", 1))}

## ADR 037 "hands": a list of {"kind","count"}, at most one entry per kind, every count >= 1, the
## total never above HANDS_CAPACITY plus the carry-skill bonus (F3, ADR 062). The single read/write point of a colonist's hands.
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

## How many more units of any kind the hands can take; capacity is HANDS_CAPACITY plus the
## actor's carry-skill bonus (ToilExecutor.hands_capacity(), F3/ADR 062) where skills apply.
static func free_capacity(actor: Dictionary, capacity: int = HANDS_CAPACITY) -> int:
	var used := 0
	for entry in (actor.get("hands", []) as Array):
		used += int(entry["count"])
	return capacity - used

## Merges into a same-kind entry or appends one; callers never exceed free_capacity().
static func add_to_hands(actor: Dictionary, kind: String, count: int) -> void:
	var hands: Array = actor.get("hands", [])
	for entry in hands:
		if String(entry["kind"]) == kind:
			entry["count"] = int(entry["count"]) + count
			actor["hands"] = hands
			return
	hands.append({"kind": kind, "count": count})
	actor["hands"] = hands

## Callers check the amount first; an entry reaching zero is dropped.
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

## A copy safe to iterate while the hands are mutated (ToilExecutor.place()).
static func hands_snapshot(actor: Dictionary) -> Array:
	var snapshot: Array = []
	for entry in (actor.get("hands", []) as Array):
		snapshot.append({"kind": entry["kind"], "count": entry["count"]})
	return snapshot

## Empties actor's hands entirely.
static func clear_hands(actor: Dictionary) -> void:
	actor["hands"] = []
