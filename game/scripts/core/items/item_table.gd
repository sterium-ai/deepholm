class_name ItemTable
extends RefCounted

## WorldState's stackable ground items: the item map and its id counter, the
## per-item faction map, the per-tile ground-berries counters, and the work
## find roll (ADR 026, ADR 051) with its own injected seeded RNG. Identity-bearing tools
## (axe/pick) live in tool_item_store.gd instead. Plain data, no
## scene/node/wall-clock dependency; every WorldState rule it needs arrives as
## a Callable.
##
## Invariants:
## - items[id] is exactly {id, x, y, kind, count}; a faction lives in the
##   parallel item_factions map (absent means "colony"), never inside the item,
##   because StateCodec's item encoding assumes that fixed shape.
## - Every ground-item spawn draws its id from next_item_id ("item_%d"), so an
##   id is never reused; next_item_id is persisted and hashed.
## - ground_berries is a per-tile counter keyed "%d_%d" (like WorldState's
##   _objects), not a pickable item; the key is dropped when it reaches zero.
## - state_hash() covers items, next_item_id, ground_berries and the dig-find
##   RNG (hash_into()); item_factions, ground_berries_factions and
##   pending_dig_finds are deliberately left out (ADR 047: factions decide
##   nothing during a tick).
## - ground_berries_factions is persisted with ground_berries (one factionId
##   per groundBerries entry, ADR 047), so a load restores it.
## - pending_dig_finds ({job_id, kind, x, y}; any kind with a find_table, not
##   only dig) is staged during a tick and drained by resolve_dig_finds() in
##   ascending job-id order, so the find sequence never depends on colonist
##   iteration order. Always empty between ticks; not saved.
## - roll draws exactly one randi_range() per staged find, whatever the outcome.
## - _ids_at (tile -> ground item ids, A4) is trusted only between begin_tick() and
##   end_tick(): WorldState.tick() brackets itself with them, and inside a tick every
##   item is placed through _place_ground_item() and removed through
##   _remove_ground_item(). Outside a tick (the viewer's debug scenario and tests
##   write items directly) has_item_at()/get_ground_wood() scan items as before.
##   Derived, never saved or hashed.

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
## Vector2i -> Array[String] of ground item ids there; see the class doc.
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
		var x: int = item["x"]
		var y: int = item["y"]
		_file(item_id, x, y)
	_ids_at_trusted = true

func end_tick() -> void:
	_ids_at_trusted = false
	_ids_at.clear()

func _file(item_id: String, x: int, y: int) -> void:
	var tile := Vector2i(x, y)
	if not _ids_at.has(tile):
		_ids_at[tile] = []
	(_ids_at[tile] as Array).append(item_id)

## Sum over ground "wood" items at (x, y).
func get_ground_wood(x: int, y: int) -> int:
	var total := 0
	if _ids_at_trusted:
		for item_id: String in _ids_at.get(Vector2i(x, y), []):
			var item: Dictionary = items[item_id]
			if item["kind"] == "wood":
				var count: int = item["count"]
				total += count
		return total
	for item in items.values():
		if int(item["x"]) == x and int(item["y"]) == y and String(item["kind"]) == "wood":
			total += int(item["count"])
	return total

func has_item_at(x: int, y: int) -> bool:
	if _ids_at_trusted:
		return _ids_at.has(Vector2i(x, y))
	for item in items.values():
		if int(item["x"]) == x and int(item["y"]) == y:
			return true
	return false

## ToilExecutor's item_lookup: a detached copy, {} when gone.
func item_lookup(item_id: String) -> Dictionary:
	if not items.has(item_id):
		return {}
	return (items[item_id] as Dictionary).duplicate(true)

func _remove_ground_item(item_id: String) -> void:
	if _ids_at_trusted and items.has(item_id):
		var item: Dictionary = items[item_id]
		var x: int = item["x"]
		var y: int = item["y"]
		var tile := Vector2i(x, y)
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
func _place_ground_item(item_id: String, kind: String, count: int, x: int, y: int) -> void:
	items[item_id] = {"id": item_id, "x": x, "y": y, "kind": kind, "count": count}
	item_factions[item_id] = "colony"
	if _ids_at_trusted:
		_file(item_id, x, y)

