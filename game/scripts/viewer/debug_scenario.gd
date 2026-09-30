extends RefCounted

## Builds the seeded debug-viewer scenario: a fresh WorldState plus its
## deterministic stream of dig orders. Never reads player/UI input, so a
## scene (boot.tscn) and a scene-free caller (test_viewer_hash.gd) that both
## call build() with the same arguments end up with identical state.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

const SCENARIO_SEED := 20260915
const TICK_RATE := 10
const DIG_ORDER_COUNT := 24
## Distinct from SCENARIO_SEED so order selection draws from its own stream,
## independent of WorldState's internal map/spawn random consumption.
const DIG_ORDER_SEED_OFFSET := 91
const DIG_PRIORITY := 1

## Distinct from SCENARIO_SEED and DIG_ORDER_SEED_OFFSET so object placement
## draws from its own stream. Places a short wall line (with one door gap)
## just south of the spawn area, and a few chairs and tables just north of
## it, exercising passability's object costs (colonist-ai.md 3.5) in the
## debug viewer without ever landing on a colonist's own spawn tile.
const OBJECT_SEED_OFFSET := 173
const WALL_LINE_LENGTH := 6
const CHAIR_COUNT := 3
const TABLE_COUNT := 2

## A third row, two tiles south of the wall row (itself south of the spawn
## area), placing a berry_bush and a bed so the debug scenario exercises
## forage and rest sources (colonist-ai.md section 3 "the debug scenario
## places some of each") the same unconditional, seed-derived way the wall
## and furniture rows above do -- no separate random stream needed since
## placement is purely row/index derived, exactly like the furniture row's
## chair/table split.
const FORAGE_ROW_OFFSET := 2
const BERRY_BUSH_COUNT := 1
const BED_COUNT := 1

## One already-plowed tile and a small starting stock of seed items (see
## colonist-ai.md's farming section), so a fresh web build has something to till/sow
## immediately without waiting on a colonist to plow first. The plowed tile
## is produced the same way a player would produce it -- a till job
## submitted through world.apply() and driven to completion by world.tick()
## (see _till_starting_plot() below) -- never a direct tile write; no public
## command can spawn a stackable ground item on demand, though, so the seed
## stock alone is written directly onto WorldState's own item fields (see
## _seed_starting_farm_stock()'s doc comment for why that one exception is
## allowed).
##
## The till target is the nearest TILE_SOIL tile to an actual spawned
## colonist (_pick_till_target()), not a fixed row further out: colonist
## needs decay fast enough (content/needs.json: water rate=2, critical=10,
## colonists start near full at ~98) that a till job needing much more than
## ~40 ticks of uninterrupted travel+work risks a real need interruption
## (colonist-ai.md 3.1/3.6) before finishing -- survivable, but each one
## multiplies the tick budget this bootstrap step needs and bloats the
## fresh scenario's own event/job history for no benefit. Keeping travel
## short (typically 1-2 tiles here) keeps the whole job -- travel plus
## till's own 30 work_ticks -- comfortably inside that window.
##
## This farm bootstrap only runs for the canonical SCENARIO_SEED -- "the
## debug scenario" boot.gd and test_viewer_hash.gd/test_debug_scenario_
## objects.gd all build with the default seed_value. build() also doubles as
## a scene-free scenario factory for other seeds (test_save_io_atomicity.gd
## builds seeds 1201-1203 for its own persistence/determinism coverage,
## unrelated to farming), and those callers' fixtures depend on a
## still-tick-0 world right after build() -- ticking forward to finish a
## till job would silently break that, for a feature those scenarios never
## exercise.
const STARTING_SEED_COUNT := 3
## How far _pick_till_target()/_pick_seed_tile() search outward (Chebyshev
## distance) from a colonist's own spawn tile for a candidate; generous
## relative to the 1-2 tile distances actually seen, to tolerate an
## unusually soil-poor spawn pocket.
const NEAR_TILE_SEARCH_RADIUS := 15
## Bound on how many ticks _till_starting_plot() will advance the simulation
## waiting for the seeded till job to complete. Real completion normally
## lands under 100 ticks (see the till-target doc comment above); this just
## keeps a scenario that can somehow never path there from hanging boot.
const TILL_TICK_BUDGET := 800

## incidents_enabled defaults false so every pre-existing
## caller (every test that calls build() with its own default arguments)
## keeps building byte-identically; boot.gd's own live/debug viewer entry
## point is the one caller that passes true, so spawn_incident is actually
## reachable there.
static func build(seed_value: int = SCENARIO_SEED, tick_rate: int = TICK_RATE, incidents_enabled: bool = false) -> WorldStateType:
	var world := WorldStateType.new(seed_value, tick_rate, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, incidents_enabled)
	_place_scenario_objects(world, seed_value)

	var plow_target := Vector2i(-1, -1)
	if seed_value == SCENARIO_SEED:
		var colonists := world.get_colonists()
		plow_target = _pick_till_target(world, colonists)
		_submit_dig_orders(world, seed_value, plow_target)
		if plow_target != Vector2i(-1, -1):
			_till_starting_plot(world, plow_target)
		var seed_tile := _pick_seed_tile(world, colonists, plow_target)
		_seed_starting_farm_stock(world, seed_tile)
	else:
		_submit_dig_orders(world, seed_value, plow_target)
	return world

