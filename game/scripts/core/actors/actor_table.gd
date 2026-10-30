class_name ActorTable
extends RefCounted

## Actor table (foundation-for-breadth.md F2, ADR 012): builds an actor Dictionary from its
## content/actors.json definition and answers component queries against that definition. All
## static, registry passed explicitly. has_component()/get_component() look up the actor's "kind",
## never a per-instance flag, so a colonist keeps its historic field set and order.

const MoverType = preload("res://scripts/core/actors/components/mover.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const NeedsType = preload("res://scripts/core/actors/components/needs.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CombatType = preload("res://scripts/core/actors/components/combat.gd")
const WildType = preload("res://scripts/core/actors/components/wild.gd")
const VisitorType = preload("res://scripts/core/actors/components/visitor.gd")
const SkillsType = preload("res://scripts/core/actors/components/skills.gd")

## The closed component vocabulary content_registry.gd's _check_references() enforces.
const COMPONENT_NAMES: Array[String] = [
	"mover", "worker", "needs", "health", "inventory", "combat", "wild", "visitor",
]

static func is_known_component(name: String) -> bool:
	return COMPONENT_NAMES.has(name)

## Dispatches to the component's validate(tunables) for cross-field rules the registry's schema
## subset cannot express. Only called after the name is known; false outside COMPONENT_NAMES.
static func validate_component(name: String, tunables: Dictionary) -> bool:
	match name:
		"mover":
			return MoverType.validate(tunables)
		"worker":
			return WorkerType.validate(tunables)
		"needs":
			return NeedsType.validate(tunables)
		"health":
			return HealthType.validate(tunables)
		"inventory":
			return InventoryType.validate(tunables)
		"combat":
			return CombatType.validate(tunables)
		"wild":
			return WildType.validate(tunables)
		"visitor":
			return VisitorType.validate(tunables)
		_:
			return false

## Builds actor def_id at (x, y), every tunable from the registry. "colonist" keeps its exact
## field set/order; every other kind gets component-keyed fields ("wild"/"visitor" as true flags,
## "route" for mover).
static func spawn(def_id: String, x: int, y: int, registry, id: String) -> Dictionary:
	var definition: Dictionary = registry.get_entry("actors", def_id)
	var components: Array = definition.get("components", [])
	var tunables: Dictionary = definition.get("tunables", {})
	if def_id == "colonist":
		return _spawn_colonist(x, y, id, tunables, registry)
	return _spawn_generic_actor(def_id, x, y, id, components, tunables, registry)

static func _spawn_colonist(x: int, y: int, id: String, tunables: Dictionary, registry) -> Dictionary:
	var worker_tunables: Dictionary = tunables.get("worker", {})
	var health_tunables: Dictionary = tunables.get("health", {})
	var labours: Array = worker_tunables.get("labours", [])
	return {
		"id": id,
		"kind": "colonist",
		"x": x,
		"y": y,
		"needs": NeedsType.build_full_needs(registry),
		"needsAccumulator": NeedsType.build_full_accumulator(registry),
		"labourTable": WorkerType.default_labour_table(worker_tunables),
		# F3 (ADR 062): every worker labour at level 0; WorldSeeding seeds a new world's start.
		"skills": SkillsType.build_zero(labours),
		"route": null,
		"work": null,
		"carrying": null,
		"held_tool": "",
		"health": HealthType.build_full(health_tunables),
	}

static func _spawn_generic_actor(def_id: String, x: int, y: int, id: String, components: Array,
		tunables: Dictionary, registry) -> Dictionary:
	var actor: Dictionary = {"id": id, "kind": def_id, "x": x, "y": y, "route": null}
	if components.has("needs"):
		actor["needs"] = NeedsType.build_full_needs(registry)
		actor["needsAccumulator"] = NeedsType.build_full_accumulator(registry)
	if components.has("health"):
		actor["health"] = HealthType.build(tunables.get("health", {}))
	if components.has("inventory"):
		actor["inventory"] = InventoryType.build(tunables.get("inventory", {}))
	if components.has("combat"):
		actor["combat"] = CombatType.build(tunables.get("combat", {}))
	if components.has("wild"):
		actor["wild"] = true
	if components.has("visitor"):
		actor["visitor"] = true
	return actor

## True when the actor's definition (by "kind") declares component `name`.
static func has_component(actor: Dictionary, name: String, registry) -> bool:
	var def_id := String(actor.get("kind", ""))
	var definition: Dictionary = registry.get_entry("actors", def_id)
	if definition.is_empty():
		return false
	var components: Array = definition.get("components", [])
	return components.has(name)

## The component's per-instance state, or null when undeclared. "worker" is assembled from
## "labourTable"/"held_tool", "mover" reads "route"; others read their like-named key.
static func get_component(actor: Dictionary, name: String, registry) -> Variant:
	if not has_component(actor, name, registry):
		return null
	match name:
		"worker":
			return {"labourTable": actor.get("labourTable", {}), "held_tool": actor.get("held_tool", "")}
		"mover":
			return {"route": actor.get("route")}
		_:
			return actor.get(name)
