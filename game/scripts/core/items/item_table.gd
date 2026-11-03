class_name ItemTable
extends RefCounted

## Stackable ground items (tools live in tool_item_store.gd), item factions, per-tile ground
## berries and the work find roll (ADR 026, 051) with its own seeded RNG.
## Invariants:
## - items[id] is exactly {id, x, y, z, kind, count}; factions live in item_factions (absent = "colony").
## - Ids come from next_item_id ("item_%d") and are never reused.
## - ground_berries is a TileGrid.coord_key()-keyed counter, not an item; a key is dropped at zero.
## - Hashed: items, next_item_id, ground_berries, the find RNG. Not hashed: item_factions,
##   ground_berries_factions (persisted, ADR 047), pending_dig_finds.
## - pending_dig_finds is drained in ascending job-id order, one randi_range() per find;
##   empty between ticks, never saved.
## - _ids_at is trusted only between begin_tick()/end_tick() (TickPipeline brackets the tick);
##   outside a tick lookups scan items. Derived, never saved or hashed.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

var items: Dictionary = {}
var next_item_id: int = 1
var item_factions: Dictionary = {}
var ground_berries: Dictionary = {}
var ground_berries_factions: Dictionary = {}
var pending_dig_finds: Array[Dictionary] = []
var dig_find_random: RandomNumberGenerator
## Vector3i -> Array[String] of ground item ids there; see the class doc.
var _ids_at: Dictionary = {}
var _ids_at_trusted := false

var _content: ContentRegistryType
## () -> Array[Dictionary]: WorldState's live colonist list (replaced wholesale on load).
var _colonists: Callable
var _passability: Callable
var _get_tile: Callable
var _is_in_any_zone: Callable
## () -> ReservationTable: JobQueue's current table (rebuilt on load).
var _reservation_table: Callable
var _fail_haul_jobs_referencing_item: Callable
var _cancel_haul_job_carrying_consumed_item: Callable

func _init(content: ContentRegistryType, p_dig_find_random: RandomNumberGenerator, colonists: Callable,
		passability: Callable, get_tile: Callable, is_in_any_zone: Callable, reservation_table: Callable,
		fail_haul_jobs_referencing_item: Callable, cancel_haul_job_carrying_consumed_item: Callable) -> void:
	_content = content
	dig_find_random = p_dig_find_random
	_colonists = colonists
	_passability = passability
	_get_tile = get_tile
	_is_in_any_zone = is_in_any_zone
	_reservation_table = reservation_table
	_fail_haul_jobs_referencing_item = fail_haul_jobs_referencing_item
	_cancel_haul_job_carrying_consumed_item = cancel_haul_job_carrying_consumed_item

## The save fields this table owns: "items", "groundBerries" and "digFindRng".
func encode() -> Dictionary:
	return {
		"items": StateCodec._encode_items(items, next_item_id, item_factions),
		"groundBerries": StateCodec._encode_ground_berries(ground_berries, ground_berries_factions),
		"digFindRng": {"seed": dig_find_random.seed, "state": dig_find_random.state},
	}

## digFindRng is optional on the wire: when absent, the constructor's fresh seed stays.
func decode(state: Dictionary) -> void:
	var items_data := StateCodec._decode_items(state["items"])
	items = items_data["items"]
	next_item_id = items_data["next_id"]
	item_factions = items_data["factions"]
	var berries_data := StateCodec._decode_ground_berries(state["groundBerries"])
	ground_berries = berries_data["berries"]
	ground_berries_factions = berries_data["factions"]
	if state.has("digFindRng"):
		var dig_find_rng: Dictionary = state["digFindRng"]
		dig_find_random.seed = int(dig_find_rng["seed"])
		dig_find_random.state = int(dig_find_rng["state"])

## Adds this table's state_hash() entries to snapshot (see the class doc for what is left out).
func hash_into(snapshot: Dictionary) -> void:
	snapshot["items"] = items
	snapshot["next_item_id"] = next_item_id
	snapshot["ground_berries"] = ground_berries
	snapshot["dig_find_rng"] = {"seed": dig_find_random.seed, "state": dig_find_random.state}

## Id-sorted detached copies, each with its "faction_id".
func get_items() -> Array[Dictionary]:
	var keys := items.keys()
	keys.sort()
	var copy: Array[Dictionary] = []
	for key in keys:
		var item: Dictionary = (items[key] as Dictionary).duplicate(true)
		item["faction_id"] = String(item_factions.get(key, "colony"))
		copy.append(item)
	return copy

