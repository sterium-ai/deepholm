class_name Relations
extends RefCounted

## Relations (foundation-for-breadth.md F3, ADR 014): faction-to-faction opinion from
## content/factions.json. Registry is untyped to avoid a preload cycle (content_registry.gd
## preloads this file for RELATION_VALUES).

const RELATION_VALUES: Array[String] = ["hostile", "neutral", "friendly"]
const DEFAULT_RELATION := "neutral"

static func is_known_relation_value(value: String) -> bool:
	return RELATION_VALUES.has(value)

var _registry

func _init(registry) -> void:
	_registry = registry

## The declared opinion of a toward b (not necessarily symmetric); a faction is always "friendly"
## to itself; "neutral" only for an undeclared a (the registry requires complete relation rows).
func relation(a_faction_id: String, b_faction_id: String) -> String:
	if a_faction_id == b_faction_id:
		return "friendly"
	var faction_entry: Dictionary = _registry.get_entry("factions", a_faction_id)
	var relations: Dictionary = faction_entry.get("relations", {})
	return String(relations.get(b_faction_id, DEFAULT_RELATION))

## Reads each actor's content-style "faction_id" key, not the runtime "factionId": combat code
## uses relation() with "factionId" instead (ADR 021).
func is_hostile(actor_a: Dictionary, actor_b: Dictionary) -> bool:
	var a_faction_id := String(actor_a.get("faction_id", ""))
	var b_faction_id := String(actor_b.get("faction_id", ""))
	return relation(a_faction_id, b_faction_id) == "hostile"
