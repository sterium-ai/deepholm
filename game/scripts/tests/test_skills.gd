extends SceneTree

## F3 (ADR 062): skills and XP per labour, through the real triggers (chop orders, a ground
## stack the haul giver picks up, ticks, saves, a replay):
## - two colonists, chop 8 (farther) and chop 0 (nearer), one tree order: the level-8 colonist
##   gets it and its work toil lasts ~49 % of the level-0 one (owner, 2026-10-30: the curve
##   70 % -> 160 % stays, so the entry's "~62 %" became ~49 %); equal skills keep the nearer one;
## - completed chops raise XP and cross the first threshold after xp_to_next[0] jobs;
## - a level-5 hauler carries one more unit than a level-0 one;
## - starting skills for seed 42 are identical across runs and through a save, two labours at
##   3..6 and the rest at 0..2; a roster's skills override them;
## - save/load mid-XP keeps ticking in step (state_hash every tick); a replay reproduces it;
## - the view snapshot carries {level, xp, next} per labour.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const SkillsType = preload("res://scripts/core/actors/components/skills.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const WorldSeedingType = preload("res://scripts/core/worldgen/world_seeding.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const SEED := 6201
const TICK_BUDGET := 3000
const SAVE_PATH := "user://test-skills-mid-xp.json"
const LABOURS := ["mine", "chop", "farm", "haul", "build", "craft", "cook"]

var _failed := false
var _next_command := 0

func _init() -> void:
	_check_skilled_colonist_is_picked_and_faster()
	_check_equal_skills_keep_the_nearer_colonist()
	_check_xp_crosses_the_first_threshold()
	_check_level_five_hauler_carries_one_more()
	_check_starting_skills_are_seeded_and_stable()
	_check_roster_skills_override_the_seeded_ones()
	_check_save_load_mid_xp_continues_identically()
	_check_replay_reproduces_skill_gains()
	_check_view_snapshot_carries_skill_progress()
	if _failed:
		quit(1)
		return
	print("test_skills: PASS")
	quit(0)

## Acceptance: the chop-8 colonist is picked although the chop-0 one is nearer, earns the XP,
## and its work toil lasts ~49 % of what the chop-0 colonist's lasts on the same tree alone.
func _check_skilled_colonist_is_picked_and_faster() -> void:
	var world := _arena()
	var novice := _add_worker(world, "c_novice", 8, 10, {"chop": 0})
	var expert := _add_worker(world, "c_expert", 14, 10, {"chop": 8})
	var tree := Vector2i(10, 10)
	TestAccess.set_tile(world, tree.x, tree.y, WorldStateType.TILE_TREE)
	_reset_caches(world)
	world.spawn_ground_tool_item("axe", 8, 11)
	world.spawn_ground_tool_item("axe", 14, 11)
	var run := _run_chop(world, tree)
	_expect(run["worker"] == "c_expert", "the chop-8 colonist must take the order, got '%s'" % run["worker"])
	_expect(int(expert["skills"]["chop"]["xp"]) == 1, "the chop-8 colonist must earn 1 chop XP, got %s" % [expert["skills"]["chop"]])
	_expect(int(novice["skills"]["chop"]["xp"]) == 0, "the chop-0 colonist must earn nothing")
	var alone := _arena()
	_add_worker(alone, "c_novice", 8, 10, {"chop": 0})
	TestAccess.set_tile(alone, tree.x, tree.y, WorldStateType.TILE_TREE)
	_reset_caches(alone)
	alone.spawn_ground_tool_item("axe", 8, 11)
	var slow := _run_chop(alone, tree)
	var base_ticks := int(TestAccess.work_ticks(world)["chop"])
	_expect(slow["worker"] == "c_novice", "alone, the chop-0 colonist must take the order")
	_expect(int(run["work_ticks"]) == 28 and int(slow["work_ticks"]) == 57,
		"chop (%d ticks) must last 28 ticks at level 8 and 57 at level 0, got %d and %d"
			% [base_ticks, run["work_ticks"], slow["work_ticks"]])
	var ratio := float(run["work_ticks"]) / float(slow["work_ticks"])
	_expect(ratio > 0.46 and ratio < 0.52, "level 8 must work in ~49 %% of the level-0 time, got %.3f" % ratio)
	print("test_skills: chop work ticks level 8 = %d, level 0 = %d, ratio %.3f" % [run["work_ticks"], slow["work_ticks"], ratio])