func begin_tick() -> void:
	_ids_at.clear()
	for item: Dictionary in items.values():
		var item_id: String = item["id"]
		_file(item_id, TileGrid.tile_of(item))
	_ids_at_trusted = true

func end_tick() -> void:
	_ids_at_trusted = false
	_ids_at.clear()

func _file(item_id: String, tile: Vector3i) -> void:
	if not _ids_at.has(tile):
		_ids_at[tile] = []
	(_ids_at[tile] as Array).append(item_id)

## Sum over ground "wood" items at tile.
func get_ground_wood(tile: Vector3i) -> int:
	var total := 0
	if _ids_at_trusted:
		for item_id: String in _ids_at.get(tile, []):
			var item: Dictionary = items[item_id]
			if item["kind"] == "wood":
				var count: int = item["count"]
				total += count
		return total
	for item in items.values():
		if TileGrid.tile_of(item) == tile and String(item["kind"]) == "wood":
			total += int(item["count"])
	return total

func has_item_at(tile: Vector3i) -> bool:
	if _ids_at_trusted:
		return _ids_at.has(tile)
	for item in items.values():
		if TileGrid.tile_of(item) == tile:
			return true
	return false

## ToilExecutor's item_lookup: a detached copy, {} when gone.
func item_lookup(item_id: String) -> Dictionary:
	if not items.has(item_id):
		return {}
	return (items[item_id] as Dictionary).duplicate(true)

func _remove_ground_item(item_id: String) -> void:
	if _ids_at_trusted and items.has(item_id):
		var tile := TileGrid.tile_of(items[item_id])
		var ids: Array = _ids_at.get(tile, [])
		ids.erase(item_id)
		if ids.is_empty():
			_ids_at.erase(tile)
	items.erase(item_id)
	item_factions.erase(item_id)

## ToilExecutor's pick_up: takes count units, removing the item at 0.
func remove_ground_item_units(item_id: String, count: int) -> void:
	if not items.has(item_id):
		return
	var item: Dictionary = items[item_id]
	var remaining := int(item["count"]) - count
	if remaining > 0:
		item["count"] = remaining
	else:
		_remove_ground_item(item_id)

## Always "colony": nothing can produce an item of any other faction today.
func _place_ground_item(item_id: String, kind: String, count: int, tile: Vector3i) -> void:
	items[item_id] = {"id": item_id, "x": tile.x, "y": tile.y, "z": tile.z, "kind": kind, "count": count}
	item_factions[item_id] = "colony"
	if _ids_at_trusted:
		_file(item_id, tile)

## ToilExecutor's place and every drop: one fresh item per call, off next_item_id.
func place_new_ground_item(kind: String, count: int, tile: Vector3i) -> String:
	var item_id: String = "item_%d" % next_item_id
	next_item_id += 1
	_place_ground_item(item_id, kind, count, tile)
	return item_id

## One unit of any content/items.json id: every work yield and find (ADR 051), trade goods.
func spawn_item(kind: String, tile: Vector3i) -> void:
	place_new_ground_item(kind, 1, tile)

## One unit on the tile's ground-berry counter: berries are not an item (ADR 051).
func spawn_berries_item(tile: Vector3i) -> void:
	var key := _ground_berries_key(tile)
	ground_berries[key] = int(ground_berries.get(key, 0)) + 1
	ground_berries_factions[key] = "colony"

func get_ground_berries(tile: Vector3i) -> int:
	return int(ground_berries.get(_ground_berries_key(tile), 0))

## "" when no berries are on the ground here.
func get_ground_berries_faction_id(tile: Vector3i) -> String:
	return String(ground_berries_factions.get(_ground_berries_key(tile), ""))

## eat_food's effect: one berry less at tile, dropping the key at zero.
func consume_ground_berry(tile: Vector3i) -> void:
	var key := _ground_berries_key(tile)
	var remaining := maxi(0, int(ground_berries.get(key, 0)) - 1)
	if remaining == 0:
		ground_berries.erase(key)
		ground_berries_factions.erase(key)
	else:
		ground_berries[key] = remaining

func _ground_berries_key(tile: Vector3i) -> String:
	return TileGrid.coord_key(tile)

## sow's blocked_missing_input precondition: on the ground/stockpile or in a colonist's hands.
func has_item_of_kind(kind: String) -> bool:
	for item in items.values():
		if String(item["kind"]) == kind:
			return true
	for colonist in _colonists.call():
		if InventoryType.has_kind(colonist, kind):
			return true
	return false

