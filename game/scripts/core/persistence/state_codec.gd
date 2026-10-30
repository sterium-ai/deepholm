class_name StateCodec
extends RefCounted

## Converts a live WorldState to and from the JSON-safe Dictionary of
## docs/architecture/contracts/game-state.schema.json; no file I/O. The only module that knows
## both the native Variants (Vector2i keys, route snapshots) and their wire encoding.
## Invariant: decode(encode(world)) ticks identically to world, and every map is written in
## sorted-key order so the same state always yields the same bytes.

const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const WorldSetupType = preload("res://scripts/core/world/world_setup.gd")
## The schema was reset to v1 before release (R14, ADR 049); v2 drops terminal jobs (A5,
## ADR 053); v3 records the content packs (A13b, ADR 010 amendment 2); v4 saves the scenario's
## calendar and enabled incidents (A16b, ADR 057); v5 saves route-search costs and SaveIO writes
## the compact SaveWire encoding (A7, ADR 058); v6 adds farm zones and crop growth (F1, ADR 059);
## v7 saves the workbench targets, orders and bills (F2, ADR 061).
## v8 saves every colonist's skills (F3, ADR 062).
## Every later shape change bumps this and adds a SaveMigrations step and a fixture.
const SCHEMA_VERSION := 8

## The session registry's manifest version (null: the base bundle on disk); "" when the
## registry is invalid, which SaveIO._validate_state() rejects.
static func content_version(content: ContentRegistryType = null) -> String:
	return (content if content != null else ContentRegistryType.new()).version()

## The ContentRegistry world was built on: what its save records and is validated against.
static func content_of(world: WorldState) -> ContentRegistryType:
	return world._content

static func encode(world: WorldState) -> Dictionary:
	var item_table := world._item_table.encode()
	var object_table := world._object_table.encode()
	var zone_table := world._zone_table.encode()
	var work_progress := world._progress_table.encode()
	return {
		"schemaVersion": SCHEMA_VERSION,
		"contentVersion": world._content.version(),
		# Ordered like ContentRegistry.packs(); SaveIO refuses to load it on any other list.
		"contentPacks": _encode_content_packs(world._content.packs()),
		"seed": world._seed,
		"tick": world._clock.tick,
		# SaveManager's session marker; WorldState has no session, so SaveManager overwrites it.
		"epoch": 0,
		"map": {
			"width": world.get_map_width(),
			"height": world.get_map_height(),
			"tiles": world._tile_grid.encode()["tiles"],
			"generatorVersion": world.get_generator_version(),
		},
		"entities": EntityCodec._encode_entities(world._colonists, world._reroutes),
		"inventory": {},
		# Live jobs only: terminal jobs leave the save (A5, schema v2).
		"jobs": SchedulingCodec._encode_jobs(world._scheduler.queue.get_jobs(false)),
		"scheduling": SchedulingCodec._encode_scheduling(world._scheduler, world._event_log.encode()),
		"rng": {"seed": world._random.seed, "state": world._random.state},
		"items": item_table["items"],
		"objects": object_table["objects"],
		# One record per active construction site.
		"constructionSites": world._construction.encode()["constructionSites"],
		# ADR 061 (v6): per-bench targets, orders and the bill in progress.
		"crafting": world._crafting.encode()["crafting"],
		"zones": zone_table["zones"],
		"nextZoneId": zone_table["nextZoneId"],
		# F1 (ADR 059): growth of every sown tile, in tile-key order.
		"crops": world._farm.encode()["crops"],
		"groundBerries": item_table["groundBerries"],
		"workProgress": work_progress["workProgress"],
		# The exact owning job_id per key, so decode() never guesses ownership from job targets.
		"workProgressOwners": work_progress["workProgressOwners"],
		# A suspended job's own ticks, kept apart so another job on that tile cannot inherit them.
		"suspendedWorkProgress": work_progress["suspendedWorkProgress"],
		"pausedJobs": world._needs_system.encode()["pausedJobs"],
		"toolItems": _encode_tool_items(world._tool_store.items, world._tool_store.next_id),
		"toolReservations": world._tool_store.reservations.snapshot(),
		"needJobAssignments": _encode_paused_jobs(world._need_giver.get_pending_assignments()),
		# Persisted verbatim: adjacency cannot tell two victims of one target apart.
		"rescueVictimAssignments": GiverCodec._encode_rescue_victim_assignments(world._rescue_giver.get_job_victims()),
		"combatBlockedTargets": GiverCodec._encode_combat_blocked_targets(world._combat_giver.get_blocked_targets()),
		# Persisted verbatim: an object target has no live record to re-scan after a load.
		"approachJobTargets": GiverCodec._encode_approach_job_targets(world._approach_giver.get_job_targets()),
		"calendarAlerts": GiverCodec._encode_calendar_alerts(world._calendar_alerts_fired),
		"toolFetchExcluded": GiverCodec._encode_tool_fetch_excluded(world._toils.get_fetch_tool_excluded()),
		"incidentScheduler": GiverCodec._encode_incident_scheduler(world._incidents),
		# ADR 026: dig find-roll RNG continuation; absent keeps the constructor's salted stream.
		"digFindRng": item_table["digFindRng"],
		# ADR 044: pending area_order expansions, resumed at their next row-major tile.
		"areaOrders": world._area_orders.encode(),
		# ADR 057 (v4): the scenario calendar and incident list the world keeps running under.
		"scenarioStart": world._setup.encode(),
	}

