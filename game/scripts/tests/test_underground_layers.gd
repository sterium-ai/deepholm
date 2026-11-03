extends SceneTree

## F4 (ADR 071) acceptance: underground layers, every layer found through real build orders and
## ticks (the colonist hauls the drill and wood down the stairs, so the L3b route links are in
## use). A tunnel built with a drill discovers L1 with stairs under it; a layer is a function of
## the seed alone (same at tick 100 and tick 10000); a colonist walks down and mines a copper vein
## and the ore reaches a stockpile; three tunnels reach L3 and its veins and a fourth finds
## nothing; the A11 replay of that run reproduces every checkpoint; save/load between two
## discoveries continues identically; one tunnel per layer and a blocked landing are rejected, a
## landing keeps non-vein objects; three discovered layers add little to the tick.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const SEED := 42
## Ticks a tunnel order may take, hauls down the stairs included.
const BUILD_TICKS := 2000
const MINE_TICKS := 2000
const CHECKPOINT_INTERVAL := 50
const TIMING_ROUNDS := 5
const TIMING_TICKS := 100
const TUNNEL := Vector3i(10, 10, 0)
## One tunnel per layer, each inside the landing of the one above (LANDING_RADIUS 1), off its stairs.
const TUNNELS: Array[Vector3i] = [Vector3i(10, 10, 0), Vector3i(11, 10, 1), Vector3i(12, 10, 2), Vector3i(13, 10, 3)]
const STOCK_ZONE := Vector2i(4, 1)
const LAYER_ORES := {1: ["coal_ore", "copper_ore", "tin_ore"], 2: ["iron_ore", "silver_ore"], 3: ["gold_ore", "rough_gem"]}
## A passable-false object with no vein block, standing in for anything built underground.
const BLOCKER := "table"

var _failed := false

func _init() -> void:
	_check_fresh_world_holds_the_surface_only()
	_check_every_vein_ore_is_an_ore_item_on_its_layer()
	_check_tunnel_built_with_a_drill_discovers_l1_with_stairs()
	_check_seed_42_l1_is_the_same_at_tick_100_and_tick_10000()
	_check_colonist_walks_down_mines_copper_and_the_ore_reaches_a_stockpile()
	_check_three_tunnels_reach_l3_and_the_replay_reproduces_the_run()
	_check_save_load_between_discoveries_continues_identically()
	_check_one_tunnel_per_layer()
	_check_landing_blocked_and_landing_keeps_objects()
	if _failed:
		quit(1)
		return
	print("test_underground_layers: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _command_ok(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	var result := Scenarios.command(world, command_id, command_type, payload)
	_expect(bool(result.get("ok", false)), "%s must be accepted: %s" % [command_id, result])
	return result

func _build_tunnel(world: WorldStateType, command_id: String, tile: Vector3i) -> Dictionary:
	return Scenarios.command(world, command_id, "build", {"kind": LayerDiscovery.TUNNEL_KIND, "x": tile.x, "y": tile.y, "z": tile.z})

func _rejection_detail(result: Dictionary) -> String:
	return String(((result.get("rejection", {}) as Dictionary).get("params", {}) as Dictionary).get("detail", ""))

## A floor world (idle `idle_ticks` first) with one colonist at (1, 1) and a surface stockpile at
## the origin holding `drills` drills and twice as much wood: the start state of every run.
func _stocked_world(seed_value: int, drills: int, idle_ticks: int = 0) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	for _i in idle_ticks:
		world.tick()
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 1, 1))
	Scenarios.add_stock(world, "drill", drills, 0, 0)
	Scenarios.add_stock(world, "wood", 2 * drills, 1, 0)
	return world

func _add_stock_zone(world: WorldStateType) -> void:
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "z": 0, "width": STOCK_ZONE.x, "height": STOCK_ZONE.y})

## Ticks until the map has `layer_count` layers; `log` (if any) observes every tick.
func _tick_until_layers(world: WorldStateType, layer_count: int, budget: int, log: ReplayLogType = null) -> bool:
	for _i in budget:
		if TestAccess.tile_grid(world).layer_count >= layer_count:
			return true
		world.tick()
		if log != null:
			log.observe_tick(world)
	return TestAccess.tile_grid(world).layer_count >= layer_count

func _layer_objects(world: WorldStateType, layer: int) -> Dictionary:
	var grid := TestAccess.tile_grid(world)
	var objects := {}
	for y in grid.height:
		for x in grid.width:
			var kind := TestAccess.object_table(world).get_object(Vector3i(x, y, layer))
			if kind != "":
				objects[Vector2i(x, y)] = kind
	return objects

