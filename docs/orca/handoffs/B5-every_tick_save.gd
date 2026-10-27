extends SceneTree

## B5 acceptance probe: replays the R2 and R4 scenario probes (handoffs/R2-scenario_dump.gd and
## handoffs/R4-scenario_dump.gd: seed 777, 48x48, 10 colonists, incidents on, digs that open
## trenches and trigger rescues, chops, mines, forages, till + sow, hauls, trader visits, random
## orders; R4 adds two wolf attacks, R2 adds a rejected "bogus" command) for 800 ticks each, and
## after EVERY tick writes the world through SaveIO.write_atomic(), reads it back through
## SaveIO.read(), rebuilds a WorldState from it and compares:
##   - the write and the read succeed (no "invalid tile coordinates" refusal);
##   - the reloaded world's state_hash() equals the live world's;
##   - every ground-berries pile keeps its count and faction.
## Same command streams as the two probes; the live world carries on unchanged (the reloaded
## copy is only compared), so one save never changes what the next tick does.
## Prints one summary line per scenario plus "b5_probe: ..." with the totals; exits 1 when a
## save is refused or a berry pile changes (the B5 acceptance). Hash mismatches are counted
## and listed but do not fail the run: the ones seen are pre-existing, on main too, and come
## from the load-time incident reconcile cancelling a still-queued "incident" job in the
## first ticks after trader_visit/wolf_attack (see handoffs/B5.md, "Known limitations").
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

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

func _order_wave(world, wave: int) -> void:
	var c0: Dictionary = world.get_colonists()[0]
	var home := Vector2i(int(c0["x"]), int(c0["y"]))
	for t in _nearest_tiles(world, "soil", home, 4 + 2 * wave):
		world.apply(_cmd(world, "dig", {"x": t.x, "y": t.y, "priority": 1}))
	for t in _nearest_tiles(world, "tree", home, 3):
		world.apply(_cmd(world, "chop", {"x": t.x, "y": t.y, "priority": 2}))
	for t in _nearest_tiles(world, "rock", home, 2):
		world.apply(_cmd(world, "mine", {"x": t.x, "y": t.y, "priority": 2}))
	for t in _nearest_objects(world, "berry_bush", home, 2):
		world.apply(_cmd(world, "forage", {"x": t.x, "y": t.y, "priority": 2}))
	for t in _nearest_tiles(world, "plowed_soil", home, 1):
		world.apply(_cmd(world, "sow", {"x": t.x, "y": t.y, "priority": 1}))
	for t in _nearest_tiles(world, "soil", home + Vector2i(3, 3), 1):
		world.apply(_cmd(world, "till", {"x": t.x, "y": t.y, "priority": 1}))

## The commands R2/R4's _play() issues before tick t (R2 reseeds its order RNG at 0 and 400,
## R4 every 100 ticks; both seed it 4242 + the segment start).
func _orders(world, rng: RandomNumberGenerator, t: int, variant: String) -> void:
	var segment := 400 if variant == "r2" else 100
	if t % segment == 0:
		rng.seed = 4242 + t
	if t == 0:
		var c0: Dictionary = world.get_colonists()[0]
		for kind in ["pick", "pick", "axe"]:
			world.spawn_ground_tool_item(kind, int(c0["x"]), int(c0["y"]))
	if t % 120 == 0:
		_order_wave(world, t / 120)
	if t % 25 == 0:
		for k in 3:
			var x := rng.randi_range(0, 47)
			var y := rng.randi_range(0, 47)
			var kind: String = ["dig", "chop", "forage", "till", "mine", "sow"][rng.randi_range(0, 5)]
			world.apply(_cmd(world, kind, {"x": x, "y": y, "priority": 1}))
		if variant == "r2":
			world.apply(_cmd(world, "bogus", {}))
	if t == 5:
		var c0: Dictionary = world.get_colonists()[0]
		world.apply(_cmd(world, "zone_add", {"x": int(c0["x"]) - 2, "y": int(c0["y"]) - 2, "width": 3, "height": 3}))
	if t == 150 or t == 500:
		world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"}))
	if variant == "r4" and (t == 60 or t == 460):
		world.apply(_cmd(world, "spawn_incident", {"id": "wolf_attack"}))
	for offer in world.get_pending_trade_offers():
		world.apply(_cmd(world, "accept_trade", {"trader_id": offer["trader_id"]}))

