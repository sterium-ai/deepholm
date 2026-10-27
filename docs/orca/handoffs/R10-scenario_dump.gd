extends SceneTree

## R10 byte-identity probe: a command fuzzer over every apply()/preview() path.
## Seed 9090, 48x48, incidents on. Every tick a probe-local RNG (seeded, never the
## world's) draws 6 commands over every command type the router dispatches plus an
## unknown type and malformed envelopes (not a Dictionary, missing or mistyped
## actor/command_id/tick/type/payload, float/bool payload values, a stale tick,
## build_line's tiles array on another type). Payloads mix valid targets (live job,
## site, zone, colonist and trader ids, in-bounds tiles, content kinds) with invalid
## ones. Each command is previewed first (the result, plus whether state_hash() or
## the event count moved -- they must not), then applied. Every tick traces
## state_hash(); every 100 ticks the world is saved and reloaded into a side copy
## (play continues on the original, a reloaded world has incidents off). Writes
## results, trace, saves and the full event log to the directory given as the first
## user argument. Run before and after the refactor and compare the files.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R10.md:
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const TICKS := 600
const TYPES := ["noop", "dig", "chop", "forage", "till", "sow", "mine", "complete_job", "cancel_job",
	"fail_job", "invalidate_job", "build", "build_line", "area_order", "cancel_site", "place_object",
	"remove_object", "set_labour", "set_faction", "spawn_incident", "accept_trade", "zone_add",
	"zone_remove", "no_such_type"]
const OBJECT_KINDS := ["chair", "door", "wooden_wall", "stone_wall", "table", "berry_bush", "bed",
	"workbench", "test_footprint_crate", "no_such_kind"]
const INCIDENTS := ["wildlife_wander", "trader_visit", "migrant_joins", "raider_incursion", "wolf_attack", "no_such_incident"]
const FACTIONS := ["colony", "wildlife", "raiders", "traders", "allies", "predators", "no_such_faction"]
const AREA_ORDERS := ["dig", "chop", "forage", "till", "sow", "mine", "cancel", "remove_object", "no_such_order"]
const LABOURS := ["mine", "chop", "farm", "haul", "build", "craft", "cook", "no_such_labour"]

var _rng := RandomNumberGenerator.new()
var _n := 0
var _preview_mutations := 0

func _pick(values: Array):
	return values[_rng.randi_range(0, values.size() - 1)]

func _coord() -> int:
	return _rng.randi_range(-2, 49)

func _job_id(world) -> String:
	var jobs: Array = world.get_jobs()
	if jobs.is_empty() or _rng.randi_range(0, 4) == 0:
		return _pick(["job_999999", "nope", ""])
	return String(_pick(jobs)["id"])

func _site_tile(world) -> Vector2i:
	var sites: Array = world.get_construction_sites()
	if sites.is_empty() or _rng.randi_range(0, 2) == 0:
		return Vector2i(_coord(), _coord())
	var site: Dictionary = _pick(sites)
	return Vector2i(int(site["origin"].x), int(site["origin"].y)) if site.get("origin") is Vector2i else Vector2i(int(site.get("x", 0)), int(site.get("y", 0)))

func _actor_id(world) -> String:
	var actors: Array = world.get_colonists()
	if actors.is_empty() or _rng.randi_range(0, 4) == 0:
		return "nobody"
	return String(_pick(actors)["id"])

