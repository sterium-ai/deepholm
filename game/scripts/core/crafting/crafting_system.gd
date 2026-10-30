class_name CraftingSystem
extends RefCounted

## Workbench production (F2, ADR 061): per bench, "keep N in stock" targets, a queue of
## orders and at most one bill (the recipe being crafted now, with the inputs hauled to it).
## CraftGiver decides which jobs exist; this module owns the state and its rules.
## Invariants:
## - A bench is the origin tile of a colony object whose kind is some recipe's "bench"; its
##   record exists only once a command configured it and is dropped when the object is gone.
## - A bill's held inputs never exceed the recipe's; craft_fetch deposits through
##   deposit_into() (clamped), craft_work completion spends them all and places the outputs
##   on one free tile next to the bench.
## - A bill is chosen only when every input is available in a stockpile, so a recipe whose
##   inputs are missing never takes the bench; a bill that can no longer be met is abandoned,
##   its held inputs dropped next to the bench (they are hauled back like any loose item).
## - A crafted tool travels as a stackable item until it lies in a stockpile, where
##   stock_tools() turns it into an identity-bearing tool item (ToolItemStore).
## - "crafting" is persisted, and hashed once any bench was configured; no RNG draw here.

const RecipeBookType = preload("res://scripts/core/crafting/recipe_book.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")

## craft_fetch's deposit target id: BILL_PREFIX + "x,y" of the bench origin.
const BILL_PREFIX := "bench:"
const COMMAND_TYPES: Array[String] = ["craft_set_target", "craft_add_order", "craft_cancel_order"]
const MAX_COUNT := 999
const NO_BENCH := Vector2i(-1, -1)

var recipes: RecipeBookType
## "x,y" -> {origin: Vector2i, targets: {recipe: int}, orders: [{id, recipe, remaining}],
## bill: {} or {recipe, order_id, held: [{item, quantity}]}}.
var _benches: Dictionary = {}
var _next_order_id: int = 1

var _object_table: ObjectTableType
var _item_table: ItemTableType
var _tile_grid: TileGridType
var _passability: PassabilityType
var _scheduler: AssignmentType
var _is_in_any_zone: Callable
## (kind) -> bool, (kind, x, y) -> String, (item_id, x, y) -> bool, () -> Array[Dictionary].
var _is_tool_kind: Callable
var _spawn_ground_tool: Callable
var _set_tool_stockpile: Callable
var _get_tool_items: Callable
## () -> Array[Dictionary]: the live actors, whose hands count as stock.
var _get_colonists: Callable
var _finish_job: Callable
var _drop_carried_haul_item: Callable
## ConstructionSystem's deposit callables: any id without BILL_PREFIX is a construction site.
var _site_exists: Callable
var _site_deposit: Callable

func _init(recipe_list: Array, object_table: ObjectTableType, item_table: ItemTableType, tile_grid: TileGridType,
		passability: PassabilityType, scheduler: AssignmentType, is_in_any_zone: Callable, is_tool_kind: Callable,
		spawn_ground_tool: Callable, set_tool_stockpile: Callable, get_tool_items: Callable, get_colonists: Callable,
		finish_job: Callable, drop_carried_haul_item: Callable, site_exists: Callable, site_deposit: Callable) -> void:
	recipes = RecipeBookType.new(recipe_list)
	_object_table = object_table
	_item_table = item_table
	_tile_grid = tile_grid
	_passability = passability
	_scheduler = scheduler
	_is_in_any_zone = is_in_any_zone
	_is_tool_kind = is_tool_kind
	_spawn_ground_tool = spawn_ground_tool
	_set_tool_stockpile = set_tool_stockpile
	_get_tool_items = get_tool_items
	_get_colonists = get_colonists
	_finish_job = finish_job
	_drop_carried_haul_item = drop_carried_haul_item
	_site_exists = site_exists
	_site_deposit = site_deposit

## TileGrid.comma_key(): the same "x,y" format as a construction site's origin (L1).
static func bench_key(origin: Vector2i) -> String:
	return TileGridType.comma_key(origin.x, origin.y)

# --- persistence -----------------------------------------------------------

