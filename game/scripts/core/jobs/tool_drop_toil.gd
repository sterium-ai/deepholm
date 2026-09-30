class_name ToolDropToil
extends RefCounted

## drop_tool toil, the tool handover wait, and the destroyed-mid-job failure
## path (ADR 013, extending the fetch_tool toil). Extracted from
## toil_executor.gd to keep that file within its line budget
## (docs/architecture/core-budgets.json) and injected the same way
## tool_fetch_toil.gd is; it has no dependency on WorldState or on Godot
## scene/node state.
##
## Holds three things:
##  - the holder side of the handover: a colonist whose held tool is reserved
##    by a job other than its own runs this toil -- dropping in place, or at
##    the nearest free stockpile cell within TOOL_DROP_RADIUS
##    (HaulGiver.find_free_haul_cell()'s pattern, reused read-only through
##    injected callables; haul_giver.gd itself is unchanged) -- before its own
##    next dispatched job's first toil;
##  - the requester side of the same handover: waiting_for_handover() lets
##    ToilExecutor.advance() skip fetch_tool's travel/pickup while the tool it
##    reserved is still physically held by someone else, so it is only picked
##    up once actually dropped. No persisted "waiting" state is needed:
##    dropping (tool_item_store.gd's set_ground()/set_stockpile()) releases
##    whatever reservation the tool carries, including the requester's, so the
##    requester's next advance() finds itself unreserved and re-reserves and
##    fetches the dropped item like any other free candidate
##    (docs/decisions/013-tool-toils.md, "Requester side: the handover wait");
##  - the destroyed-mid-job failure path: a job's reserved tool (held, or
##    still being travelled to) that disappears from tracking fails the job's
##    current toil, releases every reservation the job held, and re-queues it
##    through the same on_no_tool_found -> backoff path as an ordinary
##    fetch_tool failure.

const TOIL_DROP_TOOL := "drop_tool"
const TOIL_FETCH_TOOL := "fetch_tool"
const TOIL_WORK := "work"
const TOIL_GO_TO := "go_to"
## Small radius a foreign-reserved-tool detour prefers over dropping in place.
const TOOL_DROP_RADIUS := 5

var _job_kinds: Dictionary
var _work_ticks: Dictionary
var _passability: Callable
var _cell_occupied: Callable
var _is_cell_free: Callable
var _get_zones: Callable
var _tool_reservation_of: Callable
var _tool_item_lookup: Callable
var _tool_reservation_table: Callable
var _release_all_tool_reservations: Callable
var _drop_tool_ground: Callable
var _drop_tool_stockpile: Callable
var _work_progress_clear: Callable
var _reroutes: Dictionary
var _advance_go_to: Callable
var _record: Callable
var _get_colonists: Callable
var _get_tool_items: Callable
## Live colonist lookup by id (mutating the returned Dictionary mutates
## WorldState._colonists in place, mirroring world_state.gd's own private
## _find_colonist() -- injected the same way ToolItemStore._find_colonist
## already is). Used only by fail_for_destroyed_tool()'s own
## _reconcile_stale_holders() below to fix a foreign colonist's held_tool,
## never job_id's own colonist (already reachable as an ordinary parameter).
var _find_colonist: Callable
## WorldState.get_assignments() (colonist_id -> {"job_id", ...}), for
## _reconcile_stale_holders() below to find a foreign holder's own active job
## id -- the only way to look up that job's own drop-leg marker (_get_active_
## item below is keyed by job_id, not colonist_id).
var _get_assignments: Callable
## Drop-leg identity marker: per job, the item id of the tool that job's
## colonist is dropping right now. It is the only thing is_dropping() below
## consults to identify an in-flight leg. Set when advance() below starts
## driving a job's drop and cleared as soon as that drop finishes or fails --
## never re-derived from the ReservationTable, colonist.held_tool's kind, or
## any other signal that can change for reasons unrelated to which leg is in
## flight (a foreign job being cancelled, or a different job's reservation on
## a different tool being released by its holder's drop). Reservation-derived
## signals decide whether to start a drop (needs_drop() below) but cannot
## reliably say whether a route already in flight is one.
## The marker is persisted on JobQueue's live active-job record through
## JobQueue.set_active_item_marker()/get_active_item_marker()
## (_set_active_item/_get_active_item below), reusing the job's
## blockingJobId field, which already round-trips through state_codec.gd, so
## no schema change or restore-time reconstruction is needed. It must not be
## itemId: that is a haul job's cargo identity (see job_queue.gd's
## set_active_item_marker() doc comment), and drop_tool runs for any active
## job kind, haul included. See docs/decisions/013-tool-toils.md,
## "Drop-leg identity marker".
var _set_active_item: Callable
var _get_active_item: Callable