func _payload(world, type: String) -> Dictionary:
	match type:
		"dig", "chop", "forage", "till", "sow", "mine":
			var p := {"x": _coord(), "y": _coord()}
			if _rng.randi_range(0, 3) == 0:
				p["priority"] = _rng.randi_range(-1, 5)
			if _rng.randi_range(0, 3) == 0:
				p["assignee"] = _actor_id(world)
			if _rng.randi_range(0, 9) == 0:
				p.erase("x")
			return p
		"complete_job", "cancel_job", "fail_job", "invalidate_job":
			# An int job_id on cancel_job hits a script error on main too (String(int) in
			# the site-id lookup; R10.md "Known limitations"), so only the others get one.
			if _rng.randi_range(0, 9) == 0 and type != "cancel_job":
				return {"job_id": 5}
			if type == "cancel_job" and _rng.randi_range(0, 2) == 0 and not world.get_construction_sites().is_empty():
				return {"job_id": String(_pick(world.get_construction_sites())["id"])}
			return {"job_id": _job_id(world)}
		"build", "place_object":
			var p := {"x": _coord(), "y": _coord(), "kind": _pick(OBJECT_KINDS)}
			if _rng.randi_range(0, 3) == 0:
				p["orientation"] = _pick(["horizontal", "vertical", "diagonal"])
			return p
		"build_line":
			var tiles: Array = []
			var start := Vector2i(_coord(), _coord())
			var horizontal := _rng.randi_range(0, 1) == 0
			for i in _rng.randi_range(0, 6):
				tiles.append({"x": start.x + (i if horizontal else 0), "y": start.y + (0 if horizontal else i)})
			if _rng.randi_range(0, 9) == 0:
				tiles.append({"x": "a", "y": 1})
			return {"kind": _pick(["wooden_wall", "stone_wall", "door", "berry_bush"]), "tiles": tiles}
		"area_order":
			var p := {"order": _pick(AREA_ORDERS), "x": _coord(), "y": _coord(),
				"width": _rng.randi_range(0, 6), "height": _rng.randi_range(0, 6)}
			if _rng.randi_range(0, 4) == 0:
				p["priority"] = _rng.randi_range(0, 4)
			return p
		"cancel_site":
			var tile := _site_tile(world)
			var p := {"x": tile.x, "y": tile.y}
			if _rng.randi_range(0, 9) == 0:
				p["extra"] = 1
			return p
		"remove_object":
			var objects: Array = world.get_objects()
			if not objects.is_empty() and _rng.randi_range(0, 1) == 0:
				var o: Dictionary = _pick(objects)
				return {"x": int(o["x"]), "y": int(o["y"])}
			return {"x": _coord(), "y": _coord()}
		"set_labour":
			return {"colonist": _actor_id(world), "kind": _pick(LABOURS), "level": _rng.randi_range(-1, 5)}
		"set_faction":
			return {"target": _actor_id(world), "faction_id": _pick(FACTIONS)}
		"spawn_incident":
			return {"id": _pick(INCIDENTS)}
		"accept_trade":
			var offers: Array = world.get_pending_trade_offers()
			if not offers.is_empty() and _rng.randi_range(0, 1) == 0:
				return {"trader_id": String(_pick(offers)["trader_id"])}
			return {"trader_id": _pick(["nobody", ""])}
		"zone_add":
			return {"x": _coord(), "y": _coord(), "width": _rng.randi_range(0, 5), "height": _rng.randi_range(0, 5)}
		"zone_remove":
			var zones: Array = world.get_zones()
			if not zones.is_empty() and _rng.randi_range(0, 1) == 0:
				return {"id": String(_pick(zones)["id"])}
			return {"id": _pick(["zone_999", ""])}
	return {"x": 1}