## The save field this module owns ("crafting"), benches sorted by key.
func encode() -> Dictionary:
	var benches: Array = []
	for key: String in bench_keys():
		var record: Dictionary = _benches[key]
		var target_counts: Dictionary = record["targets"]
		var recipe_ids: Array = target_counts.keys()
		recipe_ids.sort()
		var targets: Array = []
		for recipe_id: String in recipe_ids:
			var count: int = target_counts[recipe_id]
			targets.append({"recipe": recipe_id, "count": count})
		var bill: Dictionary = record["bill"]
		var wire_bill: Variant = null
		if not bill.is_empty():
			var held: Array = bill["held"]
			wire_bill = {"recipe": bill["recipe"], "orderId": bill["order_id"], "held": held.duplicate(true)}
		var origin: Vector2i = record["origin"]
		var orders: Array = record["orders"]
		benches.append({"x": origin.x, "y": origin.y, "targets": targets, "orders": orders.duplicate(true), "bill": wire_bill})
	return {"crafting": {"benches": benches, "nextOrderId": _next_order_id}}

## Absent "crafting" (no bench configured) restores an empty table.
func decode(state: Dictionary) -> void:
	_benches = {}
	var crafting: Dictionary = state.get("crafting", {})
	_next_order_id = crafting.get("nextOrderId", 1)
	var entries: Array = crafting.get("benches", [])
	for entry: Dictionary in entries:
		var x: int = entry["x"]
		var y: int = entry["y"]
		var targets: Dictionary = {}
		for target: Dictionary in (entry["targets"] as Array):
			var recipe_id: String = target["recipe"]
			var count: int = target["count"]
			targets[recipe_id] = count
		var orders: Array = []
		for order: Dictionary in (entry["orders"] as Array):
			var remaining_count: int = order["remaining"]
			orders.append({"id": order["id"], "recipe": order["recipe"], "remaining": remaining_count})
		var bill: Dictionary = {}
		if entry["bill"] is Dictionary:
			var wire_bill: Dictionary = entry["bill"]
			var held: Array = []
			for stack: Dictionary in (wire_bill["held"] as Array):
				var quantity: int = stack["quantity"]
				held.append({"item": stack["item"], "quantity": quantity})
			bill = {"recipe": wire_bill["recipe"], "order_id": wire_bill["orderId"], "held": held}
		_benches[bench_key(Vector2i(x, y))] = {"origin": Vector2i(x, y), "targets": targets, "orders": orders, "bill": bill}

## Only once a bench is configured, so a world without crafting keeps its pre-F2 hash.
func hash_into(snapshot: Dictionary) -> void:
	if not _benches.is_empty() or _next_order_id != 1:
		snapshot["crafting"] = encode()["crafting"]

# --- benches ----------------------------------------------------------------

## The bench origin covering (x, y), or NO_BENCH when no colony bench is there.
func bench_origin_at(x: int, y: int) -> Vector2i:
	var origin := _object_table.object_origin_at(x, y)
	var kind := _object_table.get_object(origin.x, origin.y)
	if not recipes.is_bench_kind(kind) or _object_table.get_object_faction_id(origin.x, origin.y) != "colony":
		return NO_BENCH
	return origin

## Every colony bench on the map with its configuration, sorted by tile (the viewer's panel).
func get_benches() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	for object: Dictionary in _object_table.get_objects():
		var x: int = object["x"]
		var y: int = object["y"]
		var origin := bench_origin_at(x, y)
		if origin == NO_BENCH or seen.has(origin):
			continue
		seen[origin] = true
		var record: Dictionary = _benches.get(bench_key(origin), {})
		var targets: Dictionary = record.get("targets", {})
		var orders: Array = record.get("orders", [])
		var bill: Dictionary = record.get("bill", {})
		out.append({"x": origin.x, "y": origin.y, "kind": _object_table.get_object(origin.x, origin.y),
			"targets": targets.duplicate(), "orders": orders.duplicate(true), "bill": bill.duplicate(true)})
	return out

## Configured bench keys, sorted: CraftGiver's iteration order.
func bench_keys() -> Array[String]:
	var keys: Array[String] = []
	for key: String in _benches.keys():
		keys.append(key)
	keys.sort()
	return keys

