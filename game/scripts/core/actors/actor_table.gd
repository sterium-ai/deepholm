class_name ActorTable
extends RefCounted

## F2 actor table (docs/architecture/foundation-for-breadth.md section F2,
## docs/decisions/012-actors-and-components.md): builds a new actor
## Dictionary from its content/actors.json definition, and answers
## "does this actor's definition declare component X" / "read component X's
## per-instance state off this actor" against the same definition. Plain,
## scene-independent GDScript (AGENTS.md): every method is static and takes
## the ContentRegistry it needs explicitly, so it is constructible and
## callable from a headless test exactly like ContentRegistry/WorldState
## themselves, with no hidden instance state.
##
## Scope-limiting design decision (see the ADR): has_component()/
## get_component() are a pure lookup against the actor's own def_id (its
## "kind" field) in the content bundle -- never a per-instance flag or a new
## nested key -- so calling ActorTable.spawn("colonist", ...) produces
## exactly the same Dictionary shape WorldState's own colonist spawning has
## always produced (id, kind, x, y, needs, labourTable, route, work,
## carrying, held_tool), with has_component() still correctly reporting the
## colonist definition's declared components. Issue #283 adds one real new
## field to that shape, "health" (hp/maxHp/dead), since health now carries
## genuine per-instance state for a colonist the way it already did for a
## generic actor -- everything else about the accessor layer is unchanged.

const MoverType = preload("res://scripts/core/actors/components/mover.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const NeedsType = preload("res://scripts/core/actors/components/needs.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CombatType = preload("res://scripts/core/actors/components/combat.gd")
const WildType = preload("res://scripts/core/actors/components/wild.gd")
const VisitorType = preload("res://scripts/core/actors/components/visitor.gd")

## The closed vocabulary content_registry.gd's _check_references() enforces
## for an actor definition's "components" array, mirroring how
## ToilExecutor.is_known_toil() closes jobs.json's toil vocabulary.
const COMPONENT_NAMES: Array[String] = [
	"mover", "worker", "needs", "health", "inventory", "combat", "wild", "visitor",
]

static func is_known_component(name: String) -> bool:
	return COMPONENT_NAMES.has(name)

## Dispatches to the named component's own validate(tunables) static method.
## Used by content_registry.gd to reject an actor definition whose declared
## component has tunables outside that component's own rules (a required
## tunable missing entirely, or a cross-field rule like health.hp <= maxHp or
## worker.labour_min <= labour_default <= labour_max that the registry's
## single-field JSON-Schema-subset validator cannot express) with
## ERROR_SCHEMA_VIOLATION, mirroring how is_known_component() backs the
## dangling-reference check for an unknown component name. False for a name
## outside COMPONENT_NAMES; the registry only calls this after its own
## dangling-reference check has already confirmed name is known.
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

## Builds a new actor Dictionary for def_id (an id in content/actors.json's
## "actors" collection) at (x, y) with the given id, reading every tunable
## from registry rather than a local literal. "colonist" is special-cased to
## preserve the exact pre-F2 field set/order (see the class doc comment);
## every other def_id gets a component-keyed shape (a "needs"/"health"/
## "inventory"/"combat" key per declared component, "wild"/"visitor" as a
## bare true flag, "route" for mover).
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
	return {
		"id": id,
		"kind": "colonist",
		"x": x,
		"y": y,
		"needs": NeedsType.build_full_needs(registry),
		"needsAccumulator": NeedsType.build_full_accumulator(registry),
		"labourTable": WorkerType.default_labour_table(worker_tunables),
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

## True when actor's own definition (looked up by its "kind" field, the def_id
## every spawned actor carries) declares a component named name -- never a
## per-instance flag, so this is correct for a colonist's legacy shape too.
static func has_component(actor: Dictionary, name: String, registry) -> bool:
	var def_id := String(actor.get("kind", ""))
	var definition: Dictionary = registry.get_entry("actors", def_id)
	if definition.is_empty():
		return false
	var components: Array = definition.get("components", [])
	return components.has(name)

## The named component's per-instance state, assembled from actor's existing
## fields, or null when actor's definition does not declare that component.
## "worker" is the scope-limiting special case: assembled from the legacy
## "labourTable"/"held_tool" fields rather than a nested "worker" key.
## "mover" reads the shared "route" field every actor kind uses. Every other
## known component reads its own like-named key.
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
