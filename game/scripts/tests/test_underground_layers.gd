extends SceneTree

## F4 (ADR 071) acceptance: underground layers. A tunnel built with a drill discovers L1 with
## stairs under it; a layer is a function of the seed alone (same at tick 100 and tick 10000);
## a colonist mines a copper vein and the ore reaches a stockpile; three tunnels reach L3 and its
## veins; save/load and a replayed run keep the same state hash; an undiscovered layer costs
## nothing (a fresh world holds the surface only).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const SEED := 42
const BUILD_TICKS := 1200
const MINE_TICKS := 1500
const TUNNEL := Vector3i(10, 10, 0)
const LAYER_ORES := {1: ["coal_ore", "copper_ore", "tin_ore"], 2: ["iron_ore", "silver_ore"], 3: ["gold_ore", "rough_gem"]}

var _failed := false

func _init() -> void:
	_check_fresh_world_holds_the_surface_only()
	_check_every_vein_ore_is_an_ore_item_on_its_layer()
	_check_tunnel_built_with_a_drill_discovers_l1_with_stairs()
	_check_seed_42_l1_is_the_same_at_tick_100_and_tick_10000()
	_check_colonist_mines_copper_and_the_ore_reaches_a_stockpile()
	_check_three_tunnels_reach_l3_with_its_veins()
	_check_save_load_after_discovery_continues_identically()
	_check_replayed_run_reproduces_the_discovery()
	_check_discovered_empty_layer_does_not_slow_the_tick()
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

func _command_ok(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> void:
	var result := Scenarios.command(world, command_id, command_type, payload)
	_expect(bool(result.get("ok", false)), "%s must be accepted: %s" % [command_id, result])

## A floor world with one colonist, a stockpile at the origin holding a drill and wood, and a
## tunnel ordered at TUNNEL.
func _tunnel_world(seed_value: int) -> WorldStateType:
	var world := Scenarios.empty_floor_world(seed_value)
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 1, 1))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "z": 0, "width": 2, "height": 1})
	Scenarios.add_stock(world, "drill", 1, 0, 0)
	Scenarios.add_stock(world, "wood", 2, 1, 0)
	_command_ok(world, "tunnel", "build", {"kind": "tunnel", "x": TUNNEL.x, "y": TUNNEL.y, "z": TUNNEL.z})
	return world

func _tick_until_layers(world: WorldStateType, layer_count: int, budget: int) -> bool:
	for _i in budget:
		if TestAccess.tile_grid(world).layer_count >= layer_count:
			return true
		world.tick()
	return TestAccess.tile_grid(world).layer_count >= layer_count

## Discovery straight through the completion hook (what a finished tunnel site calls).
func _discover(world: WorldStateType, tunnel: Vector3i) -> void:
	TestAccess.object_table(world).set_object(tunnel, LayerDiscovery.TUNNEL_KIND)
	world._layer_discovery.on_site_completed(LayerDiscovery.TUNNEL_KIND, tunnel)

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

func _check_tunnel_built_with_a_drill_discovers_l1_with_stairs() -> void:
	var world := _tunnel_world(SEED)
	_expect(_tick_until_layers(world, 2, BUILD_TICKS), "a finished tunnel must discover L1")
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

func _check_seed_42_l1_is_the_same_at_tick_100_and_tick_10000() -> void:
	var early := Scenarios.empty_floor_world(SEED)
	var late := Scenarios.empty_floor_world(SEED)
	for _i in 100:
		early.tick()
	for _i in 10000:
		late.tick()
	_discover(early, TUNNEL)
	_discover(late, TUNNEL)
	_expect(_layer_tiles(early, 1) == _layer_tiles(late, 1), "seed 42's L1 tiles must not depend on the discovery tick")
	_expect(_layer_objects(early, 1) == _layer_objects(late, 1), "seed 42's L1 veins must not depend on the discovery tick")
	var grid := TestAccess.tile_grid(early)
	var direct := UndergroundGenerator.generate_layer(SEED, 1, grid.width, grid.height, TestAccess.object_definitions(early))
	var again := UndergroundGenerator.generate_layer(SEED, 1, grid.width, grid.height, TestAccess.object_definitions(late))
	_expect(direct == again, "generate_layer must be a pure function of its arguments")
	var other := UndergroundGenerator.generate_layer(SEED + 1, 1, grid.width, grid.height, TestAccess.object_definitions(early))
	_expect(other != direct, "another seed must give another L1")