## Reconstructs a WorldState that ticks identically to the one that produced state,
## including in-flight route searches; the constructor's own generation is overwritten.
## content is the session registry the save was checked against (SaveIO.read()); null builds
## the base bundle.
static func decode(state: Dictionary, content: ContentRegistryType = null) -> WorldState:
	var map: Dictionary = state["map"]
	var width := int(map["width"])
	var height := int(map["height"])
	# Built under the saved calendar and incident list (ADR 057); absent (a replay's older
	# initial state) is the base start.
	var scenario_start: Dictionary = state.get("scenarioStart", {})
	var setup := WorldSetupType.decode(scenario_start)
	var world := WorldState.new(int(state["seed"]), 10, width, height, false, content, setup)
	# The constructor clamps size to the new-game 16..512 range; a saved map keeps its own size
	# (e.g. a 3x2 fixture), set before the tiles or the row stride is wrong.
	world._tile_grid.width = width
	world._tile_grid.height = height
	# NeedGiver/IncidentScheduler were built at the clamped size: rebuild them before use.
	world._build_dimension_services(false)
	world._generator_version = int(map.get("generatorVersion", WorldGeneratorType.GENERATOR_VERSION))
	world._tile_grid.decode(state["map"])
	world._colonists = EntityCodec._decode_entities(state["entities"])
	# Items, ground berries and the dig-find RNG; nothing else in decode() draws from it.
	world._item_table.decode(state)
	# One record per origin, expanded to the footprint by ObjectTable.decode().
	world._object_table.decode(state)
	# Absent "constructionSites" restores an empty table (ConstructionSystem.decode()).
	world._construction.decode(state)
	# Absent "crafting" restores no configured bench (CraftingSystem.decode()).
	world._crafting.decode(state)
	world._zone_table.decode(state)
	# After the tiles: reconciles the records with the decoded stage tiles (FarmSystem.decode()).
	world._farm.decode(state)
	# Owners are applied by restore_owners() below, once jobs exist.
	var work_progress_owners := world._progress_table.decode(state)
	world._needs_system.decode(state)
	var tool_items_data := _decode_tool_items(state["toolItems"])
	world._tool_store.items = tool_items_data["items"]
	world._tool_store.next_id = tool_items_data["next_id"]
	world._tool_store.reservations.restore(state["toolReservations"] as Dictionary)
	world._clock.tick = int(state["tick"])
	world._random.seed = int(state["rng"]["seed"])
	world._random.state = int(state["rng"]["state"])
	world._need_giver.restore_pending_assignments(_decode_paused_jobs(state["needJobAssignments"]))
	world._calendar_alerts_fired = GiverCodec._decode_calendar_alerts(state["calendarAlerts"])
	world._toils.restore_fetch_tool_excluded(GiverCodec._decode_tool_fetch_excluded(state["toolFetchExcluded"]))
	world._area_orders.decode(state.get("areaOrders", {}))

	var scheduling: Dictionary = state["scheduling"]
	world._event_log.decode(scheduling)

	var jobs := SchedulingCodec._decode_jobs(state["jobs"])
	var rescue_jobs := GiverCodec._surviving_rescue_jobs(jobs)
	# Restored before queue.restore(): its reservation rebuild reads extra_keys_for_job(). Only
	# jobs that survived decode keep an association.
	var surviving_rescue_job_ids: Dictionary = {}
	for job in rescue_jobs:
		surviving_rescue_job_ids[String(job["id"])] = true
	var rescue_victims := GiverCodec._decode_rescue_victim_assignments(state.get("rescueVictimAssignments", []))
	for job_id in rescue_victims.keys().duplicate():
		if not surviving_rescue_job_ids.has(job_id):
			rescue_victims.erase(job_id)
	world._rescue_giver.restore_victim_assignments(rescue_victims)
	# Filtered to surviving jobs, like rescue_victims above.
	var surviving_approach_job_ids: Dictionary = {}
	for job in GiverCodec._surviving_approach_jobs(jobs):
		surviving_approach_job_ids[String(job["id"])] = true
	var approach_targets := GiverCodec._decode_approach_job_targets(state.get("approachJobTargets", []))
	for job_id in approach_targets.keys().duplicate():
		if not surviving_approach_job_ids.has(job_id):
			approach_targets.erase(job_id)
	world._scheduler.queue.restore(jobs, int(scheduling["jobTick"]),
		int(scheduling["nextJobId"]), int(scheduling["jobSequence"]))
	# Repoint RescueGiver at the reservation table queue.restore() just built.
	world._rescue_giver.set_reservation_table(world._scheduler.queue.get_reservation_table())
	# Owners from the persisted job_id, after the jobs and before the incident reconcile below
	# may cancel one (its ownership-gated cleanup needs them).
	world._progress_table.restore_owners(work_progress_owners, world._colonists, world._needs_system.paused_jobs)

	var bounds_max := Vector2i(width - 1, height - 1)
	world._scheduler.restore_scheduling(SchedulingCodec._decode_scheduling(scheduling),
		world._passability.is_passable, Vector2i.ZERO, bounds_max, world._passability.region_reachable)
	# rescuer_id -> job_id needs no save data: each rescue job's restrict_to names its rescuer.
	world._rescue_giver.restore_pending_assignments(GiverCodec._rescue_pending_from_scheduler(rescue_jobs, world._scheduler))
	_restore_reroutes(world, bounds_max)
	# Re-associate each restored incident job with its actor, or retire it.
	world._reconcile_incident_jobs_after_load()
	# After the scheduling restore, so CombatGiver re-adopts its flee jobs before the first tick.
	world._combat_giver.restore_blocked_targets(GiverCodec._decode_combat_blocked_targets(state.get("combatBlockedTargets", [])))
	# Same for ApproachGiver and its approach jobs.
	world._approach_giver.restore_job_targets(approach_targets)
	# ADR 004: the scheduler's continuation state is hashed; IncidentScheduler has no accessor.
	var incident_scheduler: Dictionary = state["incidentScheduler"]
	world._incidents._cooldown_until_day = SchedulingCodec._decode_int_dict(incident_scheduler["cooldownUntilDay"])
	world._incidents._last_processed_day = int(incident_scheduler["lastProcessedDay"])
	world._incidents._random.seed = int(incident_scheduler["rng"]["seed"])
	world._incidents._random.state = int(incident_scheduler["rng"]["state"])

	return world

