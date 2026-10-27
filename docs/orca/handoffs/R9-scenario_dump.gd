extends SceneTree

## R9 byte-identity probe for combat and death. Seed 4242, 48x48, incidents on. At tick 0 it
## clears an 11x11 yard at the map centre, moves the spawned colonists there and adds three
## more. Colonists start at mixed hp (some below their flee fraction, some one hit from
## death) and some hold items in their hands or a held tool (axe/pick), so deaths exercise
## every drop path. Needs decay 25x faster, so need jobs and paused jobs are live when an
## actor dies. Work orders (chop/till/dig/mine) and a stockpile zone keep colonists busy.
## Pairs of wolves (wildlife) arrive every 60 ticks from alternating sides, at mixed hp, some
## with an "inventory". Every 100 ticks a 2/2-hp "predators" wolf (hostile to the colony,
## unlike wildlife) carrying stacks, two axes and a pick slot appears next to a healthy
## colonist, which kills it, so the inventory drop path runs in every segment. Every 20 ticks three random orders or a cancel_job on a live flee/
## approach job. Every 100 ticks the world is saved (raw and through SaveIO), reloaded with
## from_save_state() and play continues on the reloaded copy. Every 5 ticks it traces every
## actor's position, health, combat component, hands, held tool, work/route state and combat
## reason, the raw combat-status and paused-jobs maps, every non-terminal job, the ground
## items and tool items, CombatGiver/ApproachGiver associations and state_hash(); each line is
## a deep copy. The event log (runtime only) is captured, deep-copied, before every reload.
## Runs unchanged on main (WorldState._combat_status) and on R9 (world._combat_system).
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const COMBAT_JOB_KINDS := ["flee", "approach"]

var _n := 0
var _wolves := 0
var _h := Vector2i(24, 24)

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## preview() then apply(), both recorded.
func _issue(world, results: Array, type: String, payload: Dictionary) -> void:
	var command := _cmd(world, type, payload)
	results.append({"preview": world.preview(command.duplicate(true))})
	results.append(world.apply(command))

## CombatSystem's field on R9, WorldState's own "_"-prefixed field on main.
func _combat_status(world) -> Dictionary:
	var system = world.get("_combat_system")
	return system.combat_status if system != null else world.get("_combat_status")

func _trace_line(world) -> Dictionary:
	var line := {"tick": world.get_tick()}
	var actors: Array = []
	for actor in world._colonists:
		var id := String(actor["id"])
		actors.append({"id": id, "kind": actor.get("kind"), "faction": actor.get("factionId"), "x": actor["x"], "y": actor["y"],
			"health": actor.get("health"), "combat": actor.get("combat"), "hands": actor.get("hands"),
			"held_tool": actor.get("held_tool"), "inventory": actor.get("inventory"), "work": actor.get("work"),
			"routed": actor.get("route") != null, "combat_reason": world.get_actor_combat_reason(id)})
	line["actors"] = actors
	line["combat_status"] = _combat_status(world)
	line["paused_jobs"] = world._needs_system.paused_jobs
	var jobs: Array = []
	for job in world.get_jobs():
		if String(job.get("status", "")) in ["queued", "active"] or String(job.get("kind", "")) in COMBAT_JOB_KINDS:
			jobs.append(job)
	line["jobs"] = jobs
	line["items"] = world.get_items()
	line["tool_items"] = world.get_tool_items()
	line["with_health"] = world.get_actors_with_health()
	line["blocked_targets"] = StateCodec._encode_combat_blocked_targets(world._combat_giver.get_blocked_targets())
	line["approach_targets"] = StateCodec._encode_approach_job_targets(world._approach_giver.get_job_targets())
	line["hash"] = world.state_hash()
	return line.duplicate(true)