func _layer_tiles(world: WorldStateType, layer: int) -> Array[String]:
	var grid := TestAccess.tile_grid(world)
	var size := grid.layer_size()
	return grid.tiles.slice(layer * size, (layer + 1) * size)

func _deepest_colonist_z(world: WorldStateType, deepest: int) -> int:
	for colonist in TestAccess.colonists(world):
		deepest = maxi(deepest, int(colonist.get("z", 0)))
	return deepest

func _check_fresh_world_holds_the_surface_only() -> void:
	var world := WorldStateType.new(SEED)
	var grid := TestAccess.tile_grid(world)
	_expect(grid.layer_count == 1, "a fresh world must hold the surface only (layer_count %d)" % grid.layer_count)
	_expect(grid.tiles.size() == grid.layer_size(), "a fresh world must store no underground tiles")

func _check_every_vein_ore_is_an_ore_item_on_its_layer() -> void:
	var world := WorldStateType.new(SEED)
	var definitions := TestAccess.object_definitions(world)
	var content := TestAccess.content(world)
	for layer: int in LAYER_ORES:
		var ores: Array[String] = []
		for kind in UndergroundGenerator.vein_kinds_for_layer(definitions, layer):
			var ore: String = (definitions[kind] as Dictionary)["vein"]["ore"]
			ores.append(ore)
			var item := content.get_entry("items", ore)
			_expect(String(item.get("kind", "")) == "ore",
				"vein %s must yield a known item of the ore group (got %s)" % [kind, item])
		ores.sort()
		_expect(ores == Array(LAYER_ORES[layer], TYPE_STRING, "", null),
			"layer %d must hold exactly the veins %s (got %s)" % [layer, LAYER_ORES[layer], ores])

## A world whose L1 was found by the tunnel at TUNNEL, built through orders and ticks.
func _l1_world(seed_value: int, drills: int, idle_ticks: int = 0) -> WorldStateType:
	var world := _stocked_world(seed_value, drills, idle_ticks)
	_add_stock_zone(world)
	_expect(bool(_build_tunnel(world, "tunnel_0", TUNNEL).get("ok", false)), "the first tunnel order must be accepted")
	_expect(_tick_until_layers(world, 2, BUILD_TICKS), "a finished tunnel must discover L1")
	return world

func _check_tunnel_built_with_a_drill_discovers_l1_with_stairs() -> void:
	var world := _l1_world(SEED, 1)
	var objects := TestAccess.object_table(world)
	_expect(objects.get_object(TUNNEL) == "tunnel", "the tunnel must stand at its tile")
	_expect(objects.get_object(TUNNEL + Vector3i(0, 0, 1)) == LayerDiscovery.STAIRS_KIND, "stairs_up must stand under the tunnel")
	_expect(TestAccess.tile_grid(world).tile_at(TUNNEL + Vector3i(0, 0, 1)) == "floor", "the stairs must stand on floor")
	var drills := world.get_items().filter(func(item: Dictionary) -> bool: return String(item["kind"]) == "drill")
	_expect(drills.is_empty(), "the drill must be consumed by the build")
	var events := world.get_events(["layer_discovered"])
	_expect(events.size() == 1, "one layer_discovered event must be logged (got %d)" % events.size())
	if events.size() == 1:
		_expect(int(events[0]["data"]["layer"]) == 1, "the event must name layer 1")
	_expect(not _layer_objects(world, 1).is_empty(), "L1 must hold its veins")

## The same order and colony, one started at tick 0 (L1 found near tick 100), one after 10000 idle ticks.
func _check_seed_42_l1_is_the_same_at_tick_100_and_tick_10000() -> void:
	var early := _l1_world(SEED, 1)
	var late := _l1_world(SEED, 1, 10000)
	var early_events := early.get_events(["layer_discovered"])
	var late_events := late.get_events(["layer_discovered"])
	if early_events.size() == 1 and late_events.size() == 1:
		_expect(int(late_events[0]["tick"]) >= 10000 and int(early_events[0]["tick"]) < 10000,
			"sanity: the two discoveries must be ~10000 ticks apart (%d, %d)" % [early_events[0]["tick"], late_events[0]["tick"]])
	_expect(_layer_tiles(early, 1) == _layer_tiles(late, 1), "seed 42's L1 tiles must not depend on the discovery tick")
	_expect(_layer_objects(early, 1) == _layer_objects(late, 1), "seed 42's L1 veins must not depend on the discovery tick")
	var grid := TestAccess.tile_grid(early)
	var direct := UndergroundGenerator.generate_layer(SEED, 1, grid.width, grid.height, TestAccess.object_definitions(early))
	var again := UndergroundGenerator.generate_layer(SEED, 1, grid.width, grid.height, TestAccess.object_definitions(late))
	_expect(direct == again, "generate_layer must be a pure function of its arguments")
	var other := UndergroundGenerator.generate_layer(SEED + 1, 1, grid.width, grid.height, TestAccess.object_definitions(early))
	_expect(other != direct, "another seed must give another L1")

