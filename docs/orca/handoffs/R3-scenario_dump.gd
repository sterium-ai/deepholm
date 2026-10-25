extends SceneTree

## R3 byte-identity probe: plays a fixed map-heavy scenario (place/remove objects including
## a rotated multi-tile one, a walled room with a door and a bed, build orders, digs that
## change tiles and regions, forage on berry bushes, zone add/remove, wolves and raiders
## that hit walls and doors, a trader), with a save/load round trip in the middle.
## Writes both saves, the event logs, every command result (including preview() answers),
## and a trace every 10 ticks: tiles, objects, zones, the dirty-cell log, region ids and
## room ids of every tile, passability of every tile for two factions, the water-tile cache,
## and state_hash(). Run before and after the refactor and diff the files.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R3.md:
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## Regions and the water cache are private; on R3 they live on world._tile_grid.
func _regions(world):
	return world._tile_grid.get_regions() if world.get("_tile_grid") != null else world._get_regions()

func _water_tiles(world) -> Array:
	return world._tile_grid.get_water_tiles() if world.get("_tile_grid") != null else world._get_water_tiles()

## The `count` tiles of `kind` nearest to `from` (ties by row-major order).
func _nearest_tiles(world, kind: String, from: Vector2i, count: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var w: int = world.get_map_width()
	var tiles: Array[String] = world.get_tiles()
	for i in tiles.size():
		if tiles[i] == kind:
			found.append(Vector2i(i % w, i / w))
	found.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - from.x) + absi(a.y - from.y)
		var db := absi(b.x - from.x) + absi(b.y - from.y)
		if da != db:
			return da < db
		return a.y * w + a.x < b.y * w + b.x)
	return found.slice(0, count)

func _nearest_objects(world, kind: String, from: Vector2i, count: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for obj in world.get_objects():
		if String(obj.get("kind", "")) == kind:
			found.append(Vector2i(int(obj["x"]), int(obj["y"])))
	found.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - from.x) + absi(a.y - from.y)
		var db := absi(b.x - from.x) + absi(b.y - from.y)
		if da != db:
			return da < db
		return a.y * 1000 + a.x < b.y * 1000 + b.x)
	return found.slice(0, count)

func _home(world) -> Vector2i:
	var c0: Dictionary = world.get_colonists()[0]
	return Vector2i(int(c0["x"]), int(c0["y"]))

## A 5x5 walled room (door on the south wall, bed inside), a rotated footprint crate,
## a workbench, a chair, all through place_object (some land on invalid tiles: rejections
## are part of the trace).
func _furnish(world, results: Array) -> void:
	var c := _home(world) + Vector2i(4, -6)
	for i in 5:
		for t in [Vector2i(c.x + i, c.y), Vector2i(c.x + i, c.y + 4), Vector2i(c.x, c.y + i), Vector2i(c.x + 4, c.y + i)]:
			var kind := "door" if t == Vector2i(c.x + 2, c.y + 4) else "wooden_wall"
			results.append(world.apply(_cmd(world, "place_object", {"kind": kind, "x": t.x, "y": t.y})))
	results.append(world.apply(_cmd(world, "place_object", {"kind": "bed", "x": c.x + 2, "y": c.y + 2})))
	var o := _home(world) + Vector2i(-5, 3)
	results.append(world.apply(_cmd(world, "place_object", {"kind": "test_footprint_crate", "x": o.x, "y": o.y, "orientation": "vertical"})))
	results.append(world.apply(_cmd(world, "place_object", {"kind": "workbench", "x": o.x + 2, "y": o.y, "orientation": "horizontal"})))
	results.append(world.apply(_cmd(world, "place_object", {"kind": "chair", "x": o.x + 2, "y": o.y + 2})))

func _order_wave(world, results: Array, wave: int) -> void:
	var home := _home(world)
	for t in _nearest_tiles(world, "soil", home, 4 + 2 * wave):
		results.append(world.apply(_cmd(world, "dig", {"x": t.x, "y": t.y, "priority": 1})))
	for t in _nearest_tiles(world, "tree", home, 3):
		results.append(world.apply(_cmd(world, "chop", {"x": t.x, "y": t.y, "priority": 2})))
	for t in _nearest_tiles(world, "rock", home, 2):
		results.append(world.apply(_cmd(world, "mine", {"x": t.x, "y": t.y, "priority": 2})))
	for t in _nearest_objects(world, "berry_bush", home, 2):
		results.append(world.apply(_cmd(world, "forage", {"x": t.x, "y": t.y, "priority": 2})))
	for t in _nearest_tiles(world, "soil", home + Vector2i(3, 3), 1):
		results.append(world.apply(_cmd(world, "till", {"x": t.x, "y": t.y, "priority": 1})))
	var b := home + Vector2i(-3, -3 - wave)
	results.append(world.apply(_cmd(world, "build", {"kind": "wooden_wall", "x": b.x, "y": b.y})))
	results.append(world.apply(_cmd(world, "build", {"kind": "workbench", "x": b.x + 2, "y": b.y, "orientation": "vertical"})))
	var line: Array = []
	for i in 3:
		line.append({"x": b.x - 4 + i, "y": b.y})
	results.append(world.apply(_cmd(world, "build_line", {"kind": "wooden_wall", "tiles": line})))

## preview() never mutates: its answers over a row of tiles go into the results.
func _previews(world, results: Array) -> void:
	var home := _home(world)
	for dx in range(-6, 7):
		var t := home + Vector2i(dx, -6)
		results.append({"preview_place": world.preview(_cmd(world, "place_object", {"kind": "workbench", "x": t.x, "y": t.y, "orientation": "vertical"}))})
		results.append({"preview_build": world.preview(_cmd(world, "build", {"kind": "door", "x": t.x, "y": t.y}))})
	results.append({"preview_zone": world.preview(_cmd(world, "zone_add", {"x": home.x - 2, "y": home.y - 2, "width": 2, "height": 2}))})