func _init(job_kinds: Dictionary, work_ticks: Dictionary, passability: Callable, cell_occupied: Callable,
		is_cell_free: Callable, get_zones: Callable, tool_reservation_of: Callable, tool_item_lookup: Callable,
		tool_reservation_table: Callable, release_all_tool_reservations: Callable, drop_tool_ground: Callable,
		drop_tool_stockpile: Callable, work_progress_clear: Callable, reroutes: Dictionary,
		advance_go_to: Callable, record: Callable, get_colonists: Callable,
		get_tool_items: Callable, set_active_item: Callable, get_active_item: Callable,
		find_colonist: Callable, get_assignments: Callable) -> void:
	_job_kinds = job_kinds
	_work_ticks = work_ticks
	_passability = passability
	_cell_occupied = cell_occupied
	_is_cell_free = is_cell_free
	_get_zones = get_zones
	_tool_reservation_of = tool_reservation_of
	_tool_item_lookup = tool_item_lookup
	_tool_reservation_table = tool_reservation_table
	_release_all_tool_reservations = release_all_tool_reservations
	_drop_tool_ground = drop_tool_ground
	_drop_tool_stockpile = drop_tool_stockpile
	_work_progress_clear = work_progress_clear
	_reroutes = reroutes
	_advance_go_to = advance_go_to
	_record = record
	_get_colonists = get_colonists
	_get_tool_items = get_tool_items
	_set_active_item = set_active_item
	_get_active_item = get_active_item
	_find_colonist = find_colonist
	_get_assignments = get_assignments

## True once colonist's held tool is reserved by a job other than job_id: the
## decision to start a fresh drop (ToilExecutor.advance()'s own idle-gated
## check). A genuine decision, not a leg-continuation check -- see
## is_dropping() below for why those must never be conflated.
func needs_drop(colonist: Dictionary, job_id: String) -> bool:
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty():
		return false
	var owner := String(_tool_reservation_of.call(held_id))
	return not owner.is_empty() and owner != job_id

## job_id's own currently reserved tool item id, read straight off the
## ReservationTable (not off the live tool-item list, unlike tool_fetch_toil.
## gd's own _reserved_tool_for()): a destroyed item is erased from tracking
## but its dangling reservation is not, so this is the only lookup that still
## finds it -- exactly what active_tool_missing() below needs.
func _reserved_item_id_for(job_id: String) -> String:
	var owners: Dictionary = (_tool_reservation_table.call() as ReservationTable).snapshot()
	for item_id in owners:
		if String(owners[item_id]) == job_id:
			return String(item_id)
	return ""

## Every item id job_id currently reserves, for active_tool_missing()/
## fail_for_destroyed_tool() below to check exhaustively. A job can hold more
## than one reservation at once (fetch_tool's candidate plus a stale one, or
## two acquired in different ticks), and iteration order over the
## ReservationTable's Dictionary snapshot is not guaranteed to surface the
## destroyed one first.
func _reserved_item_ids_for(job_id: String) -> Array[String]:
	var owners: Dictionary = (_tool_reservation_table.call() as ReservationTable).snapshot()
	var ids: Array[String] = []
	for item_id in owners:
		if String(owners[item_id]) == job_id:
			ids.append(String(item_id))
	return ids