## L1 found by a real tunnel; a copper vein is set two tiles off the stairs (fixture: the seed's
## own veins sit in unexplored rock) and the pick lies on the surface, so the colonist walks down.
func _check_colonist_walks_down_mines_copper_and_the_ore_reaches_a_stockpile() -> void:
	var world := _l1_world(SEED, 1)
	var landing := TUNNEL + Vector3i(-1, -1, 1)
	var vein := TUNNEL + Vector3i(2, 0, 1)
	var grid := TestAccess.tile_grid(world)
	grid.tiles[grid.index_of(vein)] = "rock"
	grid.mark_dirty(vein)
	TestAccess.object_table(world).set_object(vein, "copper_vein")
	grid.reset_cells()
	grid.regions = null
	TestAccess.tool_store(world).spawn_ground("pick", Vector3i(3, 3, 0))
	_command_ok(world, "zone_l1", "zone_add", {"x": landing.x, "y": landing.y, "z": 1, "width": 1, "height": 1})
	_command_ok(world, "mine", "mine", {"x": vein.x, "y": vein.y, "z": vein.z, "priority": 1})
	var stock_tiles := {landing: true}
	for x in STOCK_ZONE.x:
		stock_tiles[Vector3i(x, 0, 0)] = true
	var deepest := 0
	for _i in MINE_TICKS:
		world.tick()
		deepest = _deepest_colonist_z(world, deepest)
		if _copper_in(world, stock_tiles):
			_expect(deepest >= 1, "the colonist must have walked down the stairs")
			_expect(TestAccess.object_table(world).get_object(vein) == "", "the mined vein must be gone")
			_expect(grid.tile_at(vein) == "floor", "the mined vein's rock must become floor")
			return
	_fail("copper ore did not reach a stockpile within %d ticks (vein %s, items %s)"
		% [MINE_TICKS, TestAccess.object_table(world).get_object(vein), world.get_items()])

func _copper_in(world: WorldStateType, tiles: Dictionary) -> bool:
	for item in world.get_items():
		if String(item["kind"]) == "copper_ore" and tiles.has(Vector3i(int(item["x"]), int(item["y"]), int(item.get("z", 0)))):
			return true
	return false

## Four tunnel orders, each given once the layer it stands on exists: L1, L2 and L3 are found, the
## tunnel on L3 finds nothing. The whole run is recorded and replayed (A11); then three discovered
## layers are timed against a surface-only twin.
func _check_three_tunnels_reach_l3_and_the_replay_reproduces_the_run() -> void:
	var world := _stocked_world(SEED, TUNNELS.size())
	var log := ReplayLogType.begin(world, CHECKPOINT_INTERVAL, false)
	world.command_observer = func(command: Variant, result: Dictionary) -> void:
		log.record_command(world.get_tick(), command, result.get("ok", false))
	_add_stock_zone(world)
	var deepest := 0
	for layer in TUNNELS.size():
		_expect(bool(_build_tunnel(world, "tunnel_%d" % layer, TUNNELS[layer]).get("ok", false)),
			"the tunnel order on layer %d must be accepted" % layer)
		if layer < LayerDiscovery.MAX_UNDERGROUND_LAYER:
			_expect(_tick_until_layers(world, layer + 2, BUILD_TICKS, log), "the tunnel on layer %d must discover layer %d" % [layer, layer + 1])
		else:
			_tick_until_built(world, TUNNELS[layer], log)
		deepest = _deepest_colonist_z(world, deepest)
	log.finish(world)
	world.command_observer = Callable()
	var grid := TestAccess.tile_grid(world)
	_expect(grid.layer_count == 4, "three tunnels must reach L3 and a fourth find nothing (layer_count %d)" % grid.layer_count)
	_expect(grid.tiles.size() == 4 * grid.layer_size(), "every layer must store its tiles")
	_expect(world.get_events(["layer_discovered"]).size() == 3, "each layer must log one discovery")
	_expect(deepest >= 2, "the builder must have hauled down to L2 at least (deepest z %d)" % deepest)
	for layer: int in LAYER_ORES:
		var kinds := {}
		for kind: String in _layer_objects(world, layer).values():
			kinds[kind] = true
		for vein in UndergroundGenerator.vein_kinds_for_layer(TestAccess.object_definitions(world), layer):
			_expect(kinds.has(vein), "layer %d must hold a %s" % [layer, vein])
		var above := TUNNELS[layer - 1]
		_expect(TestAccess.object_table(world).get_object(Vector3i(above.x, above.y, layer)) == LayerDiscovery.STAIRS_KIND,
			"layer %d must have stairs under the tunnel" % layer)
	var replayed := log.replay()
	print("test_underground_layers: L3 run %d ticks, %d commands, replay %s" % [world.get_tick(), log.commands.size(), replayed])
	_expect(replayed.get("ok", false) and int(replayed.get("checkpoints", 0)) >= log.checkpoints.size(),
		"the A11 replay of the L1..L3 run must reproduce every checkpoint and the final hash: %s" % replayed)
	_check_discovered_layers_do_not_slow_the_tick(world)

