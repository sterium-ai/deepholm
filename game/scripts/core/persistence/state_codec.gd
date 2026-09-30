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
const SCHEMA_VERSION := 25

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
			"tiles": world._tiles.duplicate(),
			"generatorVersion": world.get_generator_version(),
		},
		"entities": _encode_entities(world._colonists),
		"inventory": {},
		"jobs": _encode_jobs(world._scheduler.queue.get_jobs()),
		"scheduling": _encode_scheduling(world),
		"rng": {"seed": world._random.seed, "state": world._random.state},
		"items": _encode_items(world._items, world._next_item_id, world._item_factions),
		"objects": _encode_objects(world._objects, world._object_factions, world._object_health, world._object_origin, world._object_orientation),
		# One record per active construction site. Optional on the
		# wire like "combatBlockedTargets"/"digFindRng" above -- an older save
		# predating construction sites simply has none, matching decode()'s own
		# constructor default (a fresh, empty ConstructionSiteTable).
		"constructionSites": _encode_construction_sites(world._sites.list()),
		"zones": _encode_zones(world._zones),
		"nextZoneId": world._next_zone_id,
		"groundBerries": _encode_ground_berries(world._ground_berries),
		"workProgress": _encode_work_progress(world._work_progress),
		# The exact job_id that owns each workProgress
		# key, so decode() restores real ownership instead of guessing it from
		# whichever job happens to target that key (see world_state.gd's own
		# _work_progress_owner doc comment). Optional on the wire like
		# "digFindRng"/"combatBlockedTargets" -- see SaveIO._validate_state() --
		# so an older fixture predating this field still validates.
		"workProgressOwners": _encode_work_progress_owners(world._work_progress_owner),
		# A suspended (still-queued, not
		# terminated) job's own work-toil ticks, moved out of the live
		# "workProgress"/"workProgressOwners" tile cache so a different job
		# that later works the same tile can never inherit or clobber them
		# (world_state.gd's own _suspend_work_progress()/_resume_work_progress()
		# doc comments). Optional on the wire like "workProgressOwners" --
		# an older save predating this field simply restores with no
		# suspended entries, matching decode()'s own constructor default.
		"suspendedWorkProgress": _encode_suspended_work_progress(world._suspended_work_progress),
		"pausedJobs": _encode_paused_jobs(world._paused_jobs),
		"toolItems": _encode_tool_items(world._tool_store.items, world._tool_store.next_id),
		"toolReservations": world._tool_store.reservations.snapshot(),
		"needJobAssignments": _encode_paused_jobs(world._need_giver.get_pending_assignments()),
		# RescueGiver's own job_id ->
		# victim_id association, persisted verbatim (see
		# _encode_rescue_victim_assignments()'s own doc comment) rather than
		# re-derived from target-tile adjacency, which cannot uniquely
		# identify a victim whenever two victims share a target or have
		# overlapping adjacency sets.
		"rescueVictimAssignments": _encode_rescue_victim_assignments(world._rescue_giver.get_job_victims()),
		"combatBlockedTargets": _encode_combat_blocked_targets(world._combat_giver.get_blocked_targets()),
		# ApproachGiver's own job_id -> target association,
		# persisted verbatim (see _encode_approach_job_targets()'s own doc
		# comment) for the same reason rescueVictimAssignments is -- an object
		# target has no living record to re-scan after a load.
		"approachJobTargets": _encode_approach_job_targets(world._approach_giver.get_job_targets()),
		"calendarAlerts": _encode_calendar_alerts(world._calendar_alerts_fired),
		"toolFetchExcluded": _encode_tool_fetch_excluded(world._toils.get_fetch_tool_excluded()),
		"incidentScheduler": _encode_incident_scheduler(world),
		# ADR 026: dig's own find-roll RNG continuation (world._dig_find_random),
		# mirroring "rng" above and "incidentScheduler.rng" -- optional on the wire (see
		# SaveIO._validate_state()) so an older hand-built fixture that never exercises dig's
		# find roll still validates; decode() below leaves the constructor's own fresh
		# seed + WorldState.DIG_FIND_SEED_SALT value in place when this key is absent.
		"digFindRng": {"seed": world._dig_find_random.seed, "state": world._dig_find_random.state},
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
	# _width/_height with the saved dimensions before replacing _tiles, or
	# every tile index below would use the wrong row stride.
	world._width = width
	world._height = height
	# The constructor above already built
	# NeedGiver/IncidentScheduler against its own resolve_size()-clamped
	# width/height (16..512), before the two lines above corrected
	# world._width/_height to the saved map's real, possibly-smaller size.
	# Rebuild both services now, from the corrected dimensions, before
	# anything below (restore_pending_assignments, the reroute rebuild,
	# _reconcile_incident_jobs_after_load) touches them.
	world._build_dimension_services(false)
	world._generator_version = int(map.get("generatorVersion", WorldGeneratorType.GENERATOR_VERSION))
	world._tiles = Array(state["map"]["tiles"], TYPE_STRING, "", null)
	world._colonists = _decode_entities(state["entities"])
	var items_data := _decode_items(state["items"])
	world._items = items_data["items"]
	world._next_item_id = items_data["next_id"]
	world._item_factions = items_data["factions"]
	# State["objects"] holds one record per placed *origin* tile,
	# not per occupied tile -- _decode_objects() below only decodes the raw
	## per-origin records; expanding each back out to every tile of its
	# footprint needs world._object_definitions (footprint/rotatable), already
	# populated by the WorldState.new() constructor above, so that expansion
	# happens here via world._object_footprint_tiles() rather than inside a
	# static helper with no world to call through (mirrors
	# world._build_dimension_services() above, already called directly on
	# `world` from this same static decode()).
	var objects: Dictionary = {}
	var object_factions: Dictionary = {}
	var object_health: Dictionary = {}
	var object_origin: Dictionary = {}
	var object_orientation: Dictionary = {}
	for record in _decode_objects(state["objects"]):
		var origin: Vector2i = record["origin"]
		var origin_key := "%d_%d" % [origin.x, origin.y]
		var kind: String = record["kind"]
		var orientation: String = record["orientation"]
		for tile in world._object_footprint_tiles(kind, origin, orientation):
			var key := "%d_%d" % [tile.x, tile.y]
			objects[key] = kind
			object_factions[key] = record["factionId"]
			if key != origin_key:
				object_origin[key] = origin
		if record.has("health"):
			object_health[origin_key] = (record["health"] as Dictionary).duplicate()
		if not orientation.is_empty():
			object_orientation[origin_key] = orientation
	world._objects = objects
	world._object_factions = object_factions
	world._object_health = object_health
	world._object_origin = object_origin
	world._object_orientation = object_orientation
	# Absent for any save written before construction sites existed -- restore()
	# with an empty array/next_id 1 matches a fresh ConstructionSiteTable's
	# own starting state exactly.
	var construction_sites := _decode_construction_sites(state.get("constructionSites", []))
	world._sites.restore(construction_sites, _next_construction_site_id(construction_sites))
	world._zones = _decode_zones(state["zones"])
	world._next_zone_id = int(state["nextZoneId"])
	world._ground_berries = _decode_ground_berries(state["groundBerries"])
	world._work_progress = _decode_work_progress(state["workProgress"])
	var work_progress_owners := _decode_work_progress_owners(state.get("workProgressOwners", []))
	world._suspended_work_progress = _decode_suspended_work_progress(state.get("suspendedWorkProgress", []))
	world._paused_jobs = _decode_paused_jobs(state["pausedJobs"])
	var tool_items_data := _decode_tool_items(state["toolItems"])
	world._tool_store.items = tool_items_data["items"]
	world._tool_store.next_id = tool_items_data["next_id"]
	world._tool_store.reservations.restore(state["toolReservations"] as Dictionary)
	world._clock.tick = int(state["tick"])
	world._random.seed = int(state["rng"]["seed"])
	world._random.state = int(state["rng"]["state"])
	world._events = []
	world._need_giver.restore_pending_assignments(_decode_paused_jobs(state["needJobAssignments"]))
	world._calendar_alerts_fired = _decode_calendar_alerts(state["calendarAlerts"])
	world._toils.restore_fetch_tool_excluded(_decode_tool_fetch_excluded(state["toolFetchExcluded"]))

	var scheduling: Dictionary = state["scheduling"]
	world._event_sequence = int(scheduling["eventSequence"])
	world._queue_event_sequence = int(scheduling["queueEventSequence"])

	var jobs := _decode_jobs(state["jobs"])
	var rescue_jobs := _surviving_rescue_jobs(jobs)
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
	var rescue_victims := _decode_rescue_victim_assignments(state.get("rescueVictimAssignments", []))
	for job_id in rescue_victims.keys().duplicate():
		if not surviving_rescue_job_ids.has(job_id):
			rescue_victims.erase(job_id)
	world._rescue_giver.restore_victim_assignments(rescue_victims)
	# Filtered to jobs that actually survived decode, the
	# same way rescue_victims is above -- a corrupted/hand-built fixture must
	# never seed an association for a job that no longer exists.
	var surviving_approach_job_ids: Dictionary = {}
	for job in _surviving_approach_jobs(jobs):
		surviving_approach_job_ids[String(job["id"])] = true
	var approach_targets := _decode_approach_job_targets(state.get("approachJobTargets", []))
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
	# world._work_progress_owner is restored from the persisted job_id above
	# (guessing it from job-target iteration order could hand one job's
	# progress to another queued at the same tile), right after jobs
	# restore and before _reconcile_incident_jobs_after_load() below may
	# cancel one through the shared _finish_job() boundary, so that
	# cancellation's own ownership-gated work-progress cleanup fires correctly immediately after a load.
	world._restore_work_progress_owners(work_progress_owners)

	var bounds_max := Vector2i(width - 1, height - 1)
	world._scheduler.restore_scheduling(_decode_scheduling(scheduling),
		world._is_passable, Vector2i.ZERO, bounds_max)
	# rescuer_id -> job_id needs no save data of its own either: every
	# surviving rescue job's own restrict_to, now available from the just-
	# restored scheduler, already names its rescuer (the same field a
	# player-ordered dig/chop job's own assignee restriction already
	# persists, see WorldState._resubmit_unreachable_job()'s own comment).
	world._rescue_giver.restore_pending_assignments(_rescue_pending_from_scheduler(rescue_jobs, world._scheduler))
	_restore_reroutes(world, bounds_max)
	# Re-associate each restored incident job with its actor,
	# or retire it (see WorldState).
	world._reconcile_incident_jobs_after_load()
	# Restored after the queue/scheduling restore above, so
	# CombatGiver can re-adopt every restored non-terminal flee job for its
	# owned episode right here, before the first tick's own decisions.
	world._combat_giver.restore_blocked_targets(_decode_combat_blocked_targets(state.get("combatBlockedTargets", [])))
	# Restored after the queue/scheduling restore above, so
	# ApproachGiver can re-adopt every restored non-terminal `approach` job for
	# its actor right here, before the first tick's own decisions (mirrors
	# CombatGiver.restore_blocked_targets() immediately above).
	world._approach_giver.restore_job_targets(approach_targets)
	# ApproachGiver no longer retires an actor permanently (see
	# approach_giver.gd's own class doc comment) -- an old save's own
	# "approachRetiredActors" field, if present, is simply ignored; save_io.gd
	# still accepts it for backward compatibility (world_state.gd's own
	# construction/decode no longer treat it as authoritative).
	# ADR 004 ("WorldState's diagnostic hash includes this continuation
	# state"): IncidentScheduler's own cooldowns/last-drawn-day/RNG are read
	# and written here directly, since incident_scheduler.gd exposes no
	# accessor for them.
	var incident_scheduler: Dictionary = state["incidentScheduler"]
	world._incidents._cooldown_until_day = _decode_int_dict(incident_scheduler["cooldownUntilDay"])
	world._incidents._last_processed_day = int(incident_scheduler["lastProcessedDay"])
	world._incidents._random.seed = int(incident_scheduler["rng"]["seed"])
	world._incidents._random.state = int(incident_scheduler["rng"]["state"])
	# ADR 026: restores dig's find-roll RNG continuation when the
	# save carries it (see encode()'s own comment on "digFindRng" above); absent
	# only for a hand-built fixture predating this field, which keeps the
	# constructor's own fresh WorldState.new() seed instead.
	if state.has("digFindRng"):
		var dig_find_rng: Dictionary = state["digFindRng"]
		world._dig_find_random.seed = int(dig_find_rng["seed"])
		world._dig_find_random.state = int(dig_find_rng["state"])

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
## The two `world._is_passable` branches (haul leg-two, dropping) stay
## colony-only by construction -- see their own comments above -- and are
## untouched.
static func _restore_reroutes(world: WorldState, bounds_max: Vector2i) -> void:
	for colonist in world._colonists:
		var route = colonist.get("route")
		if route == null:
			continue
		var snapshot = route.get("rerouting")
		if snapshot == null:
			continue
		var job_id: String = route["job_id"]
		var job := world._scheduler.queue.get_job(job_id)
		var faction_id := String(colonist.get("factionId", "colony"))
		var cost_fn: Callable
		if String(job.get("kind", "")) == "haul" and InventoryType.is_carrying(colonist):
			cost_fn = world._is_passable
		elif String(job.get("kind", "")) == "build" and InventoryType.is_carrying(colonist):
			# A carrying build's live second leg searches toward job.site with
			# the site-tile exception (WorldState._toil_go_to_passable()), never
			# toward job.target, the wood's own tile.
			cost_fn = world._routable_to(job["site"], faction_id)
		elif world._toils.is_dropping_leg(colonist, job_id, job, world._toil_hooks):
			cost_fn = world._is_passable
		elif world._toils.needs_fetch_tool(colonist, job, job_id):
			cost_fn = world._routable_to(snapshot["target"], faction_id)
		else:
			var target: Vector2i = job["target"]
			cost_fn = world._routable_to(target, faction_id)
		var search: RerouteType = RerouteType.new(snapshot["start"], snapshot["start"],
			cost_fn, Vector2i.ZERO, bounds_max)
		search.restore(snapshot)
		world._reroutes[colonist["id"]] = search

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