## sow's effect: one ground unit first (id order), else a carried one; false when none.
func remove_one_item_of_kind(kind: String) -> bool:
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = items[id]
		if String(item["kind"]) != kind:
			continue
		var count := int(item.get("count", 1))
		if count > 1:
			item["count"] = count - 1
		else:
			_remove_ground_item(str(id))
			_fail_haul_jobs_referencing_item.call(String(id))
		return true
	return _consume_carried_item_of_kind(kind)

## Lowest colonist id first; fails that colonist's haul once its last unit of `kind` is gone.
func _consume_carried_item_of_kind(kind: String) -> bool:
	var ordered: Array[Dictionary] = _colonists.call().duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	for colonist in ordered:
		if not InventoryType.has_kind(colonist, kind):
			continue
		InventoryType.remove_from_hands(colonist, kind, 1)
		if not InventoryType.has_kind(colonist, kind):
			_cancel_haul_job_carrying_consumed_item.call(String(colonist["id"]))
		return true
	return false

## accept_trade's draw: the lowest-id unreserved stockpiled item_kind with >= quantity, or "".
func find_available_stockpiled_item(item_kind: String, quantity: int) -> String:
	var table: Variant = _reservation_table.call()
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = items[id]
		if String(item["kind"]) != item_kind or int(item.get("count", 1)) < quantity:
			continue
		if not _is_in_any_zone.call(TileGrid.tile_of(item)):
			continue
		if not table.owner(JobQueueType.ITEM_KEY_PREFIX + String(id)).is_empty():
			continue
		return String(id)
	return ""

## Takes one unit of an already-resolved stockpiled item; returns its tile.
func remove_stockpiled_item_unit(item_id: String) -> Vector3i:
	var item: Dictionary = items[item_id]
	var tile := TileGrid.tile_of(item)
	var count := int(item.get("count", 1))
	if count > 1:
		item["count"] = count - 1
	else:
		_remove_ground_item(item_id)
		_fail_haul_jobs_referencing_item.call(item_id)
	return tile

## jobs.json's effects block for kind (ADR 051), {} for a kind without one.
func work_effects(kind: String) -> Dictionary:
	var effects: Dictionary = _content.get_entry("jobs", kind).get("effects", {})
	return effects

## Where a yield lands: "adjacent" uses dig_item_placement(), "target" the tile itself.
func yield_placement(kind: String, tile: Vector3i) -> Vector3i:
	var yields: Dictionary = work_effects(kind).get("yields", {})
	if yields.get("placement", "") == "adjacent":
		return dig_item_placement(tile)
	return tile

## ADR 026: the first passable, non-trench neighbour (N, W, E, S) on tile's layer, else tile itself.
func dig_item_placement(tile: Vector3i) -> Vector3i:
	for offset: Vector3i in [Vector3i(0, -1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0)]:
		var neighbor := tile + offset
		if bool(_passability.call(neighbor)["passable"]) and _get_tile.call(neighbor) != ContentRegistryType.TILE_TRENCH:
			return neighbor
	return tile

## Stages one completion of a kind with a find_table for this tick's resolve_dig_finds().
func stage_dig_find(job_id: String, kind: String, tile: Vector3i) -> void:
	pending_dig_finds.append({"job_id": job_id, "kind": kind, "x": tile.x, "y": tile.y, "z": tile.z})

## kind's effects.yields.find_table (content/jobs.json): the rolled item id, or "" for no find.
func _roll_dig_find(kind: String) -> String:
	var yields: Dictionary = work_effects(kind).get("yields", {})
	var find_table: Array = yields.get("find_table", [])
	var roll := dig_find_random.randi_range(0, 99)
	var cumulative := 0
	for entry in find_table:
		cumulative += int(entry["weight"])
		if roll < cumulative:
			var item: Variant = entry.get("item")
			return String(item) if item != null else ""
	return ""

## Called once per tick, after colonists advance.
func resolve_dig_finds() -> void:
	if pending_dig_finds.is_empty():
		return
	var pending := pending_dig_finds
	pending_dig_finds = []
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(String(a["job_id"]).trim_prefix("job_")) < int(String(b["job_id"]).trim_prefix("job_")))
	for entry in pending:
		var kind: String = entry["kind"]
		var find_item := _roll_dig_find(kind)
		if find_item.is_empty():
			continue
		spawn_item(find_item, yield_placement(kind, TileGrid.tile_of(entry)))
