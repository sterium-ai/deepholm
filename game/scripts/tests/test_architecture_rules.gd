extends SceneTree

## Architecture-trace test for issue #242 (AGENTS.md "one work engine"):
## 1) every kind content/jobs.json declares is driven to completion purely
##    via world.tick(), asserting against ToilExecutor's own execution trace
##    (world._toils.trace, populated by toil_executor.gd itself) that each
##    toil the kind's own toils array names was actually entered/completed
##    through ToilExecutor -- not inferred after the fact from colonist
##    state. "reserve"/"release_all" are not in ToilExecutor's vocabulary (its
##    own doc comment: reserve is satisfied by the scheduler activating the
##    job, release_all by WorldState finishing it through the scheduler), so
##    those two are checked against the job's own observed status history
##    (must pass through "active", must reach "completed") instead;
## 2) world_state.gd declares exactly one per-colonist advance function and
##    none of the kind-specific symbols task #242 requires gone;
## 3) no game/scripts/viewer/*.gd script calls anything on a WorldState
##    instance beyond a get_* getter, apply(), get_events() or tick() -- its
##    two public mutators (world_state.gd's own "Only mutator alongside ..."
##    doc comments) plus the read-only surface. tick() is included alongside
##    apply() because it is WorldState's other declared mutator and
##    scripts/viewer/tick_driver.gd (unowned, unchanged by this task) already
##    calls it to advance the simulation once per frame; see "## Blocked" in
##    the handoff for why the literal get_*/apply()/get_events()-only wording
##    cannot be enforced without editing that out-of-scope file.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const WORLD_STATE_PATH := "res://scripts/core/world_state.gd"
const VIEWER_DIR := "res://scripts/viewer"
const JOBS_CONTENT_PATH := "res://content/jobs.json"

const MAX_TICKS := 400

## kind -> need field the job is driven by, for the three need-driven kinds;
## order-driven kinds (dig/chop/forage/haul) are absent from this map.
const NEED_DRIVEN_KINDS := {"sleep": "rest", "eat_food": "food", "drink_water": "water"}

var _failed := false
var _jobs_content: Dictionary = {}

func _init() -> void:
	_jobs_content = _load_jobs_content()
	_check_execution_trace()
	_check_single_advance_path()
	_check_viewer_purity()
	_check_drop_tool_in_vocabulary()
	if _failed:
		quit(1)
		return
	print("test_architecture_rules: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("could not open %s" % path)
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _load_jobs_content() -> Dictionary:
	var file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_fail("could not open %s" % JOBS_CONTENT_PATH)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("jobs")) != TYPE_ARRAY:
		_fail("content/jobs.json did not parse into {jobs: [...]}")
		return {}
	var kinds: Dictionary = {}
	for entry in parsed["jobs"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			kinds[String(entry["kind"])] = (entry.get("toils", []) as Array).duplicate()
	return kinds

# --- scenario helpers (mirror test_need_jobs.gd's own) ----------------------

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	# issue #300: a freshly generated world can now place berry_bush objects
	# (docs/decisions/020); this fixture rebuilds tiles/colonists from scratch
	# and must clear generator-placed objects the same way, or a stray one
	# left over from the real (pre-override) terrain could sit on a coordinate
	# this scenario relies on being free.
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "carrying": null, "held_tool": ""})
	return world

## Zeroes every need's decay rate except `kind` (or, when `kind` is "", every
## need's rate), so a scenario's own order/need job is never disturbed by an
## unrelated need crossing its own threshold and having the need-giver
## preempt the colonist mid-job -- which would otherwise re-enter go_to/work
## through their own resume-from-adjacent shortcut (colonist-ai.md 3.6) and
## break the execution trace's exact per-toil counts.
func _isolate_need(world: WorldStateType, kind: String) -> void:
	for other in world._need_definitions.keys():
		if other != kind:
			world._need_definitions[other]["rate_per_day"] = 0

