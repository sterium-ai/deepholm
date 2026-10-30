class_name ConstructionSystem
extends RefCounted

## Construction sites and their flow (ADR 040, 042): build/build_line checks and submission,
## site fetch sources, site work, finalize, cancel and the enclosure check.
## Invariants:
## - A site exists from acceptance; its footprint is reserved under site_table.owner_key(id)
##   (never a job id) until finalize or cancel.
## - build and build_line share _construction_footprint_check(); build_line runs the
##   enclosure check once, before creating any site.
## - A fetch job's submission-time source is a seed, swapped for the nearest one on activation.
## - A site record's "progress" (ConstructionSiteTable) is the one work counter; site_work
##   never writes WorkProgress.
## - site_fetch_source_retargeted/site_fetch_picked_kind are runtime caches, never saved or hashed.
## - "constructionSites" is persisted and hashed; the next site id is re-derived on load.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ConstructionSiteTableType = preload("res://scripts/core/objects/construction_site.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const ZoneTableType = preload("res://scripts/core/objects/zone_table.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")

const TILE_TREE := ContentRegistryType.TILE_TREE
const TILE_TRENCH := ContentRegistryType.TILE_TRENCH

## One record per active construction site.
var site_table := ConstructionSiteTableType.new()
## job_id -> true once a site_fetch source was retargeted: its precomputed assignment_path
## is stale, so every later go_to leg runs a fresh search.
var site_fetch_source_retargeted: Dictionary = {}
## job_id -> item kind read before the latest pick_up (an exhausted source is deleted).
var site_fetch_picked_kind: Dictionary = {}

## object kind -> content/objects.json definition, shared by reference with WorldState.
var _object_definitions: Dictionary
var _tile_grid: TileGridType
var _passability: PassabilityType
var _object_table: ObjectTableType
var _zone_table: ZoneTableType
var _item_table: ItemTableType
var _scheduler: AssignmentType
var _event_log: EventLogType
## () -> Array[Dictionary]: the live colonist list (StateCodec.decode() reassigns it).
var _get_colonists: Callable
## (tile: Vector3i) -> bool: a colonist stands on the tile.
var _colonist_at: Callable
## (job_id: String) -> Dictionary: the colonist assigned to the job, or {}.
var _find_job_colonist: Callable
## (job_id: String, status: String) -> Dictionary: WorldState's terminal-transition boundary.
var _finish_job: Callable
## (job_id: String) -> void: completes a builder job a finished site ends, awarding its XP
## (F3, ADR 062: ToilBindings sets it); unset, the job is finished as complete_job.
var complete_builder: Callable
## (job_id: String) -> void: drops a site_fetch job's carried item on the colonist's tile.
var _drop_carried_haul_item: Callable
## (from: Vector3i, to: Vector3i, faction_id: String) -> int: route cost, -1 when unreachable.
var _route_cost: Callable

func _init(object_definitions: Dictionary, tile_grid: TileGridType, passability: PassabilityType,
		object_table: ObjectTableType, zone_table: ZoneTableType, item_table: ItemTableType,
		scheduler: AssignmentType, event_log: EventLogType, get_colonists: Callable, colonist_at: Callable,
		find_job_colonist: Callable, finish_job: Callable, drop_carried_haul_item: Callable,
		route_cost: Callable) -> void:
	_object_definitions = object_definitions
	_tile_grid = tile_grid
	_passability = passability
	_object_table = object_table
	_zone_table = zone_table
	_item_table = item_table
	_scheduler = scheduler
	_event_log = event_log
	_get_colonists = get_colonists
	_colonist_at = colonist_at
	_find_job_colonist = find_job_colonist
	_finish_job = finish_job
	_drop_carried_haul_item = drop_carried_haul_item
	_route_cost = route_cost

## The save field this system owns, in StateCodec's wire shape (optional on load).
func encode() -> Dictionary:
	return {"constructionSites": StateCodec._encode_construction_sites(site_table.list())}