## ADR 062: equal skill keeps the old choice, the nearer (best-scored) colonist.
func _check_equal_skills_keep_the_nearer_colonist() -> void:
	var world := _arena()
	_add_worker(world, "c_far", 14, 10, {"chop": 3})
	_add_worker(world, "c_near", 8, 10, {"chop": 3})
	var tree := Vector2i(10, 10)
	TestAccess.set_tile(world, tree.x, tree.y, WorldStateType.TILE_TREE)
	_reset_caches(world)
	world.spawn_ground_tool_item("axe", 8, 11)
	world.spawn_ground_tool_item("axe", 14, 11)
	var run := _run_chop(world, tree)
	_expect(run["worker"] == "c_near", "with equal chop skill the nearer colonist must take the order, got '%s'" % run["worker"])

## Acceptance: each completed chop earns xp_per_job's default (1); the level rises exactly when
## the count reaches xp_to_next[0], with XP restarting at 0.
func _check_xp_crosses_the_first_threshold() -> void:
	var world := _arena()
	var worker := _add_worker(world, "c_learner", 4, 4, {"chop": 0})
	world.spawn_ground_tool_item("axe", 4, 5)
	var rules := SkillsType.rules(TestAccess.content(world))
	var needed := int((rules["xp_to_next"] as Array)[0])
	var per_job := SkillsType.xp_for_kind(rules, "chop")
	_expect(per_job == 1, "chop must earn the default 1 XP per job, got %d" % per_job)
	for i in needed:
		var tree := Vector2i(6 + i, 8)
		TestAccess.set_tile(world, tree.x, tree.y, WorldStateType.TILE_TREE)
		_reset_caches(world)
		var run := _run_chop(world, tree)
		_expect(run["worker"] == "c_learner", "chop %d must be done by the learner" % i)
		var record: Dictionary = worker["skills"]["chop"]
		if i < needed - 1:
			_expect(int(record["level"]) == 0 and int(record["xp"]) == i + 1,
				"after %d chops the learner must be level 0 with %d XP, got %s" % [i + 1, i + 1, record])
		else:
			_expect(int(record["level"]) == 1 and int(record["xp"]) == 0,
				"after %d chops the learner must reach level 1 with 0 XP, got %s" % [needed, record])

## Acceptance: haul capacity is 4 plus one per 5 haul levels: the level-5 hauler lifts 5 units
## of a 10-unit stack, the level-0 one 4.
func _check_level_five_hauler_carries_one_more() -> void:
	var lifted := {}
	for level in [0, 5]:
		var world := _arena()
		_add_worker(world, "c_hauler", 6, 6, {"haul": level})
		Scenarios.add_stock(world, "wood", 10, 12, 12)
		var zone := Scenarios.command(world, "zone_%d" % level, "zone_add", {"x": 2, "y": 2, "width": 2, "height": 2})
		_expect(bool(zone.get("ok", false)), "zone_add must be accepted: %s" % zone)
		var most := 0
		for _tick in 400:
			_top_up_needs(world)
			world.tick()
			var hauler := TestAccess.find_colonist(world, "c_hauler")
			for entry: Dictionary in (hauler.get("hands", []) as Array):
				most = maxi(most, int(entry["count"]))
		lifted[level] = most
	_expect(int(lifted[0]) == 4, "a level-0 hauler must carry 4 units, got %d" % lifted[0])
	_expect(int(lifted[5]) == 5, "a level-5 hauler must carry 5 units, got %d" % lifted[5])

## Acceptance: seed 42's starting skills are the same on two runs and after a save/load; every
## colonist has exactly starting.major_count labours at major_min..major_max and the rest at
## minor_min..minor_max, all with 0 XP.
func _check_starting_skills_are_seeded_and_stable() -> void:
	var first := WorldStateType.new(42)
	var second := WorldStateType.new(42)
	var skills_first := _skills_of(first)
	_expect(JSON.stringify(skills_first) == JSON.stringify(_skills_of(second)),
		"seed 42 must seed the same skills on every run")
	_expect(first.state_hash() == second.state_hash(), "seed 42 must build the same world twice")
	var starting: Dictionary = SkillsType.rules(TestAccess.content(first))["starting"]
	for id: String in skills_first:
		var majors := 0
		for labour: String in LABOURS:
			var record: Dictionary = skills_first[id][labour]
			var level := int(record["level"])
			_expect(int(record["xp"]) == 0, "%s %s must start with 0 XP" % [id, labour])
			if level >= int(starting["major_min"]):
				majors += 1
				_expect(level <= int(starting["major_max"]), "%s %s starts above major_max: %d" % [id, labour, level])
			else:
				_expect(level >= int(starting["minor_min"]) and level <= int(starting["minor_max"]),
					"%s %s starts outside minor_min..minor_max: %d" % [id, labour, level])
		_expect(majors == int(starting["major_count"]), "%s must start with %d strong labours, got %d" % [id, starting["major_count"], majors])
	print("test_skills: seed 42 starting skills %s" % JSON.stringify(skills_first))
	var loaded := _save_and_load(first)
	_expect(loaded != null and JSON.stringify(_skills_of(loaded)) == JSON.stringify(skills_first),
		"seed 42's starting skills must survive a save/load")
	_expect(loaded != null and loaded.state_hash() == first.state_hash(), "the loaded world must keep the state_hash")

