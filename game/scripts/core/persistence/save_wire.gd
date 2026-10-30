class_name SaveWire
extends RefCounted

## The compact file encoding of a StateCodec state (A7, schema v5, save-system.md "Wire
## encoding"). StateCodec and the validators work on the plain state; SaveIO packs it right
## before the one JSON.stringify of a write and unpacks it right after the parse of a read, so
## a packed field never reaches the validators or decode().
##
## - "map": "tiles" becomes "palette" (tile ids in first-appearance order) plus "tileRuns"
##   (flat [paletteIndex, runLength, ...] in row-major order).
## - A route search ("entities[].route.rerouting", "scheduling.pending.*.route") keeps start,
##   target, status, path and its counters, and replaces "visited"/"cameFrom"/"cost"/"frontier"
##   with "box" ([x, y, width, height] around the visited tiles), "visitedBits" (a bitset over
##   the box in row-major order), "cameFromDirs" (2 bits per visited tile, in that order: the
##   direction to its parent, NEIGHBOR_OFFSETS' index), "costBytes" (one float64 per visited
##   tile, in that order) and "frontierTiles" (int32 map tile indices, in frontier order), all
##   base64. The start tile's 2 bits are written as 0 and never read.
## - "entities", "jobs" and "scheduling.waiting" (lists of same-shaped records) become a table:
##   a first element {"$keys": [sorted keys]}, then one row [values in key order] per record. A
##   record with other keys stays a plain object in place, and so does a list of fewer than
##   two records; unpack() accepts plain objects anywhere after the header.
##
## pack() never changes its argument and only packs what it can restore exactly: a route whose
## cameFrom is not one adjacent parent per visited tile (a hand-built state), or with a tile off
## the map, stays in the plain form, which unpack() leaves alone; so does a plain "tiles" list.
## Unpacked visited tiles come back in row-major order instead of discovery order: no reader
## depends on that order (state_hash() stringifies with sorted keys, see RouteSearch.restore()).

const PACKED_ROUTE_FIELDS: Array[String] = ["box", "visitedBits", "cameFromDirs", "frontierTiles"]
## The header element of a record table; never a field of a real record.
const TABLE_KEYS := "$keys"
const RECORD_LISTS: Array[String] = ["entities", "jobs"]
const PLAIN_ROUTE_FIELDS: Array[String] = ["visited", "cameFrom", "cost", "frontier"]
## Parent minus child, indexed by the 2-bit code; RouteSearch.NEIGHBOR_OFFSETS' order.
const DIRECTIONS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]

## A copy of state with the map, every route search and the record lists packed; untouched
## subtrees are shared.
static func pack(state: Dictionary) -> Dictionary:
	var packed := _pack_map_and_routes(state)
	for key in RECORD_LISTS:
		var records: Variant = packed.get(key)
		if records is Array:
			packed[key] = _pack_records(records as Array)
	var scheduling: Variant = packed.get("scheduling")
	if scheduling is Dictionary and (scheduling as Dictionary).get("waiting") is Array:
		var scheduling_copy: Dictionary = (scheduling as Dictionary).duplicate()
		var waiting: Array = scheduling_copy["waiting"]
		scheduling_copy["waiting"] = _pack_records(waiting)
		packed["scheduling"] = scheduling_copy
	return packed

static func _pack_map_and_routes(state: Dictionary) -> Dictionary:
	var packed := state.duplicate()
	var map_value: Variant = state.get("map")
	if not (map_value is Dictionary):
		return packed
	var map: Dictionary = map_value
	if not _is_size(map):
		return packed
	var width: int = map["width"]
	var height: int = map["height"]
	packed["map"] = _pack_map(map)
	var entities: Variant = state.get("entities")
	if entities is Array:
		var copies: Array = []
		for entity: Variant in entities:
			copies.append(_pack_entity_route(entity, width, height))
		packed["entities"] = copies
	var scheduling: Variant = state.get("scheduling")
	if scheduling is Dictionary and (scheduling as Dictionary).get("pending") is Dictionary:
		var scheduling_copy: Dictionary = (scheduling as Dictionary).duplicate()
		var pending: Dictionary = scheduling_copy["pending"]
		var pending_copy: Dictionary = {}
		for worker: Variant in pending:
			var request: Variant = pending[worker]
			var route: Variant = (request as Dictionary).get("route") if request is Dictionary else null
			if route is Dictionary:
				var request_copy: Dictionary = (request as Dictionary).duplicate()
				request_copy["route"] = pack_route(route as Dictionary, width, height)
				request = request_copy
			pending_copy[worker] = request
		scheduling_copy["pending"] = pending_copy
		packed["scheduling"] = scheduling_copy
	return packed