func decode(state: Dictionary) -> void:
	var construction_sites := StateCodec._decode_construction_sites(state.get("constructionSites", []))
	site_table.restore(construction_sites, StateCodec._next_construction_site_id(construction_sites))

## Materials, progress and builders are hashed; list() is sorted by site id.
func hash_into(snapshot: Dictionary) -> void:
	snapshot["construction_sites"] = site_table.list()

## A site_work job's remaining duration, always re-derived from its site.
func site_work_ticks_remaining(job: Dictionary, target: Vector3i) -> int:
	var site_id := site_table.find_at_origin(job.get("site", target))
	if site_id.is_empty():
		return 0
	var site := site_table.get_site(site_id)
	return maxi(0, int(site["build_ticks"]) - int(site["progress"]))

## One tick of a builder's work on the site at origin; finalizes the site once
## the summed progress meets build_ticks. completing_job_id "" (a non-final
## tick crossing build_ticks) finishes every builder, this one included.
func add_site_work(origin: Vector3i, completing_job_id: String) -> void:
	var site_id := site_table.find_at_origin(origin)
	if not site_id.is_empty():
		var progress := site_table.add_progress(site_id, 1)
		if progress >= int(site_table.get_site(site_id)["build_ticks"]):
			_finalize_construction_site(site_id, completing_job_id)

## build {kind, x, y, orientation}: creates the site and reserves its footprint; no stock
## check and no job (ConstructionGiver submits them later).
func apply_construction_submission(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var check := check_construction_command(payload)
	if not check.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
	var kind: String = payload["kind"]
	var orientation := String(payload.get("orientation", ""))
	var origin := TileGrid.tile_of(payload)
	var definition: Dictionary = _object_definitions[kind]
	var site := site_table.create(kind, origin, orientation, definition["build_cost"] as Array,
		int(definition["build_ticks"]), int(definition["max_builders"]))
	var owner := site_table.owner_key(String(site["id"]))
	var table := _scheduler.queue.get_reservation_table()
	for tile in _object_table.object_footprint_tiles(kind, origin, orientation):
		table.acquire(_build_site_key(tile), owner)
	var applied := _event_log.applied(command)
	applied["site_id"] = site["id"]
	# The viewer's Cancel tool names a pending order by job_id, so it mirrors site_id (ADR 040).
	applied["job_id"] = site["id"]
	return applied

## build's read-only rule, shared by apply() and preview(); impassable kinds also run
## the enclosure check (blocked_target_unreachable).
func check_construction_command(payload: Dictionary) -> Dictionary:
	for key in payload.keys():
		if not (key == "kind" or key == "x" or key == "y" or key == "z" or key == "orientation"):
			return {"reason": "invalid_payload", "params": {"detail": "build_extra_field", "field": str(key)}}
	if (typeof(payload.get("kind")) != TYPE_STRING or String(payload.get("kind")).is_empty()
			or typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("orientation", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "params": {"detail": "build_payload"}}
	var kind: String = payload["kind"]
	if not _object_definitions.has(kind) or (_object_definitions[kind].get("build_cost", []) as Array).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "unknown_buildable_kind", "kind": kind}}
	var orientation := String(payload.get("orientation", ""))
	if not orientation.is_empty() and orientation != "horizontal" and orientation != "vertical":
		return {"reason": "invalid_payload", "params": {"detail": "invalid_orientation"}}
	var origin := TileGrid.tile_of(payload)
	var footprint_tiles := _object_table.object_footprint_tiles(kind, origin, orientation)
	var occupancy_check := _construction_footprint_check(footprint_tiles)
	if not occupancy_check.is_empty():
		return occupancy_check
	if not bool(_object_definitions[kind].get("passable", true)) and _would_enclose_tiles(footprint_tiles):
		return {"reason": "blocked_target_unreachable", "params": {"detail": "build_seals_colony"}}
	return {}