## A16b roster: a colonist definition's "skills" replaces those labours' seeded levels (XP 0)
## and leaves the other labours and the other colonists as seeded.
func _check_roster_skills_override_the_seeded_ones() -> void:
	var host_a := WorldStateType.new(42)
	var host_b := WorldStateType.new(42)
	var content := TestAccess.content(host_a)
	var mapgen: Dictionary = content.document("mapgen")
	var seeded := WorldSeedingType.seed_world(42, 4242, 48, 48, mapgen, content,
		ObjectTableType.new(TestAccess.object_definitions(host_a), TestAccess.tile_grid(host_a)))
	var fixed := WorldSeedingType.seed_world(42, 4242, 48, 48, mapgen, content,
		ObjectTableType.new(TestAccess.object_definitions(host_b), TestAccess.tile_grid(host_b)),
		[{"skills": {"chop": 8, "haul": 0}}])
	var seeded_skills: Dictionary = seeded["colonists"][0]["skills"]
	var fixed_skills: Dictionary = fixed["colonists"][0]["skills"]
	_expect(JSON.stringify(fixed_skills["chop"]) == JSON.stringify({"level": 8, "xp": 0}), "the roster must fix chop at 8, got %s" % [fixed_skills["chop"]])
	_expect(JSON.stringify(fixed_skills["haul"]) == JSON.stringify({"level": 0, "xp": 0}), "the roster must fix haul at 0")
	for labour: String in ["mine", "farm", "build", "craft", "cook"]:
		_expect(JSON.stringify(fixed_skills[labour]) == JSON.stringify(seeded_skills[labour]), "unlisted %s must keep its seeded level" % labour)
	_expect(JSON.stringify(fixed["colonists"][1]["skills"]) == JSON.stringify(seeded["colonists"][1]["skills"]),
		"colonists the roster does not define keep their seeded skills")

## Acceptance: a world saved mid-XP (some chops done, more queued, one in progress) loads and
## keeps ticking in step with the original, state_hash checked every tick, ending with the same
## skills.
func _check_save_load_mid_xp_continues_identically() -> void:
	var world := _chop_session_world()
	for _tick in 260:
		_top_up_needs(world)
		world.tick()
	var saved_chop: Dictionary = TestAccess.find_colonist(world, "c_learner")["skills"]["chop"].duplicate()
	_expect(int(saved_chop["xp"]) > 0 and int(saved_chop["level"]) == 0, "the save must be taken mid-XP, got %s" % [saved_chop])
	var loaded := _save_and_load(world)
	if loaded == null:
		return
	_expect(loaded.state_hash() == world.state_hash(), "the loaded world must hash like the saved one")
	for tick in 700:
		_top_up_needs(world)
		_top_up_needs(loaded)
		world.tick()
		loaded.tick()
		if loaded.state_hash() != world.state_hash():
			_fail("the loaded world diverged at tick %d" % world.get_tick())
			return
	var after := TestAccess.find_colonist(loaded, "c_learner")
	_expect(int(after["skills"]["chop"]["xp"]) > int(saved_chop["xp"]),
		"the loaded world must keep earning chop XP past %s, got %s" % [saved_chop, after["skills"]["chop"]])

## Acceptance: a recorded session (chop orders issued during it, XP gained) replays to every
## state_hash checkpoint.
func _check_replay_reproduces_skill_gains() -> void:
	var world := _arena()
	var worker := _add_worker(world, "c_learner", 4, 4, {"chop": 2})
	world.spawn_ground_tool_item("axe", 4, 5)
	for i in 3:
		TestAccess.set_tile(world, 6 + i, 8, WorldStateType.TILE_TREE)
	_reset_caches(world)
	var recorder := CommandRecorderType.new()
	# WorldState.new() runs without incidents (only boot enables them), and so must the replay.
	recorder.start(world, 10, false)
	for tick in 600:
		if tick < 3:
			world.apply(_command(world, "chop", {"x": 6 + tick, "y": 8, "priority": 1}))
		world.tick()
		recorder.observe_tick(world)
	var recording := recorder.stop()
	_expect(int(worker["skills"]["chop"]["xp"]) == 3, "the recorded session must earn 3 chop XP, got %s" % [worker["skills"]["chop"]])
	var result := recording.replay()
	_expect(bool(result.get("ok", false)), "the replay must match every checkpoint: %s" % [result])

