extends SceneTree

## Issue #299 acceptance: save/load round-trips both the 48x48 fixture size
## and the 256x256 large size without regenerating stored terrain, 100 ticks
## after loading equal an uninterrupted continuation with the same commands,
## SaveIO rejects a snapshot with mismatched/unsupported dimensions or an
## out-of-bounds entity without disturbing a previously-good save on disk,
## and orders/routes near a large map's far edge actually complete.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const TARGET := "user://test-save-dimensions.json"
const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var _failed := false

func _init() -> void:
	_remove(TARGET)
	_check_round_trip(48, 48, 311)
	_check_round_trip(256, 256, 312)
	_check_continuation_equivalence(256, 256, 313)
	_check_far_edge_order_completes()
	_check_file_backed_round_trip(48, 48, 314)
	_check_file_backed_round_trip(256, 256, 315)
	_check_small_map_decodes_at_exact_size()
	_check_supported_limit_round_trip()
	_check_rejects_oversized_dimensions()
	_check_rejects_tile_count_mismatch()
	_check_rejects_out_of_bounds_entity()
	_check_rejects_out_of_bounds_zone()
	_check_small_map_service_bounds_and_east_edge_trader_spawn()
	_remove(TARGET)
	if _failed:
		quit(1)
		return
	print("test_save_dimensions: PASS")
	quit()

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A world with a real, tool-equipped, in-flight dig job at its far corner,
## advanced a few ticks before saving. Round 1 review: a prior version of
## this fixture applied the dig with no pick tool present and never checked
## the result, so the "in-flight job" it claimed to round-trip was actually a
## silently rejected no-op the whole time.
func _prepared_world(width: int, height: int, seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, width, height)
	var colonists := world.get_colonists()
	_expect(not colonists.is_empty(), "a %dx%d world must spawn at least one colonist" % [width, height])
	world.spawn_ground_tool_item("pick", 0, 0)
	var far_target := _nearest_soil_tile(world, Vector2i(width - 1, height - 1))
	_expect(far_target != Vector2i(-1, -1), "a soil tile must exist near the far corner of a %dx%d world" % [width, height])
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "dig_far_corner", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": far_target.x, "y": far_target.y, "priority": 1},
	})
	_expect(result.get("ok", false), "the far-corner dig command must be accepted (%dx%d): %s" % [width, height, result])
	for _i in 5:
		world.tick()
	return world

func _check_round_trip(width: int, height: int, seed_value: int) -> void:
	var world := _prepared_world(width, height, seed_value)
	var state := StateCodecType.encode(world)
	_expect(state["map"]["width"] == width and state["map"]["height"] == height,
		"encoded map width/height must match the live world (%dx%d)" % [width, height])
	_expect((state["map"]["tiles"] as Array).size() == width * height,
		"encoded tiles length must equal width*height for a %dx%d world" % [width, height])
	var loaded := StateCodecType.decode(state)
	_expect(loaded.get_map_width() == width and loaded.get_map_height() == height,
		"decoded world must keep the original %dx%d dimensions" % [width, height])
	_expect(loaded.get_tiles() == world.get_tiles(),
		"decoded terrain must equal the original terrain, never regenerated (%dx%d)" % [width, height])
	var original_colonists := world.get_colonists()
	var loaded_colonists := loaded.get_colonists()
	original_colonists.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	loaded_colonists.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	for i in original_colonists.size():
		_expect(original_colonists[i]["x"] == loaded_colonists[i]["x"] and original_colonists[i]["y"] == loaded_colonists[i]["y"],
			"decoded colonist positions must equal the original (%dx%d)" % [width, height])
	_expect(loaded.state_hash() == world.state_hash(),
		"decoded world's state_hash() must equal the original's right after load (%dx%d)" % [width, height])

## "100 ticks after loading equal an uninterrupted continuation with the same
## commands" (issue #299 acceptance): the loaded world and the original are
## ticked in lockstep with NO injected commands of any kind (round 1 review:
## a prior version forced every active job to complete via a synthetic
## complete_job command each tick, which proves nothing about natural work
## continuation -- a colonist actually walking to and digging its far-corner
## target, exactly the same way in both worlds, is what this must show).
func _check_continuation_equivalence(width: int, height: int, seed_value: int) -> void:
	var world := _prepared_world(width, height, seed_value)
	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded.state_hash() == world.state_hash(), "loaded world must start equal to the original before continuing")
	for i in 100:
		world.tick()
		loaded.tick()
		_expect(world.state_hash() == loaded.state_hash(),
			"world and its save/load round trip must stay hash-equal after tick %d of natural continuation (%dx%d)" % [i, width, height])