## Per-tile rule shared by build and build_line so both agree on validity and reason;
## the enclosure check is left to each caller.
func _construction_footprint_check(footprint_tiles: Array[Vector3i]) -> Dictionary:
	var table := _scheduler.queue.get_reservation_table()
	for tile in footprint_tiles:
		if (_colonist_at.call(tile) or not _object_table.get_object(tile).is_empty()
				or not _build_site_terrain_valid(tile)):
			return {"reason": "invalid_target", "params": {"detail": "build_tile_blocked"}}
		if not table.owner(_build_site_key(tile)).is_empty():
			return {"reason": "invalid_target", "params": {"detail": "build_tile_claimed"}}
	return {}

## build_line's read-only classification (ADR 042), shared by apply() and preview():
## tiles canonicalized row-major and de-duplicated, overlapping footprints skipped,
## one enclosure check over all survivors.
func classify_build_line_command(payload: Dictionary) -> Dictionary:
	if typeof(payload.get("kind")) != TYPE_STRING or String(payload.get("kind")).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "build_line_kind"}}
	var kind: String = payload["kind"]
	if not _object_definitions.has(kind) or (_object_definitions[kind].get("build_cost", []) as Array).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "unknown_buildable_kind", "kind": kind}}
	if typeof(payload.get("orientation", "")) != TYPE_STRING:
		return {"reason": "invalid_payload", "params": {"detail": "invalid_orientation"}}
	var orientation := String(payload.get("orientation", ""))
	if not orientation.is_empty() and orientation != "horizontal" and orientation != "vertical":
		return {"reason": "invalid_payload", "params": {"detail": "invalid_orientation"}}
	if typeof(payload.get("tiles")) != TYPE_ARRAY or (payload["tiles"] as Array).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "build_line_tiles"}}
	var seen := {}
	var canonical: Array[Vector3i] = []
	for entry in (payload["tiles"] as Array):
		if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("x")) != TYPE_INT or typeof(entry.get("y")) != TYPE_INT:
			return {"reason": "invalid_payload", "params": {"detail": "build_line_tile_payload"}}
		var tile := TileGrid.tile_of(entry)
		if not seen.has(tile):
			seen[tile] = true
			canonical.append(tile)
	canonical.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	var surviving: Array[Vector3i] = []
	var skipped: Array[Dictionary] = []
	var claimed_footprint := {}
	for tile in canonical:
		var footprint := _object_table.object_footprint_tiles(kind, tile, orientation)
		var occupancy_check := _construction_footprint_check(footprint)
		if not occupancy_check.is_empty():
			skipped.append({"x": tile.x, "y": tile.y, "z": tile.z, "reason": occupancy_check["reason"]})
			continue
		var overlaps_earlier_survivor := false
		for footprint_tile in footprint:
			if claimed_footprint.has(footprint_tile):
				overlaps_earlier_survivor = true
				break
		if overlaps_earlier_survivor:
			skipped.append({"x": tile.x, "y": tile.y, "z": tile.z, "reason": "invalid_target"})
			continue
		for footprint_tile in footprint:
			claimed_footprint[footprint_tile] = true
		surviving.append(tile)
	if not surviving.is_empty() and not bool(_object_definitions[kind].get("passable", true)):
		var combined_footprint: Array[Vector3i] = []
		for tile in surviving:
			combined_footprint.append_array(_object_table.object_footprint_tiles(kind, tile, orientation))
		if _would_enclose_tiles(combined_footprint):
			return {"reason": "blocked_target_unreachable", "params": {"detail": "build_line_seals_colony"}}
	return {"kind": kind, "orientation": orientation, "surviving": surviving, "skipped": skipped}