func _command(world: WorldStateType, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": "%s_%d" % [kind, world.get_events().size()],
		"tick": world.get_tick(), "type": kind, "payload": payload})

func _jobs_of_kind(world: WorldStateType, kind: String) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	for job in world.get_jobs():
		if String(job["kind"]) == kind:
			jobs.append(job)
	return jobs

# --- 1) execution trace ------------------------------------------------------

## Runs one job-kind scenario to completion, isolating the relevant need (for
## need-driven kinds) and clearing world._toils.trace right before ticking so
## the trace only reflects this scenario's own execution, then returns the
## world plus every job status this kind's job was observed in and whether it
## reached "completed".
func _run_scenario(kind: String, seed_value: int, setup: Callable) -> Dictionary:
	var world := _build_world(seed_value)
	if NEED_DRIVEN_KINDS.has(kind):
		var need_kind: String = NEED_DRIVEN_KINDS[kind]
		_isolate_need(world, need_kind)
		world._colonists[0]["needs"][need_kind] = 20
	else:
		_isolate_need(world, "")
	setup.call(world)
	world._toils.clear_trace()
	var statuses: Dictionary = {}
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		for job in _jobs_of_kind(world, kind):
			statuses[String(job["status"])] = true
		if statuses.has("completed"):
			completed = true
			break
	return {"world": world, "statuses": statuses, "completed": completed}

func _trace_count(world: WorldStateType, toil: String, phase: String) -> int:
	var n := 0
	for entry in world._toils.trace:
		if String(entry["toil"]) == toil and String(entry["phase"]) == phase:
			n += 1
	return n

## Verifies, from content/jobs.json's own toils array for `kind` (not a
## hardcoded copy of it), that: every declared toil is a name ToilExecutor
## actually knows (ToilExecutorType.VOCABULARY) -- so a typo'd or newly
## invented toil that ToilExecutor would silently no-op on fails loudly here
## instead of passing unnoticed; "reserve" and "release_all" are satisfied by
## the job's observed status history (scheduler activation / scheduler
## completion, per toil_executor.gd's own doc comment on what it does and does
## not execute); and every other declared toil (go_to/work/pick_up/place/
## consume) was entered and completed *exactly* the number of times its own
## occurrence count in content/jobs.json's toils array says (not "at least",
## which would also pass a kind that runs a toil more times than declared),
## according to ToilExecutor's own execution trace.
func _verify_trace_against_toils(kind: String, toils: Array, world: WorldStateType, statuses: Dictionary, completed: bool) -> void:
	_expect(completed, "%s job must complete within the tick budget" % kind)
	if not completed:
		return
	for toil in toils:
		var declared_name := String(toil)
		_expect(ToilExecutorType.is_known_toil(declared_name),
			"%s declares toil \"%s\", which is not in ToilExecutor.VOCABULARY (%s) -- ToilExecutor would silently no-op it"
				% [kind, declared_name, ToilExecutorType.VOCABULARY])
	if "reserve" in toils:
		_expect(statuses.has("active"),
			"%s must pass through the scheduler's \"active\" status (satisfies the reserve toil)" % kind)
	if "release_all" in toils:
		_expect(statuses.has("completed"),
			"%s must reach \"completed\" status through the scheduler (satisfies the release_all toil)" % kind)
	var expected := {"go_to": 0, "work": 0, "pick_up": 0, "place": 0, "deposit": 0, "consume": 0, "fetch_tool": 0}
	for toil in toils:
		var name := String(toil)
		if expected.has(name):
			expected[name] += 1
	for toil_name in expected:
		var count: int = expected[toil_name]
		var complete_count := _trace_count(world, toil_name, "complete")
		_expect(complete_count == count,
			"%s must execute the %s toil through ToilExecutor exactly %d time(s) (trace shows %d completion(s): %s)"
				% [kind, toil_name, count, complete_count, world._toils.trace])
		if toil_name in ["go_to", "work"]:
			var enter_count := _trace_count(world, toil_name, "enter")
			_expect(enter_count == count,
				"%s must enter the %s toil through ToilExecutor exactly %d time(s) (trace shows %d entrance(s): %s)"
					% [kind, toil_name, count, enter_count, world._toils.trace])

