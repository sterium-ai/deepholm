class_name StateCodec
extends RefCounted

## Converts between a live WorldState and the JSON-schema-safe Dictionary
## shape defined by docs/architecture/contracts/game-state.schema.json
## (see SCHEMA_VERSION below). No file I/O: callers own reading/writing
## bytes. This is
## the only module that knows both WorldState's native-Variant internals
## (Vector2i keys/values, RouteSearch/MeasuredRoute snapshots) and the
## JSON-safe encoding (objects with "x"/"y", string-keyed maps, arrays of
## pairs instead of Vector2i-keyed dictionaries).

const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
## The schema was reset to v1 before release (R14, ADR 049); v2 drops terminal jobs (A5,
## ADR 053). Every later shape change bumps this and adds a SaveMigrations step and a fixture.
const SCHEMA_VERSION := 2

## content/manifest.json's version, read fresh through a new ContentRegistry
## each call (mirroring how WorldState._init() itself builds one) rather than
## cached at load time, so a save always records the content bundle that is
## actually on disk right now instead of whatever was current at process
## start. "" when the registry itself is invalid (ContentRegistry.version()'s
## own documented fallback), which _validate_state()'s non-empty-string check
## already rejects -- no separate handling is needed here.
static func content_version() -> String:
	return ContentRegistryType.new().version()

static func encode(world: WorldState) -> Dictionary:
	var item_table := world._item_table.encode()
	var object_table := world._object_table.encode()
	var zone_table := world._zone_table.encode()
	var work_progress := world._progress_table.encode()
	return {
		"schemaVersion": SCHEMA_VERSION,
		"contentVersion": content_version(),
		"seed": world._seed,
		"tick": world._clock.tick,
		# SaveManager's own game-session marker (see save_manager.gd's header
		# comment): WorldState carries no session concept of its own, so
		# encode() always emits the game-agnostic default here; SaveManager
		# overwrites this field on the returned Dictionary before writing a
		# manual/autosave slot. Every direct encode()/write_atomic() caller that
		# never touches this field (tests, StateCodec.decode() round trips) gets a
		# valid, schema-complete state without needing to know epoch exists.
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
		"zones": zone_table["zones"],
		"nextZoneId": zone_table["nextZoneId"],
		"groundBerries": item_table["groundBerries"],
		"workProgress": work_progress["workProgress"],
		# The exact job_id that owns each workProgress
		# key, so decode() restores real ownership instead of guessing it from
		# whichever job happens to target that key (see the WorkProgress
		# class doc).
		"workProgressOwners": work_progress["workProgressOwners"],
		# A suspended (still-queued, not
		# terminated) job's own work-toil ticks, moved out of the live
		# "workProgress"/"workProgressOwners" tile cache so a different job
		# that later works the same tile can never inherit or clobber them
		# (WorkProgress.suspend()/resume()).
		"suspendedWorkProgress": work_progress["suspendedWorkProgress"],
		"pausedJobs": world._needs_system.encode()["pausedJobs"],
		"toolItems": _encode_tool_items(world._tool_store.items, world._tool_store.next_id),
		"toolReservations": world._tool_store.reservations.snapshot(),
		"needJobAssignments": _encode_paused_jobs(world._need_giver.get_pending_assignments()),
		# RescueGiver's own job_id ->
		# victim_id association, persisted verbatim (see
		# _encode_rescue_victim_assignments()'s own doc comment) rather than
		# re-derived from target-tile adjacency, which cannot uniquely
		# identify a victim whenever two victims share a target or have
		# overlapping adjacency sets.
		"rescueVictimAssignments": GiverCodec._encode_rescue_victim_assignments(world._rescue_giver.get_job_victims()),
		"combatBlockedTargets": GiverCodec._encode_combat_blocked_targets(world._combat_giver.get_blocked_targets()),
		# ApproachGiver's own job_id -> target association,
		# persisted verbatim (see _encode_approach_job_targets()'s own doc
		# comment) for the same reason rescueVictimAssignments is -- an object
		# target has no living record to re-scan after a load.
		"approachJobTargets": GiverCodec._encode_approach_job_targets(world._approach_giver.get_job_targets()),
		"calendarAlerts": GiverCodec._encode_calendar_alerts(world._calendar_alerts_fired),
		"toolFetchExcluded": GiverCodec._encode_tool_fetch_excluded(world._toils.get_fetch_tool_excluded()),
		"incidentScheduler": GiverCodec._encode_incident_scheduler(world._incidents),
		# ADR 026: dig's own find-roll RNG continuation (ItemTable.dig_find_random),
		# mirroring "rng" above and "incidentScheduler.rng"; when absent, ItemTable.decode()
		# keeps the constructor's fresh seed + WorldState.DIG_FIND_SEED_SALT stream.
		"digFindRng": item_table["digFindRng"],
		# ADR 044: pending area_order expansions, each with
		# the next row-major tile to expand, so a save taken mid-expansion
		# resumes exactly there (AreaOrders.encode()).
		"areaOrders": world._area_orders.encode(),
	}