## One site per surviving tile, row-major; atomic (classification precedes any reservation).
func apply_build_line_command(command: Dictionary) -> Dictionary:
	var classification := classify_build_line_command(command["payload"])
	if classification.has("reason"):
		return _event_log.rejection(command["command_id"], command["actor"], classification["reason"], classification["params"])
	var kind: String = classification["kind"]
	var orientation: String = classification["orientation"]
	var definition: Dictionary = _object_definitions[kind]
	var table := _scheduler.queue.get_reservation_table()
	var sites: Array[Dictionary] = []
	for tile in (classification["surviving"] as Array[Vector3i]):
		var site := site_table.create(kind, tile, orientation, definition["build_cost"] as Array,
			int(definition["build_ticks"]), int(definition["max_builders"]))
		var owner := site_table.owner_key(String(site["id"]))
		for footprint_tile in _object_table.object_footprint_tiles(kind, tile, orientation):
			table.acquire(_build_site_key(footprint_tile), owner)
		sites.append({"id": site["id"], "x": tile.x, "y": tile.y, "z": tile.z})
	var applied := _event_log.applied(command)
	applied["sites"] = sites
	applied["skipped"] = classification["skipped"]
	return applied

## Terrain a site may occupy: in bounds, passable, not tree, not trench (a pit
## is passable but no foundation). place_object keeps its own looser rule.
func _build_site_terrain_valid(site: Vector3i) -> bool:
	if not _tile_grid.contains(site):
		return false
	var tile_kind := _tile_grid.tile_at(site)
	if tile_kind == TILE_TREE or tile_kind == TILE_TRENCH:
		return false
	return bool(_passability.passability(site)["passable"])

## The same "tile:" key work jobs reserve: sites and jobs contend through one ledger.
func _build_site_key(build_target: Vector3i) -> String:
	return TileGridType.target_key(build_target)

## A detached copy with builder_ids translated from job ids to the colonist
## currently driving each job (one no longer found is omitted).
func _public_site_view(site: Dictionary) -> Dictionary:
	var view := site.duplicate(true)
	var colonist_ids: Array[String] = []
	for job_id in (site["builder_ids"] as Array):
		var colonist: Dictionary = _find_job_colonist.call(String(job_id))
		if not colonist.is_empty():
			colonist_ids.append(String(colonist["id"]))
	view["builder_ids"] = colonist_ids
	return view

func get_construction_sites() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for site in site_table.list():
		out.append(_public_site_view(site))
	return out

## {} for a tile no site covers; any footprint tile resolves to its site.
func get_construction_site(tile: Vector3i) -> Dictionary:
	var id := construction_site_id_at(tile)
	if id.is_empty():
		return {}
	return _public_site_view(site_table.get_site(id))

func construction_site_id_at(tile: Vector3i) -> String:
	for site in site_table.list():
		if _object_table.object_footprint_tiles(String(site["kind"]), site["origin"], String(site["orientation"])).has(tile):
			return String(site["id"])
	return ""

## site_exists callable for ToilExecutor's deposit toil.
func construction_site_exists(site_id: String) -> bool:
	return site_table.has(site_id)

## site_deposit callable for ToilExecutor's deposit toil; deposit() clamps to
## what the site still needs and returns the amount accepted.
func construction_site_deposit(site_id: String, item_kind: String, count: int) -> int:
	return site_table.deposit(site_id, item_kind, count)

## reservation_owner callable for ConstructionGiver's source selection.
func construction_item_reservation_owner(item_id: String) -> String:
	return _scheduler.queue.get_reservation_table().owner(JobQueueType.ITEM_KEY_PREFIX + item_id)

## Every queued/active site_fetch job except exclude_job_id: a queued job holds
## no reservation on its item yet, so source searches must skip it explicitly.
func _pending_site_fetch_jobs(exclude_job_id: String = "") -> Array[Dictionary]:
	var pending: Array[Dictionary] = []
	for job in _scheduler.queue.view_jobs_of_kinds(["site_fetch"]):
		if String(job.get("status", "")) not in ["queued", "active"]:
			continue
		if String(job["id"]) != exclude_job_id:
			pending.append(job)
	return pending