## "Orders and routes near the far edge work" (issue #299 acceptance):
## a dig order actually near the world's real far boundary (254/255 on a
## 256x256 map, not merely past the legacy 48x48 fixture's max coordinate of
## 47) must route a colonist all the way there and complete, turning the
## target to floor. Round 2 review: the prior version targeted (60,60), well
## inside the map, and never asserted arrival -- this now asserts every route
## tile stays in bounds, that the colonist actually arrives at the target,
## that the dig naturally completes, AND that a save taken mid-flight (route
## arrived, work toil active) round-trips hash-equal and stays hash-equal for
## 100 ticks of continuation after loading, exactly like
## _check_continuation_equivalence() above but starting mid-job instead of
## from a freshly-prepared world. The tool is placed directly at the target
## (rather than far away at (0,0)) so the single long walk this exercises is
## the far-edge route itself, not an unrelated tool-fetch detour.
##
## Issue #300 round 1 revision picked whichever of the four corners was
## real-route-reachable from spawn (a river can strand one corner across the
## water under the new independent-tile-free river generator), but round 2
## review correctly found this let the check pass on a nearby low-coordinate
## corner like (1,1), silently losing the legacy-48x48-bounds regression this
## item exists to catch. This now carves a short, deterministic, guaranteed-
## soil corridor (a real generated world's own colonist origin straight to
## (254,254), never touching the river's own water tiles anywhere else on the
## map) so the far coordinate itself is always exercised, never weakened to
## whichever corner happened to be reachable.
const FAR_EDGE_TARGET := Vector2i(254, 254)
const FAR_EDGE_MIN_COORD := 200
const FAR_EDGE_SEARCH_RADIUS := 30
const FAR_EDGE_TICK_BUDGET := 6000