## True while job_id's own reserved tool is currently physically held by a
## different, currently busy colonist who has not yet dropped it (a tool
## fetch_tool found held but unreserved): {} when not waiting, else {"item_id",
## "holder_colonist_id"}. Both ToilExecutor.advance()'s own wait gate and
## WorldState.get_jobs()'s presentation overlay (tool_handover.gd) call this
## same method, so the two can never disagree about when a job is actually
## waiting. The holder must be busy (route or work in flight, i.e. actually
## has a job the scheduler is driving through advance()) for the wait to make
## sense: a fully idle holder (no assignment at all, e.g. a tool taken away
## while its own job was interrupted and reassigned elsewhere) never gets a
## "next dispatched job" to insert a drop_tool toil into, so waiting on it
## would stall the requester forever -- direct pickup is correct there.
func waiting_for_handover(colonist_id: String, job_id: String) -> Dictionary:
	var item_id := _reserved_item_id_for(job_id)
	if item_id.is_empty():
		return {}
	var item: Dictionary = _tool_item_lookup.call(item_id)
	if item.is_empty():
		return {}
	var location: Dictionary = item.get("location", {})
	if String(location.get("type", "")) != "held":
		return {}
	var holder := String(location.get("colonist_id", ""))
	if holder.is_empty() or holder == colonist_id or not _colonist_busy(holder):
		return {}
	return {"item_id": item_id, "holder_colonist_id": holder}

func _colonist_busy(colonist_id: String) -> bool:
	for c in (_get_colonists.call() as Array):
		if String(c["id"]) == colonist_id:
			return c.get("route") != null or c.get("work") != null
	return false

## True once any item id job_id actively reserves no longer exists (destroyed/
## removed) -- whether already held, or still only reserved while fetch_tool
## is travelling toward it. Checks every reservation the job holds, not just
## the first the ReservationTable snapshot happens to yield, since a surviving
## reservation must never mask the destruction of a different one.
func active_tool_missing(job_id: String) -> bool:
	for item_id in _reserved_item_ids_for(job_id):
		if _tool_item_lookup.call(item_id).is_empty():
			return true
	return false