## ToilExecutor's place and every drop: one fresh item per call, off next_item_id.
func place_new_ground_item(kind: String, count: int, x: int, y: int) -> String:
	var item_id: String = "item_%d" % next_item_id
	next_item_id += 1
	_place_ground_item(item_id, kind, count, x, y)
	return item_id

## One unit of any content/items.json id: every work yield and find (ADR 051), trade goods.
func spawn_item(kind: String, x: int, y: int) -> void:
	place_new_ground_item(kind, 1, x, y)

## One unit on the tile's ground-berry counter: berries are not an item (ADR 051).
func spawn_berries_item(x: int, y: int) -> void:
	var key := _ground_berries_key(x, y)
	ground_berries[key] = int(ground_berries.get(key, 0)) + 1
	ground_berries_factions[key] = "colony"

func get_ground_berries(x: int, y: int) -> int:
	return int(ground_berries.get(_ground_berries_key(x, y), 0))

## "" when no berries are on the ground here.
func get_ground_berries_faction_id(x: int, y: int) -> String:
	return String(ground_berries_factions.get(_ground_berries_key(x, y), ""))

## eat_food's effect: one berry less at (x, y), dropping the key at zero.
func consume_ground_berry(x: int, y: int) -> void:
	var key := _ground_berries_key(x, y)
	var remaining := maxi(0, int(ground_berries.get(key, 0)) - 1)
	if remaining == 0:
		ground_berries.erase(key)
		ground_berries_factions.erase(key)
	else:
		ground_berries[key] = remaining

func _ground_berries_key(x: int, y: int) -> String:
	return "%d_%d" % [x, y]

## sow's blocked_missing_input precondition: on the ground/stockpile or in a colonist's hands.
func has_item_of_kind(kind: String) -> bool:
	for item in items.values():
		if String(item["kind"]) == kind:
			return true
	for colonist in _colonists.call():
		if InventoryType.has_kind(colonist, kind):
			return true
	return false

## sow's effect: one unit of `kind`, ground/stockpile first (id order), else a
## carried one. false when none exist, so the caller fails the job.
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

## accept_trade's stockpile draw: the lowest-id unreserved item of item_kind
## with at least quantity, inside a stockpile zone, or "".
func find_available_stockpiled_item(item_kind: String, quantity: int) -> String:
	var table: Variant = _reservation_table.call()
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var item: Dictionary = items[id]
		if String(item["kind"]) != item_kind or int(item.get("count", 1)) < quantity:
			continue
		if not _is_in_any_zone.call(int(item["x"]), int(item["y"])):
			continue
		if not table.owner(JobQueueType.ITEM_KEY_PREFIX + String(id)).is_empty():
			continue
		return String(id)
	return ""

## Takes one unit of an already-resolved stockpiled item; returns its tile.
func remove_stockpiled_item_unit(item_id: String) -> Vector2i:
	var item: Dictionary = items[item_id]
	var tile := Vector2i(int(item["x"]), int(item["y"]))
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

## Where a yield of kind lands: effects.yields.placement "adjacent" uses
## dig_item_placement(), "target" the tile itself.
func yield_placement(kind: String, x: int, y: int) -> Vector2i:
	var yields: Dictionary = work_effects(kind).get("yields", {})
	if yields.get("placement", "") == "adjacent":
		return dig_item_placement(x, y)
	return Vector2i(x, y)

## ADR 026's placement rule: the first passable, non-trench orthogonal
## neighbour in row-major order (N, W, E, S), else (x, y) itself.
func dig_item_placement(x: int, y: int) -> Vector2i:
	for neighbor in [Vector2i(x, y - 1), Vector2i(x - 1, y), Vector2i(x + 1, y), Vector2i(x, y + 1)]:
		if bool(_passability.call(neighbor.x, neighbor.y)["passable"]) and _get_tile.call(neighbor.x, neighbor.y) != ContentRegistryType.TILE_TRENCH:
			return neighbor
	return Vector2i(x, y)

## Stages one completion of a kind with a find_table for this tick's resolve_dig_finds().
func stage_dig_find(job_id: String, kind: String, x: int, y: int) -> void:
	pending_dig_finds.append({"job_id": job_id, "kind": kind, "x": x, "y": y})

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
		var x: int = entry["x"]
		var y: int = entry["y"]
		var at := yield_placement(kind, x, y)
		spawn_item(find_item, at.x, at.y)