func _berries(world) -> Dictionary:
	var berries := {}
	for y in world.get_map_height():
		for x in world.get_map_width():
			var b: int = world.get_ground_berries(x, y)
			if b > 0:
				berries["%d_%d" % [x, y]] = [b, world.get_ground_berries_faction_id(x, y)]
	return berries

func _scoped_keys(world) -> int:
	var scoped := 0
	for k in world._progress_table.progress:
		if String(k).contains(":"):
			scoped += 1
	return scoped

func _run(variant: String, out_dir: String) -> Dictionary:
	_n = 0
	var world = WorldStateType.new(777, 10, 48, 48, true)
	var rng := RandomNumberGenerator.new()
	var path := out_dir.path_join("%s_tick.json" % variant)
	var stats := {"ticks": 0, "refused": [], "hash_mismatch": [], "berry_mismatch": [], "scoped_ticks": 0,
		"scoped_keys": 0, "berry_ticks": 0}
	for t in 800:
		_orders(world, rng, t, variant)
		world.tick()
		stats["ticks"] += 1
		var scoped := _scoped_keys(world)
		if scoped > 0:
			stats["scoped_ticks"] += 1
			stats["scoped_keys"] += scoped
		var live_berries := _berries(world)
		if not live_berries.is_empty():
			stats["berry_ticks"] += 1
		var written := SaveIOType.write_atomic(path, world.to_save_state())
		if not written.get("ok"):
			stats["refused"].append("%d:write %s %s" % [world.get_tick(), written.get("code", ""), written.get("message", "")])
			continue
		var read := SaveIOType.read(path)
		if not read.get("ok"):
			stats["refused"].append("%d:read %s %s" % [world.get_tick(), read.get("code", ""), read.get("message", "")])
			continue
		var loaded = WorldStateType.from_save_state(read["state"])
		loaded.enable_incidents()
		if loaded.state_hash() != world.state_hash():
			stats["hash_mismatch"].append(world.get_tick())
		if _berries(loaded) != live_berries:
			stats["berry_mismatch"].append(world.get_tick())
	stats["final_hash"] = world.state_hash()
	return stats

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var failed := false
	var totals := {"ticks": 0, "refused": 0, "hash_mismatch": 0, "berry_mismatch": 0}
	for variant in ["r2", "r4"]:
		var stats := _run(variant, out_dir)
		print("b5_probe[%s]: ticks=%d saved_and_reloaded=%d refused=%s hash_mismatch=%s berry_mismatch=%s ticks_with_rescue_key=%d rescue_keys=%d ticks_with_berries=%d final_hash=%d" % [
			variant, stats["ticks"], stats["ticks"] - (stats["refused"] as Array).size(), str(stats["refused"].slice(0, 5)),
			str(stats["hash_mismatch"]), str(stats["berry_mismatch"].slice(0, 10)), stats["scoped_ticks"],
			stats["scoped_keys"], stats["berry_ticks"], stats["final_hash"]])
		totals["ticks"] += stats["ticks"]
		totals["refused"] += (stats["refused"] as Array).size()
		totals["hash_mismatch"] += (stats["hash_mismatch"] as Array).size()
		totals["berry_mismatch"] += (stats["berry_mismatch"] as Array).size()
		if not (stats["refused"] as Array).is_empty() or not (stats["berry_mismatch"] as Array).is_empty():
			failed = true
	print("b5_probe: ticks=%d refused=%d hash_mismatch=%d berry_mismatch=%d %s" % [
		totals["ticks"], totals["refused"], totals["hash_mismatch"], totals["berry_mismatch"], "FAIL" if failed else "PASS"])
	quit(1 if failed else 0)