## Rebuilds world._reroutes from each colonist's persisted route.rerouting snapshot, with the
## same cost function the live search used: plain passability for a carrying haul leg and a
## drop_tool leg, snapshot["target"] for a fetch_tool leg (the tool may have moved since), and
## the job target's exception with the actor's own faction otherwise.
static func _restore_reroutes(world: WorldState, bounds_max: Vector2i) -> void:
	for colonist in world._colonists:
		var route: Variant = colonist.get("route")
		if route == null:
			continue
		var snapshot: Variant = route.get("rerouting")
		if snapshot == null:
			continue
		var job_id: String = route["job_id"]
		var job := world._scheduler.queue.get_job(job_id)
		var faction_id := String(colonist.get("factionId", "colony"))
		var cost_fn: Callable
		# A job finished by a command since the last tick is not saved (ADR 053); the next
		# TickPipeline._advance_colonists() drops the route before the callable is used.
		if job.is_empty():
			cost_fn = world._passability.is_passable
		elif String(job.get("kind", "")) == "haul" and InventoryType.is_carrying(colonist):
			cost_fn = world._passability.is_passable
		elif job.get("kind", "") == "craft_fetch" and job.get("cell") != null:
			# A delivering craft_fetch routes to its bench (impassable): the target-tile exception.
			cost_fn = world._routable_to(job["site"] as Vector2i, faction_id)
		elif String(job.get("kind", "")) == "build" and InventoryType.is_carrying(colonist):
			# The carrying build leg routes to job.site (ToilBindings._toil_go_to_passable()).
			cost_fn = world._routable_to(job["site"], faction_id)
		elif world._toils.is_dropping_leg(colonist, job_id, job, world._toil_hooks):
			cost_fn = world._passability.is_passable
		elif world._toils.needs_fetch_tool(colonist, job, job_id):
			cost_fn = world._routable_to(snapshot["target"], faction_id)
		else:
			var target: Vector2i = job["target"]
			cost_fn = world._routable_to(target, faction_id)
		var search: RerouteType = RerouteType.new(snapshot["start"], snapshot["start"],
			cost_fn, Vector2i.ZERO, bounds_max)
		search.restore(snapshot)
		world._reroutes[colonist["id"]] = search
		# Back to the live shape: the full snapshot stays on the search.
		route["rerouting"] = search.summary()