func _command(world):
	_n += 1
	var command := {"actor": "player", "command_id": "c%d" % _n, "tick": world.get_tick(), "type": "noop", "payload": {}}
	var type: String = _pick(TYPES)
	command["type"] = type
	command["payload"] = _payload(world, type)
	match _rng.randi_range(0, 39):
		0: return "not a dictionary"
		1: command.erase("actor")
		2: command["actor"] = 7
		3: command.erase("command_id")
		4: command["tick"] = world.get_tick() + 1
		5: command["tick"] = "now"
		6: command.erase("type")
		7: command["payload"] = []
		8: command["payload"]["f"] = 1.5
		9: command["payload"]["b"] = true
		10: command["payload"]["tiles"] = [{"x": 1, "y": 1}]
		11: command["actor"] = ""
	return command

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	for t in range(from_tick, to_tick):
		if t % 25 == 0:
			results.append(world.apply({"actor": "player", "command_id": "w%d" % t, "tick": world.get_tick(),
				"type": "spawn_incident", "payload": {"id": "trader_visit" if t % 50 == 0 else "wolf_attack"}}))
		# Accept every other pending offer the tick it appears (the success path of accept_trade).
		var offers: Array = world.get_pending_trade_offers()
		if not offers.is_empty() and t % 2 == 0:
			var trader_id := String(offers[0]["trader_id"])
			results.append({"preview": world.preview({"actor": "player", "command_id": "p%d" % t, "tick": world.get_tick(),
				"type": "accept_trade", "payload": {"trader_id": trader_id}})})
			results.append(world.apply({"actor": "player", "command_id": "t%d" % t, "tick": world.get_tick(),
				"type": "accept_trade", "payload": {"trader_id": trader_id}}))
		for i in 6:
			var command = _command(world)
			var hash_before: int = world.state_hash()
			var events_before: int = world._event_log._events.size()
			var preview: Dictionary = world.preview(command)
			if world.state_hash() != hash_before or world._event_log._events.size() != events_before:
				_preview_mutations += 1
			results.append({"preview": preview})
			results.append(world.apply(command))
		world.tick()
		trace.append({"tick": world.get_tick(), "hash": world.state_hash(), "jobs": world.get_jobs().size(),
			"sites": world.get_construction_sites().size(), "zones": world.get_zones().size(),
			"objects": world.get_objects().size(), "actors": world.get_colonists().size()})

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	_rng.seed = 424242
	var world = WorldStateType.new(9090, 10, 48, 48, true)
	var results: Array = []
	var trace: Array = []
	var io: Array = []
	for leg in TICKS / 100:
		_play(world, results, trace, leg * 100, (leg + 1) * 100)
		var state: Dictionary = world.to_save_state()
		_write(out_dir.path_join("state_%d.json" % ((leg + 1) * 100)), JSON.stringify(state, "\t"))
		io.append(SaveIOType.write_atomic(out_dir.path_join("save_%d.json" % ((leg + 1) * 100)), state).get("ok"))
		var loaded = WorldStateType.from_save_state(state)
		results.append({"hash": world.state_hash(), "loaded_hash": loaded.state_hash(),
			"resaved_equal": JSON.stringify(loaded.to_save_state()) == JSON.stringify(state)})
	var events: Array = world.get_events()
	_write(out_dir.path_join("events.json"), JSON.stringify(events, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io))
	var applied := {}
	var rejected := {}
	var previews_ok := 0
	for r in results:
		if r.has("preview"):
			if r["preview"]["ok"]:
				previews_ok += 1
		elif r.has("ok"):
			if r["ok"]:
				var type := String(r["applied"]["type"])
				applied[type] = int(applied.get(type, 0)) + 1
			else:
				var reason := String((r["rejection"] as Dictionary).get("reason", "?"))
				rejected[reason] = int(rejected.get(reason, 0)) + 1
	var keys := applied.keys()
	keys.sort()
	var applied_sorted := {}
	for k in keys:
		applied_sorted[k] = applied[k]
	keys = rejected.keys()
	keys.sort()
	var rejected_sorted := {}
	for k in keys:
		rejected_sorted[k] = rejected[k]
	print("scenario_dump: commands=%d previews_ok=%d preview_mutations=%d applied=%s rejected=%s events=%d actors=%d io=%s hash=%d" % [
		_n, previews_ok, _preview_mutations, JSON.stringify(applied_sorted), JSON.stringify(rejected_sorted),
		events.size(), world.get_colonists().size(), str(io), world.state_hash()])
	quit(0)