## world._items is keyed by item id; sorted keys give a deterministic
## encoding order. next_id is world._next_item_id, carried alongside the list
## so a restored WorldState never reuses an id a save already handed out.
## item_factions is world._item_factions (the persisted counterpart of the
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

## world._zones is keyed by zone id; sorted keys give a deterministic
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

## world._objects is keyed by "%d_%d" % [x, y] (see world_state.gd); the
## sorted keys give a deterministic encoding order. object_factions is
## world._object_factions (the persisted counterpart of the "faction_id"
## runtime field get_objects() adds), a parallel map
## keyed the same way as objects rather than a nested value inside it.
## object_health is world._object_health, the same kind of parallel
## map: present only for a key whose object kind declares "max_health"
## (content/objects.json), so an older save (no key ever had a health
## entry) and a bare/non-damageable object both simply omit the "health" wire
## field -- optional, not required, in game-state.schema.json's "object" $def,
## so no schema-version bump or migration step is needed (mirrors how
## route.rerouting is optional for the same reason, see save_io.gd's
## _valid_entity_route()). A save/load that omits it falls back to
## WorldState._ensure_object_health()'s own backfill, the same recovery an
## object placed by an older fixture already relies on.
## object_origin/object_orientation are world._object_origin/
## _object_orientation -- one record is written per placed *object*, not per
## occupied tile: a key present in object_origin names a non-origin footprint
## tile of a multi-tile object and is skipped entirely (its origin's own
## record, plus decode()'s world._object_footprint_tiles() expansion, already
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
## per placed object, in wire order -- decode() itself expands each back out
## to every tile of its footprint (world._object_footprint_tiles(), needing
## world._object_definitions, which this static function has no access to).
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