func _tick_until_built(world: WorldStateType, tile: Vector3i, log: ReplayLogType) -> void:
	for _i in BUILD_TICKS:
		if TestAccess.object_table(world).get_object(tile) == LayerDiscovery.TUNNEL_KIND:
			return
		world.tick()
		log.observe_tick(world)
	_fail("the tunnel at %s was not built within %d ticks" % [tile, BUILD_TICKS])

## `deep` (L1..L3 found, its colonist idle) against a surface-only twin with the same colony, timed
## in alternating rounds; the median round is compared. Tolerance 1.5x + 0.5 ms per tick: the
## tick visits colonists, jobs and dirty cells, never whole layers, so the two should be close;
## one full pass over the three extra layers' tiles every tick (3 x the surface's tiles) would
## exceed it many times over. The figures are printed for the handoff.
func _check_discovered_layers_do_not_slow_the_tick(deep: WorldStateType) -> void:
	var surface := _stocked_world(SEED, TUNNELS.size())
	_add_stock_zone(surface)
	for _i in 50:
		surface.tick()
		deep.tick()
	var surface_rounds: Array[int] = []
	var deep_rounds: Array[int] = []
	for _round in TIMING_ROUNDS:
		surface_rounds.append(_time_ticks(surface, TIMING_TICKS))
		deep_rounds.append(_time_ticks(deep, TIMING_TICKS))
	surface_rounds.sort()
	deep_rounds.sort()
	var surface_usec := surface_rounds[TIMING_ROUNDS / 2]
	var deep_usec := deep_rounds[TIMING_ROUNDS / 2]
	print("test_underground_layers: timing median of %d x %d ticks: surface %d us (%.1f us/tick), 4 layers %d us (%.1f us/tick), ratio %.2f"
		% [TIMING_ROUNDS, TIMING_TICKS, surface_usec, float(surface_usec) / TIMING_TICKS, deep_usec,
			float(deep_usec) / TIMING_TICKS, float(deep_usec) / maxf(1.0, surface_usec)])
	_expect(deep_usec <= surface_usec * 3 / 2 + 500 * TIMING_TICKS,
		"three discovered layers must not slow the tick (surface %d us, deep %d us for %d ticks)" % [surface_usec, deep_usec, TIMING_TICKS])

func _time_ticks(world: WorldStateType, ticks: int) -> int:
	var started := Time.get_ticks_usec()
	for _i in ticks:
		world.tick()
	return Time.get_ticks_usec() - started

## Saved after L1 is found and the L1 tunnel is ordered (its site pending); the loaded world and
## the original are ticked side by side until both find L2.
func _check_save_load_between_discoveries_continues_identically() -> void:
	var world := _l1_world(SEED, 2)
	_expect(bool(_build_tunnel(world, "tunnel_1", TUNNELS[1]).get("ok", false)), "the L1 tunnel order must be accepted")
	for _i in 20:
		world.tick()
	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded != null, "the save with L1 and a pending tunnel must load")
	if loaded == null:
		return
	_expect(loaded.state_hash() == world.state_hash(), "the loaded state must hash like the saved one")
	_expect(TestAccess.tile_grid(loaded).layer_count == 2, "the loaded world must keep L1")
	var found_world := _tick_until_layers(world, 3, BUILD_TICKS)
	var found_loaded := _tick_until_layers(loaded, 3, BUILD_TICKS)
	_expect(found_world and found_loaded, "both worlds must find L2 (original %s, loaded %s)" % [found_world, found_loaded])
	_expect(loaded.get_tick() == world.get_tick(), "the loaded world must find L2 on the same tick (%d vs %d)" % [loaded.get_tick(), world.get_tick()])
	_expect(_layer_tiles(loaded, 2) == _layer_tiles(world, 2), "a layer discovered after load must match")
	_expect(loaded.state_hash() == world.state_hash(), "discovery after load must hash identically")