## Restores the plain form in place (state is a freshly parsed save, after SaveIO's int
## coercion). {"ok": true} or a schema_error naming the malformed field. max_world_size is the
## session's cap (SaveIO.content_rules()): a packed map larger than it is refused before any
## tile is expanded, so a hostile run length cannot make the reader allocate past it.
static func unpack(state: Dictionary, max_world_size: int) -> Dictionary:
	for key in RECORD_LISTS:
		var records := _unpack_records_at(state, key)
		if not records["ok"]:
			return records
	var scheduling: Variant = state.get("scheduling")
	if scheduling is Dictionary:
		var waiting := _unpack_records_at(scheduling as Dictionary, "waiting")
		if not waiting["ok"]:
			return waiting
	var map_value: Variant = state.get("map")
	if not (map_value is Dictionary):
		return {"ok": true}
	var map: Dictionary = map_value
	var map_check := _unpack_map(map, max_world_size)
	if not map_check["ok"] or not _is_size(map):
		return map_check
	var width: int = map["width"]
	var height: int = map["height"]
	# A plain map is not expanded, but its size bounds every packed route below: same refusal.
	if width > max_world_size or height > max_world_size:
		return _fail("map dimensions exceed the supported maximum")
	var entities: Variant = state.get("entities")
	if entities is Array:
		for entity: Variant in entities:
			var route: Variant = (entity as Dictionary).get("route") if entity is Dictionary else null
			if not (route is Dictionary) or not ((route as Dictionary).get("rerouting") is Dictionary):
				continue
			var rerouting: Dictionary = (route as Dictionary)["rerouting"]
			var unpacked := unpack_route(rerouting, width, height)
			if not unpacked["ok"]:
				return unpacked
			(route as Dictionary)["rerouting"] = unpacked["route"]
	if scheduling is Dictionary and (scheduling as Dictionary).get("pending") is Dictionary:
		var pending: Dictionary = (scheduling as Dictionary)["pending"]
		for worker: Variant in pending:
			var request: Variant = pending[worker]
			var route: Variant = (request as Dictionary).get("route") if request is Dictionary else null
			if route is Dictionary:
				var unpacked := unpack_route(route as Dictionary, width, height)
				if not unpacked["ok"]:
					return unpacked
				(request as Dictionary)["route"] = unpacked["route"]
	return {"ok": true}

# --- record tables -----------------------------------------------------------------

static func _pack_records(records: Array) -> Array:
	if records.size() < 2 or not (records[0] is Dictionary) or (records[0] as Dictionary).is_empty():
		return records
	var keys: Array = (records[0] as Dictionary).keys()
	keys.sort()
	var table: Array = [{TABLE_KEYS: keys}]
	for record: Variant in records:
		if not (record is Dictionary):
			return records # the validator rejects it; never pack what cannot come back as is
		var fields: Dictionary = record
		if fields.size() != keys.size() or not fields.has_all(keys):
			table.append(fields)
			continue
		var row: Array = []
		for key: Variant in keys:
			row.append(fields[key])
		table.append(row)
	return table

## Turns container[key]'s record table back into its records, in place; a plain list is left.
static func _unpack_records_at(container: Dictionary, key: String) -> Dictionary:
	var value: Variant = container.get(key)
	if not (value is Array) or (value as Array).is_empty():
		return {"ok": true}
	var table: Array = value
	if not (table[0] is Dictionary) or not (table[0] as Dictionary).has(TABLE_KEYS):
		return {"ok": true}
	var header: Dictionary = table[0]
	var keys_value: Variant = header[TABLE_KEYS]
	if header.size() != 1 or not (keys_value is Array) or (keys_value as Array).is_empty():
		return _fail("invalid %s table header" % key)
	var keys: Array = keys_value
	var seen: Dictionary = {}
	for name: Variant in keys:
		if not (name is String) or seen.has(name):
			return _fail("invalid %s table header" % key)
		seen[name] = true
	var records: Array = []
	for i in range(1, table.size()):
		var item: Variant = table[i]
		if item is Dictionary:
			records.append(item)
			continue
		if not (item is Array) or (item as Array).size() != keys.size():
			return _fail("invalid %s table row" % key)
		var row: Array = item
		var record: Dictionary = {}
		for k in keys.size():
			record[keys[k]] = row[k]
		records.append(record)
	container[key] = records
	return {"ok": true}

