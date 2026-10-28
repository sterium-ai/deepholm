class_name ConstructionSiteTable
extends RefCounted

## One record per active construction site (ADR 040), a build order that exists independently
## of any job. ConstructionSystem is the only mutator; readers go through these methods.
## Record: {id, kind, origin, orientation, required_materials, held_materials, progress,
## build_ticks, max_builders, builder_ids}. build_ticks/max_builders are copied from content at
## creation, so a content edit never changes an in-progress site; builder_ids <= max_builders.

var _sites: Dictionary = {}
var _next_id: int = 1

static func _materials_copy(materials: Array) -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for entry in materials:
		copy.append({"item": String(entry["item"]), "quantity": int(entry["quantity"])})
	return copy

## Creates a site (held_materials zeroed per build_cost item); returns a detached copy.
func create(kind: String, origin: Vector2i, orientation: String, required_materials: Array,
		build_ticks: int, max_builders: int) -> Dictionary:
	var id := "site_%d" % _next_id
	_next_id += 1
	var held: Array[Dictionary] = []
	for entry in required_materials:
		held.append({"item": String(entry["item"]), "quantity": 0})
	var site := {
		"id": id, "kind": kind, "origin": origin, "orientation": orientation,
		"required_materials": _materials_copy(required_materials),
		"held_materials": held,
		"progress": 0, "build_ticks": build_ticks, "max_builders": max_builders,
		"builder_ids": [] as Array[String],
	}
	_sites[id] = site
	return site.duplicate(true)

## The ReservationTable owner of a site's footprint ("" for an unknown id). Never a job id,
## so ReservationInvariants takes it through extra_active_owners.
func owner_key(id: String) -> String:
	return "site:" + id

func has(id: String) -> bool:
	return _sites.has(id)

func get_site(id: String) -> Dictionary:
	return _sites[id].duplicate(true) if _sites.has(id) else {}

## Every active site, sorted by id for deterministic iteration/hashing.
func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids := _sites.keys()
	ids.sort()
	for id in ids:
		out.append(_sites[id].duplicate(true))
	return out

func remove(id: String) -> void:
	_sites.erase(id)

func required_quantity(site: Dictionary, item: String) -> int:
	for entry in (site["required_materials"] as Array):
		if String(entry["item"]) == item:
			return int(entry["quantity"])
	return 0

func held_quantity(site: Dictionary, item: String) -> int:
	for entry in (site["held_materials"] as Array):
		if String(entry["item"]) == item:
			return int(entry["quantity"])
	return 0

## How many more units of item the site still needs (never negative).
func remaining(site: Dictionary, item: String) -> int:
	return maxi(0, required_quantity(site, item) - held_quantity(site, item))

## True once every declared required material is fully held.
func materials_met(site: Dictionary) -> bool:
	for entry in (site["required_materials"] as Array):
		if held_quantity(site, String(entry["item"])) < int(entry["quantity"]):
			return false
	return true

## Accepts up to `count` units, clamped to what the site still needs (0 for an undeclared
## item); returns the amount accepted so the remainder stays in the colonist's hands.
func deposit(id: String, item: String, count: int) -> int:
	if not _sites.has(id) or count <= 0:
		return 0
	var site: Dictionary = _sites[id]
	var accepted := mini(count, remaining(site, item))
	if accepted <= 0:
		return 0
	for entry in (site["held_materials"] as Array):
		if String(entry["item"]) == item:
			entry["quantity"] = int(entry["quantity"]) + accepted
			return accepted
	return 0

## Zeroes held materials; cancel reads them first to drop them on the ground.
func clear_held_materials(id: String) -> void:
	if not _sites.has(id):
		return
	for entry in (_sites[id]["held_materials"] as Array):
		entry["quantity"] = 0

## True on success or when already a builder; false for an unknown id or a full site.
func add_builder(id: String, colonist_id: String) -> bool:
	if not _sites.has(id):
		return false
	var site: Dictionary = _sites[id]
	var builders: Array = site["builder_ids"]
	if colonist_id in builders:
		return true
	if builders.size() >= int(site["max_builders"]):
		return false
	builders.append(colonist_id)
	return true

func remove_builder(id: String, colonist_id: String) -> void:
	if not _sites.has(id):
		return
	(_sites[id]["builder_ids"] as Array).erase(colonist_id)

func builder_ids(id: String) -> Array:
	return (_sites[id]["builder_ids"] as Array).duplicate() if _sites.has(id) else []

## Adds `amount` ticks of work (summed over all builders); the new total, or 0 for an unknown id.
func add_progress(id: String, amount: int) -> int:
	if not _sites.has(id):
		return 0
	var site: Dictionary = _sites[id]
	site["progress"] = int(site["progress"]) + amount
	return int(site["progress"])

func find_at_origin(origin: Vector2i) -> String:
	for id in _sites.keys():
		if _sites[id]["origin"] == origin:
			return id
	return ""

## Overwrites every record from a save; next_id continues create()'s monotonic counter.
func restore(records: Array[Dictionary], next_id: int) -> void:
	_sites = {}
	for record in records:
		_sites[String(record["id"])] = record.duplicate(true)
	_next_id = next_id

func get_next_id() -> int:
	return _next_id