func _check_far_edge_order_completes() -> void:
	var world := WorldStateType.new(42, 10, 256, 256)
	_expect(not world.get_colonists().is_empty(), "a 256x256 world must spawn at least one colonist")
	if world.get_colonists().is_empty():
		return
	var origin := Vector2i(int(world.get_colonists()[0]["x"]), int(world.get_colonists()[0]["y"]))
	_carve_land_corridor(world, origin, FAR_EDGE_TARGET)
	var reachable := _reachable_from(world, origin)
	var target := _nearest_reachable_soil_tile(world, FAR_EDGE_TARGET, reachable)
	_expect(target != Vector2i(-1, -1), "a real-route-reachable soil tile must exist near (254, 254) once the corridor is carved")
	if target == Vector2i(-1, -1):
		return
	_expect(target.x >= FAR_EDGE_MIN_COORD and target.y >= FAR_EDGE_MIN_COORD,
		"the far-edge dig target must sit near the world's actual far boundary (254/255), got %s" % target)
	world.spawn_ground_tool_item("pick", target.x, target.y)
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "far_edge_dig", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": target.x, "y": target.y, "priority": 1},
	})
	_expect(result.get("ok", false), "a dig order near the far boundary must be accepted: %s" % result)

	var width := world.get_map_width()
	var height := world.get_map_height()
	var arrived_working := false
	var ticks := 0
	# Phase 1: drive `world` alone until the colonist has arrived at the
	# far-edge target AND begun the work toil, checking every route tile
	# stays in bounds along the way. Stops the instant that condition is met
	# (rather than running to completion) so the mid-flight snapshot below
	# reflects the exact same point `world` continues from -- letting `world`
	# advance further first would desync it from `loaded` before the
	# lockstep comparison even starts.
	while ticks < FAR_EDGE_TICK_BUDGET and not arrived_working:
		# Keeps every colonist's needs topped up so this check exercises only
		# what it claims to -- routing/completion at distance -- without
		# fighting the (unrelated, separately tested) need-decay system for
		# one of only 3 colonists: with real need decay, a far order competes
		# against recurring eat/drink/sleep jobs that a fixed small colonist
		# count can never fully clear, so it would sit queued indefinitely
		# (debug_scenario.gd's own _till_starting_plot() picks a 1-2 tile
		# target for exactly this reason -- this check needs a real
		# long-distance route instead, so it neutralizes need pressure rather
		# than shortening the distance).
		for colonist in world._colonists:
			var needs: Dictionary = colonist["needs"]
			for kind in needs.keys():
				needs[kind] = 100
		world.tick()
		ticks += 1
		for colonist in world.get_colonists():
			var route = colonist.get("route")
			if route != null:
				for tile in (route.get("path", []) as Array):
					var t: Vector2i = tile
					_expect(t.x >= 0 and t.x < width and t.y >= 0 and t.y < height,
						"a far-edge route tile must stay within the map's own bounds, got %s" % t)
			if int(colonist["x"]) == target.x and int(colonist["y"]) == target.y and colonist.get("work") != null:
				arrived_working = true
	_expect(arrived_working, "a colonist must actually arrive at the far-edge dig target and begin work within %d ticks" % FAR_EDGE_TICK_BUDGET)
	if not arrived_working:
		return

	# Phase 2: a save taken mid-flight (route arrived, work toil active) must
	# round-trip hash-equal, then stay hash-equal to the uninterrupted
	# original for 100 ticks of natural continuation with no injected
	# commands of any kind -- mirrors _check_continuation_equivalence()
	# above, starting mid-job instead of from a freshly-prepared world.
	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded.state_hash() == world.state_hash(),
		"a save taken mid-flight during far-edge work must round-trip hash-equal")
	for i in 100:
		world.tick()
		loaded.tick()
		_expect(world.state_hash() == loaded.state_hash(),
			"a far-edge save taken mid-flight must stay hash-equal to the original for 100 ticks of natural continuation (tick %d)" % i)

	# Phase 3: the dig must still naturally complete (the 100 equivalence
	# ticks above already cover the ~30-tick work duration in the common
	# case; this drives `world` the rest of the way if needed).
	var completion_ticks := 0
	while completion_ticks < FAR_EDGE_TICK_BUDGET and world.get_tile(target.x, target.y) != "trench":
		for colonist in world._colonists:
			var needs: Dictionary = colonist["needs"]
			for kind in needs.keys():
				needs[kind] = 100
		world.tick()
		completion_ticks += 1
	_expect(world.get_tile(target.x, target.y) == "trench",
		"a dig order near the far boundary must actually route a colonist there and complete")

## Carves a straight L-shaped corridor of TILE_SOIL from `from` to `to`
## (horizontal leg first, then vertical), clearing any object in the way --
## the same direct `_tiles`/`_objects` mutation pattern already used by
## test_toils_dig_chop_regression.gd's own fixtures. Never touches any tile
## outside this one corridor, so the rest of the real generated map (the
## river included) is untouched; this exists only to guarantee the far-edge
## coordinate itself stays reachable regardless of where the river happened
## to land for this seed, per round 2 review.
func _carve_land_corridor(world: WorldStateType, from: Vector2i, to: Vector2i) -> void:
	var x := from.x
	var y := from.y
	_clear_land_tile(world, x, y)
	while x != to.x:
		x += 1 if to.x > x else -1
		_clear_land_tile(world, x, y)
	while y != to.y:
		y += 1 if to.y > y else -1
		_clear_land_tile(world, x, y)

func _clear_land_tile(world: WorldStateType, x: int, y: int) -> void:
	world._tiles[world._tile_index(x, y)] = WorldStateType.TILE_SOIL
	var key := "%d_%d" % [x, y]
	world._objects.erase(key)
	world._object_factions.erase(key)

## Expanding Chebyshev-ring search for the nearest soil tile to `origin`,
## mirroring debug_scenario.gd's own _nearest_matching_tile().
## Every tile real-route-reachable from `origin` through world.passability()
## (4-connected, never Chebyshev/Euclidean) -- the same real-movement rule the
## far-edge check above uses to pick a target that is not stranded across the
## river from the colonist's own shore.
func _reachable_from(world: WorldStateType, origin: Vector2i) -> Dictionary:
	var width := world.get_map_width()
	var height := world.get_map_height()
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [origin]
	visited[origin.y * width + origin.x] = true
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for offset in NEI4:
			var next: Vector2i = current + offset
			if next.x < 0 or next.x >= width or next.y < 0 or next.y >= height:
				continue
			var index := next.y * width + next.x
			if visited.has(index) or not bool(world.passability(next.x, next.y)["passable"]):
				continue
			visited[index] = true
			queue.append(next)
	return visited