## Submits every order at construction (tick 0) so the resulting stream
## depends only on the scenario seed, never on elapsed ticks or wall time.
## `excluded` (the chosen till target, before it is plowed) is never offered
## as a dig target, so a later dig job can never race the fixture and turn
## the pre-plowed tile back into floor.
static func _submit_dig_orders(world: WorldStateType, seed_value: int, excluded: Vector2i = Vector2i(-1, -1)) -> void:
	var soil_tiles: Array[Vector2i] = []
	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			var tile := Vector2i(x, y)
			if tile != excluded and world.get_tile(x, y) == WorldStateType.TILE_SOIL:
				soil_tiles.append(tile)
	if soil_tiles.is_empty():
		return

	var order_random := RandomNumberGenerator.new()
	order_random.seed = seed_value + DIG_ORDER_SEED_OFFSET

	var order_count := mini(DIG_ORDER_COUNT, soil_tiles.size())
	for i in order_count:
		var index := order_random.randi_range(0, soil_tiles.size() - 1)
		var target := soil_tiles[index]
		soil_tiles.remove_at(index)
		world.apply({
			"actor": "scenario",
			"command_id": "scenario_dig_%d" % i,
			"tick": world.get_tick(),
			"type": "dig",
			"payload": {"x": target.x, "y": target.y, "priority": DIG_PRIORITY},
		})

## Places a wall line with one door gap just south of the spawn clearing, and
## a few chairs and tables just north of it (the clearing itself is
## WorldState.get_spawn_clearing()'s river-aware, dynamically chosen
## rectangle, not a fixed constant -- see ADR 020). Rows are
## clamped into the map so a clearing search that happened to land near an
## edge still gets a valid (if visually tighter) row instead of an out-of-
## bounds no-op; _passable_line()'s own bounds check is a second, harmless
## backstop. No row is guaranteed collision-free with another when clamping
## collapses them onto the same tile -- world.apply()'s own place_object
## validation (occupied tile) just silently skips the second one, same as it
## always has for any tile _passable_line() offers that a prior row already
## claimed.
static func _place_scenario_objects(world: WorldStateType, seed_value: int) -> void:
	var object_random := RandomNumberGenerator.new()
	object_random.seed = seed_value + OBJECT_SEED_OFFSET

	var clearing := world.get_spawn_clearing()
	var clearing_x: int = int(clearing.get("x", 0))
	var clearing_y: int = int(clearing.get("y", 0))
	var clearing_height: int = int(clearing.get("height", 0))
	var last_row := world.get_map_height() - 1

	var wall_row := clampi(clearing_y + clearing_height, 0, last_row)
	var wall_line := _passable_line(world, clearing_x, wall_row, WALL_LINE_LENGTH)
	if not wall_line.is_empty():
		var door_index := object_random.randi_range(0, wall_line.size() - 1)
		for i in wall_line.size():
			var kind := "door" if i == door_index else "wooden_wall"
			_place_object(world, wall_line[i], kind, "wall_%d" % i)

	var furniture_row := clampi(clearing_y - 2, 0, last_row)
	var furniture_line := _passable_line(
		world, clearing_x, furniture_row, CHAIR_COUNT + TABLE_COUNT
	)
	for i in furniture_line.size():
		var kind := "chair" if i < CHAIR_COUNT else "table"
		_place_object(world, furniture_line[i], kind, "furniture_%d" % i)

	var forage_row := clampi(wall_row + FORAGE_ROW_OFFSET, 0, last_row)
	var forage_line := _passable_line(
		world, clearing_x, forage_row, BERRY_BUSH_COUNT + BED_COUNT
	)
	for i in forage_line.size():
		var kind := "berry_bush" if i < BERRY_BUSH_COUNT else "bed"
		_place_object(world, forage_line[i], kind, "forage_%d" % i)