## Reconstructs a WorldState that ticks identically to the instance that
## produced state (see encode()), including in-flight route searches and
## scheduler continuation state. The constructor's own map/colonist
## generation and random draws are discarded and fully overwritten below.
static func decode(state: Dictionary) -> WorldState:
	var map: Dictionary = state["map"]
	var width := int(map["width"])
	var height := int(map["height"])
	var world := WorldState.new(int(state["seed"]), 10, width, height)
	# The constructor above clamps p_width/p_height into WorldGenerator's
	# 16..512 new-game range (resolve_size()), which a saved map is never
	# subject to on restore (SaveIO._validate_state() only rejects a map
	# above that upper bound; a smaller saved fixture, e.g. 3x2, is valid and
	# must decode at its own exact size). Overwrite the constructor's resolved
	# width/height with the saved dimensions before replacing the tiles, or
	# every tile index below would use the wrong row stride.
	world._tile_grid.width = width
	world._tile_grid.height = height
	# The constructor above already built
	# NeedGiver/IncidentScheduler against its own resolve_size()-clamped
	# width/height (16..512), before the two lines above corrected
	# world._tile_grid.width/height to the saved map's real, possibly-smaller size.
	# Rebuild both services now, from the corrected dimensions, before
	# anything below (restore_pending_assignments, the reroute rebuild,
	# _reconcile_incident_jobs_after_load) touches them.
	world._build_dimension_services(false)
	world._generator_version = int(map.get("generatorVersion", WorldGeneratorType.GENERATOR_VERSION))
	world._tile_grid.decode(state["map"])
	world._colonists = EntityCodec._decode_entities(state["entities"])
	# "items", "groundBerries" and the optional "digFindRng". Nothing else in
	# decode() reads them or draws from the dig-find stream, so restoring all
	# three here (berries and the RNG used to be restored later) is order-safe.
	world._item_table.decode(state)
	# One record per placed origin tile, expanded back to every footprint tile
	# by ObjectTable.decode() (it needs the object definitions' footprint/rotatable).
	world._object_table.decode(state)
	# Absent "constructionSites" restores an empty table (ConstructionSystem.decode()).
	world._construction.decode(state)
	world._zone_table.decode(state)
	# "workProgress" and the optional "suspendedWorkProgress"; the persisted owners
	# are applied by restore_owners() below, once jobs are restored.
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
	# RescueGiver's own job_id ->
	# victim_id association is persisted verbatim on the wire (see
	# _encode_rescue_victim_assignments()'s own doc comment) -- restore it
	# before queue.restore() runs immediately below: that call's own
	# active-job reservation rebuild needs extra_keys_for_job() (see
	# job_queue.gd), which reads this. Filtered to jobs that actually survived
	# decode: a terminal job carries no live association (see
	# RescueGiver.resolve_job()), and a corrupted/hand-built fixture must
	# never seed an association for a job that no longer exists.
	var surviving_rescue_job_ids: Dictionary = {}
	for job in rescue_jobs:
		surviving_rescue_job_ids[String(job["id"])] = true
	var rescue_victims := GiverCodec._decode_rescue_victim_assignments(state.get("rescueVictimAssignments", []))
	for job_id in rescue_victims.keys().duplicate():
		if not surviving_rescue_job_ids.has(job_id):
			rescue_victims.erase(job_id)
	world._rescue_giver.restore_victim_assignments(rescue_victims)
	# Filtered to jobs that actually survived decode, the
	# same way rescue_victims is above -- a corrupted/hand-built fixture must
	# never seed an association for a job that no longer exists.
	var surviving_approach_job_ids: Dictionary = {}
	for job in GiverCodec._surviving_approach_jobs(jobs):
		surviving_approach_job_ids[String(job["id"])] = true
	var approach_targets := GiverCodec._decode_approach_job_targets(state.get("approachJobTargets", []))
	for job_id in approach_targets.keys().duplicate():
		if not surviving_approach_job_ids.has(job_id):
			approach_targets.erase(job_id)
	world._scheduler.queue.restore(jobs, int(scheduling["jobTick"]),
		int(scheduling["nextJobId"]), int(scheduling["jobSequence"]))
	# Repoints RescueGiver's own ReservationTable reference at the table
	# queue.restore() just built in place of the one _build_dimension_services()
	# handed it -- otherwise every is_reserved()/owner() peek this giver makes
	# from now on reads an obsolete, orphaned table.
	world._rescue_giver.set_reservation_table(world._scheduler.queue.get_reservation_table())
	# The work-progress owners are restored from the persisted job_id above
	# (guessing it from job-target iteration order could hand one job's
	# progress to another queued at the same tile), right after jobs
	# restore and before _reconcile_incident_jobs_after_load() below may
	# cancel one through the shared _finish_job() boundary, so that
	# cancellation's own ownership-gated work-progress cleanup fires correctly immediately after a load.
	world._progress_table.restore_owners(work_progress_owners, world._colonists, world._needs_system.paused_jobs)

	var bounds_max := Vector2i(width - 1, height - 1)
	world._scheduler.restore_scheduling(SchedulingCodec._decode_scheduling(scheduling),
		world._passability.is_passable, Vector2i.ZERO, bounds_max)
	# rescuer_id -> job_id needs no save data of its own either: every
	# surviving rescue job's own restrict_to, now available from the just-
	# restored scheduler, already names its rescuer (the same field a
	# player-ordered dig/chop job's own assignee restriction already
	# persists, see WorldState._resubmit_unreachable_job()'s own comment).
	world._rescue_giver.restore_pending_assignments(GiverCodec._rescue_pending_from_scheduler(rescue_jobs, world._scheduler))
	_restore_reroutes(world, bounds_max)
	# Re-associate each restored incident job with its actor,
	# or retire it (see WorldState).
	world._reconcile_incident_jobs_after_load()
	# Restored after the queue/scheduling restore above, so
	# CombatGiver can re-adopt every restored non-terminal flee job for its
	# owned episode right here, before the first tick's own decisions.
	world._combat_giver.restore_blocked_targets(GiverCodec._decode_combat_blocked_targets(state.get("combatBlockedTargets", [])))
	# Restored after the queue/scheduling restore above, so
	# ApproachGiver can re-adopt every restored non-terminal `approach` job for
	# its actor right here, before the first tick's own decisions (mirrors
	# CombatGiver.restore_blocked_targets() immediately above).
	world._approach_giver.restore_job_targets(approach_targets)
	# ADR 004 ("WorldState's diagnostic hash includes this continuation
	# state"): IncidentScheduler's own cooldowns/last-drawn-day/RNG are read
	# and written here directly, since incident_scheduler.gd exposes no
	# accessor for them.
	var incident_scheduler: Dictionary = state["incidentScheduler"]
	world._incidents._cooldown_until_day = SchedulingCodec._decode_int_dict(incident_scheduler["cooldownUntilDay"])
	world._incidents._last_processed_day = int(incident_scheduler["lastProcessedDay"])
	world._incidents._random.seed = int(incident_scheduler["rng"]["seed"])
	world._incidents._random.state = int(incident_scheduler["rng"]["state"])

	return world

