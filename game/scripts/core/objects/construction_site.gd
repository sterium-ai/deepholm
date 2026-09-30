class_name ConstructionSiteTable
extends RefCounted

## One record per active construction site (ADR 040):
## a persistent, multi-tick `build` order that exists independently of any
## job. WorldState is the only mutator; ConstructionGiver and the toil hooks
## read/write through the methods below rather than indexing a site
## Dictionary directly, mirroring ReservationTable's own "generic ledger,
## callers own the keyspace" discipline. Plain data plus pure helpers, no
## scene/node/RNG/wall-clock dependency (AGENTS.md simulation rules).
##
## A site record: {id, kind, origin (Vector2i), orientation (String),
## required_materials (Array[{item, quantity}], from the kind's own
## content/objects.json build_cost), held_materials (Array[{item, quantity}],
## same item set, quantities delivered so far), progress (int, ticks of work
## accumulated), build_ticks (int, copied from content at creation so a later
## content edit never retroactively changes an in-progress site), max_builders
## (int, ditto), builder_ids (Array[String], colonists currently contributing
## a `site_work` job -- capped at max_builders).

var _sites: Dictionary = {}
var _next_id: int = 1

static func _materials_copy(materials: Array) -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for entry in materials:
		copy.append({"item": String(entry["item"]), "quantity": int(entry["quantity"])})
	return copy

## Creates and stores a new site record, returning a detached copy.
## required_materials is the kind's own content/objects.json "build_cost"
## list; held_materials starts at zero for each of the same items.
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

## "" for an unknown id; the shared ReservationTable owner string a site's own
## footprint reservation is acquired under -- never a job id, so
## ReservationInvariants.find_orphaned_reservations() must be told about it
## through its own extra_active_owners parameter.
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

## Delivers up to `count` units of `item` into id's held_materials, clamped to
## what the site still needs -- never past required_quantity(), and a no-op
## (returns 0) for an item the site's kind never declared at all. Returns the
## amount actually accepted so a caller (ToilExecutor.deposit()) can leave any
## unaccepted remainder in the colonist's own hands rather than destroying it.
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

## Zeroes every held-material entry (cancel_site: materials are dropped on the
## ground instead, not simply discarded -- the caller reads the pre-clear
## amounts first).
func clear_held_materials(id: String) -> void:
	if not _sites.has(id):
		return
	for entry in (_sites[id]["held_materials"] as Array):
		entry["quantity"] = 0

## True on success; false when id is unknown, colonist_id is already a
## builder (idempotent no-op success, not a failure, mirroring
## ReservationTable.acquire()'s own "already owned by the same job" shape --
## returns true), or every max_builders slot is already taken.
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

## Adds `amount` ticks to id's own accumulated progress -- every active
## builder's `site_work` job calls this once per tick it works, so the
## mechanism sums correctly for more than one concurrent builder. Returns
## the new total, or 0 for an unknown id.
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

## Overwrites every site record from a prior save state (state_codec.gd);
## next_id continues the same monotonic counter create() uses, exactly like
## JobQueue.restore()'s own next_id parameter.
func restore(records: Array[Dictionary], next_id: int) -> void:
	_sites = {}
	for record in records:
		_sites[String(record["id"])] = record.duplicate(true)
	_next_id = next_id

func get_next_id() -> int:
	return _next_id
