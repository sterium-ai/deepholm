class_name ScenarioBuilder
extends RefCounted

## Builds a fresh WorldState from one content/scenarios.json entry (A16, ADR 053): the map
## size, seed, tick rate and incident switch, then the entry's setup steps in order. A
## caller-side factory, not a WorldState module: it constructs the world and drives it only
## through apply()/tick() and the public spawn_ground_tool_item(), except for the two
## bootstrap writes documented on _run_till_plot() and _run_ground_items(). Pure and seeded:
## the same scenario, content and options always build the same state_hash().
##
## Step vocabulary (the fields each reads are ContentRegistry.SCENARIO_STEP_FIELDS):
## - needed_tools: one ground tool per job needs_tool kind, on the spawn clearing's land pool;
## - per_colonist_objects: one `kind` object per colonist, on the pool tiles past the tools;
## - object_rows: rows of objects along the spawn clearing's edges (one may hold a door);
## - dig_orders: `count` dig orders on random soil tiles, drawn from seed + seed_offset;
## - till_plot: tills the soil tile nearest a colonist by running real ticks;
## - ground_items: one stack of `count` `kind` items on the soil tile nearest a colonist.
## A step with "when": "scenario_seed" runs only when the world's seed is the scenario's own.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const NEW_GAME_SCENARIO_ID := "new_game"
const NO_TILE := Vector2i(-1, -1)

## Lazily computed values several steps share, so each one is taken at the same point of
## the build no matter which step asks first.
class BuildContext:
	var has_till_step := false
	var colonists: Array[Dictionary] = []
	var colonists_taken := false
	var till_target := NO_TILE
	var till_target_taken := false
	var till_search_radius := 0
	## How many spawn-pool tiles the needed_tools/per_colonist_objects steps so far claimed;
	## each such step takes the tiles from here on, so no two of them share a tile.
	var pool_cursor := 0

## The world scenario_id describes, built on content (the session registry). options may
## set "seed", "tick_rate" and "incidents_enabled" over the entry's own values; a scenario
## with no "seed" needs options.seed. Returns null, with an error pushed, when the scenario
## is unknown or has no seed to use.
static func build(content: ContentRegistryType, scenario_id: String, options: Dictionary = {}) -> WorldStateType:
	var scenario := content.get_entry("scenarios", scenario_id)
	if scenario.is_empty():
		push_error("ScenarioBuilder: unknown scenario '%s'" % scenario_id)
		return null
	if not options.has("seed") and not scenario.has("seed"):
		push_error("ScenarioBuilder: scenario '%s' has no seed and none was given" % scenario_id)
		return null
	var seed_value: int = options.get("seed", scenario.get("seed", 0))
	var tick_rate: int = options.get("tick_rate", scenario["tick_rate"])
	var size := WorldGeneratorType.default_new_game_size(content.document("mapgen"))
	if scenario.has("map"):
		var map: Dictionary = scenario["map"]
		var width: int = map["width"]
		var height: int = map["height"]
		size = Vector2i(width, height)
	var world := WorldStateType.new(seed_value, tick_rate, size.x, size.y, false, content)
	var incidents_enabled: bool = options.get("incidents_enabled", scenario["incidents_enabled"])
	if incidents_enabled:
		world.enable_incidents()
	var own_seed: int = scenario.get("seed", 0)
	var fixed_seed := scenario.has("seed") and seed_value == own_seed
	var steps: Array[Dictionary] = []
	for step: Dictionary in (scenario["setup"] as Array):
		if not step.has("when") or fixed_seed:
			steps.append(step)
	var context := BuildContext.new()
	for step in steps:
		if step["step"] == "till_plot":
			context.has_till_step = true
			context.till_search_radius = step["search_radius"]
	for step in steps:
		_run_step(world, content, step, context)
	return world

static func _run_step(world: WorldStateType, content: ContentRegistryType, step: Dictionary, context: BuildContext) -> void:
	var step_kind: String = step["step"]
	match step_kind:
		"needed_tools":
			_run_needed_tools(world, content, context)
		"per_colonist_objects":
			var kind: String = step["kind"]
			_run_per_colonist_objects(world, content, kind, context)
		"object_rows":
			_run_object_rows(world, step)
		"dig_orders":
			_run_dig_orders(world, step, _till_target(world, context) if context.has_till_step else NO_TILE)
		"till_plot":
			var tick_budget: int = step["tick_budget"]
			_run_till_plot(world, content, _till_target(world, context), tick_budget)
		"ground_items":
			var avoid := _till_target(world, context) if context.has_till_step else NO_TILE
			_run_ground_items(world, step, _colonists(world, context), avoid)