func _trace_line(world) -> Dictionary:
	var w: int = world.get_map_width()
	var h: int = world.get_map_height()
	var regions = _regions(world)
	var region_ids: Array = []
	var rooms: Array = []
	var pass_colony: Array = []
	var pass_wild: Array = []
	for y in h:
		for x in w:
			region_ids.append(regions.region_id(x, y))
			rooms.append(world.get_room_at(x, y))
			pass_colony.append(world.passability(x, y))
			pass_wild.append(world.passability(x, y, "wildlife"))
	var dirty: Array[Vector2i] = world.get_dirty_cells()
	var faction_ids: Array = []
	for obj in world.get_objects():
		faction_ids.append(world.get_object_faction_id(int(obj["x"]), int(obj["y"])))
	return {"tick": world.get_tick(), "tiles": hash(JSON.stringify(world.get_tiles())), "objects": world.get_objects(),
		"object_factions": faction_ids, "zones": world.get_zones(), "dirty_count": dirty.size(),
		"dirty_hash": hash(str(dirty)), "regions": hash(JSON.stringify(region_ids)), "rooms": hash(JSON.stringify(rooms)),
		"pass_colony": hash(JSON.stringify(pass_colony)), "pass_wild": hash(JSON.stringify(pass_wild)),
		"water": hash(str(_water_tiles(world))), "hash": world.state_hash()}

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + from_tick
	var zone_ids: Array = []
	for t in range(from_tick, to_tick):
		if t == 0:
			for kind in ["pick", "pick", "axe"]:
				results.append({"spawned_tool": world.spawn_ground_tool_item(kind, _home(world).x, _home(world).y)})
			_furnish(world, results)
		if t % 120 == 0:
			_order_wave(world, results, t / 120)
		if t % 50 == 0:
			_previews(world, results)
		if t % 25 == 0:
			for k in 3:
				var x := rng.randi_range(0, 47)
				var y := rng.randi_range(0, 47)
				var kind: String = ["dig", "chop", "forage", "till", "mine", "place_object"][rng.randi_range(0, 5)]
				var payload := {"x": x, "y": y, "priority": 1} if kind != "place_object" else {"kind": "stone_wall", "x": x, "y": y}
				results.append(world.apply(_cmd(world, kind, payload)))
			results.append(world.apply(_cmd(world, "zone_add", {"x": rng.randi_range(0, 44), "y": rng.randi_range(0, 44), "width": 3, "height": 2})))
		if t == 5 or t == 405:
			var r: Dictionary = world.apply(_cmd(world, "zone_add", {"x": _home(world).x - 2, "y": _home(world).y + 2, "width": 3, "height": 3}))
			results.append(r)
			if r.has("zone_id"):
				zone_ids.append(r["zone_id"])
		if t == 300 or t == 700:
			for z in world.get_zones():
				if (zone_ids.is_empty() or String(z["id"]) != String(zone_ids[0])) and rng.randi_range(0, 1) == 0:
					results.append(world.apply(_cmd(world, "zone_remove", {"id": String(z["id"])})))
		if t == 250 or t == 650:
			var o := _home(world) + Vector2i(-5, 3)
			results.append(world.apply(_cmd(world, "remove_object", {"x": o.x + 3, "y": o.y})))
			results.append(world.apply(_cmd(world, "remove_object", {"x": o.x, "y": o.y + 1})))
			var c := _home(world) + Vector2i(4, -6)
			results.append(world.apply(_cmd(world, "remove_object", {"x": c.x + 4, "y": c.y + 2})))
		if t == 60 or t == 460:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "wolf_attack"})))
		if t == 150 or t == 500:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"})))
		if t == 330:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "raider_incursion"})))
		for offer in world.get_pending_trade_offers():
			results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": offer["trader_id"]})))
		world.tick()
		if t % 10 == 0:
			trace.append(_trace_line(world))

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(777, 10, 48, 48, true)
	var results: Array = []
	var trace: Array = []
	_play(world, results, trace, 0, 400)
	var first := world.to_save_state()
	var io1 := SaveIOType.write_atomic(out_dir.path_join("save_400.json"), first)
	var loaded = WorldStateType.from_save_state(first)
	loaded.enable_incidents()
	var results2: Array = []
	_play(loaded, results2, trace, 400, 800)
	var second: Dictionary = loaded.to_save_state()
	# SaveIO validates before writing; also dump the raw state so a validation refusal never hides a diff.
	_write(out_dir.path_join("state_400.json"), JSON.stringify(first, "	"))
	_write(out_dir.path_join("state_800.json"), JSON.stringify(second, "	"))
	var io2 := SaveIOType.write_atomic(out_dir.path_join("save_800.json"), second)
	_write(out_dir.path_join("events.json"), JSON.stringify([world.get_events(), loaded.get_events()], "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify({"a": results, "b": results2, "hash400": world.state_hash(), "hash800": loaded.state_hash()}, "\t"))
	var last: Dictionary = trace[trace.size() - 1]
	if not io2.get("ok"): print("io2: ", io2)
	var applied := 0
	for r in results + results2:
		if (r as Dictionary).get("ok", false):
			applied += 1
	print("scenario_dump: io1=%s io2=%s results=%d/%d applied=%d objects=%d zones=%d dirty=%d hash=%d/%d" % [io1.get("ok"), io2.get("ok"),
		results.size(), results2.size(), applied, (last["objects"] as Array).size(), (last["zones"] as Array).size(),
		int(last["dirty_count"]), world.state_hash(), loaded.state_hash()])
	quit(0)
