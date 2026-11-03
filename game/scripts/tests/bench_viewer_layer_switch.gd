extends SceneTree

## L4 benchmark (ADR 069 §3, owner amendments 15211a7 and c769a48): a layer switch rebuilds the
## drawn layer (no per-layer cache in v1), and that rebuild must fit in 50 ms at the A9 viewer scale.
## The world is A9's (BenchCommon.world_with_colonists() on a generated 128x128 map, 1,000
## actors, the boot scene built as in bench_viewer_refresh.gd) with a second layer added through
## the save: rock with a floor cell under every other colonist, and those colonists moved down
## to it, so both layers have tiles, objects (surface) and about 500 actors to draw. Each sample
## times one boot._map_view.set_active_layer() (the slice read, the tile and object
## TileMapLayer rebuild, the sprite filters and the map view's own refresh), then the
## boot._refresh() that the next frame runs, alternating surface -> deep -> surface.
##
## Evidence, not a gate (bench_common.gd). The budget is 50 ms per switch (c769a48; one frame,
## 16.7 ms, is the target of the cached-reuse task L4b). Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_viewer_layer_switch.gd
## Optional: -- --actors=1000 --switches=40

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const Boot = preload("res://scripts/boot.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 128
const DEFAULT_ACTORS := [1000]
const DEFAULT_SWITCHES := 40
const BUDGET_MS := 50.0

func _initialize() -> void:
	_run_all.call_deferred()

func _run_all() -> void:
	var args := _parse_args()
	print(BenchCommon.header("bench_viewer_layer_switch"))
	print("bench_viewer_layer_switch: map=%dx%dx2 seed=%d switches=%d per run budget=%.1fms" % [SIZE, SIZE, SEED, args["switches"], BUDGET_MS])
	for actor_count in args["actors"]:
		await _run(int(actor_count), int(args["switches"]))
	print("bench_viewer_layer_switch: done")
	quit(0)

func _run(actor_count: int, switches: int) -> void:
	var world := _two_layer_world(actor_count)
	root.size = Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")),
		int(ProjectSettings.get_setting("display/window/size/viewport_height")))
	var boot := Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	boot._build_ui()
	boot._replace_world(world)
	for _i in 3:
		await process_frame
	var map_view = boot._map_view
	var series := {0: [], 1: []}
	var with_refresh := {0: [], 1: []}
	for i in switches:
		var target := 1 if i % 2 == 0 else 0
		var start := Time.get_ticks_usec()
		map_view.set_active_layer(target)
		var switch_usec := Time.get_ticks_usec() - start
		boot._refresh()
		var total_usec := Time.get_ticks_usec() - start
		(series[target] as Array).append(switch_usec)
		(with_refresh[target] as Array).append(total_usec)
		await process_frame
	var drawn := {}
	for target in [1, 0]:
		map_view.set_active_layer(target)
		drawn[target] = (map_view.get("_colonist_sprites").get("_sprites") as Dictionary).size()
	for target in [1, 0]:
		var name: String = "to deep (z 1)" if target == 1 else "to surface (z 0)"
		var stats := BenchCommon.stats_ms(series[target])
		var total := BenchCommon.stats_ms(with_refresh[target])
		print("bench_viewer_layer_switch: actors=%d %s drawn=%d switch %s | switch+refresh mean=%.2fms p95=%.2fms max=%.2fms" % [
			world.get_colonists().size(), name, drawn[target], BenchCommon.format_stats(stats),
			total["mean"], total["p95"], total["max"]])
		var values := {"actors": world.get_colonists().size(), "drawn": drawn[target]}
		values.merge(BenchCommon.stats_values(stats))
		values.merge(BenchCommon.stats_values(total, "+refresh "))
		BenchCommon.row("bench_viewer_layer_switch", "layer switch", "%d actors, %s" % [actor_count, name], values)
	root.remove_child(boot)
	boot.free()

## A9's world with a second layer: rock, with a floor cell under every other colonist (and a
## sparse floor scatter so the deep layer is not one tile), those colonists moved down.
func _two_layer_world(actor_count: int) -> WorldStateType:
	var state := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, actor_count).to_save_state()
	state["map"]["layerCount"] = 2
	var deep: Array = []
	for y in SIZE:
		for x in SIZE:
			deep.append(WorldStateType.TILE_FLOOR if (x * 7 + y * 13) % 5 == 0 else WorldStateType.TILE_ROCK)
	var moved := 0
	for entity: Dictionary in state["entities"]:
		if String(entity.get("kind", "")) != "colonist":
			continue
		moved += 1
		if moved % 2 == 0:
			deep[int(entity["y"]) * SIZE + int(entity["x"])] = WorldStateType.TILE_FLOOR
			entity["z"] = 1
	(state["map"]["tiles"] as Array).append_array(deep)
	var world = WorldStateType.from_save_state(state)
	assert(world is WorldStateType, "the two-layer save must load")
	return world

func _parse_args() -> Dictionary:
	var result := {"actors": DEFAULT_ACTORS, "switches": DEFAULT_SWITCHES}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--actors="):
			var counts: Array = []
			for part in arg.substr(9).split(","):
				counts.append(int(part))
			result["actors"] = counts
		elif arg.begins_with("--switches="):
			result["switches"] = int(arg.substr(11))
	return result