## Plain (unfrozen) copies, so the state stays a mutable Dictionary like every other field.
static func _encode_content_packs(packs: Array) -> Array:
	var encoded: Array = []
	for pack: Dictionary in packs:
		var id: String = pack["id"]
		var version: String = pack["version"]
		encoded.append({"id": id, "version": version})
	return encoded

# --- tiles ---------------------------------------------------------------

static func _encode_tile(tile: Vector2i) -> Dictionary:
	return {"x": tile.x, "y": tile.y}

static func _decode_tile(tile: Dictionary) -> Vector2i:
	return Vector2i(int(tile["x"]), int(tile["y"]))

static func _encode_tile_array(tiles: Array) -> Array:
	var encoded: Array = []
	for tile in tiles:
		encoded.append(_encode_tile(tile))
	return encoded

static func _decode_tile_array(tiles: Array) -> Array:
	var decoded: Array = []
	for tile in tiles:
		decoded.append(_decode_tile(tile))
	return decoded

# --- items -----------------------------------------------------------------

## Sorted by item id. next_id travels with the list so a restored world never reuses an id;
## item_factions is a parallel map keyed by item id, like the objects' factions.
static func _encode_items(items: Dictionary, next_id: int, item_factions: Dictionary) -> Dictionary:
	var keys := items.keys()
	keys.sort()
	var list: Array = []
	for key in keys:
		var item: Dictionary = items[key]
		list.append({
			"id": item["id"], "x": item["x"], "y": item["y"],
			"kind": item["kind"], "count": item["count"],
			"factionId": String(item_factions.get(key, "colony")),
		})
	return {"nextId": next_id, "list": list}