## The cheapest-route stockpiled source of `kind` not committed to another site_fetch job
## (ties by lowest id); "" when none. A pure query.
func next_site_fetch_source(colonist: Dictionary, job: Dictionary, kind: String, from: Vector3i) -> String:
	var table := _scheduler.queue.get_reservation_table()
	var job_id := String(job["id"])
	var faction_id := String(colonist.get("factionId", "colony"))
	var committed := {}
	for other in _pending_site_fetch_jobs(job_id):
		committed[String(other.get("item_id", ""))] = true
	var best_id := ""
	var best_cost := 0
	var ids := _item_table.items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = _item_table.items[id]
		if String(item["kind"]) != kind:
			continue
		if not _zone_table.is_in_any_zone(TileGrid.tile_of(item)):
			continue
		if committed.has(String(id)):
			continue
		var owner := table.owner(JobQueueType.ITEM_KEY_PREFIX + String(id))
		if not owner.is_empty() and owner != job_id:
			continue
		var tile := TileGrid.tile_of(item)
		var cost: int = _route_cost.call(from, tile, faction_id)
		if cost < 0:
			continue
		if not best_id.is_empty():
			if cost > best_cost:
				continue
			if cost == best_cost and String(id) >= best_id:
				continue
		best_id = String(id)
		best_cost = cost
	return best_id

## Every other site still short of `kind`, reachable from `from` and below its
## max_builders busy count (a retarget bypasses the giver's own cap), sorted by
## route cost then site id: where a colonist may chain a leftover hands-load.
func reachable_short_sibling_sites(colonist: Dictionary, kind: String, from: Vector3i, exclude_site_id: String) -> Array[Dictionary]:
	var faction_id := String(colonist.get("factionId", "colony"))
	var scored: Array = []
	for site in site_table.list():
		var site_id := String(site["id"])
		if site_id == exclude_site_id or site_table.remaining(site, kind) <= 0:
			continue
		if _site_fetch_work_busy(site["origin"]) >= int(site["max_builders"]):
			continue
		var cost: int = _route_cost.call(from, site["origin"], faction_id)
		if cost < 0:
			continue
		scored.append({"site": site, "cost": cost})
	scored.sort_custom(func(a, b):
		if int(a["cost"]) != int(b["cost"]): return int(a["cost"]) < int(b["cost"])
		return String(a["site"]["id"]) < String(b["site"]["id"]))
	var out: Array[Dictionary] = []
	for entry in scored:
		out.append(entry["site"])
	return out

## Queued/active site_fetch + site_work jobs on `origin`: the same busy count
## ConstructionGiver.advance() uses.
func _site_fetch_work_busy(origin: Vector3i) -> int:
	var busy := 0
	for job in _scheduler.queue.view_jobs_of_kinds(["site_fetch", "site_work"]):
		if String(job.get("status", "")) in ["queued", "active"] and job.get("site") == origin:
			busy += 1
	return busy

## The nearest reachable_short_sibling_sites() candidate, or {}.
func next_site_fetch_site(colonist: Dictionary, kind: String, from: Vector3i, exclude_site_id: String) -> Dictionary:
	var candidates := reachable_short_sibling_sites(colonist, kind, from, exclude_site_id)
	return candidates[0] if not candidates.is_empty() else {}

## TickPipeline's snapshot before the scheduler phase, to spot just-(re)activated jobs.
func active_site_fetch_job_ids() -> Dictionary:
	var ids: Dictionary = {}
	for job in _scheduler.queue.view_jobs_of_kinds(["site_fetch"]):
		if String(job.get("status", "")) == "active":
			ids[String(job["id"])] = true
	return ids