## Rebuilds world._reroutes's live in-flight search objects from each
## colonist's persisted route.rerouting snapshot (see WorldState._begin_reroute()/
## _begin_haul_leg()), mirroring how GlobalAssignment.restore_scheduling()
## rebuilds its own pending route searches from their snapshots. A haul
## colonist already carrying its item is mid-leg-two: that search targets
## job["cell"] with plain passability, never job["target"] (the item's tile,
## leg one's own target) with the tree/target exception dig/chop's re-routes
## need. A colonist still mid-fetch_tool (ToilExecutor.needs_fetch_tool() true
## -- a read-only check, see tool_fetch_toil.gd's needs()) instead rebuilds
## the passability exception from snapshot["target"] itself -- the search's
## own already-persisted original target (see ToolFetchToil.advance(), which
## bakes the tool's position in at the moment the search starts into the very
## same field _encode_route()/_decode_route() already round-trip) -- rather
## than recomputing the tool's current location from toolItems/toolReservations
## (those differ once a held tool's holder moves
## after the search began, silently applying the exception to the wrong
## tile). A colonist mid-drop_tool (ToilExecutor.is_dropping_leg()) instead
## rebuilds with plain passability, no exception at
## all: the live drop toil never applies one either (a drop destination is
## always pre-verified passable, see tool_drop_toil.gd), so using job["target"]'s
## own exception here was wrong whenever that tile sat between the holder and
## the chosen stockpile cell -- it could open a "shortcut" through what should
## still be an impassable tile, a divergence only this branch, not a live
## uninterrupted run, could ever produce. Every other in-flight search uses
## job["target"] as before.
## The two `world._routable_to()` branches below now pass the
## acting colonist's own factionId (defaulting "colony", a no-op for an
## ordinary colonist) instead of `_routable_to()`'s colony default -- a
## restored search for a non-colony actor (a raider mid-flee) must be gated by
## its own faction's door permissions, exactly like the live, uninterrupted
## search tick()'s own _toil_go_to_passable()/_advance_go_to_or_resubmit()
## already are, or a save mid-search could diverge from an uninterrupted run.
## The two `world._passability.is_passable` branches (haul leg-two, dropping) stay
## colony-only by construction -- see their own comments above -- and are
## untouched.
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
		# A job finished by a command since the last tick is not saved (A5, ADR 053) but
		# may still name this route: with no assignment, the next _advance_colonists()
		# drops the route before any resume, so the cost callable is never consulted.
		if job.is_empty():
			cost_fn = world._passability.is_passable
		elif String(job.get("kind", "")) == "haul" and InventoryType.is_carrying(colonist):
			cost_fn = world._passability.is_passable
		elif String(job.get("kind", "")) == "build" and InventoryType.is_carrying(colonist):
			# A carrying build's live second leg searches toward job.site with
			# the site-tile exception (WorldState._toil_go_to_passable()), never
			# toward job.target, the wood's own tile.
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