func _nearest_reachable_soil_tile(world: WorldStateType, origin: Vector2i, reachable: Dictionary) -> Vector2i:
	var width := world.get_map_width()
	var height := world.get_map_height()
	for radius in range(0, FAR_EDGE_SEARCH_RADIUS + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if world.get_tile(x, y) == "soil" and reachable.has(y * width + x):
					return Vector2i(x, y)
	return Vector2i(-1, -1)

func _nearest_soil_tile(world: WorldStateType, origin: Vector2i) -> Vector2i:
	var width := world.get_map_width()
	var height := world.get_map_height()
	for radius in range(0, FAR_EDGE_SEARCH_RADIUS + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if world.get_tile(x, y) == "soil":
					return Vector2i(x, y)
	return Vector2i(-1, -1)

## File-backed round trip (issue #299 round 1 review): exercises the actual
## SaveIO.write_atomic()/read() file pipeline, not just StateCodec.encode()/
## decode() in memory, at both required sizes.
func _check_file_backed_round_trip(width: int, height: int, seed_value: int) -> void:
	var world := _prepared_world(width, height, seed_value)
	var path := "user://test-save-dimensions-file-backed-%dx%d.json" % [width, height]
	_remove(path)
	var write_result := SaveIOType.write_atomic(path, StateCodecType.encode(world))
	_expect(write_result.get("ok", false), "a %dx%d world must save through the real file pipeline: %s" % [width, height, write_result])
	var read_result := SaveIOType.read(path)
	_expect(read_result.get("ok", false), "a %dx%d world must read back through the real file pipeline: %s" % [width, height, read_result])
	if read_result.get("ok", false):
		var loaded := StateCodecType.decode(read_result["state"])
		_expect(loaded.get_map_width() == width and loaded.get_map_height() == height,
			"a file-backed round trip must keep the original %dx%d dimensions" % [width, height])
		_expect(loaded.get_tiles() == world.get_tiles(),
			"a file-backed round trip must keep the original terrain, never regenerated (%dx%d)" % [width, height])
		_expect(loaded.state_hash() == world.state_hash(),
			"a file-backed round trip's state_hash() must equal the original's (%dx%d)" % [width, height])
	_remove(path)

## issue #299 round 1 review: a saved map below WorldGenerator's 16-tile
## new-game minimum (a small fixture, e.g. 3x2) must decode at its own exact
## size, not be silently re-clamped to 16x16 with a mismatched tile array --
## StateCodec.decode() must preserve every SUPPORTED saved dimension exactly,
## restoration being a distinct concern from new-world size clamping.
func _check_small_map_decodes_at_exact_size() -> void:
	var state := _minimal_state_at_size(3, 2, 401)
	var loaded := StateCodecType.decode(state)
	_expect(loaded.get_map_width() == 3 and loaded.get_map_height() == 2,
		"a 3x2 saved map must decode at its own exact size, not WorldGenerator's 16-tile new-game minimum")
	_expect(loaded.get_tiles() == (state["map"]["tiles"] as Array),
		"a 3x2 saved map must decode with exactly its own 6 stored tiles")
	var validation := SaveIOType._validate_state(state)
	_expect(validation["ok"], "a 3x2 saved map must pass SaveIO validation (no lower bound on restore): %s" % validation.get("message", ""))

## issue #299 round 1 review: the largest size WorldGenerator/WorldState ever
## support (512x512, mapgen.json's max_world_size) must round-trip through
## the real file pipeline exactly like any other supported size.
func _check_supported_limit_round_trip() -> void:
	_check_file_backed_round_trip(512, 512, 402)

## issue #299 round 1 review: a map above the supported maximum must be
## rejected before it can ever replace a working save or reach WorldState,
## even when its tiles array length matches width*height (isolating the new
## oversized-dimension check from the pre-existing tile-count check below).
func _check_rejects_oversized_dimensions() -> void:
	var good := StateCodecType.encode(WorldStateType.new(403, 10, 48, 48))
	_expect(SaveIOType.write_atomic(TARGET, good)["ok"], "a valid state must save so this check has something to protect")
	var oversized_size := WorldGeneratorType.DEFAULT_MAX_WORLD_SIZE + 1
	var bad := _minimal_state_at_size(oversized_size, oversized_size, 404)
	var result := SaveIOType.write_atomic(TARGET, bad)
	_expect(not result["ok"], "a map above the supported maximum must be rejected")
	_expect(result.get("code", "") == "schema_error", "an oversized map must be a typed schema_error")
	var still_good := SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"]["seed"] == good["seed"],
		"the previously-written good save must survive a rejected oversized-dimension write")

## A minimal but fully current-schema-shaped state at an arbitrary width x
## height, with no entities/items/etc. to worry about -- for tests that only
## care about map-dimension handling. tiles are all "soil".
func _minimal_state_at_size(width: int, height: int, seed_value: int) -> Dictionary:
	var tiles: Array = []
	tiles.resize(width * height)
	tiles.fill("soil")
	return {
		"schemaVersion": StateCodecType.SCHEMA_VERSION, "contentVersion": StateCodecType.content_version(),
		"seed": seed_value, "tick": 0, "epoch": 0,
		"map": {"width": width, "height": height, "tiles": tiles, "generatorVersion": WorldGeneratorType.GENERATOR_VERSION},
		"entities": [], "inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {}, "activatedEntries": {},
		},
		"rng": {"seed": seed_value, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [], "toolItems": {"nextId": 1, "list": []},
		"toolReservations": {}, "needJobAssignments": [], "calendarAlerts": {"fired": []},
		"toolFetchExcluded": [],
		"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": seed_value, "state": 0}},
	}