## The nearest TILE_SOIL tile to any spawned colonist (checked colonist by
## colonist, id-sorted for determinism; each colonist's own surroundings
## scanned in expanding Chebyshev rings out to NEAR_TILE_SEARCH_RADIUS) --
## see the till-target doc comment above for why "nearest", not "a fixed
## row", is what keeps the till job short enough to normally finish before a
## need interruption. Called after _place_scenario_objects() so an
## already-occupied tile (get_object() non-empty) is never chosen out from
## under a wall/door/chair/table/berry_bush/bed. Vector2i(-1, -1) when no
## candidate qualifies for any colonist.
static func _pick_till_target(world: WorldStateType, colonists: Array[Dictionary]) -> Vector2i:
	var sorted_colonists := colonists.duplicate()
	sorted_colonists.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for colonist in sorted_colonists:
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var found := _nearest_matching_tile(world, origin, func(x: int, y: int) -> bool:
			return world.get_tile(x, y) == WorldStateType.TILE_SOIL and world.get_object(x, y) == "")
		if found != Vector2i(-1, -1):
			return found
	return Vector2i(-1, -1)

## The nearest TILE_SOIL tile to any spawned colonist, distinct from
## till_target, for the starting seed stock to sit on. Vector2i(-1, -1) when
## no candidate qualifies.
static func _pick_seed_tile(world: WorldStateType, colonists: Array[Dictionary], till_target: Vector2i) -> Vector2i:
	var sorted_colonists := colonists.duplicate()
	sorted_colonists.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for colonist in sorted_colonists:
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var found := _nearest_matching_tile(world, origin, func(x: int, y: int) -> bool:
			return Vector2i(x, y) != till_target and world.get_tile(x, y) == WorldStateType.TILE_SOIL and world.get_object(x, y) == "")
		if found != Vector2i(-1, -1):
			return found
	return Vector2i(-1, -1)

## Scans outward from `origin` in expanding Chebyshev-distance rings (0, 1,
## 2, ...) up to NEAR_TILE_SEARCH_RADIUS, row-major within each ring, for the
## first in-bounds tile `matches` accepts. Vector2i(-1, -1) when none does.
static func _nearest_matching_tile(world: WorldStateType, origin: Vector2i, matches: Callable) -> Vector2i:
	for radius in range(0, NEAR_TILE_SEARCH_RADIUS + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= WorldStateType.MAP_HEIGHT:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= WorldStateType.MAP_WIDTH:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if matches.call(x, y):
					return Vector2i(x, y)
	return Vector2i(-1, -1)

## Produces the pre-plowed starting tile the same way a player would: submits
## a till job at `target` through world.apply() (HIGH priority so an idle
## colonist claims it ahead of the scenario's own NORMAL-priority dig
## orders), then ticks until get_tile() reports the tile plowed, bounded by
## TILL_TICK_BUDGET so a scenario that can somehow never path there does not
## hang the boot sequence -- it just leaves the tile untilled rather than
## looping forever.
##
## Needs are topped up every tick of this loop only (mirroring
## test_new_game_dig_chop.gd's own reasoning): the river-aware spawn search
## (ADR 020) can legitimately place water/food up to 40 real route
## steps from the clearing, so a colonist mid-till can now be need-
## interrupted, travel that far round trip to service it, and get bumped back
## onto a scattered dig order before ever accumulating a full uninterrupted
## work_ticks["till"] run -- repeatedly, well past what TILL_TICK_BUDGET
## tolerated when the till target was always 1-2 tiles from a fixed, central
## spawn. This one-time bootstrap step's own colonists, not a real player's,
## are what gets the top-up; real need decay/interruption is untouched
## everywhere else, including for the very same colonists the instant this
## function returns.
static func _till_starting_plot(world: WorldStateType, target: Vector2i) -> void:
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
	while ticks < TILL_TICK_BUDGET and world.get_tile(target.x, target.y) != WorldStateType.TILE_PLOWED_SOIL:
		for colonist in world._colonists:
			var needs: Dictionary = colonist.get("needs", {})
			for kind in needs.keys():
				needs[kind] = 100
		world.tick()
		ticks += 1

## Writes WorldState's item fields directly -- the one deliberate exception:
## no public command can spawn a stackable ground
## item on demand, since the only item-spawn entry points are the
## toil-triggered _spawn_wood_item()/_spawn_berries_item() and the tool-only
## spawn_ground_tool_item(). Mirrors those helpers' own {id, x, y, kind,
## count} item shape and _next_item_id bookkeeping, so a later chop's
## _spawn_wood_item() call still allocates a fresh, non-colliding id. This
## exception covers this one-time seed-stock bootstrap only -- the plowed
## tile above goes through apply()/tick() like everything else.
static func _seed_starting_farm_stock(world: WorldStateType, seed_tile: Vector2i) -> void:
	if seed_tile == Vector2i(-1, -1):
		return
	var item_id := "item_%d" % world._next_item_id
	world._next_item_id += 1
	world._items[item_id] = {"id": item_id, "x": seed_tile.x, "y": seed_tile.y, "kind": "seed", "count": STARTING_SEED_COUNT}

## Up to `count` in-bounds, non-tree tiles starting at (start_x, y) and
## advancing along x -- mirrors _submit_dig_orders()'s soil-tile filtering so
## a rock vein, hazard, or tree scattered onto this row is skipped rather
## than blocking placement.
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