## ItemTable.items is keyed by item id; sorted keys give a deterministic
## encoding order. next_id is ItemTable.next_item_id, carried alongside the list
## so a restored WorldState never reuses an id a save already handed out.
## item_factions is ItemTable.item_factions (the persisted counterpart of the
## "faction_id" runtime field get_items() adds), a parallel map keyed by item id rather than a nested value inside
## items itself -- mirroring _encode_objects()'s own parallel
## object_factions map.
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

## world._tool_store.items is keyed by item id; sorted keys give a
## deterministic encoding order, mirroring _encode_items()/_encode_objects().
## next_id is world._tool_store.next_id, carried alongside the list like
## _next_item_id.
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

## A tool item's location is one of three shapes (WorldState.set_tool_item_*):
## ground/stockpile carry a tile, held carries the holding colonist's id.
static func _encode_tool_location(location: Dictionary) -> Dictionary:
	if String(location["type"]) == "held":
		return {"type": "held", "colonistId": String(location["colonist_id"])}
	return {"type": String(location["type"]), "x": int(location["x"]), "y": int(location["y"])}

static func _decode_tool_location(location: Dictionary) -> Dictionary:
	if String(location["type"]) == "held":
		return {"type": "held", "colonist_id": String(location["colonistId"])}
	return {"type": String(location["type"]), "x": int(location["x"]), "y": int(location["y"])}

# --- zones -------------------------------------------------------------