func _run_and_verify(kind: String, seed_value: int, setup: Callable) -> void:
	if not _jobs_content.has(kind):
		_fail("content/jobs.json does not declare a \"%s\" job kind" % kind)
		return
	var toils: Array = _jobs_content[kind]
	var result := _run_scenario(kind, seed_value, setup)
	_verify_trace_against_toils(kind, toils, result["world"], result["statuses"], result["completed"])

func _check_execution_trace() -> void:
	var expected_kinds: Array[String] = ["dig", "mine", "chop", "forage", "till", "sow", "haul", "site_fetch", "site_work", "eat_food", "drink_water", "sleep", "incident", "escape_trench", "flee", "rescue", "approach"]
	for kind in expected_kinds:
		_expect(_jobs_content.has(kind), "content/jobs.json must declare a \"%s\" job kind" % kind)
	_expect(_jobs_content.size() == expected_kinds.size(),
		"content/jobs.json declares %d kind(s) (%s) but this test covers %d (%s); add/remove a scenario to match"
			% [_jobs_content.size(), _jobs_content.keys(), expected_kinds.size(), expected_kinds])

	_run_and_verify("dig", 201001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_SOIL
		world.spawn_ground_tool_item("pick", 0, 0)
		_expect(_command(world, "dig", {"x": 5, "y": 0, "priority": 1})["ok"], "dig order must be accepted"))
	_run_and_verify("mine", 201501, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_ROCK
		world.spawn_ground_tool_item("pick", 0, 0)
		_expect(_command(world, "mine", {"x": 5, "y": 0, "priority": 1})["ok"], "mine order must be accepted"))
	_run_and_verify("chop", 202001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_TREE
		world.spawn_ground_tool_item("axe", 0, 0)
		_expect(_command(world, "chop", {"x": 5, "y": 0, "priority": 1})["ok"], "chop order must be accepted"))
	_run_and_verify("forage", 203001, func(world: WorldStateType) -> void:
		_expect(_command(world, "place_object", {"x": 5, "y": 0, "kind": "berry_bush"})["ok"],
			"berry_bush placement must be accepted")
		_expect(_command(world, "forage", {"x": 5, "y": 0, "priority": 1})["ok"], "forage order must be accepted"))
	_run_and_verify("sleep", 204001, func(world: WorldStateType) -> void:
		_expect(_command(world, "place_object", {"x": 5, "y": 0, "kind": "bed"})["ok"], "bed placement must be accepted"))
	_run_and_verify("eat_food", 205001, func(world: WorldStateType) -> void:
		world._ground_berries["5_0"] = 1)
	_run_and_verify("drink_water", 206001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_WATER)
	_check_haul_execution_trace(207001)
	_check_construction_execution_trace(207501)
	_run_and_verify("till", 208001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_SOIL
		_expect(_command(world, "till", {"x": 5, "y": 0, "priority": 1})["ok"], "till order must be accepted"))
	_run_and_verify("sow", 209001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_PLOWED_SOIL
		world._items["item_1"] = {"id": "item_1", "x": 0, "y": 0, "kind": "seed", "count": 1}
		world._next_item_id = 2
		_expect(_command(world, "sow", {"x": 5, "y": 0, "priority": 1})["ok"], "sow order must be accepted"))
	# F5 (issue #294): stages a wolf through IncidentScheduler.propose() (the
	# real staging path, with a chosen target) rather than the day-gated draw
	# -- this test proves only that the "incident" kind itself runs through
	# the ordinary ToilExecutor dispatch once activated/assigned.
	_run_and_verify("incident", 210001, func(world: WorldStateType) -> void:
		var wolf: Dictionary = ActorTableType.spawn("wolf", 0, 5, world._content, "arch_wolf")
		wolf["factionId"] = "wildlife"
		_expect(not world._incidents.propose(wolf, Vector2i(1, 5), 5).is_empty(),
			"incident job submission must be accepted"))
	# issue #359 (ADR 025 t3): walks a hostile actor into a trench through a
	# real incident job (setup's own ticking, cleared from the trace by
	# _run_scenario()'s clear_trace() right after setup returns, below), so
	# only the escape_trench job's own go_to/work toils are traced.
	_run_and_verify("escape_trench", 211001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(1, 5)] = WorldStateType.TILE_TRENCH
		var wolf: Dictionary = ActorTableType.spawn("wolf", 0, 5, world._content, "arch_wolf_trap")
		wolf["factionId"] = "wildlife"
		_expect(not world._incidents.propose(wolf, Vector2i(1, 5), 5).is_empty(),
			"incident job submission for the trap scenario must be accepted")
		for _i in 50:
			world.tick()
			if world._find_colonist("arch_wolf_trap").get("trapped") != null:
				break
		_expect(world._find_colonist("arch_wolf_trap").get("trapped") != null,
			"the wolf must be trapped before the escape_trench trace assertions run"))
	# issue #302: a combat actor at/below its own flee_hp_fraction gets a
	# `flee` job from CombatGiver. The hostile actor sits far enough away
	# (chebyshev 10) to give the giver a real away-direction without the
	# combat resolver's own adjacency-only attack rule reaching colonist_0
	# first (which would kill it at hp 1 before it ever flees). Issue #390:
	# spawned from the "trader" definition (no "combat" component) rather than
	# "colonist", with its factionId overridden to "raiders" -- CombatGiver's
	# own flee-target pick only needs a hostile body with health, never a
	# combat component of its own, and a "trader"-shaped threat is
	# structurally invisible to ApproachGiver (its very first check skips any
	# actor with no "combat" component), so it is never itself given a
	# competing `approach` job that would pollute this scenario's own shared
	# ToilExecutor trace with an unrelated go_to/work pair.
	_run_and_verify("flee", 212001, func(world: WorldStateType) -> void:
		world._colonists[0]["health"] = {"hp": 1, "maxHp": 100, "dead": false}
		var threat: Dictionary = ActorTableType.spawn("trader", 10, 0, world._content, "arch_threat")
		threat["factionId"] = "raiders"
		world._append_colonist(threat))
	# issue #360 (ADR 025 t4): traps colonist_0 through a real till job's route
	# (setup's own ticking, cleared from the trace by _run_scenario()'s
	# clear_trace() right after setup returns), then spawns the rescuer so only
	# the rescue job's own go_to/work toils are traced.
	_run_and_verify("rescue", 213001, func(world: WorldStateType) -> void:
		world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
		world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
		var submit := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", "colonist_0")
		_expect(submit.get("ok", false), "setup: till submission for the rescue trap scenario must be accepted")
		for _i in 50:
			world.tick()
			if world._colonists[0].get("trapped") != null:
				break
		_expect(world._colonists[0].get("trapped") != null, "setup: colonist_0 must be trapped before the rescue trace assertions run")
		var rescuer: Dictionary = ActorTableType.spawn("colonist", 5, 5, world._content, "arch_rescuer")
		rescuer.erase("carrying")
		rescuer["hands"] = []
		rescuer["factionId"] = "colony"
		world._append_colonist(rescuer))
	# issue #390 (ADR 031): a hostile actor not adjacent to any hostile
	# target, and not owned by CombatGiver (full health, never flees), gets
	# an `approach` job from ApproachGiver -- this test proves only that the
	# "approach" kind itself runs through the ordinary ToilExecutor dispatch
	# once submitted/assigned, exactly like "flee"/"incident" already do.
	_run_and_verify("approach", 214001, func(world: WorldStateType) -> void:
		var threat: Dictionary = ActorTableType.spawn("colonist", 10, 0, world._content, "arch_approacher")
		threat.erase("carrying")
		threat["hands"] = []
		threat["factionId"] = "raiders"
		world._append_colonist(threat))