func _skipped(result: Dictionary) -> Array:
	if result.has("skipped"):
		return result["skipped"]
	return (result.get("applied", {}) as Dictionary).get("skipped", [])

## A second tunnel on a layer is rejected while the first is a pending site and once it stands; a
## build_line with two tunnels on one layer keeps the first and skips the second.
func _check_one_tunnel_per_layer() -> void:
	var world := _stocked_world(SEED, 2)
	_add_stock_zone(world)
	_expect(bool(_build_tunnel(world, "tunnel_0", TUNNEL).get("ok", false)), "the first tunnel order must be accepted")
	var pending := _build_tunnel(world, "tunnel_pending", TUNNEL + Vector3i(5, 5, 0))
	_expect(not bool(pending.get("ok", true)) and _rejection_detail(pending) == "tunnel_layer_taken",
		"a second tunnel beside a pending tunnel site must be rejected as tunnel_layer_taken: %s" % pending)
	_expect(_tick_until_layers(world, 2, BUILD_TICKS), "the first tunnel must discover L1")
	var standing := _build_tunnel(world, "tunnel_standing", TUNNEL + Vector3i(5, 5, 0))
	_expect(not bool(standing.get("ok", true)) and _rejection_detail(standing) == "tunnel_layer_taken",
		"a second tunnel beside a finished tunnel must be rejected as tunnel_layer_taken: %s" % standing)
	var fresh := _stocked_world(SEED, 2)
	var line := Scenarios.command(fresh, "tunnel_line", "build_line", {"kind": LayerDiscovery.TUNNEL_KIND,
		"tiles": [{"x": 10, "y": 10, "z": 0}, {"x": 14, "y": 10, "z": 0}]})
	var skipped := _skipped(line)
	_expect(bool(line.get("ok", false)) and skipped.size() == 1 and int((skipped[0] as Dictionary)["x"]) == 14,
		"a build_line of two tunnels on one layer must keep the first and skip the second: %s" % line)

## L1 found, then its surface tunnel removed (fixture: there is no deconstruct order yet). A tunnel
## whose stairs tile below holds a non-vein object is rejected; one whose landing holds one is
## built, the object stays and the stairs are placed.
func _check_landing_blocked_and_landing_keeps_objects() -> void:
	var world := _l1_world(SEED, 2)
	var objects := TestAccess.object_table(world)
	objects.set_object(TUNNEL, "")
	var blocked := TUNNEL + Vector3i(6, 0, 0)
	objects.set_object(blocked + Vector3i(0, 0, 1), BLOCKER)
	var result := _build_tunnel(world, "tunnel_blocked", blocked)
	_expect(not bool(result.get("ok", true)) and _rejection_detail(result) == "tunnel_landing_blocked",
		"a tunnel over a non-vein object must be rejected as tunnel_landing_blocked: %s" % result)
	var tunnel := TUNNEL + Vector3i(0, 6, 0)
	var kept := tunnel + Vector3i(1, 1, 1)
	objects.set_object(kept, BLOCKER)
	_expect(bool(_build_tunnel(world, "tunnel_kept", tunnel).get("ok", false)), "a tunnel beside a landing object must be accepted")
	var stairs := tunnel + Vector3i(0, 0, 1)
	for _i in BUILD_TICKS:
		if objects.get_object(stairs) == LayerDiscovery.STAIRS_KIND:
			break
		world.tick()
	_expect(objects.get_object(stairs) == LayerDiscovery.STAIRS_KIND, "the rebuilt tunnel must place its stairs on L1")
	_expect(objects.get_object(kept) == BLOCKER, "the landing must keep a non-vein object (got '%s')" % objects.get_object(kept))
	_expect(objects.get_object(blocked + Vector3i(0, 0, 1)) == BLOCKER, "the rejected tunnel must leave L1 alone")
	_expect(TestAccess.tile_grid(world).layer_count == 2, "a rebuilt tunnel must not discover another layer")