## ADR 062 / ADR 055: the view snapshot's "skills" gives each detailed worker's level, XP and
## the XP its level needs (0 at the top level), from skills.json.
func _check_view_snapshot_carries_skill_progress() -> void:
	var world := _arena()
	var worker := _add_worker(world, "c_viewed", 4, 4, {"chop": 3, "mine": 10})
	worker["skills"]["chop"]["xp"] = 7
	var thresholds: Array = SkillsType.rules(TestAccess.content(world))["xp_to_next"]
	var skills: Dictionary = world.get_view_snapshot(["c_viewed"])["skills"]
	_expect(skills.has("c_viewed"), "the snapshot must carry the detailed worker's skills")
	if not skills.has("c_viewed"):
		return
	_expect(JSON.stringify(skills["c_viewed"]["chop"]) == JSON.stringify({"level": 3, "xp": 7, "next": int(thresholds[3])}),
		"chop progress must be level 3, 7 XP, next %d, got %s" % [thresholds[3], skills["c_viewed"]["chop"]])
	_expect(int(skills["c_viewed"]["mine"]["next"]) == 0, "the top level must report next 0")
	_expect(not world.get_view_snapshot([])["skills"].has("c_viewed"), "only detailed workers carry skills")

# --- helpers ---------------------------------------------------------------

## A floor world, no colonists or objects, needs decaying normally (topped up by the loops).
func _arena() -> WorldStateType:
	return Scenarios.empty_floor_world(SEED)

## A spawned colonist (ActorTable's real shape: labour table all 3, skills all 0) at (x, y)
## with `levels` written into its skills.
func _add_worker(world: WorldStateType, id: String, x: int, y: int, levels: Dictionary) -> Dictionary:
	var actor := ActorTableType.spawn("colonist", x, y, TestAccess.content(world), id)
	actor.erase("carrying")
	actor["hands"] = []
	actor["trapped"] = null
	for labour: String in levels:
		SkillsType.set_level(actor, labour, int(levels[labour]))
	TestAccess.append_colonist(world, actor)
	return actor

## Raw tile writes drop the passability cache and the region/room maps (see Scenarios).
func _reset_caches(world: WorldStateType) -> void:
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	TestAccess.tile_grid(world).rooms = null

## A learner with 9 trees queued as chop orders, ready to tick.
func _chop_session_world() -> WorldStateType:
	var world := _arena()
	_add_worker(world, "c_learner", 4, 4, {"chop": 0})
	world.spawn_ground_tool_item("axe", 4, 5)
	for i in 9:
		TestAccess.set_tile(world, 6 + i, 8, WorldStateType.TILE_TREE)
	_reset_caches(world)
	for i in 9:
		world.apply(_command(world, "chop", {"x": 6 + i, "y": 8, "priority": 1}))
	return world

## Issues one chop order on `tree` and ticks until the tile is no longer a tree. Returns the
## colonist whose work toil ran on it and how many ticks that toil lasted.
func _run_chop(world: WorldStateType, tree: Vector2i) -> Dictionary:
	var result := world.apply(_command(world, "chop", {"x": tree.x, "y": tree.y, "priority": 1}))
	_expect(bool(result.get("ok", false)), "chop at %s must be accepted: %s" % [tree, result])
	var worker := ""
	var work_ticks := 0
	var ticks := 0
	while ticks < TICK_BUDGET and world.get_tile(tree.x, tree.y) == WorldStateType.TILE_TREE:
		_top_up_needs(world)
		world.tick()
		ticks += 1
		for actor in TestAccess.colonists(world):
			if actor.get("work") is Dictionary:
				worker = String(actor["id"])
				work_ticks += 1
	# The completing tick clears "work" before this loop sees it.
	return {"worker": worker, "work_ticks": work_ticks + 1, "ticks": ticks}

## Needs held full so only the orders under test run (as test_chop_tile_kind.gd does).
func _top_up_needs(world: WorldStateType) -> void:
	for actor in TestAccess.colonists(world):
		if actor.get("needs") is Dictionary:
			for kind in (actor["needs"] as Dictionary).keys():
				actor["needs"][kind] = 100

func _skills_of(world: WorldStateType) -> Dictionary:
	var skills := {}
	for actor in TestAccess.colonists(world):
		skills[String(actor["id"])] = (actor["skills"] as Dictionary).duplicate(true)
	return skills

## Writes world through SaveIO and reads it back decoded; null (and a failure) when either fails.
func _save_and_load(world: WorldStateType) -> WorldStateType:
	var written := SaveIOType.write_atomic(SAVE_PATH, StateCodecType.encode(world))
	_expect(bool(written.get("ok", false)), "the save must be written: %s" % [written])
	var read := SaveIOType.read(SAVE_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(bool(read.get("ok", false)), "the save must load: %s" % [read])
	if not read.get("ok", false):
		return null
	return StateCodecType.decode(read["state"])

func _command(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	return {"actor": "player", "command_id": "skills_%d" % _next_command, "tick": world.get_tick(), "type": type, "payload": payload}

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
