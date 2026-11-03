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
var _tool_store
var _get_zones: Callable
var _get_tool_jobs: Callable

## priority comes from jobs.json; get_jobs is the read-only JobQueue.view_jobs_of_kinds(["haul"])
## (A5, never mutated); accepts_item_at and stockpiles_for_item are ZoneTable's (F5a filters and
## priorities); item_lookup is ItemTable's; the rest are WorldState/scheduler entry points.
## tool_store (ToolItemStore), get_zones (ZoneTable.get_zones) and get_tool_jobs (the read-only
## view_jobs_of_kinds(["haul_tool"])) haul rejected stocked tools out (F5a-b).
func _init(priority: int, get_jobs: Callable, get_items: Callable, accepts_item_at: Callable,
		submit_job: Callable, attach_item: Callable, stockpiles_for_item: Callable, item_lookup: Callable,
		is_cell_free: Callable, passability: Callable, is_cell_occupied: Callable,
		tool_store = null, get_zones: Callable = Callable(), get_tool_jobs: Callable = Callable()) -> void:
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
	var zones: Array[Dictionary] = _stockpiles_for_item.call(String(item["kind"]), TileGrid.tile_of(item))
	for zone: Dictionary in zones:
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				var cell := Vector3i(x, y, int(zone["z"]))
				if _cell_takes_item(cell):
					return cell
	return null

func _cell_takes_item(cell: Vector3i) -> bool:
	return bool(_is_cell_free.call(cell)) and bool((_passability.call(cell) as Dictionary)["passable"]) 		and not bool(_is_cell_occupied.call(cell, ""))

## F5a-b (ADR 064): a stocked tool (ToolItemStore, ADR 061) in a stockpile that no longer accepts
## its group gets, in id order, one haul_tool job targeting the first free cell find_free_haul_cell()'s
## order gives (one with no tool on it), else the nearest free tile edge-adjacent to its stockpile
## and outside every zone; with neither it waits for a later tick. The job reserves the tool, so a
## haul colonist carries it there through ToolFetchToil and ToolDropToil, keeping its id. A reserved
## tool (being fetched or already hauled) is skipped, and so is one outside every stockpile (its
## zone was removed: not stock, F2). A queued or active haul_tool job's target is not offered twice.
func _haul_rejected_tools(tick: int) -> void:
	if _tool_store == null or not _get_tool_jobs.is_valid():
		return
	var busy: Dictionary = {}
	for job in (_get_tool_jobs.call() as Array):
		if String(job["kind"]) == "haul_tool" and job["status"] in ["queued", "active"]:
			busy[job["target"]] = true
	for tool: Dictionary in (_tool_store.get_items() as Array):
		var location: Dictionary = tool["location"]
		var tool_id: String = tool["id"]
		if String(location["type"]) != "stockpile" or _tool_store.is_reserved(tool_id):
			continue
		var tile := TileGrid.tile_of(location)
		if bool(_accepts_item_at.call(tile, String(tool["kind"]))) or _home_stockpile(tile).is_empty():
			continue
		var cell: Variant = _free_tool_stockpile_cell(String(tool["kind"]), tile, busy)
		if cell == null:
			cell = _free_ground_cell_beside(tile, busy)
		if cell == null:
			continue
		var result: Dictionary = _submit_job.call(cell, _priority, tick, "haul_tool")
		if result.get("ok", false):
			_tool_store.reserve(tool_id, String(result["job_id"]))
			busy[cell] = true

func _free_tool_stockpile_cell(kind: String, from: Vector3i, busy: Dictionary) -> Variant:
	for zone: Dictionary in (_stockpiles_for_item.call(kind, from) as Array):
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				var cell := Vector3i(x, y, int(zone["z"]))
				if _cell_takes_item(cell) and not _tool_store.lies_at(cell) and not busy.has(cell):
					return cell
	return null

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
	for y in range(zy - 1, zy + int(home["height"]) + 1):
		for x in range(zx - 1, zx + int(home["width"]) + 1):
			var cell := Vector3i(x, y, tile.z)
			var beside_x := x >= zx and x < zx + int(home["width"])
			var beside_y := y >= zy and y < zy + int(home["height"])
			if beside_x == beside_y: # inside the zone, or a diagonal corner
				continue
			if zones.any(func(zone: Dictionary) -> bool: return _zone_has(zone, cell)):
				continue
			if not _cell_takes_item(cell) or _tool_store.lies_at(cell) or busy.has(cell):
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
	return int(zone["z"]) == cell.z and cell.x >= int(zone["x"]) and cell.x < int(zone["x"]) + int(zone["width"]) 		and cell.y >= int(zone["y"]) and cell.y < int(zone["y"]) + int(zone["height"])