## issue #299: a save whose tiles array does not have width*height entries
## must be rejected (schema_error), and the previously-written good target
## must survive untouched.
func _check_rejects_tile_count_mismatch() -> void:
	var good := StateCodecType.encode(WorldStateType.new(321, 10, 48, 48))
	_expect(SaveIOType.write_atomic(TARGET, good)["ok"], "a valid state must save so this check has something to protect")
	var bad := StateCodecType.encode(WorldStateType.new(322, 10, 48, 48))
	bad = bad.duplicate(true)
	var map: Dictionary = (bad["map"] as Dictionary).duplicate(true)
	var tiles: Array = (map["tiles"] as Array).duplicate()
	tiles.resize(tiles.size() - 1) # one short of width*height
	map["tiles"] = tiles
	bad["map"] = map
	var result := SaveIOType.write_atomic(TARGET, bad)
	_expect(not result["ok"], "a tiles/width*height mismatch must be rejected")
	_expect(result.get("code", "") == "schema_error", "a tiles/width*height mismatch must be a typed schema_error")
	var still_good := SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"]["seed"] == good["seed"],
		"the previously-written good save must survive a rejected dimension-mismatched write")

## issue #299: an entity at or beyond the map's own width/height must be
## rejected the same way a negative coordinate always was.
func _check_rejects_out_of_bounds_entity() -> void:
	var good := StateCodecType.encode(WorldStateType.new(323, 10, 48, 48))
	_expect(SaveIOType.write_atomic(TARGET, good)["ok"], "a valid state must save so this check has something to protect")
	var bad := StateCodecType.encode(WorldStateType.new(324, 10, 48, 48))
	bad = bad.duplicate(true)
	var entities: Array = (bad["entities"] as Array).duplicate(true)
	_expect(not entities.is_empty(), "a 48x48 world must have at least one entity to corrupt")
	var first: Dictionary = (entities[0] as Dictionary).duplicate(true)
	first["x"] = 48 # map width is 48, so x == 48 is out of bounds
	entities[0] = first
	bad["entities"] = entities
	var result := SaveIOType.write_atomic(TARGET, bad)
	_expect(not result["ok"], "an out-of-bounds entity position must be rejected")
	_expect(result.get("code", "") == "schema_error", "an out-of-bounds entity position must be a typed schema_error")
	var still_good := SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"]["seed"] == good["seed"],
		"the previously-written good save must survive a rejected out-of-bounds-entity write")