## haul is the one kind with two go_to legs (reserve, go_to, pick_up, go_to,
## place, release_all): _verify_trace_against_toils's per-toil counts already
## require two enter/complete go_to trace pairs (content/jobs.json's own toils
## array names "go_to" twice), which is proof both legs actually ran through
## ToilExecutor, not just the first. Also keeps the domain-specific delivery
## check (the item still exists on the ground at its stockpile cell), which
## the generic trace assertions do not express.
func _check_haul_execution_trace(seed_value: int) -> void:
	var kind := "haul"
	if not _jobs_content.has(kind):
		_fail("content/jobs.json does not declare a \"haul\" job kind")
		return
	var toils: Array = _jobs_content[kind]
	var result := _run_scenario(kind, seed_value, func(world: WorldStateType) -> void:
		world._items["item_1"] = {"id": "item_1", "x": 5, "y": 0, "kind": "wood", "count": 1}
		world._next_item_id = 2
		_expect(_command(world, "zone_add", {"x": 10, "y": 0, "width": 2, "height": 2})["ok"], "zone_add must be accepted"))
	var world: WorldStateType = result["world"]
	_verify_trace_against_toils(kind, toils, world, result["statuses"], result["completed"])
	# place() now always mints a fresh item id (issue #402: hands entries have
	# no id of their own to preserve across a pick_up/place round trip), so
	# the delivered item's id may no longer be "item_1" -- only that a wood
	# item still exists on the ground still holds.
	var delivered := false
	for item in world._items.values():
		if String(item["kind"]) == "wood":
			delivered = true
	_expect(delivered, "the delivered item must still exist on the ground at its stockpile cell")