## The live record for key, or {}.
func bench_record(key: String) -> Dictionary:
	return _benches.get(key, {})

## The bill of the bench at origin, or {} (no record, no bill).
func _bill_at(origin: Vector2i) -> Dictionary:
	var record: Dictionary = _benches.get(bench_key(origin), {})
	return record.get("bill", {})

## "" when the bench at origin has no bill.
func bill_id_at(origin: Vector2i) -> String:
	return "" if _bill_at(origin).is_empty() else BILL_PREFIX + bench_key(origin)

## How many more units of item the bill at origin still needs (0 without a bill).
func remaining(origin: Vector2i, item: String) -> int:
	var bill := _bill_at(origin)
	return 0 if bill.is_empty() else _bill_remaining(bill, item)

func _bill_remaining(bill: Dictionary, item: String) -> int:
	var need := 0
	var recipe_id: String = bill["recipe"]
	for stack: Dictionary in recipes.inputs(recipe_id):
		if stack["item"] == item:
			var quantity: int = stack["quantity"]
			need += quantity
	for stack: Dictionary in (bill["held"] as Array):
		if stack["item"] == item:
			var held: int = stack["quantity"]
			need -= held
	return maxi(0, need)

func bill_met(bill: Dictionary) -> bool:
	var recipe_id: String = bill["recipe"]
	for stack: Dictionary in recipes.inputs(recipe_id):
		var item: String = stack["item"]
		if _bill_remaining(bill, item) > 0:
			return false
	return true

# --- deposit (ToilExecutor's site_exists/site_deposit, shared with construction) --------

func deposit_target_exists(id: String) -> bool:
	if not id.begins_with(BILL_PREFIX):
		return _site_exists.call(id)
	var record: Dictionary = _benches.get(id.substr(BILL_PREFIX.length()), {})
	return not record.is_empty() and not (record["bill"] as Dictionary).is_empty()

## Accepts up to count units, clamped to what the bill still needs; returns the amount taken.
func deposit_into(id: String, item: String, count: int) -> int:
	if not id.begins_with(BILL_PREFIX):
		return _site_deposit.call(id, item, count)
	if not deposit_target_exists(id) or count <= 0:
		return 0
	var record: Dictionary = _benches[id.substr(BILL_PREFIX.length())]
	var bill: Dictionary = record["bill"]
	var accepted := mini(count, _bill_remaining(bill, item))
	if accepted <= 0:
		return 0
	for stack: Dictionary in (bill["held"] as Array):
		if stack["item"] == item:
			var held: int = stack["quantity"]
			stack["quantity"] = held + accepted
	return accepted

## A craft_fetch pick_up takes only what its bill still needs, minus what hands hold; -1
## (the whole stack) when it has no bill any more (the deposit then fails the job).
func pick_up_count(job: Dictionary, colonist: Dictionary) -> int:
	var item_id: String = job.get("item_id", "")
	var item := _item_table.item_lookup(item_id)
	var site: Variant = job.get("site")
	if item.is_empty() or not (site is Vector2i):
		return -1
	var kind: String = item["kind"]
	var bench_tile: Vector2i = site
	var need := remaining(bench_tile, kind) - InventoryType.count_of_kind(colonist, kind)
	return need if need > 0 else -1

# --- stock -------------------------------------------------------------------

## The colony's stock of kind: loose items (stockpiled or waiting to be hauled), what hands
## carry, and tools not held by anyone. A tool taken by a colonist leaves the stock.
func stock_count(kind: String) -> int:
	var total := 0
	for item: Dictionary in _item_table.items.values():
		if item["kind"] == kind:
			var count: int = item["count"]
			total += count
	for actor: Dictionary in (_get_colonists.call() as Array):
		total += InventoryType.count_of_kind(actor, kind)
	var is_tool: bool = _is_tool_kind.call(kind)
	if is_tool:
		for tool_item: Dictionary in (_get_tool_items.call() as Array):
			var location: Dictionary = tool_item["location"]
			if tool_item["kind"] == kind and location.get("type", "") != "held":
				total += 1
	return total