static func _decode_items(field: Dictionary) -> Dictionary:
	var items: Dictionary = {}
	var factions: Dictionary = {}
	for entry in (field["list"] as Array):
		var id := String(entry["id"])
		items[id] = {
			"id": id, "x": int(entry["x"]), "y": int(entry["y"]),
			"kind": String(entry["kind"]), "count": int(entry["count"]),
		}
		factions[id] = String(entry.get("factionId", "colony"))
	return {"items": items, "next_id": int(field["nextId"]), "factions": factions}

# --- tool items (colonist-ai.md 2/3.4) ---------------------------

## Sorted by item id; next_id travels with the list, as for ground items.
static func _encode_tool_items(tool_items: Dictionary, next_id: int) -> Dictionary:
	var keys := tool_items.keys()
	keys.sort()
	var list: Array = []
	for key in keys:
		var item: Dictionary = tool_items[key]
		list.append({
			"id": item["id"], "kind": item["kind"],
			"location": _encode_tool_location(item["location"]),
		})
	return {"nextId": next_id, "list": list}

static func _decode_tool_items(field: Dictionary) -> Dictionary:
	var items: Dictionary = {}
	for entry in (field["list"] as Array):
		var id := String(entry["id"])
		items[id] = {
			"id": id, "kind": String(entry["kind"]),
			"location": _decode_tool_location(entry["location"]),
		}
	return {"items": items, "next_id": int(field["nextId"])}

## A location is ground/stockpile (a tile) or held (the holder's colonist id).
static func _encode_tool_location(location: Dictionary) -> Dictionary:
	if String(location["type"]) == "held":
		return {"type": "held", "colonistId": String(location["colonist_id"])}
	return {"type": String(location["type"]), "x": int(location["x"]), "y": int(location["y"])}

static func _decode_tool_location(location: Dictionary) -> Dictionary:
	if String(location["type"]) == "held":
		return {"type": "held", "colonist_id": String(location["colonistId"])}
	return {"type": String(location["type"]), "x": int(location["x"]), "y": int(location["y"])}

# --- zones -------------------------------------------------------------

## Sorted by zone id; the next-id counter travels as the top-level "nextZoneId". A farm zone
## (F1) also carries "kind": "farm" and its "crop"; a stockpile carries neither.
static func _encode_zones(zones: Dictionary) -> Array:
	var keys := zones.keys()
	keys.sort()
	var list: Array = []
	for key in keys:
		var zone: Dictionary = zones[key]
		var entry := {
			"id": zone["id"], "x": zone["x"], "y": zone["y"],
			"width": zone["width"], "height": zone["height"],
		}
		if zone.has("kind"):
			entry["kind"] = zone["kind"]
			entry["crop"] = zone["crop"]
		list.append(entry)
	return list

static func _decode_zones(list: Array) -> Dictionary:
	var zones: Dictionary = {}
	for entry in list:
		var id := String(entry["id"])
		zones[id] = {
			"id": id, "x": int(entry["x"]), "y": int(entry["y"]),
			"width": int(entry["width"]), "height": int(entry["height"]),
		}
		var farm: Dictionary = entry
		if farm.has("kind"):
			var kind: String = farm["kind"]
			var crop: String = farm["crop"]
			zones[id]["kind"] = kind
			zones[id]["crop"] = crop
	return zones

# --- objects ---------------------------------------------------------------

