class_name HaulGiver
extends RefCounted

## Job-giver for haul (colonist-ai.md 3.3/3.4): one haul job per unreserved loose item and
## its stockpile destination; execution is the toil executor's ("one work engine").

var _priority: int
var _get_jobs: Callable
var _get_items: Callable
var _accepts_item_at: Callable
var _submit_job: Callable
var _attach_item: Callable
var _stockpiles_for_item: Callable
var _item_lookup: Callable
var _is_cell_free: Callable
var _passability: Callable
var _is_cell_occupied: Callable
var _tool_store: ToolItemStore
var _get_zones: Callable
var _get_tool_jobs: Callable
var _region_reachable: Callable

## priority comes from jobs.json; get_jobs is the read-only JobQueue.view_jobs_of_kinds(["haul"])
## (A5, never mutated); accepts_item_at and stockpiles_for_item are ZoneTable's (F5a filters and
## priorities); item_lookup is ItemTable's; the rest are WorldState/scheduler entry points.
## tool_store (ToolItemStore), get_zones (ZoneTable.get_zones) and get_tool_jobs (the read-only
## view_jobs_of_kinds(["haul_tool"])) haul rejected stocked tools out (F5a-b); region_reachable
## (Passability.region_reachable) keeps one from being offered a target it cannot be carried to.
func _init(priority: int, get_jobs: Callable, get_items: Callable, accepts_item_at: Callable,
		submit_job: Callable, attach_item: Callable, stockpiles_for_item: Callable, item_lookup: Callable,
		is_cell_free: Callable, passability: Callable, is_cell_occupied: Callable,
		tool_store: ToolItemStore = null, get_zones: Callable = Callable(), get_tool_jobs: Callable = Callable(),
		region_reachable: Callable = Callable()) -> void:
	_priority = priority
	_get_jobs = get_jobs
	_get_items = get_items
	_accepts_item_at = accepts_item_at
	_submit_job = submit_job
	_attach_item = attach_item
	_stockpiles_for_item = stockpiles_for_item
	_item_lookup = item_lookup
	_is_cell_free = is_cell_free
	_passability = passability
	_is_cell_occupied = is_cell_occupied
	_tool_store = tool_store
	_get_zones = get_zones
	_get_tool_jobs = get_tool_jobs
	_region_reachable = region_reachable

## Runs once per tick (TickPipeline, before the scheduler). "Unreserved" is derived from the
## job list, so a terminated job frees its item next tick. An item already in a stockpile that
## accepts its group is skipped; one in a stockpile that no longer accepts it is hauled out.
func advance(tick: int) -> void:
	_haul_rejected_tools(tick)
	var claimed: Dictionary = {}
	for job in (_get_jobs.call() as Array):
		if String(job["kind"]) == "haul" and job["status"] in ["queued", "active"]:
			claimed[String(job["item_id"])] = true
	for item in (_get_items.call() as Array):
		var item_id: String = item["id"]
		if claimed.has(item_id):
			continue
		var tile := TileGrid.tile_of(item)
		var kind: String = item["kind"]
		var stored: bool = _accepts_item_at.call(tile, kind)
		if stored:
			continue
		var result: Dictionary = _submit_job.call(tile, _priority, tick, "haul")
		if result.get("ok", false):
			_attach_item.call(String(result["job_id"]), item_id)

## First free, passable, unoccupied cell of the first stockpile in ZoneTable.stockpiles_for_item()
## order (highest priority, nearest to the item, zone id) that has one, row-major inside it on the
## zone's layer (deterministic), or null. Matches JobQueue.set_haul_destination_finder()'s Callable.
func find_free_haul_cell(item_id: String) -> Variant:
	var item: Dictionary = _item_lookup.call(item_id)
	if item.is_empty():
		return null
	var kind: String = item["kind"]
	var zones: Array[Dictionary] = _stockpiles_for_item.call(kind, TileGrid.tile_of(item))
	for zone: Dictionary in zones:
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				var cell := Vector3i(x, y, int(zone["z"]))
				if _cell_takes_item(cell):
					return cell
	return null

func _cell_takes_item(cell: Vector3i) -> bool:
	var free: bool = _is_cell_free.call(cell)
	var passable: bool = (_passability.call(cell) as Dictionary)["passable"]
	var occupied: bool = _is_cell_occupied.call(cell, "")
	return free and passable and not occupied

