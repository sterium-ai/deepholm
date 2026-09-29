class_name Relations
extends RefCounted

## F3 relations module (docs/architecture/foundation-for-breadth.md section F3,
## docs/decisions/015-factions-and-relations.md): reads content/factions.json
## through a frozen ContentRegistry to answer "how does faction A feel about
## faction B" and "are these two actors hostile". Plain, scene-independent
## GDScript (AGENTS.md): constructed from a ContentRegistry exactly like
## ActorTable/ToilExecutor; registry is taken untyped (duck-typed) rather than
## `registry: ContentRegistry` to avoid a preload cycle, since
## content_registry.gd itself preloads this file to reuse RELATION_VALUES/
## is_known_relation_value() for its own faction-relation validation, the same
## way it already reuses ActorTable.is_known_component() and
## ToilExecutor.is_known_toil().
##
## Unused by combat or job-giver code today (this task's Non-goals): the
## documented seam the objective's later passability/reservation/order and
## combat/incident work wires up.

const RELATION_VALUES: Array[String] = ["hostile", "neutral", "friendly"]
const DEFAULT_RELATION := "neutral"

static func is_known_relation_value(value: String) -> bool:
	return RELATION_VALUES.has(value)

var _registry

func _init(registry) -> void:
	_registry = registry

## Faction a_faction_id's own declared row for b_faction_id
## (content/factions.json's "relations" field): a's opinion of b, which is
## not required to be symmetric with b's opinion of a. A faction relating to
## itself is always "friendly", regardless of what content declares. Falls
## back to "neutral" only when a_faction_id names no declared faction at
## all -- never the case for a valid registry's own declared factions, since
## ContentRegistry._check_references() requires every faction to declare a
## complete relation row naming every other declared faction id.
func relation(a_faction_id: String, b_faction_id: String) -> String:
	if a_faction_id == b_faction_id:
		return "friendly"
	var faction_entry: Dictionary = _registry.get_entry("factions", a_faction_id)
	var relations: Dictionary = faction_entry.get("relations", {})
	return String(relations.get(b_faction_id, DEFAULT_RELATION))

## Whether actor_a's faction considers actor_b's faction hostile, reading
## each actor Dictionary's own "faction_id" field. Not consulted by combat or
## any job-giver yet (Non-goals) -- the seam this objective's later F5
## combat/incident work wires up.
func is_hostile(actor_a: Dictionary, actor_b: Dictionary) -> bool:
	var a_faction_id := String(actor_a.get("faction_id", ""))
	var b_faction_id := String(actor_b.get("faction_id", ""))
	return relation(a_faction_id, b_faction_id) == "hostile"