# --- map -----------------------------------------------------------------------

static func _pack_map(map: Dictionary) -> Dictionary:
	var tiles_value: Variant = map.get("tiles")
	if not (tiles_value is Array) or (tiles_value as Array).is_empty():
		return map
	var tiles: Array = tiles_value
	var palette: Array = []
	var index_of: Dictionary = {}
	var runs := PackedInt32Array()
	var current := -1
	var run := 0
	for tile: Variant in tiles:
		if not (tile is String):
			return map # the validator rejects it; never pack what cannot come back as is
		var index: int = index_of.get(tile, -1)
		if index < 0:
			index = palette.size()
			index_of[tile] = index
			palette.append(tile)
		if index == current:
			run += 1
			continue
		if run > 0:
			runs.append(current)
			runs.append(run)
		current = index
		run = 1
	runs.append(current)
	runs.append(run)
	var packed := map.duplicate()
	packed.erase("tiles")
	packed["palette"] = palette
	packed["tileRuns"] = Array(runs)
	return packed

static func _unpack_map(map: Dictionary, max_world_size: int) -> Dictionary:
	if not map.has("palette") and not map.has("tileRuns"):
		return {"ok": true}
	if map.has("tiles"):
		return _fail("map has both tiles and tileRuns")
	if not _is_size(map):
		return _fail("invalid map dimensions")
	var width: int = map["width"]
	var height: int = map["height"]
	# MapValidator's own message: the same refusal, before anything is allocated.
	if width > max_world_size or height > max_world_size:
		return _fail("map dimensions exceed the supported maximum")
	var palette_value: Variant = map.get("palette")
	var runs_value: Variant = map.get("tileRuns")
	if not (palette_value is Array) or not (runs_value is Array) or (runs_value as Array).size() % 2 != 0:
		return _fail("invalid map palette or tileRuns")
	var palette: Array = palette_value
	var runs: Array = runs_value
	# Never more than width*height (at most max_world_size squared) tiles; the validator then
	# checks the count is exact.
	var max_tiles := width * height
	var tiles: Array = []
	var i := 0
	while i < runs.size():
		if typeof(runs[i]) != TYPE_INT or typeof(runs[i + 1]) != TYPE_INT:
			return _fail("invalid map tileRuns entry")
		var index: int = runs[i]
		var length: int = runs[i + 1]
		if index < 0 or index >= palette.size() or length < 1:
			return _fail("invalid map tileRuns entry")
		# Compared as a remainder: tiles.size() + length could overflow int64 on a hostile length.
		if length > max_tiles - tiles.size():
			return _fail("map tiles length does not match width*height")
		var tile: Variant = palette[index]
		for _r in length:
			tiles.append(tile)
		i += 2
	map.erase("palette")
	map.erase("tileRuns")
	map["tiles"] = tiles
	return {"ok": true}

# --- route searches ----------------------------------------------------------------

static func _pack_entity_route(entity: Variant, width: int, height: int) -> Variant:
	if not (entity is Dictionary) or not ((entity as Dictionary).get("route") is Dictionary):
		return entity
	var route: Dictionary = (entity as Dictionary)["route"]
	var rerouting: Variant = route.get("rerouting")
	if not (rerouting is Dictionary):
		return entity
	var entity_copy: Dictionary = (entity as Dictionary).duplicate()
	var route_copy := route.duplicate()
	route_copy["rerouting"] = pack_route(rerouting as Dictionary, width, height)
	entity_copy["route"] = route_copy
	return entity_copy