## Destroyed-mid-job failure: fails the actual current toil
## (work, drop_tool, fetch_tool, or the return-to-target go_to -- never
## hardcoded), releases every reservation job_id held (not just the one
## destroyed item), reconciles any colonist whose held_tool still names a
## destroyed id (not just job_id's own colonist -- see
## _reconcile_stale_holders() below), clears its execution state, and
## re-queues through the same on_no_tool_found -> backoff path as an ordinary
## fetch_tool failure. colonist.held_tool is cleared only when the destroyed
## item is the one actually held: a colonist can be holding a leftover, unrelated tool
## (its own item location still correctly says "held" by it) while this job's
## reservation on a different, not-yet-picked-up tool is the one that was
## destroyed -- clearing held_tool unconditionally would desync it from that
## surviving item's own location.
func fail_for_destroyed_tool(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var destroyed_ids: Array[String] = []
	for item_id in _reserved_item_ids_for(job_id):
		if _tool_item_lookup.call(item_id).is_empty():
			destroyed_ids.append(item_id)
	var current_toil := _toil_in_flight(colonist, job_id, job, hooks, destroyed_ids)
	_release_all_tool_reservations.call(job_id)
	_reconcile_stale_holders(destroyed_ids)
	colonist["route"] = null; colonist["work"] = null; _reroutes.erase(colonist["id"]); _set_active_item.call(job_id, "")
	if _work_progress_clear.is_valid() and _work_ticks.has(String(job["kind"])):
		_work_progress_clear.call(job["target"])
	var kind := String(_job_kinds.get(String(job["kind"]), {}).get("needs_tool", ""))
	(hooks["on_no_tool_found"] as Callable).call(job_id, String(colonist["id"]), kind)
	_record.call(current_toil, "failed:tool_destroyed")

## Which toil is actually driving colonist's execution right now, read off
## execution state rather than whether a tool is still needed:
## _tool_fetch.needs() necessarily reports "needs a replacement" the instant
## the destroyed item is gone, which would misclassify the return-to-target
## go_to leg (colonist already picked the tool up before it was destroyed) as
## fetch_tool. is_dropping() identifies a concurrent drop_tool leg for a
## different held tool (job_id's own drop leg for a leftover foreign-reserved
## tool, independent of whichever other reservation was destroyed); it reads
## the marker/route/held_tool triple, never a reservation snapshot. Once
## work/dropping are ruled out, whether the destroyed id is the one colonist
## physically held decides fetch vs. return: held it already (go_to, the
## return leg) vs. never got that far (fetch_tool, still travelling toward it).
func _toil_in_flight(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary, destroyed_ids: Array[String]) -> String:
	if colonist.get("work") != null:
		return TOIL_WORK
	if is_dropping(colonist, job_id, job, hooks):
		return TOIL_DROP_TOOL
	if String(colonist.get("held_tool", "")) in destroyed_ids:
		return TOIL_GO_TO
	return TOIL_FETCH_TOOL

## Clears held_tool for the actual physical holder of any of destroyed_ids,
## whoever that is -- releasing job_id's own reservations
## above only fixes the requester's bookkeeping, never a foreign colonist's
## hand. tool_item_store.gd's set_ground()/set_held() both refuse
## to touch a colonist's held_tool once the item itself is gone (there is no
## location left for their own _clear_holder() to read), so a stale reference
## here is otherwise permanent: a foreign holder's own later attempt to pick
## up a genuinely new tool keeps failing set_held()'s "already holds a
## different item" guard forever. Also unwinds the holder's own in-flight
## drop_tool leg for the same vanished item (destruction mid-drop):
## is_dropping()'s marker check would otherwise desync the
## instant held_tool clears below (the marker still names the destroyed id,
## held_tool no longer does), leaving a dangling route for the holder's own
## job to misread as its ordinary go_to leg next tick and arrive at the wrong
## tile.
func _reconcile_stale_holders(destroyed_ids: Array[String]) -> void:
	if destroyed_ids.is_empty():
		return
	var assignments: Dictionary = _get_assignments.call()
	for c in (_get_colonists.call() as Array):
		var held := String(c.get("held_tool", ""))
		if not (held in destroyed_ids):
			continue
		var holder_id := String(c["id"])
		var live: Dictionary = _find_colonist.call(holder_id)
		if live.is_empty():
			continue
		var holder_job_id := String((assignments.get(holder_id, {}) as Dictionary).get("job_id", ""))
		if not holder_job_id.is_empty() and live.get("route") != null and String(_get_active_item.call(holder_job_id)) == held:
			live["route"] = null
			_reroutes.erase(holder_id)
			_set_active_item.call(holder_job_id, "")
		live["held_tool"] = ""

## True while a drop leg begun by advance() below is still in flight for
## job_id: purely whether JobQueue's live active-job record still marks job_id
## as dropping the same item the colonist physically holds -- never
## re-derived from the route's destination or from any reservation-table
## signal. Deriving it from reservation state is unsound in both directions:
## cancelling the foreign job that triggered an in-flight drop can make
## needs_drop() false while the holder's next job needs a different tool, so
## a still-walking drop leg would look like a fetch; and a requester's fetch
## route can briefly lose its reservation (the holder dropped the target
## tool) while the requester also holds an unrelated foreign-reserved tool, so
## a fetch leg would look like a drop. Which toil drives a route is a fact
## about the route's history (which toil started it), which the persisted
## marker records directly (see the class-level field doc comment above and
## docs/decisions/013-tool-toils.md, "Drop-leg identity marker").
func is_dropping(colonist: Dictionary, job_id: String, _job: Dictionary = {}, _hooks: Dictionary = {}) -> bool:
	var marked := String(_get_active_item.call(job_id))
	return colonist.get("route") != null and not marked.is_empty() \
		and marked == String(colonist.get("held_tool", ""))

func _route_effective_target(route: Dictionary) -> Vector2i:
	var rerouting = route.get("rerouting")
	if rerouting != null:
		return rerouting["target"]
	var path: Array = route["path"]
	return path[path.size() - 1]

## drop_tool toil: drop in place, or walk to the nearest free
## stockpile cell within TOOL_DROP_RADIUS. The destination is computed once,
## when starting (colonist.route == null); a continuing leg reuses the
## route's own already-chosen destination (_route_effective_target()) rather
## than recomputing the nearest cell every tick, so a cell that stops being
## free partway through travel can never silently retarget the colonist
## elsewhere (ADR 013, "Destination consistency"). Arrival instead
## revalidates the same destination and falls back to dropping in place if it
## is no longer free, or no longer belongs to any stockpile zone (a zone
## removed mid-travel must not leave location.type "stockpile" recorded for a
## cell that is no longer inside one). The JobQueue-persisted marker
## (_set_active_item) is set at entry (idempotent across every call while
## this leg is in flight) and cleared at every completion path, per
## is_dropping()'s own doc comment above.
func advance(colonist: Dictionary, job_id: String, job: Dictionary, hooks: Dictionary) -> void:
	var held_id := String(colonist.get("held_tool", ""))
	if held_id.is_empty():
		colonist["route"] = null; _reroutes.erase(colonist["id"]); _set_active_item.call(job_id, ""); return
	_set_active_item.call(job_id, held_id)
	var route = colonist.get("route")
	var target: Vector2i
	if route == null:
		var from := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var cell = _find_drop_cell(from)
		if cell == null:
			_drop_tool_ground.call(held_id, from.x, from.y)
			_record.call(TOIL_DROP_TOOL, "complete")
			_set_active_item.call(job_id, "")
			return
		target = cell
	else:
		target = _route_effective_target(route)
	var passable := func(tile: Vector2i) -> float: return float(_passability.call(tile.x, tile.y)["cost"])
	var on_arrive := func(_c: Dictionary, _jid: String) -> void:
		if _cell_still_free(target, colonist.get("id")) and _in_any_zone(target):
			_drop_tool_stockpile.call(held_id, target.x, target.y)
		else:
			_drop_tool_ground.call(held_id, int(colonist["x"]), int(colonist["y"]))
		_record.call(TOIL_DROP_TOOL, "complete")
		_set_active_item.call(job_id, "")
	if _advance_go_to.call(colonist, job_id, target, passable, TOIL_DROP_TOOL, on_arrive) == "unreachable":
		_drop_tool_ground.call(held_id, int(colonist["x"]), int(colonist["y"]))
		_set_active_item.call(job_id, "")

## Also excludes a cell already occupied by a ground/
## stockpiled tool item -- WorldState's general cell_occupied callable only
## checks colonists and stackable items, never tool items, so a drop could
## otherwise land on top of an existing axe/pick. Checked locally via the
## injected get_tool_items (also used read-only by ToolFetchToil) rather than
## widening the shared cell_occupied callable in the line-budget-capped
## world_state.gd.
func _cell_still_free(cell: Vector2i, excluding_colonist_id) -> bool:
	if not (bool(_is_cell_free.call(cell.x, cell.y)) and bool(_passability.call(cell.x, cell.y)["passable"]) \
			and not bool(_cell_occupied.call(cell.x, cell.y, excluding_colonist_id))):
		return false
	for tool_item in (_get_tool_items.call() as Array):
		var location: Dictionary = tool_item.get("location", {})
		if String(location.get("type", "")) in ["ground", "stockpile"] \
				and int(location.get("x", -1)) == cell.x and int(location.get("y", -1)) == cell.y:
			return false
	return true

func _in_any_zone(cell: Vector2i) -> bool:
	for zone in (_get_zones.call() as Array):
		if cell.x >= int(zone["x"]) and cell.x < int(zone["x"]) + int(zone["width"]) \
				and cell.y >= int(zone["y"]) and cell.y < int(zone["y"]) + int(zone["height"]):
			return true
	return false

## Nearest free stockpile cell within TOOL_DROP_RADIUS (HaulGiver.
## find_free_haul_cell()'s checks, reused read-only). The job's own
## ordinary/fetch target and its neighbourhood are not excluded: since
## is_dropping() above identifies an in-flight leg purely from the persisted
## marker, a drop cell coinciding with (or next to) that target is not
## ambiguous with any other leg, so every qualifying free cell in radius is
## eligible, including the exact target tile itself when passable and free.
func _find_drop_cell(from: Vector2i) -> Variant:
	if not _get_zones.is_valid():
		return null
	var best = null
	var best_distance := -1
	for zone in (_get_zones.call() as Array):
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				var cell := Vector2i(x, y)
				if not _cell_still_free(cell, ""):
					continue
				var distance: int = absi(x - from.x) + absi(y - from.y)
				if distance > TOOL_DROP_RADIUS:
					continue
				if best == null or distance < best_distance or (distance == best_distance and (x < best.x or (x == best.x and y < best.y))):
					best = cell; best_distance = distance
	return best
