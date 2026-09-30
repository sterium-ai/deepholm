class_name ConstructionGiver
extends RefCounted

## Job-giver for construction sites (ADR 040): decides
## when a site's next fetch or work job should exist. A `build` command
## creates the site record and reserves its footprint immediately
## (WorldState); this module tops up `site_fetch` jobs while materials are
## still short, and tops up `site_work` jobs once every required material is
## fully held, both up to the site's own max_builders (a site
## with max_builders 2 may hold up to two colonists fetching, working, or one
## of each, at once -- never a third) -- both through the shared job_queue.gd
## entry point any order-driven job uses
## (AGENTS.md "one work engine"). Deliberately simpler than the superseded
## `build` job's own per-job multi-source fetch plan (ADR 038): a
## site_fetch job always carries exactly one kind, sized to what the site
## still needs of it (up to hands capacity); the giver resubmits a fresh one
## whenever the previous one terminates and material is still short, rather
## than one job hopping between several sources itself. See
## ADR 040's own "Alternatives considered" for why.

var _get_sites: Callable
var _get_jobs: Callable
var _get_items: Callable
var _is_in_any_zone: Callable
var _reservation_owner: Callable
var _submit_fetch: Callable
var _submit_work: Callable
var _materials_met: Callable
var _remaining: Callable

## get_sites must be ConstructionSiteTable.list (the raw internal records,
## not WorldState's own colonist-id-translated public view). get_jobs/
## get_items must be WorldState's own public methods of the same name;
## is_in_any_zone must be its like-named private method. reservation_owner(
## item_id: String) -> String must resolve the shared ReservationTable's own
## "item:" key owner. submit_fetch(origin, item_id, item_tile, tick) ->
## Dictionary and submit_work(origin, tick) -> Dictionary must be WorldState's
## own submit-and-attach wrappers (_submit_site_fetch()/_submit_site_work()).
## materials_met/remaining must be ConstructionSiteTable.materials_met/
## remaining.
func _init(get_sites: Callable, get_jobs: Callable, get_items: Callable, is_in_any_zone: Callable,
		reservation_owner: Callable, submit_fetch: Callable, submit_work: Callable,
		materials_met: Callable, remaining: Callable) -> void:
	_get_sites = get_sites
	_get_jobs = get_jobs
	_get_items = get_items
	_is_in_any_zone = is_in_any_zone
	_reservation_owner = reservation_owner
	_submit_fetch = submit_fetch
	_submit_work = submit_work
	_materials_met = materials_met
	_remaining = remaining

func _site_key(origin) -> String:
	if origin == null:
		return ""
	var tile: Vector2i = origin
	return "%d,%d" % [tile.x, tile.y]

## Hands-filling rules: the source this giver submits
## a site_fetch job against is only a position-agnostic seed for
## GlobalAssignment to route/score an idle colonist toward -- no colonist is
## chosen yet at submission time, so "nearest to the builder" cannot be
## evaluated here (see _choose_source() below). The instant that job actually
## (re)activates with a real colonist known, WorldState swaps the seed for
## the true nearest-reachable source from the colonist's own position
## (_resolve_freshly_activated_site_fetch_sources()), and re-runs the same
## search after every pick_up to decide whether to keep filling hands from a
## further source or deliver the (possibly partial) load already held,
## whichever is nearer (_toil_on_pick_up_success()) -- both in world_state.gd,
## since only WorldState has a colonist's live position and a route search.
##
## Runs once per tick (WorldState.tick(), alongside HaulGiver's own advance()):
## for every site still short of materials, tops its own fetch+work job count
## up to max_builders with fresh site_fetch jobs (two builders on a
## max_builders-2 site may fetch concurrently, each getting its own
## nearest-unclaimed source via the per-builder rule, resolved once a real
## colonist activates it -- see _next_site_fetch_source()); for every site
## with every material fully held, tops its active/queued site_work count up
## to the same max_builders cap.
func advance(tick: int) -> void:
	var fetch_counts: Dictionary = {}
	var work_counts: Dictionary = {}
	var committed_items: Dictionary = {}
	for job in (_get_jobs.call() as Array):
		var kind := String(job.get("kind", ""))
		if kind != "site_fetch" and kind != "site_work":
			continue
		if not (String(job.get("status", "")) in ["queued", "active"]):
			continue
		var site = job.get("site")
		if site == null:
			continue
		var key := _site_key(site)
		if kind == "site_fetch":
			committed_items[String(job.get("item_id", ""))] = true
			fetch_counts[key] = int(fetch_counts.get(key, 0)) + 1
		else:
			work_counts[key] = int(work_counts.get(key, 0)) + 1
	for site in (_get_sites.call() as Array):
		var origin: Vector2i = site["origin"]
		var key := _site_key(origin)
		# Busy = every fetch or work job already holding one of this site's
		# max_builders slots (queued or active): a third colonist must never
		# be offered a slot while two already hold both of them, whichever
		# mix of fetching and working they are in.
		var busy: int = int(fetch_counts.get(key, 0)) + int(work_counts.get(key, 0))
		if not bool(_materials_met.call(site)):
			for i in range(maxi(0, int(site["max_builders"]) - busy)):
				var choice := _choose_source(site, committed_items)
				if choice.is_empty():
					break
				var result: Dictionary = _submit_fetch.call(origin, String(choice["item_id"]), choice["tile"], tick)
				if not result.get("ok", false):
					break
				committed_items[String(choice["item_id"])] = true
				fetch_counts[key] = int(fetch_counts.get(key, 0)) + 1
				busy += 1
			continue
		for i in range(maxi(0, int(site["max_builders"]) - busy)):
			var result: Dictionary = _submit_work.call(origin, tick)
			if result.get("ok", false):
				work_counts[key] = int(work_counts.get(key, 0)) + 1

## Lowest-id, position-agnostic seed (no colonist is chosen yet at
## submission, ADR 038's own precedent for the superseded `build`
## job's seed -- WorldState corrects it to the true nearest-reachable source
## the instant a colonist actually activates the job, per the hands-filling
## rules) ground item covering some still-needed required material,
## stockpiled, unreserved, and not already committed to another in-flight
## site_fetch job. Required materials are tried in the site's own declared
## order; {} when nothing qualifies for any of them.
func _choose_source(site: Dictionary, committed_items: Dictionary) -> Dictionary:
	for entry in (site["required_materials"] as Array):
		var kind := String(entry["item"])
		if int(_remaining.call(site, kind)) <= 0:
			continue
		var candidates: Array = []
		for item in (_get_items.call() as Array):
			if String(item["kind"]) != kind:
				continue
			var id := String(item["id"])
			if committed_items.has(id):
				continue
			if not bool(_is_in_any_zone.call(int(item["x"]), int(item["y"]))):
				continue
			if not String(_reservation_owner.call(id)).is_empty():
				continue
			candidates.append(item)
		if candidates.is_empty():
			continue
		candidates.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
		var chosen: Dictionary = candidates[0]
		return {"item_id": String(chosen["id"]), "tile": Vector2i(int(chosen["x"]), int(chosen["y"]))}
	return {}
