class_name ActorWild
extends RefCounted

## Wild component (ADR 012): untamed wildlife flag ("tame" not implemented). Data + validate()
## only. Optional tunable trench_climb_ticks >= 1 (ADR 026), read by TrenchSystem
## (DEFAULT_TRENCH_CLIMB_TICKS when absent).

static func validate(tunables: Dictionary) -> bool:
	if tunables.is_empty():
		return true
	if tunables.size() > 1 or not tunables.has("trench_climb_ticks"):
		return false
	var ticks: Variant = tunables["trench_climb_ticks"]
	return ticks is int and int(ticks) >= 1