## Stockpiled units of kind no job holds or is about to fetch (committed: item ids named by
## a live site_fetch/craft_fetch job), the pool a bill and its fetches draw from.
func available(kind: String, committed: Dictionary) -> int:
	var total := 0
	for item: Dictionary in _item_table.items.values():
		if item["kind"] == kind and _is_free_source(item, committed):
			var count: int = item["count"]
			total += count
	return total

## The lowest-id free stockpiled item of kind, or {}.
func source_of(kind: String, committed: Dictionary) -> Dictionary:
	for id: String in _sorted_item_ids():
		var item: Dictionary = _item_table.items[id]
		if item["kind"] == kind and _is_free_source(item, committed):
			return item
	return {}

func _sorted_item_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in _item_table.items.keys():
		ids.append(id)
	ids.sort()
	return ids

func _is_free_source(item: Dictionary, committed: Dictionary) -> bool:
	var id: String = item["id"]
	var x: int = item["x"]
	var y: int = item["y"]
	var in_zone: bool = _is_in_any_zone.call(x, y)
	if committed.has(id) or not in_zone:
		return false
	return _scheduler.queue.get_reservation_table().owner(JobQueueType.ITEM_KEY_PREFIX + id).is_empty()

## Stockpiled loose tools become ToolItemStore items on their cell, one per unit.
func stock_tools() -> void:
	for id: String in _sorted_item_ids():
		var item: Dictionary = _item_table.items[id]
		var kind: String = item["kind"]
		var is_tool: bool = _is_tool_kind.call(kind)
		if not is_tool or not _is_free_source(item, {}):
			continue
		var x: int = item["x"]
		var y: int = item["y"]
		var count: int = item["count"]
		for _unit in count:
			var tool_id: String = _spawn_ground_tool.call(kind, x, y)
			_set_tool_stockpile.call(tool_id, x, y)
		_item_table.remove_ground_item_units(id, count)

# --- bills ---------------------------------------------------------------------

## One tick of bill bookkeeping (CraftGiver, before it submits jobs): forgets benches whose
## object is gone, abandons bills that can no longer be met, then gives each idle bench the
## first order, else the first target below stock, whose inputs are all available.
## fetching: bench key -> true while a craft_fetch for it is queued/active.
func update_bills(committed: Dictionary, fetching: Dictionary) -> void:
	for key: String in bench_keys():
		var record: Dictionary = _benches[key]
		var origin: Vector2i = record["origin"]
		if bench_origin_at(origin.x, origin.y) != origin:
			cancel_bench_jobs(origin)
			_drop_held(record)
			_benches.erase(key)
	var claimed: Dictionary = {}
	for key: String in bench_keys():
		var bill: Dictionary = _benches[key]["bill"]
		if bill.is_empty() or bill_met(bill):
			continue
		var recipe_id: String = bill["recipe"]
		for stack: Dictionary in recipes.inputs(recipe_id):
			var item: String = stack["item"]
			var already: int = claimed.get(item, 0)
			claimed[item] = already + _bill_remaining(bill, item)
	for key: String in bench_keys():
		var record: Dictionary = _benches[key]
		var bill: Dictionary = record["bill"]
		if not bill.is_empty() and not bill_met(bill) and not fetching.has(key) and not _inputs_available(bill, committed, claimed, true):
			_drop_held(record)
			record["bill"] = {}
		if (record["bill"] as Dictionary).is_empty():
			_choose_bill(record, committed, claimed)

## The first order, else the first target (recipe id order) below stock, whose inputs are all
## available becomes the bench's bill; its inputs join `claimed`.
func _choose_bill(record: Dictionary, committed: Dictionary, claimed: Dictionary) -> void:
	var candidates: Array[Dictionary] = []
	for order: Dictionary in (record["orders"] as Array):
		candidates.append({"recipe": order["recipe"], "order_id": order["id"]})
	var targets: Dictionary = record["targets"]
	for recipe_id: String in recipes.ids():
		var target: int = targets.get(recipe_id, 0)
		if target > _stock_of_outputs(recipe_id):
			candidates.append({"recipe": recipe_id, "order_id": ""})
	for candidate: Dictionary in candidates:
		var recipe_id: String = candidate["recipe"]
		var held: Array = []
		for stack: Dictionary in recipes.inputs(recipe_id):
			held.append({"item": stack["item"], "quantity": 0})
		var bill := {"recipe": recipe_id, "order_id": candidate["order_id"], "held": held}
		if not _inputs_available(bill, committed, claimed, false):
			continue
		record["bill"] = bill
		for stack: Dictionary in recipes.inputs(recipe_id):
			var item: String = stack["item"]
			var quantity: int = stack["quantity"]
			var already: int = claimed.get(item, 0)
			claimed[item] = already + quantity
		return