## ZoneTable.zones is keyed by zone id; sorted keys give a deterministic
## encoding order. Zones are a plain array on the wire (like objects); the
## next-id counter that keeps a restored world from reusing an id a save
## already handed out is carried separately as the top-level "nextZoneId"
## field (see encode()/decode()), not nested inside "zones".
static func _encode_zones(zones: Dictionary) -> Array:
	var keys := zones.keys()
	keys.sort()
	var list: Array = []
	for key in keys:
		var zone: Dictionary = zones[key]
		list.append({
			"id": zone["id"], "x": zone["x"], "y": zone["y"],
			"width": zone["width"], "height": zone["height"],
		})
	return list

static func _decode_zones(list: Array) -> Dictionary:
	var zones: Dictionary = {}
	for entry in list:
		var id := String(entry["id"])
		zones[id] = {
			"id": id, "x": int(entry["x"]), "y": int(entry["y"]),
			"width": int(entry["width"]), "height": int(entry["height"]),
		}
	return zones

# --- objects ---------------------------------------------------------------

## ObjectTable.objects is keyed by "%d_%d" % [x, y] (see object_table.gd); the
## sorted keys give a deterministic encoding order. object_factions is
## ObjectTable.object_factions (the persisted counterpart of the "faction_id"
## runtime field get_objects() adds), a parallel map
## keyed the same way as objects rather than a nested value inside it.
## object_health is ObjectTable.object_health, the same kind of parallel
## map: present only for a key whose object kind declares "max_health"
## (content/objects.json), so a bare/non-damageable object omits the "health"
## wire field (optional in game-state.schema.json's "object" $def, like
## route.rerouting). A load that omits it falls back to
## ObjectTable.ensure_object_health()'s own backfill.
## object_origin/object_orientation are ObjectTable.object_origin/
## object_orientation -- one record is written per placed *object*, not per
## occupied tile: a key present in object_origin names a non-origin footprint
## tile of a multi-tile object and is skipped entirely (its origin's own
## record, plus ObjectTable.decode()'s object_footprint_tiles() expansion, already
## accounts for it). "orientation" is written only when object_orientation
## names this origin (absent, not "", for an unrotated or footprint-[1,1]
## object, exactly like game-state.schema.json's optional field).
static func _encode_objects(objects: Dictionary, object_factions: Dictionary, object_health: Dictionary,
		object_origin: Dictionary, object_orientation: Dictionary) -> Array:
	var keys := objects.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		if object_origin.has(key):
			continue
		var coords := String(key).split("_")
		var tile := Vector2i(int(coords[0]), int(coords[1]))
		var entry := {"target": _encode_tile(tile), "kind": String(objects[key]),
			"factionId": String(object_factions.get(key, "colony"))}
		if object_orientation.has(key):
			entry["orientation"] = String(object_orientation[key])
		if object_health.has(key):
			var health: Dictionary = object_health[key]
			entry["health"] = {"hp": int(health["hp"]), "maxHp": int(health["maxHp"])}
		encoded.append(entry)
	return encoded

## One raw {origin, kind, factionId, orientation, health?} record
## per placed object, in wire order -- ObjectTable.decode() expands each back out
## to every tile of its footprint (object_footprint_tiles(), needing the
## object definitions, which this static function has no access to).
## orientation defaults to "" (no rotation) exactly like a save from before
## object orientation existed, which never wrote the field at all.
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

## ItemTable.ground_berries is keyed by "%d_%d" (see item_table.gd, mirroring
## _objects); the sorted keys give a deterministic encoding order. Field name
## "berries" mirrors the old per-tile groundItems wire shape's "wood" field
## ({target, wood}): ground berries stay a simple per-tile counter, not a
## first-class pickable item like wood. "factionId" (ADR 047)
## comes from the parallel ground_berries_factions map, defaulting to "colony"
## like _encode_items() does for an untracked item.
static func _encode_ground_berries(ground_berries: Dictionary, factions: Dictionary) -> Array:
	var keys := ground_berries.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var coords := String(key).split("_")
		var tile := Vector2i(int(coords[0]), int(coords[1]))
		encoded.append({"target": _encode_tile(tile), "berries": int(ground_berries[key]),
			"factionId": String(factions.get(key, "colony"))})
	return encoded

