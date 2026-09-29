class_name ToilExecutor
extends RefCounted

## Generic toil execution (colonist-ai.md 3.3): a job kind is data
## (content/jobs.json: {kind, labour, toils: [...]}), and toils are a small
## fixed vocabulary implemented once here instead of per-kind branches in
## WorldState. dig/chop/forage drive only the go_to and work toils (which
## become the colonist's existing route/work fields); haul additionally
## drives pick_up/place across two go_to legs (colonist-ai.md 3.3/3.4); reserve
## is satisfied by the scheduler activating the job (JobQueue._reservations,
## unchanged -- no ReservationTable refactor here) and release_all by
## WorldState finishing the job through the scheduler. The go_to toil owns
## re-routing (colonist-ai.md 3.5): a blocked next tile, or a leg with no
## precomputed path at all (a haul job's second leg), starts a bounded search
## through the injected route_search_factory -- WorldState owns constructing
## the actual RerouteType (bounds, RNG-free Dijkstra search) and the
## passability variant (target-tile exception for dig/chop/haul-leg-one, plain
## passability for haul-leg-two's already-guaranteed-passable destination
## cell), this module only steps whatever search object the factory returns.

const JOBS_CONTENT_PATH := "res://content/jobs.json"
## Only used for its inherited STATUS_FOUND/STATUS_UNREACHABLE vocabulary:
## this module never constructs a RerouteType, that is route_search_factory's job.
const RerouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const ToolFetchToilType = preload("res://scripts/core/jobs/tool_fetch_toil.gd")
const ToolDropToilType = preload("res://scripts/core/jobs/tool_drop_toil.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const TOIL_RESERVE := "reserve"
const TOIL_GO_TO := "go_to"
const TOIL_PICK_UP := "pick_up"
const TOIL_WORK := "work"
const TOIL_PLACE := "place"
const TOIL_DEPOSIT := "deposit"
const TOIL_CONSUME := "consume"
const TOIL_FETCH_TOOL := "fetch_tool"
const TOIL_DROP_TOOL := "drop_tool"
const TOIL_RELEASE_ALL := "release_all"
## issue #406 (docs/decisions/038): "deposit" is a new verb, not an extension
## of "place" -- it transfers carried hands into a construction site's own
## held_materials (ConstructionSiteTable) instead of minting a ground item, so
## it has no "cell still free" precondition and no ground-item side effect at
## all; sharing "place" would have meant branching that toil's own body on
## "is this destination a site or a cell", which the fixed-vocabulary
## discipline (docs/architecture/extension-points.md "Toil") treats as exactly
## the kind of per-kind special case a new verb exists to avoid.
const VOCABULARY: Array[String] = [
	TOIL_RESERVE, TOIL_GO_TO, TOIL_PICK_UP, TOIL_WORK, TOIL_PLACE, TOIL_DEPOSIT, TOIL_CONSUME, TOIL_FETCH_TOOL, TOIL_DROP_TOOL, TOIL_RELEASE_ALL
]

## colonist-ai.md 3.6: a toil declares interruptible: bool. "work" is the only
## toil that ever populates colonist.work, and it is the only one the doc's
## explicit example marks true (pick_up/consume are named false); every other
## toil in VOCABULARY defaults false via is_interruptible_toil() below.
const REASON_ITEM_NOT_FOUND := "item_not_found"
const REASON_ITEM_OUT_OF_REACH := "item_out_of_reach"
const REASON_HANDS_FULL := "hands_full"
const REASON_NOT_CARRYING := "not_carrying"
const REASON_DESTINATION_BLOCKED := "destination_blocked"
const REASON_SOURCE_GONE := "source_gone"
const REASON_SOURCE_OUT_OF_REACH := "source_out_of_reach"
const REASON_SITE_GONE := "site_gone"

## Execution trace (test_architecture_rules.gd's execution-trace assertions
## only): records each toil this module actually enters/completes, so a test
## can prove a job kind's declared toils (content/jobs.json) ran through
## ToilExecutor itself rather than inferring it from colonist state after the
## fact. Never read by production code -- purely additive bookkeeping, so it
## changes no behaviour and no function signature.
var trace: Array[Dictionary] = []

func clear_trace() -> void:
	trace.clear()

func _record(toil: String, phase: String) -> void:
	trace.append({"toil": toil, "phase": phase})

## The content bundle ActorTable.get_component() (ADR 012) resolves a
## colonist's "route" (its "mover" component) against.
var _content
var _job_kinds: Dictionary = {}
var _move_ticks_per_tile: int
var _work_ticks: Dictionary
var _passability: Callable
var _job_lookup: Callable
var _item_lookup: Callable
var _remove_item: Callable
var _place_item: Callable
var _cell_occupied: Callable
var _source_valid: Callable
var _work_progress_get: Callable
var _work_progress_set: Callable
var _work_progress_clear: Callable
## Live in-flight re-route searches, keyed by colonist id -- the same
## Dictionary instance WorldState._reroutes holds (shared by reference, not
## copied), since persistence/state_codec.gd reads and rebuilds that field
## directly and is out of this task's scope to change.
var _reroutes: Dictionary
## fetch_tool toil (colonist-ai.md 2/3.3, issue #271): extracted into its own
## injected object (tool_fetch_toil.gd) purely to keep this file under its
## line budget (docs/architecture/core-budgets.json); constructed below once
## _job_kinds is loaded, from WorldState's own existing public tool-item API
## -- no new WorldState surface beyond on_no_tool_found (a per-job hooks-dict
## entry, see advance() below), since find/reserve/hold are already public.
var _tool_fetch: ToolFetchToilType
## route_search_factory(start: Vector2i, target: Vector2i, passable: Callable)
## -> a RerouteType-shaped object (is_terminal(), resume(), snapshot(),
## get_status(), get_path()) must construct and return a fresh bounded route
## search from WorldState's own RerouteType, with WorldState's map bounds --
## this module stays decoupled from both (colonist-ai.md 3.5).
var _route_search_factory: Callable
## colonist_id -> true once its one-resume-per-tick routing allowance (ADR
## 004: "at most 64 frontier expansions across all route work" per colonist
## per tick) has been spent this external WorldState.tick(), shared by
## reference with GlobalAssignment.set_route_budget() and cleared by
## WorldState at the start of every tick() -- round 5 review: without this, a
## colonist whose job the scheduler just activated (spending its own pending-
## route search this tick) could still have fetch_tool immediately start and
## resume a second, unrelated search the same tick, and a long fetch_tool ->
## return-to-target transition could resume the same search twice.
var _route_budget: Dictionary
## work_target_for(job: Dictionary) -> Vector2i: the tile a job's `work` toil
## actually operates on/completes at (start_work()/advance_work_step()'s own
## work-progress key). Ordinarily job["target"] itself; a build job's real
## site instead of the reserved wood item's own tile job["target"] still
## names (WorldState._work_target_for(), issue #278/#303 -- build needs its
## own second destination, mirroring how haul's job["cell"] is a separate
## field from job["target"], but build has no `place` toil of its own to
## redirect through _toil_cell_for()). Falls back to job["target"] when unset,
## so every other job kind (a single-destination shape) is unaffected.
var _work_target_for: Callable
## site_exists(site_id: String) -> bool and site_deposit(site_id: String, kind:
## String, count: int) -> int (units actually accepted, clamped to what the
## site still needs) back WorldState's ConstructionSiteTable (issue #406) for
## the "deposit" toil below -- the same "inject the state-mutating callable,
## never touch WorldState directly" discipline every other toil already uses.
var _site_exists: Callable
var _site_deposit: Callable
## drop_tool toil + the handover wait + the destroyed-mid-job failure path
## (issue #266, ADR 012 amendment), extracted into its own injected object
## (tool_drop_toil.gd) for the same reason _tool_fetch is: keeps this file
## under its line budget (docs/architecture/core-budgets.json). Constructed
## below once _tool_fetch exists (it needs _tool_fetch.needs()).
var _tool_drop: ToolDropToilType

## passability(x,y,faction_id)->Dictionary must be WorldState.passability()
## (the one authoritative source; faction_id defaults "colony" there, but
## every call site in this file threads the acting colonist's own
## factionId, F5 issue #294, so a non-colony actor's own movement never
## silently uses colony door permissions). job_lookup(job_id)->Dictionary must return the
## active job record (at least "kind"), e.g. WorldState._scheduler.queue.
## get_job. work_ticks/move_ticks_per_tile are injected so this module never
## hardcodes a duration WorldState already owns. item_lookup(item_id)->
## Dictionary must return the ground item's record ("x","y","kind","count"),
## or {} when gone/carried; remove_item(item_id, count) must decrement the
## ground item's own count by count (removing it entirely at 0), and
## place_item(kind, count, x, y)->String must mint a fresh item id and place
## a new ground item there, returning that id -- both WorldState's own _items
## mutators (issue #402: pick_up/place move a count of units, not always a
## whole stack, and place() drops one fresh-id item per distinct hands kind).
## cell_occupied(x,y,excluding_colonist_id)
## ->bool must report whether another colonist or ground item occupies (x,y),
## for place()'s "cell still free" precondition. source_valid(job_id)->bool
## must report whether a need job's reserved source is still consumable
## (kind-aware lookups live in world_state.gd, colonist-ai.md 3.1/3.3), so
## consume() can fail typed instead of assuming success. work_progress_get
## (target, job_id)->Variant (int, or null with nothing stored FOR job_id
## specifically, round-6 review), work_progress_set(target, ticks_remaining,
## job_id)->void, and work_progress_clear(target)->void must be WorldState's
## job-id-scoped store (colonist-ai.md 3.6): start_work() resumes from stored
## ticks instead of the full duration, and advance_work_step() keeps it in
## sync (also stamping job_id as the key's current owner, issue #278/#303
## round-3 review) so an interrupt never loses progress, and a different job
## that later works the same tile can never inherit or clobber it (round-6
## review: WorldState._resume_work_progress()/_suspend_work_progress()).
func _init(move_ticks_per_tile: int, work_ticks: Dictionary, passability: Callable, job_lookup: Callable,
		content_registry,
		item_lookup: Callable = Callable(), remove_item: Callable = Callable(), place_item: Callable = Callable(),
		cell_occupied: Callable = Callable(), source_valid: Callable = Callable(),
		work_progress_get: Callable = Callable(), work_progress_set: Callable = Callable(),
		work_progress_clear: Callable = Callable(), reroutes: Dictionary = {},
		route_search_factory: Callable = Callable(), get_tool_items: Callable = Callable(),
		get_tool_item: Callable = Callable(), tool_reservation_of: Callable = Callable(),
		reserve_tool: Callable = Callable(), release_tool: Callable = Callable(),
		pick_up_tool: Callable = Callable(), drop_tool_ground: Callable = Callable(),
		get_colonists: Callable = Callable(), route_budget: Dictionary = {},
		get_zones: Callable = Callable(), is_cell_free: Callable = Callable(), drop_tool_stockpile: Callable = Callable(),
		release_all_tool_reservations: Callable = Callable(), tool_reservation_table: Callable = Callable(),
		set_active_drop_item: Callable = Callable(), get_active_drop_item: Callable = Callable(),
		find_colonist: Callable = Callable(), get_assignments: Callable = Callable(),
		work_target_for: Callable = Callable(), site_exists: Callable = Callable(),
		site_deposit: Callable = Callable()) -> void:
	_move_ticks_per_tile = move_ticks_per_tile
	_work_ticks = work_ticks
	_passability = passability
	_job_lookup = job_lookup
	_content = content_registry
	_item_lookup = item_lookup
	_remove_item = remove_item
	_place_item = place_item
	_cell_occupied = cell_occupied
	_source_valid = source_valid
	_work_progress_get = work_progress_get
	_work_progress_set = work_progress_set
	_work_progress_clear = work_progress_clear
	_reroutes = reroutes
	_route_search_factory = route_search_factory
	_route_budget = route_budget
	_work_target_for = work_target_for
	_site_exists = site_exists
	_site_deposit = site_deposit
	_job_kinds = _load_job_kinds()
	_tool_fetch = ToolFetchToilType.new(_job_kinds, get_tool_items, get_tool_item, tool_reservation_of,
		reserve_tool, release_tool, pick_up_tool, drop_tool_ground, get_colonists,
		advance_go_to, _record)
	_tool_drop = ToolDropToilType.new(_job_kinds, work_ticks, passability, cell_occupied, is_cell_free, get_zones,
		tool_reservation_of, get_tool_item, tool_reservation_table, release_all_tool_reservations,
		drop_tool_ground, drop_tool_stockpile, work_progress_clear, reroutes, advance_go_to,
		_record, get_colonists, get_tool_items, set_active_drop_item, get_active_drop_item,
		find_colonist, get_assignments)

## Reads the "mover" component's route off a colonist through ActorTable
## (ADR 012) rather than indexing the colonist dict directly. The returned
## Dictionary (when non-null) is the same live route object actor["route"]
## holds -- get_component() never duplicates a component's nested value -- so
## mutating a field on it (route["step"] = ...) still mutates the colonist's
## real state; only a wholesale replacement (colonist["route"] = {...}) must
## still assign the colonist dict directly, since ActorTable has no setter.
func _route(colonist: Dictionary):
	var mover_component = ActorTableType.get_component(colonist, "mover", _content)
	return mover_component.get("route") if mover_component != null else null

func has_kind(kind: String) -> bool:
	return _job_kinds.has(kind)

func get_toils(kind: String) -> Array:
	return (_job_kinds.get(kind, {}).get("toils", []) as Array).duplicate()

func get_labour(kind: String) -> String:
	return String(_job_kinds.get(kind, {}).get("labour", ""))

static func is_known_toil(name: String) -> bool:
	return name in VOCABULARY

## colonist-ai.md 3.6: "work" yes, everything else (pick_up/consume named
## explicitly, go_to/reserve/place/release_all by the same default) no.
static func is_interruptible_toil(name: String) -> bool:
	return name == TOIL_WORK

## go_to toil: begins the route toward the assignment's resolved path, or
## enters the work toil immediately when the colonist already stands on/
## adjacent to the target (path.size() <= 1), mirroring the shortcut the
## scheduler's own route search already relies on.
func start_assignment(colonist: Dictionary, job_id: String, path: Array, on_arrive: Callable = Callable()) -> void:
	_record(TOIL_GO_TO, "enter")
	if path.size() <= 1:
		if on_arrive.is_valid():
			on_arrive.call(colonist, job_id)
		else:
			start_work(colonist, job_id)
		return
	colonist["route"] = {
		"job_id": job_id,
		"path": path,
		"step": 0,
		"move_ticks_remaining": _move_ticks_per_tile,
		"rerouting": null,
	}

## work toil: duration is fixed per job kind (WorldState.WORK_TICKS, injected
## so it stays byte-identical to the pre-toils constant). A kind absent from
## _work_ticks (t5's haul: pick_up/place are instant, not timed) has no work
## phase at all: this is a no-op, leaving colonist.work null so the caller
## (WorldState) knows the colonist has simply arrived and must drive its own
## next toil instead of waiting on a timer. When the target tile already
## carries stored progress (a prior interrupt paused this same job mid-work,
## colonist-ai.md 3.6), resumes from that tick count instead of the full
## duration -- this is what makes an interrupted dig/chop/forage/sleep resume
## rather than restart.
func start_work(colonist: Dictionary, job_id: String) -> void:
	_record(TOIL_GO_TO, "complete")
	var job: Dictionary = _job_lookup.call(job_id)
	if not _work_ticks.has(job["kind"]):
		return
	_record(TOIL_WORK, "enter")
	var ticks_remaining: int = int(_work_ticks[job["kind"]])
	if _work_progress_get.is_valid():
		var stored = _work_progress_get.call(_work_target(job), job_id)
		if stored != null:
			ticks_remaining = int(stored)
	colonist["work"] = {"job_id": job_id, "ticks_remaining": ticks_remaining}

## work_target_for passthrough (see its own doc comment above): job["target"]
## when unset, so a job kind with a single destination is unaffected.
func _work_target(job: Dictionary) -> Vector2i:
	if _work_target_for.is_valid():
		return _work_target_for.call(job)
	return job["target"]

## Advances the go_to toil's movement timer by one tick along an already
## resolved path (no in-flight re-route in progress). Returns true when the
## next path tile has become impassable so the caller (advance_go_to(), below)
## can hand off to the re-route flow.
## on_arrive(colonist, job_id): called once the path is exhausted, instead of
## the default start_work(), when non-empty -- the fetch_tool toil's own
## travel leg (colonist-ai.md 2/3.3) reuses this same stepping function to
## reach a tool's location and hand off to its own pickup instead of starting
## the job's real work toil there.
func advance_route_step(colonist: Dictionary, on_arrive: Callable = Callable()) -> bool:
	var route: Dictionary = _route(colonist)
	var path: Array = route["path"]
	var step: int = int(route["step"])
	var next_tile: Vector2i = path[step + 1]
	if not bool(_passability.call(next_tile.x, next_tile.y, String(colonist.get("factionId", "colony")))["passable"]):
		return true
	route["move_ticks_remaining"] -= 1
	if route["move_ticks_remaining"] > 0:
		return false
	step += 1
	var arrived: Vector2i = path[step]
	colonist["x"] = arrived.x
	colonist["y"] = arrived.y
	route["step"] = step
	if step == path.size() - 1:
		var job_id: String = route["job_id"]
		colonist["route"] = null
		if on_arrive.is_valid():
			on_arrive.call(colonist, job_id)
		else:
			start_work(colonist, job_id)
	else:
		route["move_ticks_remaining"] = _move_ticks_per_tile
	return false

## go_to toil (colonist-ai.md 3.3/3.5): steps the colonist toward target by one
## tile per _move_ticks_per_tile ticks (advance_route_step(), above),
## re-validating the next tile's passability every call. A blocked next tile
## -- or a toil with no precomputed path at all yet (a haul job's second leg
## has no scheduler-computed path to job["cell"], unlike the assignment path
## start_assignment() begins from) -- starts a bounded re-route search through
## the injected route_search_factory instead of walking into the blocker or
## stalling silently. `passable` is the cost function the search itself uses
## (WorldState supplies the target-tile exception for dig/chop/haul-leg-one,
## or plain passability for haul-leg-two's already-guaranteed-passable
## destination cell); the found path is separately trimmed against the
## target tile's *true* passability (self._passability, not `passable`) so a
## dig/chop/haul-leg-one target that is itself impassable (a tree, an ore
## vein) still ends the route one tile short, exactly as start_assignment()'s
## own path already does.
##
## Returns "" once the toil is progressing normally (still walking, an
## in-flight search not yet terminal, arrived with the work toil started when
## the job kind has one, or a resolved search already turned into a fresh
## path) or "unreachable" once the search proves target unreachable --
## colonist.route/work are already cleared and the reroute entry already
## erased by the time this returns, so the caller only applies its own
## job-kind-specific consequence (WorldState resubmits a dig/chop/
## haul-leg-one job to the fair scheduler; a haul-leg-two job fails outright
## instead, since there is no queue entry to resubmit a destination search
## to).
## record_as/on_arrive: the fetch_tool toil's own travel leg (tool_fetch_toil.
## gd's advance(), injected as this method itself) calls this same function
## with record_as=TOIL_FETCH_TOOL and its own pickup on_arrive callable
## instead of the go_to toil's defaults, so the execution trace and arrival
## effect both reflect whichever toil is actually travelling this tick.
## force_trim_last (issue #278/#303 round-1 review): when true, the found
## path's last tile is dropped regardless of the target's own *current* real
## passability, unlike the ordinary trim condition below (which only trims a
## target that is impassable right now, correct for dig/chop/haul-leg-one's
## already-impassable tree/ore/etc.). A build job's real site is still
## genuinely passable at travel time -- nothing is built there yet -- so the
## ordinary trim never fires and the colonist would otherwise walk onto the
## exact tile about to become an object; WorldState sets this true only for a
## build job's second leg targeting a kind that will itself be impassable
## (a wall), landing the colonist adjacent instead, exactly like chop/forage's
## own always-impassable target.
func advance_go_to(colonist: Dictionary, job_id: String, target: Vector2i, passable: Callable,
		record_as: String = TOIL_GO_TO, on_arrive: Callable = Callable(), force_trim_last: bool = false) -> String:
	# Step-off rule (issue #303 round-2 review): a colonist ALREADY standing on
	# a force-trim target (the stockpile sits on the build site itself, or the
	# builder walked over it) has nothing for the trim below to drop -- the
	# search returns the one-tile path [current] and arrival would start work
	# right there, under the object about to appear. Re-aiming this same
	# go_to leg at the first passable orthogonal neighbour (deterministic
	# north/west/east/south order, matching WorldState._dig_item_placement())
	# moves it off through the ordinary route machinery; the re-aim is
	# recomputed identically every tick until the colonist has left the tile,
	# after which the real target and trim apply again unchanged.
	if force_trim_last:
		var standing := Vector2i(int(colonist["x"]), int(colonist["y"]))
		if standing == target:
			var step_off := _step_off_tile(standing, String(colonist.get("factionId", "colony")))
			if step_off != standing:
				target = step_off
				force_trim_last = false
	var route = _route(colonist)
	if route == null:
		_record(record_as, "enter")
		# path starts as the colonist's own current tile (a stationary
		# one-tile path), never [] -- SaveIO._valid_entity_route() requires at
		# least one tile, and a save taken before _begin_go_to_reroute()'s
		# search resolves (the initial fetch_tool leg, a fresh search after an
		# excluded candidate, or the return-to-target leg after pickup) would
		# otherwise persist an empty path and fail to reload (round 7 review
		# finding). advance_route_step() (the only reader of route.path) is
		# never reached while rerouting != null, so this placeholder is read
		# only by persistence until _resume_go_to_reroute() replaces it wholesale
		# with the search's own resolved path.
		var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
		colonist["route"] = {
			"job_id": job_id, "path": [current], "step": 0,
			"move_ticks_remaining": _move_ticks_per_tile, "rerouting": null,
		}
		return _begin_go_to_reroute(colonist, job_id, target, passable, record_as, on_arrive, force_trim_last)
	if route["rerouting"] != null:
		return _resume_go_to_reroute(colonist, route, job_id, target, passable, record_as, on_arrive, force_trim_last)
	if advance_route_step(colonist, on_arrive):
		return _begin_go_to_reroute(colonist, job_id, target, passable, record_as, on_arrive, force_trim_last)
	return ""

func _begin_go_to_reroute(colonist: Dictionary, job_id: String, target: Vector2i, passable: Callable,
		record_as: String = TOIL_GO_TO, on_arrive: Callable = Callable(), force_trim_last: bool = false) -> String:
	var route: Dictionary = _route(colonist)
	var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var search = _route_search_factory.call(start, target, passable)
	_reroutes[colonist["id"]] = search
	route["rerouting"] = search.snapshot()
	return _resume_go_to_reroute(colonist, route, job_id, target, passable, record_as, on_arrive, force_trim_last)

func _resume_go_to_reroute(colonist: Dictionary, route: Dictionary, job_id: String, target: Vector2i, passable: Callable,
		record_as: String = TOIL_GO_TO, on_arrive: Callable = Callable(), force_trim_last: bool = false) -> String:
	var colonist_id: String = colonist["id"]
	var search = _reroutes[colonist_id]
	if not search.is_terminal() and not bool(_route_budget.get(colonist_id, false)):
		search.resume()
		_route_budget[colonist_id] = true
	route["rerouting"] = search.snapshot()
	if not search.is_terminal():
		return ""
	if search.get_status() == RerouteType.STATUS_FOUND:
		_reroutes.erase(colonist_id)
		var new_path: Array = search.get_path()
		if new_path.size() > 1 and (force_trim_last or not bool(_passability.call(target.x, target.y, String(colonist.get("factionId", "colony")))["passable"])):
			new_path = new_path.slice(0, new_path.size() - 1)
		if new_path.size() <= 1:
			colonist["route"] = null
			if on_arrive.is_valid():
				on_arrive.call(colonist, job_id)
			else:
				start_work(colonist, job_id)
		else:
			colonist["route"] = {
				"job_id": job_id, "path": new_path, "step": 0,
				"move_ticks_remaining": _move_ticks_per_tile, "rerouting": null,
			}
		return ""
	_reroutes.erase(colonist_id)
	colonist["route"] = null
	colonist["work"] = null
	return "unreachable"

## work toil: decrements the fixed-duration timer and, once it elapses, clears
## colonist.work and returns the finished job's id (or "" while still
## working). The job kind's completion effect (what "work" actually produces
## -- a floor tile, a felled tree's wood) and the release_all toil (releasing
## the scheduler's reservation) stay with the caller: neither is part of the
## fixed toil vocabulary, and only WorldState can mutate map/ground-item state
## or the scheduler.
func advance_work_step(colonist: Dictionary) -> String:
	var work: Dictionary = colonist["work"]
	work["ticks_remaining"] -= 1
	var job_id: String = work["job_id"]
	if work["ticks_remaining"] > 0:
		if _work_progress_set.is_valid():
			var job: Dictionary = _job_lookup.call(job_id)
			_work_progress_set.call(_work_target(job), int(work["ticks_remaining"]), job_id)
		return ""
	colonist["work"] = null
	if _work_progress_clear.is_valid():
		var finished_job: Dictionary = _job_lookup.call(job_id)
		_work_progress_clear.call(_work_target(finished_job))
	_record(TOIL_WORK, "complete")
	return job_id

## pick_up toil (colonist-ai.md 3.3, issue #402): re-validates its
## precondition -- the item still exists on the ground and the colonist
## stands on or adjacent to its tile -- every call, failing with a typed
## reason rather than throwing when it no longer holds (the item was already
## taken, or the colonist never reached it), plus REASON_HANDS_FULL when no
## free hands capacity remains. On success moves
## min(count, ground_item.count, hands_free_capacity) units into the
## colonist's hands (ActorInventory.add_to_hands(), merging into an existing
## same-kind entry), decrementing the ground item's own count (removed
## entirely at 0). count < 0 (the default) requests the whole ground stack,
## letting the free-capacity clamp alone decide how much actually moves --
## the shape every existing single-unit caller and HaulGiver's own
## no-count pick_up call already rely on. A non-positive moved amount (a
## count: 0 request, or a ground item already at count 0) is a no-op:
## succeeds with count 0 without touching the ground item or hands, since
## ActorInventory's hands entries must never hold count 0 (a zero-count
## add_to_hands() call would create one).
func pick_up(colonist: Dictionary, item_id: String, count: int = -1) -> Dictionary:
	var item: Dictionary = _item_lookup.call(item_id)
	if item.is_empty():
		return {"ok": false, "reason": REASON_ITEM_NOT_FOUND}
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var item_tile := Vector2i(int(item["x"]), int(item["y"]))
	if maxi(absi(colonist_tile.x - item_tile.x), absi(colonist_tile.y - item_tile.y)) > 1:
		return {"ok": false, "reason": REASON_ITEM_OUT_OF_REACH}
	var hands_free := InventoryType.free_capacity(colonist)
	if hands_free <= 0:
		return {"ok": false, "reason": REASON_HANDS_FULL}
	var requested: int = int(item["count"]) if count < 0 else count
	var moved: int = mini(mini(requested, int(item["count"])), hands_free)
	if moved <= 0:
		return {"ok": true, "item_id": item_id, "count": 0}
	_remove_item.call(item_id, moved)
	InventoryType.add_to_hands(colonist, String(item["kind"]), moved)
	_record(TOIL_PICK_UP, "complete")
	return {"ok": true, "item_id": item_id, "count": moved}

## place toil (colonist-ai.md 3.3, issue #402): re-validates that the
## colonist is still carrying something and the destination cell is still
## free -- in bounds, passable, and unoccupied by any other colonist or
## ground item (no stockpile-zone membership yet -- t4) -- every call,
## failing with a typed reason rather than throwing when any of that no
## longer holds. On success deposits the colonist's ENTIRE current hands
## contents onto cell in one call: one fresh ground item per distinct kind
## held (ActorInventory.hands_snapshot()), each minted through the injected
## place_item callable, then clears hands entirely. A caller that needs a
## partial deposit removes the unwanted portion via the hands accessors
## first (WorldState._consume_build_cost()).
func place(colonist: Dictionary, cell: Vector2i) -> Dictionary:
	if not InventoryType.is_carrying(colonist):
		return {"ok": false, "reason": REASON_NOT_CARRYING}
	if not bool(_passability.call(cell.x, cell.y)["passable"]):
		return {"ok": false, "reason": REASON_DESTINATION_BLOCKED}
	if bool(_cell_occupied.call(cell.x, cell.y, colonist.get("id"))):
		return {"ok": false, "reason": REASON_DESTINATION_BLOCKED}
	var placed_ids: Array[String] = []
	for entry in InventoryType.hands_snapshot(colonist):
		placed_ids.append(String(_place_item.call(String(entry["kind"]), int(entry["count"]), cell.x, cell.y)))
	InventoryType.clear_hands(colonist)
	_record(TOIL_PLACE, "complete")
	return {"ok": true, "item_ids": placed_ids}

## deposit toil (issue #406, docs/decisions/038): re-validates that the
## colonist is still carrying something and the named construction site still
## exists, failing typed (REASON_NOT_CARRYING, REASON_SITE_GONE) otherwise. On
## success transfers every hands entry into site_id's own held_materials, one
## injected site_deposit() call per distinct kind held, each clamped to what
## the site still needs (never past its declared required_materials) --
## unlike place(), a kind the site does not need (or more of one than it still
## needs) is simply left in the colonist's own hands rather than minted as a
## fresh ground item, since ConstructionGiver never sizes a fetch job's pickup
## past what the site still needs in the first place; this only guards against
## a stale delivery racing a second fetch job for the same last few units.
func deposit(colonist: Dictionary, site_id: String) -> Dictionary:
	if not InventoryType.is_carrying(colonist):
		return {"ok": false, "reason": REASON_NOT_CARRYING}
	if not bool(_site_exists.call(site_id)):
		return {"ok": false, "reason": REASON_SITE_GONE}
	for entry in InventoryType.hands_snapshot(colonist):
		var accepted: int = int(_site_deposit.call(site_id, String(entry["kind"]), int(entry["count"])))
		if accepted > 0:
			InventoryType.remove_from_hands(colonist, String(entry["kind"]), accepted)
	_record(TOIL_DEPOSIT, "complete")
	return {"ok": true}

## consume toil (colonist-ai.md 3.3): a one-tick, all-or-nothing toil for a
## need job's "eat"/"drink" step -- distinct from work(ticks) because its
## effect (restore a need, remove a ground item) is not a tile-transform.
## Re-validates every call: the job must still exist, the colonist must stand
## on or adjacent to its target (mirrors pick_up's own reach check), and the
## injected source_valid() predicate must still hold (the reserved berries/
## water/bed source has not disappeared under the colonist). Never mutates
## need values or ground state itself: what "consuming" produces is entirely
## kind-specific (food decrements ground berries, water does not), so the
## caller (WorldState) applies that effect after seeing {"ok": true}, exactly
## as it already applies dig/chop/forage's own completion effect after
## advance_work_step().
func consume(colonist: Dictionary, job_id: String) -> Dictionary:
	var job: Dictionary = _job_lookup.call(job_id)
	if job.is_empty():
		return {"ok": false, "reason": REASON_SOURCE_GONE}
	var target: Vector2i = job["target"]
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	if maxi(absi(colonist_tile.x - target.x), absi(colonist_tile.y - target.y)) > 1:
		return {"ok": false, "reason": REASON_SOURCE_OUT_OF_REACH}
	if _source_valid.is_valid() and not bool(_source_valid.call(job_id)):
		return {"ok": false, "reason": REASON_SOURCE_GONE}
	_record(TOIL_CONSUME, "complete")
	return {"ok": true}

## Generic per-colonist toil-sequence advance (colonist-ai.md 3.3): drives an
## active job's colonist through job["kind"]'s own declared toils array from
## content/jobs.json -- dig/chop/forage are [reserve, go_to, work,
## release_all], haul is [reserve, go_to, pick_up, go_to, place,
## release_all]. reserve is already satisfied by the scheduler's own
## activation; release_all is absorbed into work/place's own success hook
## below rather than dispatched as its own tick, mirroring the pre-toils code
## this replaces (which never had a separate "release" step either). Nothing
## here branches on job["kind"]: which toil is current is read off the array
## and each generic completion state already on the colonist (route/work/
## carrying, see _next_toil_index()); `hooks` supplies only what WorldState
## alone may resolve -- a go_to's target/passability by position in the array
## (see is_first below), what an unreachable go_to at that position should
## do, the item/cell a pick_up/place acts on, and the map/scheduler-mutating
## effect of a finished work/place toil or a failed pick_up/place.
## `assignment_path` is the scheduler's own precomputed route to the job's
## first go_to target (colonist-ai.md 3.4's own route search, reused rather
## than searched again); any later go_to in the array (haul's second leg) has
## no such precomputed path and starts its own bounded search via
## advance_go_to() instead, exactly like a re-route.
func advance(colonist: Dictionary, job_id: String, job: Dictionary, assignment_path: Array, hooks: Dictionary) -> void:
	var toils := get_toils(String(job["kind"]))
	# issue #266 round 3 review: a destroyed active reservation must fail the
	# job before ANY route interpretation runs, including is_dropping()'s own
	# leg check below -- destroying an outstanding fetch_tool target used to
	# make ToolFetchToil.current_target() report null, which is_dropping() (run
	# first, back then) could misread as "not the fetch leg, must be a drop"
	# and let a doomed route play out a whole extra leg before this same check
	# finally ran inside the old `if TOIL_FETCH_TOOL in toils:` block below.
	if TOIL_FETCH_TOOL in toils and _tool_drop.active_tool_missing(job_id):
		_tool_drop.fail_for_destroyed_tool(colonist, job_id, job, hooks)
		return
	if _tool_drop.is_dropping(colonist, job_id, job, hooks) \
			or (_route(colonist) == null and colonist.get("work") == null and _tool_drop.needs_drop(colonist, job_id)):
		_tool_drop.advance(colonist, job_id, job, hooks)
		if _tool_drop.is_dropping(colonist, job_id, job, hooks): return # still travelling; else fall through same tick
	if TOIL_FETCH_TOOL in toils:
		if not _tool_drop.waiting_for_handover(String(colonist["id"]), job_id).is_empty(): return
		if not _tool_fetch.satisfied(colonist, job, job_id): _tool_fetch.advance(colonist, job_id, job, hooks); return
	# Whether this job's toils ever reach a work toil (dig/chop/forage's
	# [go_to, work] shape) decides how many toil-state transitions may happen
	# in one tick, purely because that is what the two shapes already did
	# before this refactor: a go_to arriving straight into a work toil chains
	# into that work toil's first tick immediately (WorldState's old
	# _advance_colonists() ran three plain "if"s, not elif/return, so a
	# freshly (re)started route or work toil was also stepped once the same
	# tick); a go_to arriving into pick_up/place (haul's shape) never chained
	# -- each tick advanced at most one toil, then returned. Reading this off
	# the declared array, not off job["kind"], is what keeps this generic.
	if "work" in toils:
		if _route(colonist) == null and colonist.get("work") == null:
			_start_current_toil(colonist, job_id, job, toils, assignment_path, hooks)
		if _route(colonist) != null:
			_continue_go_to(colonist, job_id, job, hooks)
		if colonist.get("work") != null:
			var finished_job_id := advance_work_step(colonist)
			if not finished_job_id.is_empty():
				(hooks["on_work_complete"] as Callable).call(finished_job_id)
		return
	if colonist.get("work") != null:
		var finished_job_id := advance_work_step(colonist)
		if not finished_job_id.is_empty():
			(hooks["on_work_complete"] as Callable).call(finished_job_id)
		return
	if _route(colonist) != null:
		_continue_go_to(colonist, job_id, job, hooks)
		return
	_start_current_toil(colonist, job_id, job, toils, assignment_path, hooks)

## Whether the go_to about to run is THIS job's own first (only, for a
## single-leg kind) leg. colonist.carrying is only a valid proxy for "already
## past this job's pick_up" when the job's own declared toils actually
## contain one -- a colonist carrying cargo from an unrelated interrupted
## haul/build (need/combat interrupt, ADR 009) still owes a single-leg kind
## (sleep, flee, dig, chop, forage, till, sow, incident, escape_trench) its
## one and only go_to, since none of those ever run a pick_up of their own
## (round-6 review: raw is_carrying() wrongly reported such a leg as "leg two"
## for those kinds, so _arrival_hook()/_next_toil_after_go_to() picked the
## no-op arrival and the colonist never started work on arrival).
##
## issue #403: a build job's own fetch leg may visit more than one source
## before delivering (docs/decisions/036), so "already past pick_up" can no
## longer be read off colonist.carrying alone -- a colonist that has picked up
## from one source but still needs another is still on "leg one" even though
## it is carrying something. `hooks["is_first_leg"]`, when present, decides
## this instead (WorldState._toil_is_first_leg(): true for build while its own
## on-demand fetch predicate says more sources remain worth visiting, false
## once it has decided to deliver); every other kind leaves the hook unset and
## keeps the original is_carrying()-based rule unchanged.
func _is_first_leg(toils: Array, colonist: Dictionary, job: Dictionary, hooks: Dictionary) -> bool:
	if not (TOIL_PICK_UP in toils):
		return true
	if hooks.has("is_first_leg"):
		return bool((hooks["is_first_leg"] as Callable).call(job, colonist))
	return not InventoryType.is_carrying(colonist)

## Attempts exactly the current toil once (colonist-ai.md 3.3): resolved by
## _next_toil_index() below, called only when colonist.route/work are both
## null (nothing already in flight). go_to's first occurrence (is_first: no
## pick_up/place toil has completed yet, so this is dig/chop/forage's only
## go_to, or haul's leg one -- colonist.carrying is itself the generic marker
## a pick_up toil already ran, but only for kinds that declare one; see
## _is_first_leg()) uses the scheduler's own precomputed
## assignment_path via start_assignment(); any later go_to (haul's second
## leg) has no such path and starts its own bounded search via
## _continue_go_to() -> advance_go_to() instead, exactly like a re-route.
func _start_current_toil(colonist: Dictionary, job_id: String, job: Dictionary, toils: Array, assignment_path: Array, hooks: Dictionary) -> void:
	var index := _next_toil_index(toils, colonist, job, hooks)
	if index >= toils.size():
		return
	match String(toils[index]):
		"go_to":
			var is_first: bool = _is_first_leg(toils, colonist, job, hooks)
			var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
			var use_assignment_path: bool = is_first and assignment_path.size() > 0 and assignment_path[0] == current
			# issue #403 round-2 review: a build job's own submission-time seed
			# is only a placeholder target for the scheduler's own routing/
			# scoring pass (WorldState._apply_build_submission()) -- the instant
			# it actually activates, WorldState may have already swapped it for
			# the true nearest-to-builder source
			# (_resolve_freshly_activated_build_sources()), leaving
			# `assignment_path` stale (it still leads to the placeholder, not
			# hooks["go_to_target"]'s now-current answer). `go_to_skip_
			# assignment_path`, when present and true for job, forces the same
			# fresh bounded search every later hop already uses instead of
			# walking a path toward a target this leg no longer targets. Absent
			# for every other kind (and for build's own untouched majority --
			# a single eligible source never swaps), which keeps the fast
			# precomputed-path shortcut unchanged.
			if use_assignment_path and hooks.has("go_to_skip_assignment_path"):
				use_assignment_path = not bool((hooks["go_to_skip_assignment_path"] as Callable).call(job))
			if use_assignment_path:
				start_assignment(colonist, job_id, assignment_path, _arrival_hook(toils, is_first))
			else:
				_continue_go_to(colonist, job_id, job, hooks)
		"work":
			start_work(colonist, job_id)
		"pick_up":
			var item_id: String = (hooks["item_id_for"] as Callable).call(job)
			# issue #403: build's own multi-source fetch clamps each pick_up to
			# the remainder its declared cost still needs of THIS source's kind
			# (hooks["pick_up_count_for"]), never haul's own default "take the
			# whole reachable stack" -- otherwise a single generous source could
			# fill every free hand with one kind, leaving no room for a second
			# kind the same order also needs. Absent for haul (and every other
			# pick_up-driving kind today), which keeps pick_up()'s own -1 default.
			var count := -1
			if hooks.has("pick_up_count_for"):
				count = int((hooks["pick_up_count_for"] as Callable).call(job, colonist))
			var result := pick_up(colonist, item_id, count)
			if result.get("ok", false):
				# on_pick_up_success (issue #403): lets build's own on-demand
				# planner (WorldState._toil_on_pick_up_success()) decide whether
				# to retarget this job at a further source or leave it aimed at
				# the one just visited, now that hands reflect the pickup. Every
				# other kind leaves this hook unset.
				if hooks.has("on_pick_up_success"):
					(hooks["on_pick_up_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		"place":
			var cell: Vector2i = (hooks["cell_for"] as Callable).call(job)
			var result := place(colonist, cell)
			if result.get("ok", false):
				(hooks["on_place_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		"deposit":
			var site_id: String = (hooks["site_id_for"] as Callable).call(job)
			var result := deposit(colonist, site_id)
			if result.get("ok", false):
				(hooks["on_deposit_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		"consume":
			var result := consume(colonist, job_id)
			if result.get("ok", false):
				(hooks["on_consume_success"] as Callable).call(job_id)
			else:
				(hooks["on_toil_fail"] as Callable).call(job_id, String(result["reason"]))
		_:
			pass

## Resolves which of job["kind"]'s toils (excluding "reserve", already
## satisfied by the scheduler's own activation) is next for a colonist with no
## route/work currently in flight: the first one whose own generic completion
## state does not already show it done. pick_up is done once colonist.carrying
## is set; work/place/release_all have no independent "already done" state of
## their own -- once reached they are simply the next toil to attempt. A go_to
## immediately followed by "work" (dig/chop/forage's shape) is never
## pre-empted here: it always reports current, deferring to
## start_assignment()'s own path.size() <= 1 shortcut in advance() below,
## since a `work` toil needs the colonist to actually occupy a passable
## target (not merely stand adjacent to it), which only the scheduler's
## precomputed path -- not a fixed reach test -- can decide. A go_to followed
## by anything else (haul's pick_up/place legs) is done once the colonist is
## already within reach of its own target, mirroring the explicit
## colonist-adjacency check the pre-toils haul code used for both of its legs.
func _next_toil_index(toils: Array, colonist: Dictionary, job: Dictionary, hooks: Dictionary) -> int:
	var is_first: bool = _is_first_leg(toils, colonist, job, hooks)
	for i in range(toils.size()):
		match String(toils[i]):
			"reserve", "fetch_tool":
				continue
			"go_to":
				var next_toil := String(toils[i + 1]) if i + 1 < toils.size() else ""
				if next_toil == "work":
					return i
				var target: Vector2i = (hooks["go_to_target"] as Callable).call(job, is_first)
				if _within_reach(colonist, target):
					continue
				return i
			"pick_up":
				if not is_first:
					continue
				return i
			_:
				return i
	return toils.size()

## Continues (or begins, when colonist.route is null) the go_to toil toward
## whichever target/passability `hooks` resolves for this job's current leg
## (colonist-ai.md 3.5): the same generic advance_go_to() every go_to
## occurrence shares, so a blocked next tile or a leg with no precomputed path
## at all starts the same bounded re-route search either way. "unreachable" is
## the only outcome WorldState must react to, via on_unreachable's own
## first/later distinction (resubmit vs. fail outright).
func _continue_go_to(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var toils := get_toils(String(job["kind"]))
	var is_first: bool = _is_first_leg(toils, colonist, job, hooks)
	var target: Vector2i = (hooks["go_to_target"] as Callable).call(job, is_first)
	var passable: Callable = (hooks["go_to_passable"] as Callable).call(job, is_first, target, String(colonist.get("factionId", "colony")))
	var force_trim_last := false
	if hooks.has("go_to_force_trim_last"):
		force_trim_last = bool((hooks["go_to_force_trim_last"] as Callable).call(job, is_first))
	if advance_go_to(colonist, job_id, target, passable, TOIL_GO_TO, _arrival_hook(toils, is_first), force_trim_last) == "unreachable":
		(hooks["on_unreachable"] as Callable).call(job_id, job, is_first)

## Which toil follows the go_to occurrence that is_first selects (mirrors
## _next_toil_index()'s own is_first-based occurrence selection): "pick_up"
## has not yet run when is_first is true (this go_to is leg one, or the only
## leg for a single-leg kind), so is_first true always means the FIRST go_to
## in the array; false means the first go_to AFTER a pick_up (haul/build's
## leg two). Used only to decide the arrival effect below -- a haul/build leg
## whose own next toil is "pick_up" (not "work") must never auto-start the
## work timer on arrival, the bug ADR 027 traced: advance_route_step()'s
## default on_arrive is unconditional, so a job with ANY "work" toil
## (build now has one) would otherwise start it the instant leg one reaches
## the wood, before pick_up ever runs.
func _next_toil_after_go_to(toils: Array, is_first: bool) -> String:
	var seen_pick_up := false
	for i in range(toils.size()):
		var name := String(toils[i])
		if name == TOIL_PICK_UP:
			seen_pick_up = true
			continue
		if name != TOIL_GO_TO:
			continue
		if (not seen_pick_up) == is_first:
			return String(toils[i + 1]) if i + 1 < toils.size() else ""
	return ""

## The on_arrive callable for the go_to occurrence is_first selects: the
## engine's own default (start_work, via advance_route_step()/_resume_go_to_
## reroute()'s Callable() fallback) when that occurrence truly leads into a
## work toil, otherwise an explicit no-op so arrival simply clears route and
## leaves the next toil (pick_up, for a haul/build leg one) to the ordinary
## advance()/_next_toil_index() dispatch on the following tick, exactly like
## haul's own leg one already relies on (haul has no work_ticks entry at all,
## so its own default-start_work call was always a harmless no-op; build now
## has one, so this can no longer be left implicit).
func _arrival_hook(toils: Array, is_first: bool) -> Callable:
	if _next_toil_after_go_to(toils, is_first) == TOIL_WORK:
		return Callable()
	return Callable(self, "_no_op_arrive")

## Self-records its own "complete" (matching the convention every on_arrive
## implementation follows -- start_work() records its own, tool_fetch_toil.gd's
## pickup callback records its own): only ever bound by _arrival_hook() for a
## genuine go_to occurrence (never fetch_tool's, which supplies its own
## on_arrive directly), so TOIL_GO_TO is always the correct name here.
func _no_op_arrive(_colonist: Dictionary, _job_id: String) -> void:
	_record(TOIL_GO_TO, "complete")

## Chebyshev "on or adjacent to" reach test (colonist-ai.md 3.3), shared by
## pick_up/place's own preconditions and _next_toil_index()'s go_to
## done-check above -- both mean the same "close enough to act" test.
func _within_reach(colonist: Dictionary, tile: Vector2i) -> bool:
	var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	return maxi(absi(colonist_tile.x - tile.x), absi(colonist_tile.y - tile.y)) <= 1

## Read-only counterpart of _tool_fetch.satisfied(), for callers outside
## advance() itself (WorldState._resume_paused_job()) that must decide whether
## to route/start-work directly or defer entirely to the fetch_tool toil --
## starting a route toward the job target, or the work timer, before this
## check would let a stale route/work state get reused as fetch_tool's own
## travel leg once advance() runs (round 4 review finding). See
## tool_fetch_toil.gd's needs() for why this must stay read-only.
func needs_fetch_tool(colonist: Dictionary, job: Dictionary, job_id: String) -> bool:
	return _tool_fetch.needs(colonist, job, job_id)

## advance_go_to()'s step-off rule: the first passable orthogonal neighbour
## of `tile` for `faction_id` (north, west, east, south), or `tile` itself
## when none is -- the caller then leaves the target alone and the job's own
## completion check refuses to place anything over the actor.
func _step_off_tile(tile: Vector2i, faction_id: String) -> Vector2i:
	for offset in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var next: Vector2i = tile + offset
		if bool(_passability.call(next.x, next.y, faction_id)["passable"]):
			return next
	return tile

## Read-only counterpart of _arrival_hook()/_next_toil_after_go_to(), for a
## caller outside advance() (WorldState._resume_paused_job()/
## _advance_go_to_or_resubmit(), issue #278/#303 round-1 review) that must
## decide whether resuming an interrupted job's own go_to leg may safely
## start_work() directly. True only when the go_to occurrence is_first
## selects truly leads into a work toil -- false for a haul/build leg whose
## own next toil is pick_up, so an interrupt resumed near the wood never
## starts the work timer before pick_up runs, the same bug _arrival_hook()
## prevents on the ordinary tick-driven path.
func leads_into_work(kind: String, is_first: bool) -> bool:
	return _next_toil_after_go_to(get_toils(kind), is_first) == TOIL_WORK

## Passthrough for WorldState.get_jobs()'s presentation-only overlay
## (tool_handover.gd): {} unless job_id's own fetch_tool toil is currently
## waiting on colonist_id's reserved tool to be physically dropped by a
## foreign holder (issue #266). See tool_drop_toil.gd's own doc comment.
func waiting_for_handover(colonist_id: String, job_id: String) -> Dictionary:
	return _tool_drop.waiting_for_handover(colonist_id, job_id)

## Persistence passthrough (state_codec.gd, issue #266 round 2 review): true
## while colonist's current in-flight route is a drop_tool leg, so a restored
## re-route search can reconstruct the same plain passability the drop toil
## itself always uses (no target-tile exception) instead of the ordinary
## go_to/fetch_tool policy.
func is_dropping_leg(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> bool:
	return _tool_drop.is_dropping(colonist, job_id, job, hooks)

## Persistence passthrough (state_codec.gd, issue #271 round 6/ADR 012):
## job_id -> Array[String] of tool ids _tool_fetch has already proven
## unreachable within a job's current fetch attempt, so a save/load can
## restore the exact set instead of re-trying an already-excluded candidate.
func get_fetch_tool_excluded() -> Dictionary:
	return _tool_fetch.get_excluded()

func restore_fetch_tool_excluded(excluded: Dictionary) -> void:
	_tool_fetch.restore_excluded(excluded)

func _load_job_kinds() -> Dictionary:
	var file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("jobs")) != TYPE_ARRAY:
		return {}
	var kinds: Dictionary = {}
	for entry in parsed["jobs"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			kinds[String(entry["kind"])] = entry
	return kinds