## The packed form of one plain route state, or route itself when it cannot be packed exactly.
static func pack_route(route: Dictionary, width: int, height: int) -> Dictionary:
	var start := _tile_of(route.get("start"), width, height)
	var visited_value: Variant = _tiles_of(route.get("visited"), width, height)
	var frontier_value: Variant = _tiles_of(route.get("frontier"), width, height)
	var came_from_value: Variant = route.get("cameFrom")
	if start.x < 0 or visited_value == null or frontier_value == null or not (came_from_value is Array):
		return route
	var visited: Array[Vector2i] = visited_value
	var frontier: Array[Vector2i] = frontier_value
	var parents := _parents_of(came_from_value as Array, width, height)
	if parents.is_empty() and not (came_from_value as Array).is_empty():
		return route
	var order: Dictionary = {}
	for tile in visited:
		if order.has(tile) or (tile != start and not parents.has(tile)):
			return route
		order[tile] = true
	# Every parent link belongs to a visited tile other than start.
	if parents.size() != visited.size() - (1 if order.has(start) else 0):
		return route
	var cost_of: Variant = _costs_of(route.get("cost"), visited)
	if route.has("cost") and cost_of == null:
		return route
	var packed := route.duplicate()
	for key in PLAIN_ROUTE_FIELDS:
		packed.erase(key)
	var box := _box_of(visited)
	var sorted := visited.duplicate()
	sorted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var bits := PackedByteArray()
	bits.resize((box.z * box.w + 7) >> 3)
	var dirs := PackedByteArray()
	dirs.resize((sorted.size() + 3) >> 2)
	var cost_values := PackedFloat64Array()
	for i in sorted.size():
		var tile: Vector2i = sorted[i]
		var bit := (tile.y - box.y) * box.z + (tile.x - box.x)
		bits[bit >> 3] |= 1 << (bit & 7)
		if tile != start:
			var parent: Vector2i = parents[tile]
			dirs[i >> 2] |= DIRECTIONS.find(parent - tile) << ((i & 3) * 2)
		if cost_of != null:
			var cost: float = (cost_of as Dictionary)[tile]
			cost_values.append(cost)
	var frontier_indices := PackedInt32Array()
	for tile in frontier:
		frontier_indices.append(TileGrid.flat_index(tile.x, tile.y, width))
	packed["box"] = [box.x, box.y, box.z, box.w]
	packed["visitedBits"] = Marshalls.raw_to_base64(bits)
	packed["cameFromDirs"] = Marshalls.raw_to_base64(dirs)
	if cost_of != null:
		packed["costBytes"] = Marshalls.raw_to_base64(cost_values.to_byte_array())
	packed["frontierTiles"] = Marshalls.raw_to_base64(frontier_indices.to_byte_array())
	return packed

## child -> parent for a cameFrom list of distinct children, each next to its parent on the
## map; {} when any pair is not.
static func _parents_of(pairs: Array, width: int, height: int) -> Dictionary:
	var parents: Dictionary = {}
	for pair: Variant in pairs:
		if not (pair is Dictionary):
			return {}
		var child := _tile_of((pair as Dictionary).get("child"), width, height)
		var parent := _tile_of((pair as Dictionary).get("parent"), width, height)
		if child.x < 0 or parent.x < 0 or parents.has(child) or not DIRECTIONS.has(parent - child):
			return {}
		parents[child] = parent
	return parents

## tile -> cost for a "cost" list matching visited, or null when absent or malformed.
static func _costs_of(value: Variant, visited: Array[Vector2i]) -> Variant:
	if not (value is Array) or (value as Array).size() != visited.size():
		return null
	var costs: Array = value
	var cost_of: Dictionary = {}
	for i in visited.size():
		var cost: Variant = costs[i]
		if typeof(cost) != TYPE_FLOAT and typeof(cost) != TYPE_INT:
			return null
		var number: float = cost
		cost_of[visited[i]] = number
	return cost_of

## {"ok": true, "route": <plain route>}; a plain route comes back unchanged.
static func unpack_route(route: Dictionary, width: int, height: int) -> Dictionary:
	if not route.has("visitedBits") and not route.has("box"):
		return {"ok": true, "route": route}
	for key: String in PACKED_ROUTE_FIELDS:
		if not route.has(key):
			return _fail("missing packed route field '%s'" % key)
	for key in PLAIN_ROUTE_FIELDS:
		if route.has(key):
			return _fail("packed route also has '%s'" % key)
	var start := _tile_of(route.get("start"), width, height)
	var box := _box_from(route["box"], width, height)
	if start.x < 0 or box.x < 0:
		return _fail("invalid packed route start or box")
	var bits := _bytes_of(route["visitedBits"])
	var dirs := _bytes_of(route["cameFromDirs"])
	var frontier_bytes := _bytes_of(route["frontierTiles"])
	if bits.size() != (box.z * box.w + 7) >> 3 or frontier_bytes.size() % 4 != 0:
		return _fail("invalid packed route visitedBits or frontierTiles")
	var visited: Array = []
	var came_from: Array = []
	var bit := 0
	for y in range(box.y, box.y + box.w):
		for x in range(box.x, box.x + box.z):
			var set_bit := bits[bit >> 3] & (1 << (bit & 7)) != 0
			bit += 1
			if not set_bit:
				continue
			var tile := Vector2i(x, y)
			var i := visited.size()
			visited.append(_encode_tile(tile))
			if tile == start:
				continue
			if (i >> 2) >= dirs.size():
				return _fail("invalid packed route cameFromDirs")
			var parent: Vector2i = tile + DIRECTIONS[(dirs[i >> 2] >> ((i & 3) * 2)) & 3]
			came_from.append({"child": _encode_tile(tile), "parent": _encode_tile(parent)})
	if dirs.size() != (visited.size() + 3) >> 2:
		return _fail("invalid packed route cameFromDirs")
	var plain := route.duplicate()
	for key: String in PACKED_ROUTE_FIELDS + ["costBytes"]:
		plain.erase(key)
	plain["visited"] = visited
	plain["cameFrom"] = came_from
	if route.has("costBytes"):
		var cost_bytes := _bytes_of(route["costBytes"])
		if cost_bytes.size() != visited.size() * 8:
			return _fail("invalid packed route costBytes")
		plain["cost"] = Array(cost_bytes.to_float64_array())
	var frontier: Array = []
	for index in frontier_bytes.to_int32_array():
		if index < 0 or index >= width * height:
			return _fail("invalid packed route frontier tile")
		frontier.append(_encode_tile(TileGrid.flat_coord(index, width)))
	plain["frontier"] = frontier
	return {"ok": true, "route": plain}