## {berries: key -> count, factions: key -> faction id}, keyed like ItemTable.
static func _decode_ground_berries(list: Array) -> Dictionary:
	var berries: Dictionary = {}
	var factions: Dictionary = {}
	for entry in list:
		var tile := _decode_tile(entry["target"])
		var key := "%d_%d" % [tile.x, tile.y]
		berries[key] = int(entry["berries"])
		factions[key] = String(entry["factionId"])
	return {"berries": berries, "factions": factions}

# --- work progress (colonist-ai.md 3.6) -------------------------------------

## WorkProgress.progress is keyed by "%d_%d", or by "<jobId>:%d_%d" for a
## job-scoped (rescue) key; WorkProgress.key_parts()/key_of() split and build
## it, so the wire entry names its tile and scope ("ownerJobId", present only
## for a scoped key) explicitly. Sorted keys give a deterministic encoding order.
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

## WorkProgress.owners is keyed like WorkProgress.progress -> job_id. Each
## owner is an explicit {target, jobId, ownerJobId?} record (ADR 047): target + ownerJobId name the progress key exactly as a
## workProgress entry does, jobId the owning job. Sorted keys match
## _encode_work_progress()'s order. Only keys with a non-empty owner appear --
## an "incident" job's stamped wait never participates in job-id ownership
## (see WorkProgress.release_owned()), so it is absent here, not encoded with
## an empty id.
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

## Returns the raw key -> job_id map; WorkProgress.restore_owners()
## cross-checks each job_id against the just-restored job list before trusting
## it (see that function's own doc comment).
static func _decode_work_progress_owners(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var key := WorkProgress.key_of(_decode_tile(entry["target"]), String(entry.get("ownerJobId", "")))
		decoded[key] = String(entry["jobId"])
	return decoded

## WorkProgress.suspended is keyed by job_id directly: a suspended job's own snapshot, so no tile coordinate
## participates in the key at all -- sorted job_id keys give a deterministic
## encoding order.
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

## NeedsSystem.paused_jobs is keyed by colonist id; sorted keys give a
## deterministic encoding order, matching every other keyed-map encoder here.
## Reused as-is for NeedGiver's own colonist_id -> job_id association (see
## encode()'s "needJobAssignments"): both are the same {colonistId, jobId}
## shape.
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

# --- rescue giver restoration ----------------------------------

# --- combat giver flee-destination exclusions ----

# --- approach giver target association (ADR 033) ---------------

# --- calendar alerts (ADR 008, colonist-ai.md 3.7) --------------------------

# --- tool fetch excluded candidates (ADR 013) ----------

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

## One record per active site, mirroring the object codec's own
## "origin record, expanded to the whole footprint on load" shape -- a site
## has no per-tile duplication to begin with (ConstructionSiteTable already
## stores exactly one record per site), so this is a direct field mapping.
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

## ConstructionSiteTable.restore()'s own next_id counter: re-derived from the
## highest "site_<N>" id already present rather than persisted separately, so
## no new top-level field/counter is needed at all -- the same "site_%d"
## naming create() always uses.
static func _next_construction_site_id(sites: Array[Dictionary]) -> int:
	var next_id := 1
	for site in sites:
		var id := String(site["id"])
		if id.begins_with("site_"):
			next_id = maxi(next_id, int(id.substr(5)) + 1)
	return next_id

# --- moved encoders still called as StateCodec.* by WorldState.state_hash() ----

static func _hash_colonists(colonists: Array[Dictionary], reroutes: Dictionary) -> Array:
	return EntityCodec._hash_colonists(colonists, reroutes)

static func _encode_combat_blocked_targets(blocked: Dictionary) -> Array:
	return GiverCodec._encode_combat_blocked_targets(blocked)

static func _encode_rescue_victim_assignments(job_victims: Dictionary) -> Array:
	return GiverCodec._encode_rescue_victim_assignments(job_victims)

static func _encode_approach_job_targets(job_targets: Dictionary) -> Array:
	return GiverCodec._encode_approach_job_targets(job_targets)