## A target counts the recipe's first output (the thing it is named for).
func _stock_of_outputs(recipe_id: String) -> int:
	var first: Dictionary = recipes.outputs(recipe_id)[0]
	var item: String = first["item"]
	return stock_count(item)

## own_claim: the bill's own remaining needs are already in claimed (an existing bill).
func _inputs_available(bill: Dictionary, committed: Dictionary, claimed: Dictionary, own_claim: bool) -> bool:
	var recipe_id: String = bill["recipe"]
	for stack: Dictionary in recipes.inputs(recipe_id):
		var item: String = stack["item"]
		var need := _bill_remaining(bill, item)
		var all_claims: int = claimed.get(item, 0)
		var others := all_claims - (need if own_claim else 0)
		if need > 0 and available(item, committed) - others < need:
			return false
	return true

## craft_work's completion at origin: spends the held inputs, places the outputs on one
## free tile next to the bench, counts the order down and clears the bill.
func complete_craft(origin: Vector2i) -> void:
	var record: Dictionary = _benches.get(bench_key(origin), {})
	var bill := _bill_at(origin)
	if bill.is_empty() or not bill_met(bill):
		return
	var at := _tile_next_to(origin, {})
	var recipe_id: String = bill["recipe"]
	for stack: Dictionary in recipes.outputs(recipe_id):
		var item: String = stack["item"]
		var quantity: int = stack["quantity"]
		_item_table.place_new_ground_item(item, quantity, at.x, at.y)
	var orders: Array = record["orders"]
	for i in orders.size():
		var order: Dictionary = orders[i]
		if order["id"] == bill["order_id"]:
			var left: int = order["remaining"]
			order["remaining"] = left - 1
			if left - 1 <= 0:
				orders.remove_at(i)
			break
	record["bill"] = {}

## Ends every live craft job of the bench at origin (a carried load is dropped first).
func cancel_bench_jobs(origin: Vector2i) -> void:
	for job: Dictionary in _scheduler.queue.view_jobs_of_kinds(["craft_fetch", "craft_work"]):
		var job_id: String = job["id"]
		var is_fetch: bool = job["kind"] == "craft_fetch"
		var bench_tile: Variant = job.get("site") if is_fetch else job["target"]
		if not (job["status"] in ["queued", "active"]) or bench_tile != origin:
			continue
		if is_fetch:
			_drop_carried_haul_item.call(job_id)
		_finish_job.call(job_id, "cancel_job")

## Held inputs go back to the ground next to the bench, one tile per kind where possible.
func _drop_held(record: Dictionary) -> void:
	var bill: Dictionary = record["bill"]
	if bill.is_empty():
		return
	var used: Dictionary = {}
	for stack: Dictionary in (bill["held"] as Array):
		var quantity: int = stack["quantity"]
		if quantity <= 0:
			continue
		var origin: Vector2i = record["origin"]
		var item: String = stack["item"]
		var at := _tile_next_to(origin, used)
		used[at] = true
		_item_table.place_new_ground_item(item, quantity, at.x, at.y)
		stack["quantity"] = 0