## Swaps a just-activated site_fetch job's seed source for the nearest one from its
## colonist; a running job is never re-evaluated mid-route.
func resolve_freshly_activated_site_fetch_sources(before: Dictionary) -> void:
	for job in _scheduler.queue.view_jobs_of_kinds(["site_fetch"]):
		if String(job.get("status", "")) != "active" or job.get("cell") != null:
			continue
		var job_id := String(job["id"])
		if before.has(job_id):
			continue
		var colonist: Dictionary = _find_job_colonist.call(job_id)
		if colonist.is_empty():
			continue
		var current_item_id := String(job.get("item_id", ""))
		var kind := String(_item_table.item_lookup(current_item_id).get("kind", ""))
		if kind.is_empty():
			continue
		var current := TileGrid.tile_of(colonist)
		var best_id := next_site_fetch_source(colonist, job, kind, current)
		if best_id.is_empty() or best_id == current_item_id:
			continue
		var table := _scheduler.queue.get_reservation_table()
		table.release(JobQueueType.ITEM_KEY_PREFIX + current_item_id, job_id)
		table.acquire(JobQueueType.ITEM_KEY_PREFIX + best_id, job_id)
		var best_item := _item_table.item_lookup(best_id)
		_scheduler.queue.retarget_site_fetch_source(job_id, best_id, TileGrid.tile_of(best_item))
		site_fetch_source_retargeted[job_id] = true

## submit_fetch callable for ConstructionGiver: leg one targets item_tile; the
## item and the site origin (leg two) are attached to the job.
func submit_site_fetch(origin: Vector3i, item_id: String, item_tile: Vector3i, tick: int) -> Dictionary:
	var result := _scheduler.submit(item_tile, JobQueueType.Priority.NORMAL, tick, "site_fetch", "")
	if result.get("ok", false):
		var job_id: String = result["job_id"]
		_scheduler.queue.attach_item(job_id, item_id)
		_scheduler.queue.attach_site(job_id, origin)
	return result

## submit_work callable for ConstructionGiver: targets the site origin and adds
## the job to the site's builders (capped at max_builders by the table).
func submit_site_work(origin: Vector3i, tick: int) -> Dictionary:
	var result := _scheduler.submit(origin, JobQueueType.Priority.NORMAL, tick, "site_work", "")
	if result.get("ok", false):
		var job_id: String = result["job_id"]
		_scheduler.queue.attach_site(job_id, origin)
		site_table.add_builder(site_table.find_at_origin(origin), job_id)
	return result

## The first passable, non-trench tile next to the footprint (N/W/E/S per tile)
## not in `exclude`; tiles[0] when none qualifies.
func _nearest_free_adjacent_to_footprint(tiles: Array[Vector3i], exclude: Dictionary = {}) -> Vector3i:
	var footprint := {}
	for tile in tiles:
		footprint[tile] = true
	for tile in tiles:
		for neighbor in [Vector3i(tile.x, tile.y - 1, tile.z), Vector3i(tile.x - 1, tile.y, tile.z),
				Vector3i(tile.x + 1, tile.y, tile.z), Vector3i(tile.x, tile.y + 1, tile.z)]:
			if footprint.has(neighbor) or exclude.has(neighbor):
				continue
			if bool(_passability.passability(neighbor)["passable"]) and _tile_grid.tile_at(neighbor) != TILE_TRENCH:
				return neighbor
	return tiles[0]

## cancel_site/cancel_job on a site: terminates its fetch/work jobs (dropping
## carried hands), drops held materials next to the footprint (one tile per
## kind where possible), releases the footprint reservation, removes the record.
func cancel_construction_site(site_id: String) -> void:
	var site := site_table.get_site(site_id)
	if site.is_empty():
		return
	var origin: Vector3i = site["origin"]
	for job in _scheduler.queue.view_jobs_of_kinds(["site_fetch", "site_work"]):
		if job.get("site") != origin or not (String(job.get("status", "")) in ["queued", "active"]):
			continue
		var kind := String(job.get("kind", ""))
		var job_id := String(job["id"])
		if kind == "site_fetch":
			_drop_carried_haul_item.call(job_id)
		_finish_job.call(job_id, "cancel_job")
	var footprint := _object_table.object_footprint_tiles(String(site["kind"]), origin, String(site["orientation"]))
	var used := {}
	for entry in (site["held_materials"] as Array):
		var quantity := int(entry["quantity"])
		if quantity <= 0:
			continue
		var drop_at := _nearest_free_adjacent_to_footprint(footprint, used)
		used[drop_at] = true
		_item_table.place_new_ground_item(String(entry["item"]), quantity, drop_at)
	_scheduler.queue.get_reservation_table().release_all(site_table.owner_key(site_id))
	site_table.remove(site_id)