## The colonists as they stood when a step first asked (get_colonists() copies).
static func _colonists(world: WorldStateType, context: BuildContext) -> Array[Dictionary]:
	if not context.colonists_taken:
		context.colonists = world.get_colonists()
		context.colonists_taken = true
	return context.colonists

## The till_plot step's target, chosen once: dig_orders runs before it and must not offer
## the tile (a dig job would turn the plowed tile back into floor), ground_items after it.
static func _till_target(world: WorldStateType, context: BuildContext) -> Vector2i:
	if not context.till_target_taken:
		context.till_target = _pick_till_target(world, _colonists(world, context), context.till_search_radius)
		context.till_target_taken = true
	return context.till_target

# --- needed_tools / per_colonist_objects ----------------------------------------------------

## One ground tool per needs_tool kind, kinds sorted so the placement order never depends on
## jobs.json's field order, through spawn_ground_tool_item() and the fetch_tool toil path a
## player-placed tool uses. Tiles come from the spawn clearing's vetted land pool
## (get_spawn_clearing()'s "land_tiles", never water or a colonist's tile), from the pool
## cursor on.
static func _run_needed_tools(world: WorldStateType, content: ContentRegistryType, context: BuildContext) -> void:
	var tool_kinds := _needed_tool_kinds(content)
	var mapgen := content.document("mapgen")
	var first := context.pool_cursor
	var tiles := _claim_starting_tiles(world, mapgen, first + tool_kinds.size())
	for i in tool_kinds.size():
		var tile: Vector2i = tiles[first + i] if first + i < tiles.size() else _fallback_anchor(world, mapgen)
		world.spawn_ground_tool_item(tool_kinds[i], tile.x, tile.y)
	context.pool_cursor = first + tool_kinds.size()

## Every job kind's needs_tool, deduplicated and sorted.
static func _needed_tool_kinds(content: ContentRegistryType) -> Array[String]:
	var tool_kinds: Array[String] = []
	for job_def: Dictionary in content.list("jobs"):
		var needs_tool: String = job_def.get("needs_tool", "")
		if not needs_tool.is_empty() and not tool_kinds.has(needs_tool):
			tool_kinds.append(needs_tool)
	tool_kinds.sort()
	return tool_kinds

## Exactly one `kind` object per colonist (a New Game's beds: nothing else meets the rest
## need), placed through place_object on the pool tiles from the cursor on, past those earlier
## pool steps claimed (a New Game's tools).
static func _run_per_colonist_objects(world: WorldStateType, content: ContentRegistryType, kind: String,
		context: BuildContext) -> void:
	var colonist_count := world.get_colonists().size()
	var first := context.pool_cursor
	var tiles := _claim_starting_tiles(world, content.document("mapgen"), first + colonist_count)
	var object_tiles := tiles.slice(first, first + colonist_count)
	context.pool_cursor = first + colonist_count
	for i in object_tiles.size():
		var tile: Vector2i = object_tiles[i]
		world.apply({
			"actor": "system", "command_id": "starting_%s_%d" % [kind, i], "tick": world.get_tick(),
			"type": "place_object", "payload": {"x": tile.x, "y": tile.y, "kind": kind},
		})

## The clearing's land pool; when it is empty (a decoded world never ran place_spawn()),
## `needed` copies of mapgen.json's last-resort anchor.
static func _claim_starting_tiles(world: WorldStateType, mapgen: Dictionary, needed: int) -> Array[Vector2i]:
	var clearing := world.get_spawn_clearing()
	var pool: Array = clearing.get("land_tiles", [])
	var tiles: Array[Vector2i] = []
	for entry: Vector2i in pool:
		tiles.append(entry)
	if not tiles.is_empty() or needed <= 0:
		return tiles
	var anchor := _fallback_anchor(world, mapgen)
	for i in needed:
		tiles.append(anchor)
	return tiles