## The first passable, non-trench, item-free tile next to the bench footprint (N/W/E/S per
## footprint tile, row-major) not in exclude; else the first passable neighbour, else origin.
func _tile_next_to(origin: Vector2i, exclude: Dictionary) -> Vector2i:
	var kind := _object_table.get_object(origin.x, origin.y)
	var orientation: String = _object_table.object_orientation.get(_tile_grid.index_of(origin), "")
	var footprint: Array[Vector2i] = [origin]
	if not kind.is_empty():
		footprint = _object_table.object_footprint_tiles(kind, origin, orientation)
	var fallback := NO_BENCH
	for tile in footprint:
		for offset: Vector2i in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			var neighbour := tile + offset
			if footprint.has(neighbour) or exclude.has(neighbour) or not _tile_grid.in_bounds(neighbour.x, neighbour.y):
				continue
			var passable: bool = _passability.passability(neighbour.x, neighbour.y)["passable"]
			if not passable or _tile_grid.get_tile(neighbour.x, neighbour.y) == "trench":
				continue
			if fallback == NO_BENCH:
				fallback = neighbour
			if not _item_table.has_item_at(neighbour.x, neighbour.y):
				return neighbour
	return fallback if fallback != NO_BENCH else origin

# --- commands --------------------------------------------------------------------

## The read-only rule shared by apply() and preview(): {} or {reason, params}.
## craft_set_target {x, y, recipe, count 0..MAX_COUNT}, craft_add_order {x, y, recipe, count
## 1..MAX_COUNT}, craft_cancel_order {x, y, order_id}; (x, y) is any tile of the bench.
func check_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var type: String = command["type"]
	var fields: Array[String] = ["x", "y", "recipe", "count"]
	if type == "craft_cancel_order":
		fields = ["x", "y", "order_id"]
	for key: Variant in payload.keys():
		if not fields.has(key):
			return {"reason": "invalid_payload", "params": {"detail": "craft_extra_field", "field": str(key)}}
	for key: String in fields:
		var want := TYPE_INT if key in ["x", "y", "count"] else TYPE_STRING
		if typeof(payload.get(key)) != want:
			return {"reason": "invalid_payload", "params": {"detail": "craft_payload"}}
	var x: int = payload["x"]
	var y: int = payload["y"]
	var origin := bench_origin_at(x, y)
	if origin == NO_BENCH:
		return {"reason": "invalid_target", "params": {"detail": "not_a_workbench"}}
	if type == "craft_cancel_order":
		var record: Dictionary = _benches.get(bench_key(origin), {})
		for order: Dictionary in (record.get("orders", []) as Array):
			if order["id"] == payload["order_id"]:
				return {}
		return {"reason": "invalid_target", "params": {"detail": "unknown_craft_order"}}
	var recipe_id: String = payload["recipe"]
	if not recipes.has(recipe_id):
		return {"reason": "invalid_payload", "params": {"detail": "unknown_recipe", "recipe": recipe_id}}
	if recipes.bench_of(recipe_id) != _object_table.get_object(origin.x, origin.y):
		return {"reason": "invalid_target", "params": {"detail": "recipe_wrong_bench", "recipe": recipe_id}}
	var count: int = payload["count"]
	if count < (0 if type == "craft_set_target" else 1) or count > MAX_COUNT:
		return {"reason": "invalid_payload", "params": {"detail": "craft_count_out_of_range"}}
	return {}

## Applies a command check_command() accepted; returns the extra applied fields
## (craft_add_order: "order_id").
func apply_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var x: int = payload["x"]
	var y: int = payload["y"]
	var origin := bench_origin_at(x, y)
	var key := bench_key(origin)
	if not _benches.has(key):
		_benches[key] = {"origin": origin, "targets": {}, "orders": [], "bill": {}}
	var record: Dictionary = _benches[key]
	var type: String = command["type"]
	if type == "craft_set_target":
		var targets: Dictionary = record["targets"]
		var count: int = payload["count"]
		if count == 0:
			targets.erase(payload["recipe"])
		else:
			targets[payload["recipe"]] = count
	elif type == "craft_add_order":
		var order_id := "order_%d" % _next_order_id
		_next_order_id += 1
		(record["orders"] as Array).append({"id": order_id, "recipe": payload["recipe"], "remaining": payload["count"]})
		return {"order_id": order_id}
	else:
		var order_id: String = payload["order_id"]
		var orders: Array = record["orders"]
		for i in orders.size():
			var order: Dictionary = orders[i]
			if order["id"] == order_id:
				orders.remove_at(i)
				break
		var bill: Dictionary = record["bill"]
		if bill.get("order_id", "") == order_id:
			cancel_bench_jobs(origin)
			_drop_held(record)
			record["bill"] = {}
	return {}