## Completion: completes every other builder (complete_builder), releases the
## footprint reservation, places the object (ObjectTable.set_object() handles
## footprint and regions) and removes the record; held materials are spent by definition.
func _finalize_construction_site(site_id: String, completing_job_id: String) -> void:
	var site := site_table.get_site(site_id)
	if site.is_empty():
		return
	for other_job_id in (site["builder_ids"] as Array):
		if String(other_job_id) == completing_job_id:
			continue
		if complete_builder.is_valid():
			complete_builder.call(String(other_job_id))
		else:
			_finish_job.call(String(other_job_id), "complete_job")
	_scheduler.queue.get_reservation_table().release_all(site_table.owner_key(site_id))
	var origin: Vector3i = site["origin"]
	_object_table.set_object(origin, String(site["kind"]), "colony", String(site["orientation"]))
	site_table.remove(site_id)

## A site_work job's terminal transition other than completion frees its builder
## slot. Called right after the transition, so the job is still in JobQueue's history (A5).
func release_site_builder(job_id: String) -> void:
	var job := _scheduler.queue.view_job(job_id)
	if job.is_empty() or job.get("site") == null:
		return
	var site_id := site_table.find_at_origin(job["site"])
	if not site_id.is_empty():
		site_table.remove_builder(site_id, job_id)

## True when blocking `tiles` (plus other impassable sites) would strand a tile a colony
## actor reaches today; counted per component, as build_line tiles may span several.
func _would_enclose_tiles(tiles: Array[Vector3i], exclude_site_id: String = "") -> bool:
	var blocked := {}
	for site in site_table.list():
		if String(site["id"]) == exclude_site_id:
			continue
		if bool(_object_definitions.get(String(site["kind"]), {}).get("passable", true)):
			continue
		for tile in _object_table.object_footprint_tiles(String(site["kind"]), site["origin"], String(site["orientation"])):
			blocked[tile] = true
	var seen := {}
	for colonist in _get_colonists.call():
		if String(colonist.get("factionId", "colony")) != "colony":
			continue
		var reference := TileGrid.tile_of(colonist)
		if tiles.has(reference) or seen.has(reference) or blocked.has(reference):
			continue
		var before := _flood_fill_passable(reference, blocked)
		seen.merge(before)
		var touches_candidate := false
		for tile in tiles:
			if before.has(tile):
				touches_candidate = true
				break
		if not touches_candidate:
			continue
		for tile in tiles:
			blocked[tile] = true
		var after := _flood_fill_passable(reference, blocked)
		for tile in tiles:
			blocked.erase(tile)
		var candidates_in_before := 0
		for tile in tiles:
			if before.has(tile):
				candidates_in_before += 1
		if after.size() < before.size() - candidates_in_before:
			return true
	return false

## 4-connected flood fill of colony-passable tiles from start, treating `blocked` as walls.
func _flood_fill_passable(start: Vector3i, blocked: Dictionary) -> Dictionary:
	var visited := {}
	if blocked.has(start) or not bool(_passability.passability(start)["passable"]):
		return visited
	visited[start] = true
	var frontier: Array[Vector3i] = [start]
	while not frontier.is_empty():
		var current: Vector3i = frontier.pop_back()
		for offset in [Vector3i(0, -1, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0)]:
			var next: Vector3i = current + offset
			if blocked.has(next) or visited.has(next):
				continue
			if next.x < 0 or next.x >= _tile_grid.width or next.y < 0 or next.y >= _tile_grid.height:
				continue
			if not bool(_passability.passability(next)["passable"]):
				continue
			visited[next] = true
			frontier.append(next)
	return visited
