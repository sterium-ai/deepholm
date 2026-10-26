extends SceneTree

## A3 byte-identity probe for in-flight re-route searches. Seed 7, a 64x64
## all-soil map, three colonists in the north-west corner, three picks in the
## south-east and three dig orders on soil tiles next to them. dig needs a
## pick, so every colonist starts a fetch_tool leg with no precomputed path:
## ToilExecutor._begin_go_to_reroute() runs a RouteSearch that spans many
## ticks (64 expansions per tick). At ticks 20 and 45 a wall row is dropped
## across the map (with one gap), so later legs re-route around it. Every
## tick the world is encoded (to_save_state()); every tick on which any
## colonist has route.rerouting != null the JSON is kept. Every 25 ticks the
## world is reloaded from its own save and play continues on the copy.
##
## Output: <out>/saves.json (the kept encodings, tick -> JSON) and
## <out>/summary.txt (counts, the per-tick state_hash() list). Both files must
## be byte-identical between main and A3: state_hash() hashes the live
## search's full snapshot() in place of the in-memory summary().
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")

const SIZE := 64
const TICKS := 160

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var world := WorldStateType.new(7, 10, SIZE, SIZE)
	world._tile_grid.tiles.fill(WorldStateType.TILE_SOIL)
	world._object_table.objects.clear()
	world._object_table.object_factions.clear()
	world._colonists.clear()
	for i in 3:
		world._colonists.append({"id": "colonist_%d" % i, "kind": "colonist", "x": 2 + i, "y": 2,
			"route": null, "work": null, "carrying": null})
		world.spawn_ground_tool_item("pick", 50 + i * 3, 54)
	var n := 0
	for i in 3:
		n += 1
		world.apply({"actor": "probe", "command_id": "c%d" % n, "tick": world.get_tick(), "type": "dig",
			"payload": {"x": 52 + i * 3, "y": 58, "priority": 1}})

	var saves := {}
	var hashes: Array = []
	var rerouting_ticks := 0
	var reloads := 0
	for t in TICKS:
		if t == 20 or t == 45:
			var row := 30 if t == 20 else 40
			for x in SIZE:
				if x != (5 if t == 20 else 60):
					world._tile_grid.tiles[world._tile_grid.tile_index(x, row)] = WorldStateType.TILE_ROCK
		world.tick()
		var any_rerouting := false
		for colonist in world._colonists:
			var route = colonist.get("route")
			if route != null and route.get("rerouting") != null:
				any_rerouting = true
		var state: Dictionary = world.to_save_state()
		if any_rerouting:
			rerouting_ticks += 1
			saves[str(world.get_tick())] = JSON.stringify(state)
		hashes.append(world.state_hash())
		if t % 25 == 24:
			world = WorldStateType.from_save_state(state.duplicate(true))
			reloads += 1
	var completed := 0
	for job in world.get_jobs():
		if job["status"] == "completed":
			completed += 1
	_write(out_dir.path_join("saves.json"), JSON.stringify(saves, "\t"))
	var summary := "rerouting_ticks=%d reloads=%d completed_jobs=%d final_tick=%d\nhashes=%s\n" % [
		rerouting_ticks, reloads, completed, world.get_tick(), JSON.stringify(hashes)]
	_write(out_dir.path_join("summary.txt"), summary)
	print("reroute_save_dump: rerouting_ticks=%d reloads=%d completed_jobs=%d" % [rerouting_ticks, reloads, completed])
	quit(0)

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
