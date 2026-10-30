class_name CraftingValidator
extends SaveCheck

## Save validation for what CraftingSystem persists (F2, ADR 061, schema v7): "crafting" =
## {benches: [{x, y, targets: [{recipe, count}], orders: [{id, recipe, remaining}], bill}],
## nextOrderId}; bill is null or {recipe, orderId, held: [{item, quantity}]}. Recipe and item
## ids are checked for shape only, like every other content id in a save.

const MAX_COUNT := 999

static func _valid_crafting(value: Variant, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid crafting type")
	var crafting: Dictionary = value
	var check := _require_fields(crafting, ["benches", "nextOrderId"], "crafting")
	if not check["ok"]:
		return check
	if not _int_in(crafting["nextOrderId"], 1, 1 << 62):
		return _fail("invalid crafting nextOrderId")
	if not (crafting["benches"] is Array):
		return _fail("invalid crafting benches type")
	var benches: Array = crafting["benches"]
	var seen: Dictionary = {}
	for entry: Variant in benches:
		if not (entry is Dictionary):
			return _fail("invalid crafting bench type")
		var bench: Dictionary = entry
		var bench_check := _valid_bench(bench, map_width, map_height)
		if not bench_check["ok"]:
			return bench_check
		var x: int = bench["x"]
		var y: int = bench["y"]
		if seen.has(Vector2i(x, y)):
			return _fail("duplicate crafting bench")
		seen[Vector2i(x, y)] = true
	return {"ok": true}

static func _valid_bench(bench: Dictionary, map_width: int, map_height: int) -> Dictionary:
	var check := _require_fields(bench, ["x", "y", "targets", "orders", "bill"], "crafting bench")
	if not check["ok"]:
		return check
	if not _int_in(bench["x"], 0, map_width - 1) or not _int_in(bench["y"], 0, map_height - 1):
		return _fail("invalid crafting bench tile")
	var lists := {"targets": ["recipe", "count"], "orders": ["id", "recipe", "remaining"]}
	for list_name: String in lists:
		if not (bench[list_name] is Array):
			return _fail("invalid crafting bench %s type" % list_name)
		var fields: Array = lists[list_name]
		var count_field: String = fields[fields.size() - 1]
		var entries: Array = bench[list_name]
		for item: Variant in entries:
			if not (item is Dictionary):
				return _fail("invalid crafting bench %s entry type" % list_name)
			var entry: Dictionary = item
			var entry_check := _require_fields(entry, fields, "crafting bench %s entry" % list_name)
			if not entry_check["ok"]:
				return entry_check
			var id_ok := _is_id(entry["recipe"]) and (list_name == "targets" or _is_id(entry["id"]))
			if not id_ok or not _int_in(entry[count_field], 1, MAX_COUNT):
				return _fail("invalid crafting bench %s entry" % list_name)
	if bench["bill"] == null:
		return {"ok": true}
	if not (bench["bill"] is Dictionary):
		return _fail("invalid crafting bill type")
	var bill: Dictionary = bench["bill"]
	return _valid_bill(bill)

static func _valid_bill(bill: Dictionary) -> Dictionary:
	var check := _require_fields(bill, ["recipe", "orderId", "held"], "crafting bill")
	if not check["ok"]:
		return check
	if not _is_id(bill["recipe"]) or not (bill["orderId"] is String) or not (bill["held"] is Array):
		return _fail("invalid crafting bill")
	var held: Array = bill["held"]
	for item: Variant in held:
		if not (item is Dictionary):
			return _fail("invalid crafting bill held entry type")
		var stack: Dictionary = item
		var stack_check := _require_fields(stack, ["item", "quantity"], "crafting bill held entry")
		if not stack_check["ok"]:
			return stack_check
		if not _is_id(stack["item"]) or not _int_in(stack["quantity"], 0, MAX_COUNT):
			return _fail("invalid crafting bill held entry")
	return {"ok": true}

static func _int_in(value: Variant, low: int, high: int) -> bool:
	if not (value is int):
		return false
	var number: int = value
	return number >= low and number <= high

## SaveCheck._matches_id_pattern() on a value that must be a String first.
static func _is_id(value: Variant) -> bool:
	if not (value is String):
		return false
	var text: String = value
	return _matches_id_pattern(text)