func _in_map(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < 48 and p.y < 48

func _set_tile(world, p: Vector2i, kind: String) -> void:
	if not _in_map(p):
		return
	var index: int = world._tile_grid.tile_index(p.x, p.y)
	var was_water: bool = world._tile_grid.tiles[index] == "water"
	world._tile_grid.tiles[index] = kind
	world._tile_grid.update_water_tile_cache(p.x, p.y, was_water, kind == "water")

func _send_wolf(world, results: Array, from: Vector2i, hp: int, loot: bool) -> void:
	if not _in_map(from):
		return
	_set_tile(world, from, "soil")
	world._object_table.set_object(from.x, from.y, "")
	_wolves += 1
	var id := "probe_wolf_%d" % _wolves
	var wolf: Dictionary = ActorTableType.spawn("wolf", from.x, from.y, world._content, id)
	wolf["factionId"] = "wildlife"
	wolf["health"]["hp"] = hp
	if loot:
		wolf["inventory"] = {"items": [{"kind": "stone", "count": 2}, {"kind": "axe", "count": 2}], "tool": "pick"}
	world._colonists.append(wolf)
	results.append({"wolf": id, "hp": hp, "loot": loot})

func _order_at(world, results: Array, p: Vector2i) -> void:
	if not _in_map(p):
		return
	match world.get_tile(p.x, p.y):
		"tree":
			_issue(world, results, "chop", {"x": p.x, "y": p.y, "priority": 1})
		"rock":
			_issue(world, results, "mine", {"x": p.x, "y": p.y, "priority": 1})
		"soil":
			_issue(world, results, ["till", "dig"][(p.x + p.y) % 2], {"x": p.x, "y": p.y, "priority": 1})

func _setup(world, results: Array) -> void:
	var h := _h
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			_set_tile(world, h + Vector2i(dx, dy), "soil")
			world._object_table.set_object(h.x + dx, h.y + dy, "")
	var i := 0
	for actor in world._colonists:
		actor["x"] = h.x - 1 + i % 3
		actor["y"] = h.y - 1 + i / 3
		i += 1
	for k in 3:
		var extra: Dictionary = ActorTableType.spawn("colonist", h.x - 1 + k, h.y + 1, world._content, "probe_colonist_%d" % k)
		extra.erase("carrying")
		extra["hands"] = []
		extra["factionId"] = "colony"
		world._append_colonist(extra)
	world.state_hash() # backfills health/combat on every colonist before the probe edits them
	var start_hp := [100, 8, 45, 20, 3, 70]
	var start_needs := [[60, 30, 90], [20, 80, 40], [95, 12, 70], [35, 55, 15], [80, 40, 30], [50, 50, 50]]
	i = 0
	for actor in world._colonists:
		actor["health"]["hp"] = start_hp[i % start_hp.size()]
		var levels: Array = start_needs[i % start_needs.size()]
		actor["needs"] = {"food": levels[0], "water": levels[1], "rest": levels[2]}
		if i % 3 == 1:
			actor["hands"] = [{"kind": "stone", "count": 2}, {"kind": "wood", "count": 1}]
		if i % 2 == 0:
			var tool_id: String = world.spawn_ground_tool_item(["axe", "pick"][(i % 4) / 2], int(actor["x"]), int(actor["y"]))
			world.set_tool_item_held(tool_id, String(actor["id"]))
			actor["held_tool"] = tool_id
		i += 1
	for kind in world._need_definitions:
		world._need_definitions[kind]["rate_per_day"] = int(world._need_definitions[kind]["rate_per_day"]) * 25
	_set_tile(world, h + Vector2i(-5, -5), "water")
	world._item_table.ground_berries["%d_%d" % [h.x + 5, h.y - 5]] = 3
	world._object_table.set_object(h.x + 4, h.y, "bed")
	world._item_table.place_new_ground_item("wood", 3, h.x + 2, h.y - 4)
	_issue(world, results, "zone_add", {"x": h.x + 3, "y": h.y + 3, "width": 2, "height": 2})
	for dy in range(-10, 11, 4):
		for dx in [-9, 9]:
			_order_at(world, results, h + Vector2i(dx, dy))

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9090 + from_tick
	for t in range(from_tick, to_tick):
		if t == 0:
			_setup(world, results)
		var h := _h
		if t % 20 == 10:
			for k in 3:
				var roll := rng.randi_range(0, 3)
				if roll == 0:
					var live: Array = []
					for job in world.get_jobs():
						if String(job.get("kind", "")) in COMBAT_JOB_KINDS and String(job.get("status", "")) in ["queued", "active"]:
							live.append(String(job["id"]))
					if not live.is_empty():
						results.append(world.apply(_cmd(world, "cancel_job", {"job_id": live[rng.randi_range(0, live.size() - 1)]})))
				else:
					_order_at(world, results, h + Vector2i(rng.randi_range(-11, 11), rng.randi_range(-11, 11)))
		if t % 60 == 20:
			var side := 1 if (t / 60) % 2 == 0 else -1
			for k in 2:
				var hp: int = [40, 4, 15, 2][(t / 60 + k) % 4]
				_send_wolf(world, results, h + Vector2i(side * (7 + k), rng.randi_range(-3, 3)), hp, (t / 60 + k) % 2 == 0)
		if t % 100 == 50:
			# A looted, nearly dead wolf right next to a healthy colonist: killed by it, so the
			# "inventory" drop path (stacks, tool kinds, tool slot) runs in every segment.
			for actor in world._colonists:
				if String(actor.get("kind", "")) == "colonist" and int(actor["health"]["hp"]) >= 50:
					_send_wolf(world, results, Vector2i(int(actor["x"]) + 1, int(actor["y"])), 2, true)
					# At full health (2/2) it fights instead of fleeing, and as a predator (colony
					# treats wildlife as neutral) the colonist hits back.
					var wolf: Dictionary = world._colonists[world._colonists.size() - 1]
					wolf["health"]["maxHp"] = 2
					wolf["factionId"] = "predators"
					actor["combat"]["cooldown_remaining"] = 0
					break
		if t % 150 == 140:
			# Reinforcements, so deaths keep happening in every segment.
			var extra: Dictionary = ActorTableType.spawn("colonist", h.x, h.y, world._content, "probe_reinforcement_%d" % t)
			extra.erase("carrying")
			extra["hands"] = [{"kind": "flint", "count": 1}]
			extra["factionId"] = "colony"
			world._append_colonist(extra)
		world.tick()
		if t % 5 == 0:
			trace.append(_trace_line(world))

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(4242, 10, 48, 48, true)
	var results: Array = []
	var trace: Array = []
	var saves: Array = []
	var io: Array = []
	var events: Array = []
	for step in 8:
		var from := step * 100
		_play(world, results, trace, from, from + 100)
		var state: Dictionary = world.to_save_state()
		saves.append(state)
		var check := SaveIOType.write_atomic(out_dir.path_join("save_%d.json" % (from + 100)), state)
		io.append({"tick": from + 100, "ok": check.get("ok"), "error": "%s %s" % [check.get("code", ""), check.get("message", "")]})
		events.append({"segment_end": from + 100, "events": (world.get_events() as Array).duplicate(true)})
		world = WorldStateType.from_save_state(state.duplicate(true))
		world.enable_incidents()
		for kind in world._need_definitions:
			world._need_definitions[kind]["rate_per_day"] = int(world._need_definitions[kind]["rate_per_day"]) * 25
		trace.append({"reloaded": from + 100, "line": _trace_line(world)})
	_write(out_dir.path_join("states.json"), JSON.stringify(saves, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io, "\t"))
	_write(out_dir.path_join("events.json"), JSON.stringify(events, "\t"))
	var seen := {}
	var fighting_lines := 0
	var flee_jobs := {}
	var approach_jobs := {}
	var paused_while_alive := 0
	# No event marks a death: an actor counts as killed when it vanishes from the roster
	# between two trace lines of the same segment while hurt (an incident despawn leaves at
	# full health).
	var last_hp := {}
	var killed := {}
	for line in trace:
		var l: Dictionary = line.get("line", line)
		var present := {}
		for actor in (l["actors"] as Array):
			seen[String(actor["id"])] = true
			present[String(actor["id"])] = true
			if String(actor["combat_reason"]) == "fighting":
				fighting_lines += 1
		if not line.has("reloaded"):
			for id in last_hp:
				if not present.has(id) and int(last_hp[id][0]) < int(last_hp[id][1]):
					killed[id] = true
		last_hp = {}
		for actor in (l["actors"] as Array):
			if actor["health"] is Dictionary:
				last_hp[String(actor["id"])] = [actor["health"]["hp"], actor["health"]["maxHp"]]
		paused_while_alive += (l["paused_jobs"] as Dictionary).size()
		for job in (l["jobs"] as Array):
			if String(job["kind"]) == "flee": flee_jobs[String(job["id"])] = true
			if String(job["kind"]) == "approach": approach_jobs[String(job["id"])] = true
	var applied := 0
	var rejected := 0
	for r in results:
		if r.has("ok") and not r.has("preview"):
			if r["ok"]: applied += 1
			else: rejected += 1
	var event_count := 0
	var attack_segments := 0
	var by_type := {}
	for segment in events:
		event_count += (segment["events"] as Array).size()
		var in_segment := 0
		for event in (segment["events"] as Array):
			var type := String(event.get("type", ""))
			by_type[type] = int(by_type.get(type, 0)) + 1
			if type == "attacked_by":
				in_segment += 1
		if in_segment > 0:
			attack_segments += 1
	var failed: Array = []
	for entry in io:
		if not entry["ok"]:
			failed.append("%d:%s" % [entry["tick"], entry["error"]])
	var types := by_type.keys()
	types.sort()
	var type_counts: Array = []
	for type in types:
		type_counts.append("%s=%d" % [type, by_type[type]])
	# Probe wolves are not incident actors, so a looted one missing from the final roster died
	# (its stacks/tools/tool slot went through the inventory drop path).
	var alive := {}
	for actor in world._colonists:
		alive[String(actor["id"])] = true
	var looted_dead := 0
	for r in results:
		if r.has("wolf") and r["loot"] and not alive.has(String(r["wolf"])):
			looted_dead += 1
	print("scenario_dump: actors_seen=%d actors_left=%d wolves=%d results=%d applied=%d rejected=%d fighting_lines=%d flee_jobs=%d approach_jobs=%d paused_entries=%d events=%d killed_traced=%d looted_wolves_dead=%d tool_items_end=%d ground_items_end=%d attack_segments=%d save_refused=%s hash=%d" % [
		seen.size(), world._colonists.size(), _wolves, results.size(), applied, rejected, fighting_lines, flee_jobs.size(),
		approach_jobs.size(), paused_while_alive, event_count, killed.size(), looted_dead, world.get_tool_items().size(),
		world.get_items().size(), attack_segments, str(failed), world.state_hash()])
	print("scenario_dump_events: %s" % ", ".join(type_counts))
	quit(0)