## One record per placed object (origin key, sorted), never per footprint tile. Factions,
## health and orientation are parallel maps; "health" only for kinds with max_health and
## "orientation" only when set (absent, not ""), both optional in the schema.
static func _encode_objects(objects: Dictionary, object_factions: Dictionary, object_health: Dictionary,
		object_origin: Dictionary, object_orientation: Dictionary) -> Array:
	var keys := objects.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		if object_origin.has(key):
			continue
		var tile := TileGrid.coord_of_key(String(key))
		var entry := {"target": _encode_tile(tile), "kind": String(objects[key]),
			"factionId": String(object_factions.get(key, "colony"))}
		if object_orientation.has(key):
			entry["orientation"] = String(object_orientation[key])
		if object_health.has(key):
			var health: Dictionary = object_health[key]
			entry["health"] = {"hp": int(health["hp"]), "maxHp": int(health["maxHp"])}
		encoded.append(entry)
	return encoded

## Raw records in wire order; ObjectTable.decode() expands footprints (it has the defs).
## A missing orientation means unrotated.
static func _decode_objects(objects: Array) -> Array:
	var records: Array = []
	for item in objects:
		var record := {"origin": _decode_tile(item["target"]), "kind": String(item["kind"]),
			"factionId": String(item.get("factionId", "colony")), "orientation": String(item.get("orientation", ""))}
		if item.has("health"):
			var health: Dictionary = item["health"]
			record["health"] = {"hp": int(health["hp"]), "maxHp": int(health["maxHp"])}
		records.append(record)
	return records

# --- ground berries ----------------------------------------------------

## Sorted "%d_%d" keys; berries stay a per-tile counter, not items. factionId (ADR 047)
## defaults to "colony", like an untracked item.
static func _encode_ground_berries(ground_berries: Dictionary, factions: Dictionary) -> Array:
	var keys := ground_berries.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var tile := TileGrid.coord_of_key(String(key))
		encoded.append({"target": _encode_tile(tile), "berries": int(ground_berries[key]),
			"factionId": String(factions.get(key, "colony"))})
	return encoded

## {berries: key -> count, factions: key -> faction id}, keyed like ItemTable.
static func _decode_ground_berries(list: Array) -> Dictionary:
	var berries: Dictionary = {}
	var factions: Dictionary = {}
	for entry in list:
		var tile := _decode_tile(entry["target"])
		var key := TileGrid.coord_key(tile.x, tile.y)
		berries[key] = int(entry["berries"])
		factions[key] = String(entry["factionId"])
	return {"berries": berries, "factions": factions}

# --- work progress (colonist-ai.md 3.6) -------------------------------------

## Keys are "%d_%d", or "<jobId>:%d_%d" for a job-scoped (rescue) key; the wire names tile
## and scope ("ownerJobId") explicitly. Sorted by key.
static func _encode_work_progress(work_progress: Dictionary) -> Array:
	var keys := work_progress.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var parts := WorkProgress.key_parts(String(key))
		var entry := {"target": _encode_tile(parts["tile"]), "ticksRemaining": int(work_progress[key])}
		if not String(parts["scope"]).is_empty():
			entry["ownerJobId"] = String(parts["scope"])
		encoded.append(entry)
	return encoded