# --- helpers -----------------------------------------------------------------------

## (x, y, width, height) of the box around tiles; zero for none.
static func _box_of(tiles: Array[Vector2i]) -> Vector4i:
	if tiles.is_empty():
		return Vector4i.ZERO
	var low := tiles[0]
	var high := tiles[0]
	for tile in tiles:
		low = Vector2i(mini(low.x, tile.x), mini(low.y, tile.y))
		high = Vector2i(maxi(high.x, tile.x), maxi(high.y, tile.y))
	return Vector4i(low.x, low.y, high.x - low.x + 1, high.y - low.y + 1)

## A packed "box" as (x, y, width, height), or x = -1 unless it is four ints inside the map.
## Every part is checked against the map as an int64 before the Vector4i (int32) narrowing,
## and each sum is of two values already bounded by the map, so neither can wrap.
static func _box_from(value: Variant, width: int, height: int) -> Vector4i:
	if not (value is Array) or (value as Array).size() != 4:
		return Vector4i(-1, 0, 0, 0)
	var parts: Array[int] = []
	var limits: Array[int] = [width, height, width, height]
	for i in 4:
		var part: Variant = (value as Array)[i]
		if typeof(part) != TYPE_INT:
			return Vector4i(-1, 0, 0, 0)
		var number: int = part
		if number < 0 or number > limits[i]:
			return Vector4i(-1, 0, 0, 0)
		parts.append(number)
	if parts[0] + parts[2] > width or parts[1] + parts[3] > height:
		return Vector4i(-1, 0, 0, 0)
	return Vector4i(parts[0], parts[1], parts[2], parts[3])

## Vector2i(-1, -1) unless value is an {x, y} int tile on the map.
static func _tile_of(value: Variant, width: int, height: int) -> Vector2i:
	if not (value is Dictionary) or (value as Dictionary).size() != 2:
		return Vector2i(-1, -1)
	var tile: Dictionary = value
	if typeof(tile.get("x")) != TYPE_INT or typeof(tile.get("y")) != TYPE_INT:
		return Vector2i(-1, -1)
	var x: int = tile["x"]
	var y: int = tile["y"]
	if x < 0 or y < 0 or x >= width or y >= height:
		return Vector2i(-1, -1)
	return Vector2i(x, y)

## The tiles of an {x, y} list, or null when one is not a tile on the map.
static func _tiles_of(value: Variant, width: int, height: int) -> Variant:
	if not (value is Array):
		return null
	var tiles: Array[Vector2i] = []
	for item: Variant in value:
		var tile := _tile_of(item, width, height)
		if tile.x < 0:
			return null
		tiles.append(tile)
	return tiles

static func _bytes_of(value: Variant) -> PackedByteArray:
	if not (value is String):
		return PackedByteArray()
	var text: String = value
	return Marshalls.base64_to_raw(text)

static func _encode_tile(tile: Vector2i) -> Dictionary:
	return {"x": tile.x, "y": tile.y}

static func _is_size(map: Dictionary) -> bool:
	if typeof(map.get("width")) != TYPE_INT or typeof(map.get("height")) != TYPE_INT:
		return false
	var width: int = map["width"]
	var height: int = map["height"]
	return width >= 1 and height >= 1

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "code": "schema_error", "message": message}