## F5a-b (ADR 064): a stocked tool (ToolItemStore, ADR 061) in a stockpile that no longer accepts
## its group gets, in id order, one haul_tool job targeting the first free cell find_free_haul_cell()'s
## order gives (one with no tool on it), else the nearest free tile edge-adjacent to its stockpile
## and outside every zone; with neither it waits for a later tick. The job names the tool (item_id)
## and reserves it, so a haul colonist carries it there through ToolFetchToil and ToolDropToil,
## keeping its id; a job that cannot continue (interrupt, target lost or unreachable, reservation
## gone) sets the tool down on the carrier's tile and fails (c769a48), and it is re-planned from
## there: the store marks such a tool set_down (persisted, kept until it is stocked or held again;
## a tool this giver hauled out onto the ground beside its stockpile is marked the same way),
## and a set_down ground tool outside every stockpile gets a haul_tool job only to a free cell of a
## reachable tool-accepting stockpile, never to more ground, so it stays where it lies while none
## takes it. The marker, not the current filters, makes it a candidate, so a filter change after the
## failure (A accepting tools again) never strands it; any other ground tool is left alone, as
## before F5a-b. A reserved tool (being fetched or already
## hauled), one a queued or active haul_tool job names, and a stocked one outside every stockpile
## (its zone was removed: not stock, F2) are skipped. A queued or active haul_tool job's target is not offered twice. A candidate cell in
## another passability region than the tool (walled off) is skipped and the search goes on, so a
## reachable alternative wins; with none reachable the tool waits, never offered and failed per tick.
func _haul_rejected_tools(tick: int) -> void:
	if _tool_store == null or not _get_tool_jobs.is_valid():
		return
	var busy: Dictionary = {}
	var claimed: Dictionary = {}
	for job: Dictionary in (_get_tool_jobs.call() as Array):
		var job_kind: String = job["kind"]
		if job_kind == "haul_tool" and job["status"] in ["queued", "active"]:
			busy[job["target"]] = true
			var job_item: String = job.get("item_id", "")
			claimed[job_item] = true
	for tool: Dictionary in _tool_store.get_items():
		var location: Dictionary = tool["location"]
		var tool_id: String = tool["id"]
		var tool_kind: String = tool["kind"]
		var type: String = location["type"]
		if not type in ["stockpile", "ground"] or _tool_store.is_reserved(tool_id) or claimed.has(tool_id):
			continue
		var tile := TileGrid.tile_of(location)
		var accepted: bool = _accepts_item_at.call(tile, tool_kind)
		if accepted:
			continue
		var in_stockpile := not _home_stockpile(tile).is_empty()
		if type == "stockpile" and not in_stockpile:
			continue
		var set_down: bool = tool.get("set_down", false)
		if not in_stockpile and not set_down:
			continue
		var cell: Variant = _free_tool_stockpile_cell(tool_kind, tile, busy)
		if cell == null and in_stockpile:
			cell = _free_ground_cell_beside(tile, busy)
		if cell == null:
			continue
		var result: Dictionary = _submit_job.call(cell, _priority, tick, "haul_tool")
		if result.get("ok", false):
			var job_id: String = result["job_id"]
			_attach_item.call(job_id, tool_id)
			_tool_store.reserve(tool_id, job_id)
			busy[cell] = true

func _free_tool_stockpile_cell(kind: String, from: Vector3i, busy: Dictionary) -> Variant:
	for zone: Dictionary in (_stockpiles_for_item.call(kind, from) as Array):
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		var zz: int = zone["z"]
		var zw: int = zone["width"]
		var zh: int = zone["height"]
		for y in range(zy, zy + zh):
			for x in range(zx, zx + zw):
				var cell := Vector3i(x, y, zz)
				if _cell_takes_item(cell) and not _tool_store.lies_at(cell) and not busy.has(cell) and _reaches(from, cell):
					return cell
	return null

## Whether a colonist can walk from the tool's tile to cell (same passability region); true
## when no region check is wired.
func _reaches(from: Vector3i, cell: Vector3i) -> bool:
	if not _region_reachable.is_valid():
		return true
	var reachable: bool = _region_reachable.call(from, cell)
	return reachable

## The free tile outside every zone sharing an edge with the stockpile holding tile, nearest to
## tile (Manhattan), ties by y then x; null when there is none.
func _free_ground_cell_beside(tile: Vector3i, busy: Dictionary) -> Variant:
	var zones: Array = _get_zones.call()
	var home := _home_stockpile(tile)
	if home.is_empty():
		return null
	var best: Variant = null
	var best_distance := 0
	var zx: int = home["x"]
	var zy: int = home["y"]
	var zw: int = home["width"]
	var zh: int = home["height"]
	for y in range(zy - 1, zy + zh + 1):
		for x in range(zx - 1, zx + zw + 1):
			var cell := Vector3i(x, y, tile.z)
			var beside_x := x >= zx and x < zx + zw
			var beside_y := y >= zy and y < zy + zh
			if beside_x == beside_y: # inside the zone, or a diagonal corner
				continue
			if zones.any(func(zone: Dictionary) -> bool: return _zone_has(zone, cell)):
				continue
			if not _cell_takes_item(cell) or _tool_store.lies_at(cell) or busy.has(cell) or not _reaches(tile, cell):
				continue
			var distance := TileGrid.manhattan(tile, cell)
			if best == null or distance < best_distance:
				best = cell
				best_distance = distance
	return best

## The stockpile holding tile, or {} when tile is in none.
func _home_stockpile(tile: Vector3i) -> Dictionary:
	for zone: Dictionary in (_get_zones.call() as Array):
		if not zone.has("kind") and _zone_has(zone, tile):
			return zone
	return {}

static func _zone_has(zone: Dictionary, cell: Vector3i) -> bool:
	var zx: int = zone["x"]
	var zy: int = zone["y"]
	var zz: int = zone["z"]
	var zw: int = zone["width"]
	var zh: int = zone["height"]
	return zz == cell.z and cell.x >= zx and cell.x < zx + zw and cell.y >= zy and cell.y < zy + zh