static func _decode_work_progress(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var key := WorkProgress.key_of(_decode_tile(entry["target"]), String(entry.get("ownerJobId", "")))
		decoded[key] = int(entry["ticksRemaining"])
	return decoded

## {target, jobId, ownerJobId?} per owned key (ADR 047), in _encode_work_progress() order.
## Only non-empty owners: an incident's stamped wait never owns progress.
static func _encode_work_progress_owners(work_progress_owner: Dictionary) -> Array:
	var keys := work_progress_owner.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var parts := WorkProgress.key_parts(String(key))
		var entry := {"target": _encode_tile(parts["tile"]), "jobId": String(work_progress_owner[key])}
		if not String(parts["scope"]).is_empty():
			entry["ownerJobId"] = String(parts["scope"])
		encoded.append(entry)
	return encoded

## Raw key -> job_id; WorkProgress.restore_owners() checks each against the restored jobs.
static func _decode_work_progress_owners(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var key := WorkProgress.key_of(_decode_tile(entry["target"]), String(entry.get("ownerJobId", "")))
		decoded[key] = String(entry["jobId"])
	return decoded

## Keyed by job_id (a suspended job's own snapshot, no tile); sorted by job_id.
static func _encode_suspended_work_progress(suspended_work_progress: Dictionary) -> Array:
	var keys := suspended_work_progress.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		encoded.append({"jobId": String(key), "ticksRemaining": int(suspended_work_progress[key])})
	return encoded

static func _decode_suspended_work_progress(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		decoded[String(entry["jobId"])] = int(entry["ticksRemaining"])
	return decoded

# --- paused jobs (colonist-ai.md 3.6) ---------------------------------------

## Sorted by colonist id; also encodes NeedGiver's colonist -> job map (same shape).
static func _encode_paused_jobs(paused_jobs: Dictionary) -> Array:
	var keys := paused_jobs.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		encoded.append({"colonistId": key, "jobId": String(paused_jobs[key])})
	return encoded

static func _decode_paused_jobs(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		decoded[String(entry["colonistId"])] = String(entry["jobId"])
	return decoded

# --- construction sites ------------------------------------

static func _encode_materials(materials: Array) -> Array:
	var encoded: Array = []
	for entry in materials:
		encoded.append({"item": entry["item"], "quantity": entry["quantity"]})
	return encoded

static func _decode_materials(materials: Array) -> Array[Dictionary]:
	var decoded: Array[Dictionary] = []
	for entry in materials:
		decoded.append({"item": String(entry["item"]), "quantity": int(entry["quantity"])})
	return decoded

## One record per active site; ConstructionSiteTable already stores one per site.
static func _encode_construction_sites(sites: Array[Dictionary]) -> Array:
	var encoded: Array = []
	for site in sites:
		encoded.append({
			"id": site["id"], "kind": site["kind"], "origin": _encode_tile(site["origin"]),
			"orientation": site.get("orientation", ""),
			"requiredMaterials": _encode_materials(site["required_materials"]),
			"heldMaterials": _encode_materials(site["held_materials"]),
			"progress": site["progress"], "buildTicks": site["build_ticks"],
			"maxBuilders": site["max_builders"], "builderIds": site["builder_ids"],
		})
	return encoded

static func _decode_construction_sites(sites: Array) -> Array[Dictionary]:
	var decoded: Array[Dictionary] = []
	for site in sites:
		var builder_ids: Array[String] = []
		for id in (site["builderIds"] as Array):
			builder_ids.append(String(id))
		decoded.append({
			"id": String(site["id"]), "kind": String(site["kind"]), "origin": _decode_tile(site["origin"]),
			"orientation": String(site.get("orientation", "")),
			"required_materials": _decode_materials(site["requiredMaterials"]),
			"held_materials": _decode_materials(site["heldMaterials"]),
			"progress": int(site["progress"]), "build_ticks": int(site["buildTicks"]),
			"max_builders": int(site["maxBuilders"]), "builder_ids": builder_ids,
		})
	return decoded

## The site counter is re-derived from the highest "site_<N>" id, so it is never persisted.
static func _next_construction_site_id(sites: Array[Dictionary]) -> int:
	var next_id := 1
	for site in sites:
		var id := String(site["id"])
		if id.begins_with("site_"):
			next_id = maxi(next_id, int(id.substr(5)) + 1)
	return next_id

# --- encoders also called as StateCodec.* by WorldState.state_hash() ----

static func _hash_colonists(colonists: Array[Dictionary], reroutes: Dictionary) -> Array:
	return EntityCodec._hash_colonists(colonists, reroutes)

static func _encode_combat_blocked_targets(blocked: Dictionary) -> Array:
	return GiverCodec._encode_combat_blocked_targets(blocked)

static func _encode_rescue_victim_assignments(job_victims: Dictionary) -> Array:
	return GiverCodec._encode_rescue_victim_assignments(job_victims)

static func _encode_approach_job_targets(job_targets: Dictionary) -> Array:
	return GiverCodec._encode_approach_job_targets(job_targets)