## issue #299: a zone rectangle extending past the map's own width/height
## must be rejected the same way an entity out of bounds is.
func _check_rejects_out_of_bounds_zone() -> void:
	var good := StateCodecType.encode(WorldStateType.new(325, 10, 48, 48))
	_expect(SaveIOType.write_atomic(TARGET, good)["ok"], "a valid state must save so this check has something to protect")
	var bad := StateCodecType.encode(WorldStateType.new(326, 10, 48, 48))
	bad = bad.duplicate(true)
	bad["zones"] = [{"id": "zone_oob", "x": 40, "y": 40, "width": 20, "height": 20}]
	var result := SaveIOType.write_atomic(TARGET, bad)
	_expect(not result["ok"], "a zone rectangle extending past the map bounds must be rejected")
	_expect(result.get("code", "") == "schema_error", "an out-of-bounds zone must be a typed schema_error")
	var still_good := SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"]["seed"] == good["seed"],
		"the previously-written good save must survive a rejected out-of-bounds-zone write")

## Round 5 review finding 3: decode() constructs a sub-16-tile saved map (e.g.
## 8x8) through the constructor's own resolve_size()-clamped 16x16 build, then
## only overwrites WorldState._width/_height afterward -- leaving NeedGiver's
## _bounds_max and IncidentScheduler's _map_width/_map_height stuck at 16.
## trader_visit's east-edge spawn (content/incidents.json) would then search
## for x = 15, entirely outside an 8-wide map, and never spawn. Proves both
## services are rebuilt from the SAVED dimensions, and that a trader actually
## spawns on the map's own real east edge (x = width-1).
const SMALL_MAP_TICK_BUDGET := 200

func _check_small_map_service_bounds_and_east_edge_trader_spawn() -> void:
	var width := 8
	var height := 8
	var state := _minimal_state_at_size(width, height, 501)
	var tiles: Array = []
	tiles.resize(width * height)
	tiles.fill(WorldStateType.TILE_FLOOR)
	var map: Dictionary = (state["map"] as Dictionary).duplicate(true)
	map["tiles"] = tiles
	state["map"] = map
	var loaded := StateCodecType.decode(state)
	_expect(loaded.get_map_width() == width and loaded.get_map_height() == height,
		"an 8x8 saved map must decode at its own exact size")
	_expect(loaded._need_giver._bounds_max == Vector2i(width - 1, height - 1),
		"NeedGiver's bounds must be rebuilt at the saved map's own dimensions, not the constructor's 16x16 clamp (got %s)" % [loaded._need_giver._bounds_max])
	_expect(loaded._incidents._map_width == width and loaded._incidents._map_height == height,
		"IncidentScheduler's map dimensions must be rebuilt at the saved map's own size, not the constructor's 16x16 clamp (got %dx%d)" % [loaded._incidents._map_width, loaded._incidents._map_height])

	loaded.enable_incidents()
	var result: Dictionary = loaded.apply({
		"actor": "test", "command_id": "small_map_trader", "tick": loaded.get_tick(),
		"type": "spawn_incident", "payload": {"id": "trader_visit"},
	})
	_expect(result.get("ok", false), "trader_visit must be accepted on a correctly-bounded 8x8 map: %s" % result)
	var actor_ids: Array = result.get("actor_ids", [])
	_expect(actor_ids.size() == 1, "trader_visit must propose its single trader on an 8x8 map")
	if actor_ids.is_empty():
		return
	var actor_id := String(actor_ids[0])
	var ticks := 0
	var actor := {}
	while ticks < SMALL_MAP_TICK_BUDGET:
		actor = loaded._find_colonist(actor_id)
		if not actor.is_empty():
			break
		loaded.tick()
		ticks += 1
	_expect(not actor.is_empty(), "the trader must actually spawn within %d ticks on the corrected 8x8 bounds" % SMALL_MAP_TICK_BUDGET)
	if actor.is_empty():
		return
	_expect(int(actor["x"]) == width - 1,
		"the trader must spawn on the map's own real east edge (x=%d), not the constructor's clamped x=15 (got x=%d)" % [width - 1, int(actor["x"])])
	_expect(int(actor["x"]) < width and int(actor["y"]) < height,
		"the trader's spawn tile must stay within the 8x8 map's real bounds (got %s)" % [Vector2i(int(actor["x"]), int(actor["y"]))])