## world._ground_berries is keyed by "%d_%d" (see world_state.gd, mirroring
## _objects); the sorted keys give a deterministic encoding order. Field name
## "berries" mirrors the old per-tile groundItems wire shape's "wood" field
## ({target, wood}): ground berries stay a simple per-tile counter, not a
## first-class pickable item like wood.
static func _encode_ground_berries(ground_berries: Dictionary) -> Array:
	var keys := ground_berries.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var coords := String(key).split("_")
		var tile := Vector2i(int(coords[0]), int(coords[1]))
		encoded.append({"target": _encode_tile(tile), "berries": int(ground_berries[key])})
	return encoded

static func _decode_ground_berries(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var tile := _decode_tile(entry["target"])
		decoded["%d_%d" % [tile.x, tile.y]] = int(entry["berries"])
	return decoded

# --- work progress (colonist-ai.md 3.6) -------------------------------------

## world._work_progress is keyed by "%d_%d", or by "<jobId>:%d_%d" when the
## tile's reservation is currently owned by a job (world_state.gd's
## _work_progress_key(), scoped per-job so two jobs sharing one target tile
## never read/clear each other's progress). Job ids never contain ":" (the
## `^[a-z0-9_-]+$` id pattern), so splitting on the last ":" losslessly
## recovers the owner; the sorted keys give a deterministic encoding order.
static func _encode_work_progress(work_progress: Dictionary) -> Array:
	var keys := work_progress.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var key_str := String(key)
		var owner_job_id := ""
		var coord_part := key_str
		var colon_index := key_str.rfind(":")
		if colon_index >= 0:
			owner_job_id = key_str.substr(0, colon_index)
			coord_part = key_str.substr(colon_index + 1)
		var coords := coord_part.split("_")
		var tile := Vector2i(int(coords[0]), int(coords[1]))
		var entry := {"target": _encode_tile(tile), "ticksRemaining": int(work_progress[key])}
		if not owner_job_id.is_empty():
			entry["ownerJobId"] = owner_job_id
		encoded.append(entry)
	return encoded

static func _decode_work_progress(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var tile := _decode_tile(entry["target"])
		var coord_key := "%d_%d" % [tile.x, tile.y]
		var key := coord_key
		if entry.has("ownerJobId"):
			key = "%s:%s" % [String(entry["ownerJobId"]), coord_key]
		decoded[key] = int(entry["ticksRemaining"])
	return decoded

## world._work_progress_owner is keyed like _work_progress ("%d_%d") ->
## job_id; sorted keys give a deterministic
## encoding order matching _encode_work_progress() above. Only keys with a
## non-empty owner appear -- an "incident" job's stamped wait never
## participates in job-id ownership (see WorldState._release_owned_work_progress()'s
## own comment), so it is simply absent here, not encoded with an empty id.
static func _encode_work_progress_owners(work_progress_owner: Dictionary) -> Array:
	var keys := work_progress_owner.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var coords := String(key).split("_")
		var tile := Vector2i(int(coords[0]), int(coords[1]))
		encoded.append({"target": _encode_tile(tile), "jobId": String(work_progress_owner[key])})
	return encoded

## Returns the raw key -> job_id map; WorldState._restore_work_progress_owners()
## cross-checks each job_id against the just-restored job list before trusting
## it (see that function's own doc comment).
static func _decode_work_progress_owners(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var tile := _decode_tile(entry["target"])
		decoded["%d_%d" % [tile.x, tile.y]] = String(entry["jobId"])
	return decoded

## world._suspended_work_progress is keyed by job_id directly: a suspended job's own snapshot, so no tile coordinate
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

## world._paused_jobs is keyed by colonist id; sorted keys give a
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

## RescueGiver.get_job_victims()'s own job_id -> victim_id association,
## encoded as an array of {jobId, victimId} entries: unlike _encode_paused_jobs()'s colonist-keyed shape, this map is keyed
## by job id (a colonist can be the victim of at most one live rescue job, but
## nothing here depends on that -- job id is what's actually unique), so
## sorting by job id gives the same deterministic encoding order every other
## keyed-map encoder here uses.
static func _encode_rescue_victim_assignments(job_victims: Dictionary) -> Array:
	var keys := job_victims.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		encoded.append({"jobId": key, "victimId": String(job_victims[key])})
	return encoded

static func _decode_rescue_victim_assignments(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		decoded[String(entry["jobId"])] = String(entry["victimId"])
	return decoded

## Every decoded job still queued or active (a terminal one is already
## resolved and carries no live RescueGiver association) whose kind is
## "rescue" -- decode()'s own shared input for both
## RescueGiver.restore_victim_assignments() and _rescue_pending_from_scheduler()
## below.
static func _surviving_rescue_jobs(jobs: Array[Dictionary]) -> Array[Dictionary]:
	var rescue_jobs: Array[Dictionary] = []
	for job in jobs:
		if String(job["kind"]) == "rescue" and String(job["status"]) in ["queued", "active"]:
			rescue_jobs.append(job)
	return rescue_jobs

## rescuer_id -> job_id for every surviving rescue job, read straight off the
## scheduler's own restrict_to instead of any persisted RescueGiver field
## (see decode()'s own comment): GlobalAssignment.restrict_to_for() covers a
## job that has activated at least once (active now, or queued again after a
## need/combat suspension); a rescue job saved mid-search and never yet
## activated has no such entry, so this falls back to scanning the
## scheduler's own waiting list for the same job's restrict_to directly.
static func _rescue_pending_from_scheduler(rescue_jobs: Array[Dictionary], scheduler) -> Dictionary:
	var waiting: Array[Dictionary] = scheduler.get_waiting()
	var pending: Dictionary = {}
	for job in rescue_jobs:
		var job_id: String = String(job["id"])
		var rescuer_id: String = String(scheduler.restrict_to_for(job_id))
		if rescuer_id.is_empty():
			for entry in waiting:
				if String(entry.get("id", "")) == job_id:
					rescuer_id = String(entry.get("restrict_to", ""))
					break
		if not rescuer_id.is_empty():
			pending[rescuer_id] = job_id
	return pending

# --- combat giver flee-destination exclusions ----

## world._combat_giver's own per-actor excluded-flee-destination set
## (CombatGiver._blocked_targets, actor_id -> Dictionary[Vector2i, true]):
## unlike `_fleeing`, this cannot be reconstructed from the scheduler's own
## queued/active jobs after a load (a cancelled blocked flee job that
## produced an exclusion is already gone from the queue by the time it is
## excluded), so it must round-trip explicitly. Optional on read
## (SaveIO._validate_state()) -- absent on any save written before this
## round, decoded as no exclusions, exactly like "health" is optional on an
## individual objects entry. Sorted actor keys give a deterministic encoding
## order; each actor's own tiles are emitted in the live Dictionary's
## insertion order (never re-sorted), which is itself deterministic given
## identical prior ticks -- matching every other keyed-map encoder here.
static func _encode_combat_blocked_targets(blocked: Dictionary) -> Array:
	var keys := blocked.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var tiles: Dictionary = blocked[key]
		var tile_list: Array = []
		for tile in tiles.keys():
			tile_list.append(_encode_tile(tile))
		encoded.append({"actorId": key, "tiles": tile_list})
	return encoded

static func _decode_combat_blocked_targets(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var tiles: Dictionary = {}
		for tile in (entry["tiles"] as Array):
			tiles[_decode_tile(tile)] = true
		decoded[String(entry["actorId"])] = tiles
	return decoded

# --- approach giver target association (ADR 033) ---------------

## ApproachGiver.get_job_targets()'s own job_id -> {kind, id/tile} association,
## encoded as an array of {jobId, kind, actorId} or {jobId, kind, tile}
## entries (mirroring _encode_rescue_victim_assignments()'s job-keyed shape):
## an object target has no living record to re-scan after a load (unlike an
## actor target, which still exists to look up but is not re-derived from it
## either, for the same "no per-job field" reason rescue's own victim
## association is never re-derived). Sorted job-id keys give a deterministic
## encoding order.
static func _encode_approach_job_targets(job_targets: Dictionary) -> Array:
	var keys := job_targets.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var target: Dictionary = job_targets[key]
		var entry := {"jobId": key, "kind": String(target["kind"])}
		if String(target["kind"]) == "actor":
			entry["actorId"] = String(target["id"])
		else:
			entry["tile"] = _encode_tile(target["tile"])
		encoded.append(entry)
	return encoded

static func _decode_approach_job_targets(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		if String(entry["kind"]) == "actor":
			decoded[String(entry["jobId"])] = {"kind": "actor", "id": String(entry["actorId"])}
		else:
			decoded[String(entry["jobId"])] = {"kind": "object", "tile": _decode_tile(entry["tile"])}
	return decoded

## Every decoded job still queued or active whose kind is "approach" -- a
## terminal one carries no live ApproachGiver association (mirrors
## _surviving_rescue_jobs()).
static func _surviving_approach_jobs(jobs: Array[Dictionary]) -> Array[Dictionary]:
	var approach_jobs: Array[Dictionary] = []
	for job in jobs:
		if String(job["kind"]) == "approach" and String(job["status"]) in ["queued", "active"]:
			approach_jobs.append(job)
	return approach_jobs

# --- calendar alerts (ADR 008, colonist-ai.md 3.7) --------------------------

## world._calendar_alerts_fired is a set of calendar window ids (Dictionary
## keys -> true) that have already fired their one-shot alert for the current
## occurrence (ADR 008 consequence 6: already_fired is caller-tracked, not
## calendar-owned). Sorted for deterministic encoding order, matching every
## other keyed-map encoder here.
static func _encode_calendar_alerts(fired: Dictionary) -> Dictionary:
	var keys := fired.keys()
	keys.sort()
	return {"fired": keys}

static func _decode_calendar_alerts(field: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for window_id in (field["fired"] as Array):
		decoded[String(window_id)] = true
	return decoded

# --- tool fetch excluded candidates (ADR 013) ----------

## ToolFetchToil's own _excluded map (see tool_fetch_toil.gd's get_excluded()/
## restore_excluded()): job_id -> Array[String] of tool ids already proven
## unreachable within that job's current fetch attempt. Sorted job-id keys
## give a deterministic encoding order, matching every other keyed-map
## encoder here; a job id with an empty list is simply omitted (decode()'s
## own default read is an empty array either way).
static func _encode_tool_fetch_excluded(excluded: Dictionary) -> Array:
	var keys := excluded.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var ids: Array = excluded[key]
		if ids.is_empty():
			continue
		encoded.append({"jobId": key, "toolIds": ids.duplicate()})
	return encoded

static func _decode_tool_fetch_excluded(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var ids: Array = []
		for id in (entry["toolIds"] as Array):
			ids.append(String(id))
		decoded[String(entry["jobId"])] = ids
	return decoded

# --- incident scheduler ------------------------------

## world._incidents' own cooldown-until-day map, last-processed day, and its
## independent seeded RNG stream (ADR 004 "WorldState's diagnostic hash
## includes this continuation state") -- read directly off IncidentScheduler's
## fields since that file exposes no accessor, mirroring how encode() already reads world._random/world._tiles
## directly rather than through a getter.
static func _encode_incident_scheduler(world: WorldState) -> Dictionary:
	return {
		"cooldownUntilDay": _encode_int_dict(world._incidents._cooldown_until_day),
		"lastProcessedDay": world._incidents._last_processed_day,
		"rng": {"seed": world._incidents._random.seed, "state": world._incidents._random.state},
	}

# --- entities/inventory ----------------------------------------------------

## Every component field is emitted only when the live dict
## actually carries it -- exactly the per-kind shape ActorTable.spawn()
## produces (colonist: needs/labourTable/hands/heldTool; wolf: needs/
## combat/wild; trader: inventory/visitor) -- never as a colonist-shaped
## {}/""/null default, so a non-colonist entity's wire shape matches
## game-state.schema.json's per-kind required set. "work"/"route" ride along
## for every kind (a spawned actor's own walk/wait uses the same fields a
## colonist's job does), present once spawn()/start_work() actually add them.
static func _encode_entities(colonists: Array[Dictionary]) -> Array:
	var entities: Array = []
	for colonist in colonists:
		var entity: Dictionary = {
			"id": colonist["id"], "kind": colonist["kind"],
			"x": colonist["x"], "y": colonist["y"],
			"route": _encode_route_field(colonist.get("route")),
			"factionId": String(colonist.get("factionId", "colony")),
			"health": _encode_health(colonist.get("health", {})),
			"trapped": _encode_trapped_field(colonist.get("trapped")),
		}
		if colonist.has("needs"):
			entity["needs"] = _encode_needs(colonist["needs"])
		if colonist.has("needsAccumulator"):
			entity["needsAccumulator"] = _encode_needs(colonist["needsAccumulator"])
		if colonist.has("labourTable"):
			entity["labourTable"] = _encode_labour_table(colonist["labourTable"])
		if colonist.has("work"):
			entity["work"] = _encode_work_field(colonist["work"])
		if colonist.has("hands"):
			entity["hands"] = _encode_hands_field(colonist["hands"])
		if colonist.has("held_tool"):
			entity["heldTool"] = String(colonist["held_tool"])
		if colonist.has("combat"):
			entity["combat"] = _encode_combat(colonist["combat"])
		if colonist.has("inventory"):
			entity["inventory"] = _encode_inventory(colonist["inventory"])
		if colonist.has("wild"):
			entity["wild"] = true
		if colonist.has("visitor"):
			entity["visitor"] = true
		entities.append(entity)
	return entities

## Mirrors _encode_entities()'s presence-based rule: a wire entity missing
## "needs"/"labourTable"/"hands"/"heldTool" (any non-colonist kind) decodes
## with that key absent entirely, matching the exact shape
## ActorTable.spawn()'s own generic-actor branch produces, rather than
## backfilling a colonist-shaped default that code elsewhere (_ensure_needs(),
## colonist-ai.md's own accessors) would then treat as "this actor has a
## worker/needs component after all". "factionId"/"health" are
## required on the wire (every save reaching this decoder has already
## migrated through SaveMigrations, which backfills both), but still read
## with a defensive default here, matching every other required-field decoder
## in this file.
static func _decode_entities(entities: Array) -> Array[Dictionary]:
	var colonists: Array[Dictionary] = []
	for entity in entities:
		var colonist: Dictionary = {
			"id": entity["id"], "kind": entity["kind"],
			"x": int(entity["x"]), "y": int(entity["y"]),
			"route": _decode_route_field(entity.get("route")),
			"factionId": String(entity.get("factionId", "colony")),
			"health": _decode_health(entity.get("health", {})),
			"trapped": _decode_trapped_field(entity.get("trapped")),
		}
		if entity.has("needs"):
			colonist["needs"] = _decode_needs(entity["needs"])
		if entity.has("needsAccumulator"):
			colonist["needsAccumulator"] = _decode_needs(entity["needsAccumulator"])
		if entity.has("labourTable"):
			colonist["labourTable"] = _decode_labour_table(entity["labourTable"])
		if entity.has("work"):
			colonist["work"] = _decode_work_field(entity["work"])
		if entity.has("hands"):
			colonist["hands"] = _decode_hands_field(entity["hands"])
		if entity.has("heldTool"):
			colonist["held_tool"] = String(entity["heldTool"])
		if entity.has("combat"):
			colonist["combat"] = _decode_combat(entity["combat"])
		if entity.has("inventory"):
			colonist["inventory"] = _encode_inventory(entity["inventory"])
		if entity.has("wild"):
			colonist["wild"] = true
		if entity.has("visitor"):
			colonist["visitor"] = true
		colonists.append(colonist)
	return colonists

## The combat component (ActorCombat.build()): attack/damage/cooldown
## tunables plus the per-instance cooldown_remaining (camelCase on the wire).
static func _encode_combat(combat: Dictionary) -> Dictionary:
	return {
		"attack": int(combat.get("attack", 0)),
		"damage": int(combat.get("damage", 0)),
		"cooldown": int(combat.get("cooldown", 1)),
		"cooldownRemaining": int(combat.get("cooldown_remaining", 0)),
	}

static func _decode_combat(combat: Dictionary) -> Dictionary:
	return {
		"attack": int(combat.get("attack", 0)),
		"damage": int(combat.get("damage", 0)),
		"cooldown": int(combat.get("cooldown", 1)),
		"cooldown_remaining": int(combat.get("cooldownRemaining", 0)),
	}

## The inventory component (ActorInventory.build()): {items, tool,
## capacity}; items is copied as-is (empty today: no toil fills it yet).
static func _encode_inventory(inventory: Dictionary) -> Dictionary:
	return {
		"items": (inventory.get("items", []) as Array).duplicate(true),
		"tool": String(inventory.get("tool", "")),
		"capacity": int(inventory.get("capacity", 1)),
	}

## world._colonists' "health" is the health component (ActorHealth.build*(),
## docs/decisions/012-actors-and-components.md): hp/maxHp/dead, already
## camelCase-compatible with the wire shape, so no key renaming is needed
## (unlike needs/labourTable, which only need sorted-key determinism).
static func _encode_health(health: Dictionary) -> Dictionary:
	return {
		"hp": int(health.get("hp", 0)),
		"maxHp": int(health.get("maxHp", 1)),
		"dead": bool(health.get("dead", false)),
	}

static func _decode_health(health: Dictionary) -> Dictionary:
	return {
		"hp": int(health.get("hp", 0)),
		"maxHp": int(health.get("maxHp", 1)),
		"dead": bool(health.get("dead", false)),
	}

## world._colonists' "needs" is a plain kind->value Dictionary (colonist-ai.md
## 3.1); sorted keys give a deterministic encoding order, matching every
## other keyed-map encoder in this file.
static func _encode_needs(needs: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	var keys := needs.keys()
	keys.sort()
	for key in keys:
		encoded[key] = int(needs[key])
	return encoded

static func _decode_needs(needs: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in needs.keys():
		decoded[key] = int(needs[key])
	return decoded

## world._colonists' "labourTable" is a plain kind->level Dictionary
## (colonist-ai.md 3.2); sorted keys give a deterministic encoding order,
## mirroring _encode_needs()/_decode_needs().
static func _encode_labour_table(labour_table: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	var keys := labour_table.keys()
	keys.sort()
	for key in keys:
		encoded[key] = int(labour_table[key])
	return encoded

static func _decode_labour_table(labour_table: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in labour_table.keys():
		decoded[key] = int(labour_table[key])
	return decoded

## "rerouting" is emitted only while a re-route search is actually in
## flight (route.get("rerouting") != null): keeping the wire shape at its
## original 4 keys for the common non-rerouting case is what lets an
## existing schemaVersion-4 consumer's own field allow-list keep accepting
## every save except the one genuinely new case this schema version adds.
static func _encode_route_field(route):
	if route == null:
		return null
	var encoded := {
		"jobId": route["job_id"],
		"path": _encode_tile_array(route["path"]),
		"step": route["step"],
		"moveTicksRemaining": route["move_ticks_remaining"],
	}
	var rerouting = route.get("rerouting")
	if rerouting != null:
		encoded["rerouting"] = _encode_route(rerouting)
	return encoded

static func _decode_route_field(route):
	if route == null:
		return null
	return {
		"job_id": route["jobId"],
		"path": _decode_tile_array(route["path"]),
		"step": int(route["step"]),
		"move_ticks_remaining": int(route["moveTicksRemaining"]),
		"rerouting": _decode_route(route.get("rerouting")),
	}

static func _encode_work_field(work):
	if work == null:
		return null
	return {"jobId": work["job_id"], "ticksRemaining": work["ticks_remaining"]}

static func _decode_work_field(work):
	if work == null:
		return null
	return {"job_id": work["jobId"], "ticks_remaining": int(work["ticksRemaining"])}

## A colonist's "hands" list -- {"kind","count"} per distinct kind
## held, no item id (a pick_up may merge several ground items' units into one
## entry, and place() always mints a fresh id on the way back out) and no x/y
## (a carried item has no ground position, see ToilExecutor.pick_up()/place()).
static func _encode_hands_field(hands: Array) -> Array:
	var encoded: Array = []
	for entry in hands:
		encoded.append({"kind": entry["kind"], "count": entry["count"]})
	return encoded

static func _decode_hands_field(hands: Array) -> Array:
	var decoded: Array = []
	for entry in hands:
		decoded.append({"kind": entry["kind"], "count": int(entry["count"])})
	return decoded

## "trapped": unlike carrying/work (present only for the kinds
## whose own ActorTable.spawn() shape adds them), any actor kind may fall into
## a trench, so this is encoded/decoded unconditionally for every entity,
## mirroring health/route rather than carrying's per-kind presence.
## fromTile is present only alongside
## ticksRemaining -- a trapped hostile's own escape_trench climb-out target --
## since a trapped colonist has no auto-exit to prefer a fallen-from tile for.
static func _encode_trapped_field(trapped):
	if trapped == null:
		return null
	var encoded := {"tile": _encode_tile(trapped["tile"])}
	if trapped.has("ticksRemaining"):
		encoded["ticksRemaining"] = int(trapped["ticksRemaining"])
	if trapped.has("fromTile"):
		encoded["fromTile"] = _encode_tile(trapped["fromTile"])
	return encoded

static func _decode_trapped_field(trapped):
	if trapped == null:
		return null
	var decoded := {"tile": _decode_tile(trapped["tile"])}
	if trapped.has("ticksRemaining"):
		decoded["ticksRemaining"] = int(trapped["ticksRemaining"])
	if trapped.has("fromTile"):
		decoded["fromTile"] = _decode_tile(trapped["fromTile"])
	return decoded

# --- jobs --------------------------------------------------------------

## site (replaces the older site/buildKind pair): a site_fetch/site_work job's own construction-site origin tile --
## job_queue.gd's own native field (attach_site()), mirroring itemId/cell's
## own optional shape exactly, so an in-flight wall order and an in-flight
## door order at the same tick decode to different job dicts and hash
## differently (WorldState.state_hash()'s "jobs" entry reads get_jobs()
## directly, no separate wiring needed here beyond round-tripping the field).
## No buildKind field any more: the object kind to place lives on the
## construction site record itself (state["constructionSites"]), not
## duplicated onto every job that happens to be working that site.
static func _encode_jobs(jobs: Array[Dictionary]) -> Array:
	var encoded: Array = []
	for job in jobs:
		var cell = job.get("cell")
		var site = job.get("site")
		encoded.append({
			"id": job["id"], "kind": job["kind"], "status": job["status"],
			"priority": job["priority"], "target": _encode_tile(job["target"]),
			"reason": job["reason"], "remedy": job["remedy"],
			"blockingJobId": job["blocking_job_id"],
			"itemId": job.get("item_id", ""),
			"cell": _encode_tile(cell) if cell != null else null,
			"retryAt": job.get("retry_at", 0),
			"backoffTicks": job.get("backoff_ticks", 0),
			"site": _encode_tile(site) if site != null else null,
		})
	return encoded

static func _decode_jobs(jobs: Array) -> Array[Dictionary]:
	var decoded: Array[Dictionary] = []
	for job in jobs:
		var cell = job.get("cell")
		var site = job.get("site")
		decoded.append({
			"id": job["id"], "kind": job["kind"], "status": job["status"],
			"priority": int(job["priority"]), "target": _decode_tile(job["target"]),
			"reason": job["reason"], "remedy": job["remedy"],
			"blocking_job_id": job["blockingJobId"],
			"item_id": String(job.get("itemId", "")),
			"cell": _decode_tile(cell) if cell != null else null,
			"retry_at": int(job.get("retryAt", 0)),
			"backoff_ticks": int(job.get("backoffTicks", 0)),
			"site": _decode_tile(site) if site != null else null,
		})
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

# --- scheduling (waiting/cursors/pending/assignments + counters) -------

static func _encode_scheduling(world: WorldState) -> Dictionary:
	var scheduler = world._scheduler
	return {
		"nextJobId": scheduler.queue.get_next_id(),
		"jobSequence": scheduler.queue.get_sequence(),
		"jobTick": scheduler.queue.get_tick(),
		"queueEventSequence": world._queue_event_sequence,
		"eventSequence": world._event_sequence,
		"waiting": _encode_entries(scheduler.get_waiting()),
		"nextOrdinal": scheduler.get_next_ordinal(),
		"cursors": scheduler.get_cursors(),
		"pending": _encode_pending(scheduler.get_pending()),
		"assignments": _encode_assignments(scheduler.get_assignments()),
		"activatedEntries": _encode_activated_entries(scheduler.get_activated_entries()),
	}

static func _decode_scheduling(scheduling: Dictionary) -> Dictionary:
	return {
		"waiting": _decode_entries(scheduling["waiting"]),
		"next_ordinal": int(scheduling["nextOrdinal"]),
		"cursors": _decode_int_dict(scheduling["cursors"]),
		"pending": _decode_pending(scheduling["pending"]),
		"assignments": _decode_assignments(scheduling["assignments"]),
		"activated_entries": _decode_activated_entries(scheduling["activatedEntries"]),
	}

## scheduler._activated_entries is keyed by job id (see
## GlobalAssignment.get_activated_entries()); sorted keys give a
## deterministic encoding order, matching every other keyed-map encoder here.
static func _encode_activated_entries(entries: Dictionary) -> Dictionary:
	var keys := entries.keys()
	keys.sort()
	var encoded: Dictionary = {}
	for key in keys:
		encoded[key] = _encode_entry(entries[key])
	return encoded

static func _decode_activated_entries(entries: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in entries.keys():
		decoded[key] = _decode_entry(entries[key])
	return decoded

static func _encode_entries(entries: Array[Dictionary]) -> Array:
	var encoded: Array = []
	for entry in entries:
		encoded.append(_encode_entry(entry))
	return encoded

static func _encode_entry(entry: Dictionary) -> Dictionary:
	var encoded := {
		"id": entry["id"], "target": _encode_tile(entry["target"]),
		"base": entry["base"], "submittedTick": entry["submitted_tick"],
		"ordinal": entry["ordinal"], "restrictTo": String(entry.get("restrict_to", "")),
	}
	# ADR 014 Amendment: present on the wire only when true, so
	# every ordinary entry keeps its original shape.
	if bool(entry.get("autonomous", false)):
		encoded["autonomous"] = true
	return encoded

static func _decode_entries(entries: Array) -> Array[Dictionary]:
	var decoded: Array[Dictionary] = []
	for entry in entries:
		decoded.append(_decode_entry(entry))
	return decoded

static func _decode_entry(entry: Dictionary) -> Dictionary:
	var decoded := {
		"id": entry["id"], "target": _decode_tile(entry["target"]),
		"base": int(entry["base"]), "submitted_tick": int(entry["submittedTick"]),
		"ordinal": int(entry["ordinal"]), "restrict_to": String(entry.get("restrictTo", "")),
	}
	if bool(entry.get("autonomous", false)):
		decoded["autonomous"] = true
	return decoded

static func _encode_int_dict(source: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	for key in source:
		encoded[key] = source[key]
	return encoded

static func _decode_int_dict(source: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in source:
		decoded[key] = int(source[key])
	return decoded

static func _encode_pending(pending: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	for worker in pending:
		var request: Dictionary = pending[worker]
		encoded[worker] = {
			"candidates": _encode_entries(request["candidates"]),
			"cursor": request["cursor"],
			"found": _encode_found(request["found"]),
			"start": _encode_tile(request["start"]),
			"route": _encode_route(request["route"]),
		}
	return encoded

static func _decode_pending(pending: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for worker in pending:
		var request: Dictionary = pending[worker]
		decoded[worker] = {
			"candidates": _decode_entries(request["candidates"]),
			"cursor": int(request["cursor"]),
			"found": _decode_found(request["found"]),
			"start": _decode_tile(request["start"]),
			"route": _decode_route(request["route"]),
		}
	return decoded

static func _encode_found(found: Array) -> Array:
	var encoded: Array = []
	for pair in found:
		encoded.append({
			"worker": pair["worker"], "entry": _encode_entry(pair["entry"]),
			"travel": pair["travel"],
		})
	return encoded

static func _decode_found(found: Array) -> Array:
	var decoded: Array = []
	for pair in found:
		decoded.append({
			"worker": pair["worker"], "entry": _decode_entry(pair["entry"]),
			"travel": int(pair["travel"]),
		})
	return decoded

static func _encode_route(route_state):
	if route_state == null:
		return null
	var visited: Array = []
	for tile in (route_state["visited"] as Dictionary).keys():
		visited.append(_encode_tile(tile))
	var came_from: Array = []
	var came_from_map: Dictionary = route_state["came_from"]
	for child in came_from_map.keys():
		came_from.append({"child": _encode_tile(child), "parent": _encode_tile(came_from_map[child])})
	return {
		"start": _encode_tile(route_state["start"]),
		"target": _encode_tile(route_state["target"]),
		"status": route_state["status"],
		"frontier": _encode_tile_array(route_state["frontier"]),
		"visited": visited,
		"cameFrom": came_from,
		"path": _encode_tile_array(route_state["path"]),
		"expansions": route_state["expansions"],
		"resumeCalls": route_state["resume_calls"],
	}

static func _decode_route(route):
	if route == null:
		return null
	var visited: Dictionary = {}
	for tile in route["visited"]:
		visited[_decode_tile(tile)] = true
	var came_from: Dictionary = {}
	for pair in route["cameFrom"]:
		came_from[_decode_tile(pair["child"])] = _decode_tile(pair["parent"])
	return {
		"start": _decode_tile(route["start"]),
		"target": _decode_tile(route["target"]),
		"status": route["status"],
		"frontier": _decode_tile_array(route["frontier"]),
		"visited": visited,
		"came_from": came_from,
		"path": _decode_tile_array(route["path"]),
		"expansions": int(route["expansions"]),
		"resume_calls": int(route["resumeCalls"]),
	}

static func _encode_assignments(assignments: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	for worker in assignments:
		var assignment: Dictionary = assignments[worker]
		encoded[worker] = {
			"jobId": assignment["job_id"], "startedTick": assignment["started_tick"],
			"travelTicks": assignment["travel_ticks"],
			"path": _encode_tile_array(assignment.get("path", [])),
		}
	return encoded

static func _decode_assignments(assignments: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for worker in assignments:
		var assignment: Dictionary = assignments[worker]
		decoded[worker] = {
			"job_id": assignment["jobId"], "started_tick": int(assignment["startedTick"]),
			"travel_ticks": int(assignment["travelTicks"]),
			"path": _decode_tile_array(assignment.get("path", [])),
		}
	return decoded