static func _fallback_anchor(world: WorldStateType, mapgen: Dictionary) -> Vector2i:
	var anchor_x: int = mapgen.get("spawn_area_x", 0)
	var anchor_y: int = mapgen.get("spawn_area_y", 0)
	return Vector2i(
		clampi(anchor_x, 0, maxi(0, world.get_map_width() - 1)),
		clampi(anchor_y, 0, maxi(0, world.get_map_height() - 1))
	)

# --- object_rows ----------------------------------------------------------------------------

## Each row starts at the clearing's left edge on the clearing's top or bottom edge plus
## `offset`, clamped into the map, and takes the first passable tiles along x (_passable_line).
## A row with a "door" turns one random tile of the row into that kind, drawn from
## seed + seed_offset. A place_object the world refuses (an occupied tile) is skipped.
static func _run_object_rows(world: WorldStateType, step: Dictionary) -> void:
	var object_random := RandomNumberGenerator.new()
	var seed_offset: int = step["seed_offset"]
	object_random.seed = world.get_seed() + seed_offset
	var clearing := world.get_spawn_clearing()
	var clearing_x: int = clearing.get("x", 0)
	var clearing_y: int = clearing.get("y", 0)
	var clearing_height: int = clearing.get("height", 0)
	var last_row := world.get_map_height() - 1
	for row: Dictionary in (step["rows"] as Array):
		var kinds: Array[String] = []
		for entry: Dictionary in (row["objects"] as Array):
			var count: int = entry["count"]
			for i in count:
				kinds.append(entry["kind"])
		var anchor_y := clearing_y + clearing_height if row["anchor"] == "clearing_bottom" else clearing_y
		var offset: int = row["offset"]
		var row_y := clampi(anchor_y + offset, 0, last_row)
		var line := _passable_line(world, clearing_x, row_y, kinds.size())
		if row.has("door") and not line.is_empty():
			kinds[object_random.randi_range(0, line.size() - 1)] = row["door"]
		var row_name: String = row["name"]
		for i in line.size():
			_place_object(world, line[i], kinds[i], "%s_%d" % [row_name, i])

## Up to `count` in-bounds tiles from (start_x, y) along x that are neither tree nor water.
static func _passable_line(world: WorldStateType, start_x: int, y: int, count: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	if y < 0 or y >= world.get_map_height():
		return tiles
	var x := start_x
	while tiles.size() < count and x < world.get_map_width():
		if world.get_tile(x, y) != WorldStateType.TILE_TREE and world.get_tile(x, y) != WorldStateType.TILE_WATER:
			tiles.append(Vector2i(x, y))
		x += 1
	return tiles

static func _place_object(world: WorldStateType, tile: Vector2i, kind: String, command_suffix: String) -> void:
	world.apply({
		"actor": "scenario",
		"command_id": "scenario_object_%s" % command_suffix,
		"tick": world.get_tick(),
		"type": "place_object",
		"payload": {"x": tile.x, "y": tile.y, "kind": kind},
	})

# --- dig_orders -----------------------------------------------------------------------------

## Every order is submitted at tick 0 from its own stream (seed + seed_offset), so the
## stream depends only on the seed, never on elapsed ticks. `excluded` is never offered.
static func _run_dig_orders(world: WorldStateType, step: Dictionary, excluded: Vector2i) -> void:
	var soil_tiles: Array[Vector2i] = []
	for y in world.get_map_height():
		for x in world.get_map_width():
			var tile := Vector2i(x, y)
			if tile != excluded and world.get_tile(x, y) == WorldStateType.TILE_SOIL:
				soil_tiles.append(tile)
	if soil_tiles.is_empty():
		return

	var order_random := RandomNumberGenerator.new()
	var seed_offset: int = step["seed_offset"]
	order_random.seed = world.get_seed() + seed_offset

	var count: int = step["count"]
	var priority: int = step["priority"]
	var order_count := mini(count, soil_tiles.size())
	for i in order_count:
		var index := order_random.randi_range(0, soil_tiles.size() - 1)
		var target := soil_tiles[index]
		soil_tiles.remove_at(index)
		world.apply({
			"actor": "scenario",
			"command_id": "scenario_dig_%d" % i,
			"tick": world.get_tick(),
			"type": "dig",
			"payload": {"x": target.x, "y": target.y, "priority": priority},
		})

# --- till_plot / ground_items ---------------------------------------------------------------

## The free soil tile nearest any colonist (colonists id-sorted, each one's rings searched
## out to `radius`), so the till job stays short enough to finish before a need interrupts.
static func _pick_till_target(world: WorldStateType, colonists: Array[Dictionary], radius: int) -> Vector2i:
	return _nearest_to_colonists(world, colonists, radius, func(x: int, y: int) -> bool:
		return world.get_tile(x, y) == WorldStateType.TILE_SOIL and world.get_object(x, y) == "")

static func _nearest_to_colonists(world: WorldStateType, colonists: Array[Dictionary], radius: int, matches: Callable) -> Vector2i:
	var sorted_colonists := colonists.duplicate()
	sorted_colonists.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_id: String = a["id"]
		var b_id: String = b["id"]
		return a_id < b_id)
	for colonist: Dictionary in sorted_colonists:
		var x: int = colonist["x"]
		var y: int = colonist["y"]
		var origin := Vector2i(x, y)
		var found := _nearest_matching_tile(world, origin, radius, matches)
		if found != NO_TILE:
			return found
	return NO_TILE