## A copper vein next to the stairs landing; the colonist starts on the landing with a stockpile there.
func _check_colonist_mines_copper_and_the_ore_reaches_a_stockpile() -> void:
	var world := Scenarios.empty_floor_world(SEED)
	_discover(world, TUNNEL)
	var vein := TUNNEL + Vector3i(2, 0, 1)
	var grid := TestAccess.tile_grid(world)
	grid.tiles[grid.index_of(vein)] = "rock"
	grid.mark_dirty(vein)
	TestAccess.object_table(world).set_object(vein, "copper_vein")
	grid.reset_cells()
	grid.regions = null
	var colonist := Scenarios.idle_colonist("colonist_0", TUNNEL.x - 1, TUNNEL.y - 1)
	colonist["z"] = 1
	TestAccess.colonists(world).append(colonist)
	TestAccess.tool_store(world).spawn_ground("pick", Vector3i(TUNNEL.x + 1, TUNNEL.y + 1, 1))
	_command_ok(world, "zone", "zone_add", {"x": TUNNEL.x - 1, "y": TUNNEL.y - 1, "z": 1, "width": 1, "height": 1})
	_command_ok(world, "mine", "mine", {"x": vein.x, "y": vein.y, "z": vein.z, "priority": 1})
	for _i in MINE_TICKS:
		world.tick()
		if _ore_in_zone(world, Vector3i(TUNNEL.x - 1, TUNNEL.y - 1, 1)):
			_expect(TestAccess.object_table(world).get_object(vein) == "", "the mined vein must be gone")
			_expect(grid.tile_at(vein) == "floor", "the mined vein's rock must become floor")
			return
	_fail("copper ore did not reach the stockpile within %d ticks (vein %s, items %s)"
		% [MINE_TICKS, TestAccess.object_table(world).get_object(vein), world.get_items()])

func _ore_in_zone(world: WorldStateType, tile: Vector3i) -> bool:
	for item in world.get_items():
		if String(item["kind"]) == "copper_ore" and Vector3i(int(item["x"]), int(item["y"]), int(item.get("z", 0))) == tile:
			return true
	return false

func _check_three_tunnels_reach_l3_with_its_veins() -> void:
	var world := Scenarios.empty_floor_world(SEED)
	for layer in 3:
		_discover(world, _deep_tunnel(layer))
	var grid := TestAccess.tile_grid(world)
	_expect(grid.layer_count == 4, "three tunnels must reach L3 (layer_count %d)" % grid.layer_count)
	_expect(grid.tiles.size() == 4 * grid.layer_size(), "every layer must store its tiles")
	_expect(world.get_events(["layer_discovered"]).size() == 3, "each layer must log one discovery")
	for layer: int in LAYER_ORES:
		var kinds := {}
		for kind: String in _layer_objects(world, layer).values():
			kinds[kind] = true
		for vein in UndergroundGenerator.vein_kinds_for_layer(TestAccess.object_definitions(world), layer):
			_expect(kinds.has(vein), "layer %d must hold a %s" % [layer, vein])
		var above := _deep_tunnel(layer - 1)
		_expect(TestAccess.object_table(world).get_object(Vector3i(above.x, above.y, layer)) == LayerDiscovery.STAIRS_KIND,
			"layer %d must have stairs under the tunnel" % layer)
	_discover(world, _deep_tunnel(3))
	_expect(grid.layer_count == 4, "a tunnel on L3 must not discover a fourth layer")

## The tunnel on `layer`, a step aside from the one above so it never stands on its stairs.
func _deep_tunnel(layer: int) -> Vector3i:
	return Vector3i(TUNNEL.x + 3 * layer, TUNNEL.y, layer)

func _check_save_load_after_discovery_continues_identically() -> void:
	var world := _tunnel_world(SEED)
	_expect(_tick_until_layers(world, 2, BUILD_TICKS), "the tunnel must discover L1 before the save")
	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded != null, "the save with L1 must load")
	if loaded == null:
		return
	_expect(loaded.state_hash() == world.state_hash(), "the loaded state must hash like the saved one")
	_expect(TestAccess.tile_grid(loaded).layer_count == 2, "the loaded world must keep L1")
	for _i in 200:
		world.tick()
		loaded.tick()
	_expect(loaded.state_hash() == world.state_hash(), "the loaded world must continue identically")
	_discover(world, _deep_tunnel(1))
	_discover(loaded, _deep_tunnel(1))
	_expect(_layer_tiles(loaded, 2) == _layer_tiles(world, 2), "a layer discovered after load must match")
	_expect(loaded.state_hash() == world.state_hash(), "discovery after load must hash identically")

func _check_replayed_run_reproduces_the_discovery() -> void:
	var first := _tunnel_world(SEED)
	var second := _tunnel_world(SEED)
	_expect(_tick_until_layers(first, 2, BUILD_TICKS), "the first run must discover L1")
	while second.get_tick() < first.get_tick():
		second.tick()
	_expect(TestAccess.tile_grid(second).layer_count == 2, "the replayed run must discover L1 on the same tick")
	_expect(second.state_hash() == first.state_hash(), "the replayed run must hash identically")

## The tick never visits an undiscovered layer, and a discovered layer with nobody on it adds
## little: a generous bound (3x + 2 ms) so only a per-tile scan of the new layer would trip it.
func _check_discovered_empty_layer_does_not_slow_the_tick() -> void:
	var surface := WorldStateType.new(SEED)
	var deep := WorldStateType.new(SEED)
	for layer in 3:
		_discover(deep, _deep_tunnel(layer))
	for _i in 50:
		surface.tick()
		deep.tick()
	var surface_usec := _time_ticks(surface, 200)
	var deep_usec := _time_ticks(deep, 200)
	_expect(deep_usec <= surface_usec * 3 + 2000 * 200,
		"three empty layers must not slow the tick (surface %d us, deep %d us for 200 ticks)" % [surface_usec, deep_usec])

func _time_ticks(world: WorldStateType, ticks: int) -> int:
	var started := Time.get_ticks_usec()
	for _i in ticks:
		world.tick()
	return Time.get_ticks_usec() - started
