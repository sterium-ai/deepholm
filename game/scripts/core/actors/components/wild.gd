class_name ActorWild
extends RefCounted

## F2 wild component: marks an actor as untamed wildlife (the "wild" half of
## foundation-for-breadth.md F2's "tame/wild" pair; "tame" is not implemented
## yet). Data + validate() only -- "Must not change" real behaviour in this
## task (docs/decisions/012-actors-and-components.md, task t3). Presence of
## the component on an actor definition is itself the flag; the one optional
## tunable (ADR 025 t3, issue #359) is trench_climb_ticks, an integer >= 1
## read by WorldState._trench_climb_ticks() -- absent tunables are still valid
## (WorldState falls back to DEFAULT_TRENCH_CLIMB_TICKS).

static func validate(tunables: Dictionary) -> bool:
	if tunables.is_empty():
		return true
	if tunables.size() > 1 or not tunables.has("trench_climb_ticks"):
		return false
	var ticks = tunables["trench_climb_ticks"]
	return ticks is int and int(ticks) >= 1