## Expanding Chebyshev rings (0, 1, 2, ...) around `origin` up to `radius`, row-major within
## each ring: the first in-bounds tile `matches` accepts, or NO_TILE.
static func _nearest_matching_tile(world: WorldStateType, origin: Vector2i, radius: int, matches: Callable) -> Vector2i:
	for ring in range(0, radius + 1):
		for y in range(origin.y - ring, origin.y + ring + 1):
			if y < 0 or y >= world.get_map_height():
				continue
			for x in range(origin.x - ring, origin.x + ring + 1):
				if x < 0 or x >= world.get_map_width():
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != ring:
					continue
				if matches.call(x, y):
					return Vector2i(x, y)
	return NO_TILE

## Plows `target` the way a player would: a HIGH-priority till order through apply() (claimed
## ahead of the NORMAL dig orders), then ticks until the tile is plowed, at most tick_budget
## ticks so an unreachable target never hangs the build. Bootstrap exception: the colonists'
## needs are topped up before each of these ticks, because a need interruption could keep
## the job from ever finishing within the budget; nothing else touches needs.
static func _run_till_plot(world: WorldStateType, content: ContentRegistryType, target: Vector2i, tick_budget: int) -> void:
	if target == NO_TILE:
		return
	var result: Dictionary = world.apply({
		"actor": "scenario",
		"command_id": "scenario_till_starting_plot",
		"tick": world.get_tick(),
		"type": "till",
		"payload": {"x": target.x, "y": target.y, "priority": JobQueueType.Priority.HIGH},
	})
	if not result.get("ok", false):
		return
	var ticks := 0
	while ticks < tick_budget and world.get_tile(target.x, target.y) != WorldStateType.TILE_PLOWED_SOIL:
		for colonist: Dictionary in world._colonists:
			var needs_component: Variant = ActorTableType.get_component(colonist, "needs", content)
			if needs_component is Dictionary:
				var needs: Dictionary = needs_component
				for kind: String in needs.keys():
					needs[kind] = 100
		world.tick()
		ticks += 1

## One stack of `count` `kind` items on the free soil tile nearest a colonist, never `avoid`.
## Bootstrap exception: no command spawns a stackable ground item, so this writes the item
## table directly, in the {id, x, y, kind, count} shape and _next_item_id bookkeeping the
## item spawn helpers use, so later spawns still get fresh ids.
static func _run_ground_items(world: WorldStateType, step: Dictionary, colonists: Array[Dictionary], avoid: Vector2i) -> void:
	var radius: int = step["search_radius"]
	var tile := _nearest_to_colonists(world, colonists, radius, func(x: int, y: int) -> bool:
		return Vector2i(x, y) != avoid and world.get_tile(x, y) == WorldStateType.TILE_SOIL and world.get_object(x, y) == "")
	if tile == NO_TILE:
		return
	var item_id := "item_%d" % world._next_item_id
	world._next_item_id += 1
	var kind: String = step["kind"]
	var count: int = step["count"]
	world._items[item_id] = {"id": item_id, "x": tile.x, "y": tile.y, "kind": kind, "count": count}