## Construction (issue #406, docs/decisions/038, supersedes the single-job
## `build` scenario ADR 027 once exercised here): `build` now creates a
## persistent site driven by ConstructionGiver's own two job kinds --
## site_fetch (haul's own [go_to, pick_up, go_to, ..., release_all] shape,
## ending in `deposit` instead of `place`) and site_work ([go_to, work,
## release_all], the single-leg shape dig/chop/mine already use). Both must
## run through ToilExecutor's ordinary dispatch and reach "completed"; the
## site record itself (not either job in isolation) is what proves the whole
## flow worked, so this scenario drives its own tick loop rather than reusing
## _run_scenario()'s single-kind-completion shortcut.
func _check_construction_execution_trace(seed_value: int) -> void:
	for kind in ["site_fetch", "site_work"]:
		if not _jobs_content.has(kind):
			_fail("content/jobs.json does not declare a \"%s\" job kind" % kind)
			return
	var world := _build_world(seed_value)
	_isolate_need(world, "")
	world._items["item_1"] = {"id": "item_1", "x": 5, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	_expect(_command(world, "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1})["ok"], "zone_add must be accepted")
	var build_result := _command(world, "build", {"kind": "wooden_wall", "x": 10, "y": 0})
	_expect(build_result["ok"], "build order must be accepted")
	world._toils.clear_trace()
	# world._toils.trace is one shared buffer across every job/toil in the
	# world, unlike _run_scenario()'s own single-kind scenarios above -- so
	# site_fetch's own trace is verified and cleared the instant it completes,
	# before site_work's separate trace (a fresh job kind, on the same
	# colonist) has a chance to mix into the same buffer.
	var site_fetch_statuses: Dictionary = {}
	var fetch_verified := false
	var site_work_statuses: Dictionary = {}
	var site_completed := false
	for _i in MAX_TICKS:
		world.tick()
		for job in _jobs_of_kind(world, "site_fetch"):
			site_fetch_statuses[String(job["status"])] = true
		if not fetch_verified and site_fetch_statuses.has("completed"):
			_verify_trace_against_toils("site_fetch", _jobs_content["site_fetch"], world, site_fetch_statuses, true)
			world._toils.clear_trace()
			fetch_verified = true
		for job in _jobs_of_kind(world, "site_work"):
			site_work_statuses[String(job["status"])] = true
		if world.get_construction_site(10, 0).is_empty():
			site_completed = true
			break
	_expect(fetch_verified, "site_fetch must complete before the site itself does")
	_expect(site_completed, "the construction site must complete within the tick budget")
	_verify_trace_against_toils("site_work", _jobs_content["site_work"], world, site_work_statuses, site_work_statuses.has("completed"))
	_expect(not world._items.has("item_1"), "the delivered wood must be consumed by construction, not left on the ground")
	_expect(world.get_object(10, 0) == "wooden_wall", "the declared object must appear at the build target")

# --- 2) single per-colonist advance path -------------------------------------

## Source scan of world_state.gd: no _advance_need_*/_advance_haul_* function,
## no _begin_*reroute*/_resume_*reroute* function, no _start_need_search/
## _advance_need_search function, no _need_jobs/_need_searches/
## _need_job_by_colonist field -- and exactly one function whose name both
## starts with _advance_ and names "colonist" (_advance_colonists), matching
## this task's "no kind-specific branch other than reading the toils list".
func _check_single_advance_path() -> void:
	var lines := _read_text(WORLD_STATE_PATH).split("\n")
	var per_colonist_advance: Array[String] = []
	for raw_line in lines:
		var line := String(raw_line).strip_edges()
		if not line.begins_with("func "):
			continue
		if line.begins_with("func _advance_need_") or line.begins_with("func _advance_haul_") \
				or line.begins_with("func _start_need_search(") or line.begins_with("func _advance_need_search("):
			_fail("world_state.gd declares a forbidden kind-specific function: %s" % line)
		if (line.begins_with("func _begin_") or line.begins_with("func _resume_")) and "reroute" in line:
			_fail("world_state.gd declares a forbidden reroute function: %s" % line)
		if line.begins_with("func _advance_") and "(" in line:
			var name := line.substr(5, line.find("(") - 5)
			if "colonist" in name:
				per_colonist_advance.append(name)
	for raw_line in lines:
		var line := String(raw_line)
		if "_need_jobs" in line or "_need_searches" in line or "_need_job_by_colonist" in line:
			_fail("world_state.gd references a forbidden field: %s" % line.strip_edges())
	_expect(per_colonist_advance.size() == 1 and per_colonist_advance[0] == "_advance_colonists",
		"world_state.gd must declare exactly one per-colonist advance function, _advance_colonists (found %s)"
			% [per_colonist_advance])

## issue #266: drop_tool is a real toil ToilExecutor implements even though no
## content/jobs.json kind declares it (it is inserted dynamically for a
## foreign-reservation handover) -- proves it is not merely a typo that would
## otherwise silently no-op, mirroring is_known_toil()'s own contract.
func _check_drop_tool_in_vocabulary() -> void:
	_expect(ToilExecutorType.is_known_toil("drop_tool"),
		"ToilExecutor.VOCABULARY must include drop_tool (issue #266), got %s" % [ToilExecutorType.VOCABULARY])

# --- 3) viewer purity ---------------------------------------------------------

func _check_viewer_purity() -> void:
	var call_re := RegEx.new()
	call_re.compile("\\bworld\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	var dir := DirAccess.open(VIEWER_DIR)
	_expect(dir != null, "could not open %s" % VIEWER_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	var scanned := 0
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".gd"):
			scanned += 1
			var source := _read_text(VIEWER_DIR + "/" + file_name)
			for m in call_re.search_all(source):
				var method := m.get_string(1)
				var ok := method.begins_with("get_") or method in ["apply", "tick", "get_events"]
				_expect(ok, "%s calls world.%s(), which is not a get_* getter, apply(), get_events() or tick()"
					% [file_name, method])
		file_name = dir.get_next()
	dir.list_dir_end()
	_expect(scanned > 0, "viewer purity scan must actually inspect at least one script")
