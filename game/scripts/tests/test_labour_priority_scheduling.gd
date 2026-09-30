extends SceneTree

## Exercises colonist-ai.md 3.2's wired effective-priority formula and the
## non-terminal "labour_disabled" reason: a candidate whose
## job's labour is 0 for a worker is never proposed to that worker; an
## eligible candidate's score is
## `16 * (order_priority + calendar_boost + 4 - labour_level) + ticks_waiting`,
## capped via GlobalAssignment.MAX_PRIORITY_BRACKET; a job whose labour every
## colonist has disabled stays queued with reason "labour_disabled" and
## clears the moment any colonist re-enables it; and CalendarService's
## active_boost (ADR 008) feeds the same formula once wired into WorldState.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SchedulerType = preload("res://scripts/core/scheduling/global_assignment.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

var _failed := false

func _init() -> void:
	_check_labour_priority_ordering()
	_check_labour_disabled_reason()
	_check_haul_unaffected_by_labour_disabled()
	_check_calendar_boost_orders_dig_first_inside_window()
	_check_replay_determinism()
	_check_committed_need_job_precedes_work_with_labour_and_calendar_boost()
	_check_negative_calendar_boost_stays_eligible()
	_check_negative_calendar_boost_during_pending_route()
	_check_labour_disabled_reason_accounts_for_searching_colonists()
	_check_labour_disabled_reservation_no_flapping_and_unblocks_once()
	_check_committed_need_outside_scan_window_still_wins()
	_check_committed_need_with_reserved_target_blocks_other_work()
	_check_committed_need_discards_stale_pending_work_batch()
	_check_committed_need_beats_boosted_interrupted_work()
	_check_labour_disabled_reason_survives_failed_route_search()
	_check_scheduler_haul_backoff_labour_disable_regression()

	if _failed:
		quit(1)
		return
	print("test_labour_priority_scheduling: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _no_boost(_labour: String, _tick: int) -> int:
	return 0

func _dig_or_chop_labour(kind: String) -> String:
	return {"dig": "mine", "chop": "chop"}.get(kind, "")

func _fixed_negative_boost(_labour: String, _tick: int) -> int:
	return -3

## Mutated between tick() calls by _check_negative_calendar_boost_during_pending_route()
## so a single Callable can report a different boost mid-route-search.
var _dynamic_boost_value := 0
func _dynamic_boost(_labour: String, _tick: int) -> int:
	return _dynamic_boost_value

## Colonist A (mine=1, chop=4) and B (mine=4, chop=1) both start at the
## origin, so travel is identical for both on any given target and cannot
## mask the labour-driven score gap. Targets are placed in increasing
## distance so within a single colonist's own preferred kind, its own
## proposals are also ordered predictably. Exercised directly against
## GlobalAssignment (not WorldState) for exact control over labour tables and
## job kinds without needing valid soil/tree tiles.
func _check_labour_priority_ordering() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var no_boost := Callable(self, "_no_boost")
	var workers: Array[Dictionary] = [
		{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 1, "chop": 4}},
		{"id": "b", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 4, "chop": 1}},
	]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(20, 20)
	var tick_number := 0

	var d1 := String(scheduler.submit(Vector2i(1, 0), 1, 0, "dig")["job_id"])
	var d2 := String(scheduler.submit(Vector2i(2, 0), 1, 0, "dig")["job_id"])
	var d3 := String(scheduler.submit(Vector2i(3, 0), 1, 0, "dig")["job_id"])
	var c1 := String(scheduler.submit(Vector2i(4, 0), 1, 0, "chop")["job_id"])

	tick_number = _settle(scheduler, workers, passable, bounds, get_labour, no_boost, tick_number)
	var assignments := scheduler.get_assignments()
	_expect(String(assignments.get("a", {}).get("job_id", "")) == d1,
		"A (mine=1) must take its own dig job first, got %s" % assignments.get("a"))
	_expect(String(assignments.get("b", {}).get("job_id", "")) == c1,
		"B (chop=1) must take its own chop job first, got %s" % assignments.get("b"))

	scheduler.finish(d1, "complete_job")
	scheduler.finish(c1, "complete_job")
	tick_number = _settle(scheduler, workers, passable, bounds, get_labour, no_boost, tick_number)
	assignments = scheduler.get_assignments()
	_expect(String(assignments.get("a", {}).get("job_id", "")) == d2,
		"A must continue taking dig jobs while any remain, got %s" % assignments.get("a"))
	_expect(String(assignments.get("b", {}).get("job_id", "")) == d3,
		"B must take the leftover dig job once chop is exhausted (crossover), got %s" % assignments.get("b"))

	scheduler.finish(d2, "complete_job")
	scheduler.finish(d3, "complete_job")
	var d4 := String(scheduler.submit(Vector2i(5, 0), 1, tick_number, "dig")["job_id"])
	var c2 := String(scheduler.submit(Vector2i(6, 0), 1, tick_number, "chop")["job_id"])
	var c3 := String(scheduler.submit(Vector2i(7, 0), 1, tick_number, "chop")["job_id"])
	var c4 := String(scheduler.submit(Vector2i(8, 0), 1, tick_number, "chop")["job_id"])

	tick_number = _settle(scheduler, workers, passable, bounds, get_labour, no_boost, tick_number)
	assignments = scheduler.get_assignments()
	_expect(String(assignments.get("a", {}).get("job_id", "")) == d4,
		"A must still prefer its own dig job, got %s" % assignments.get("a"))
	_expect(String(assignments.get("b", {}).get("job_id", "")) == c2,
		"B must take its own chop job first, got %s" % assignments.get("b"))

	scheduler.finish(d4, "complete_job")
	scheduler.finish(c2, "complete_job")
	tick_number = _settle(scheduler, workers, passable, bounds, get_labour, no_boost, tick_number)
	assignments = scheduler.get_assignments()
	_expect(String(assignments.get("b", {}).get("job_id", "")) == c3,
		"B must continue taking chop jobs while any remain, got %s" % assignments.get("b"))
	_expect(String(assignments.get("a", {}).get("job_id", "")) == c4,
		"A must take the leftover chop job once dig is exhausted (crossover), got %s" % assignments.get("a"))

## Ticks the scheduler until every worker in `workers` has an assignment (a
## route-searched candidate takes one tick per batch slot to resolve -- see
## global_assignment.gd's cursor-driven batching -- so a single tick() call is
## not always enough), bounded generously since these fixtures are tiny
## (distances under 10 tiles, no obstacles). Returns the last tick_number used.
func _settle(scheduler: SchedulerType, workers: Array[Dictionary], passable: Callable, bounds: Vector2i,
		get_labour: Callable, get_boost: Callable, start_tick: int) -> int:
	var tick_number := start_tick
	for i in 10:
		tick_number += 1
		scheduler.tick(tick_number, workers, passable, Vector2i.ZERO, bounds, get_labour, get_boost)
		var assignments := scheduler.get_assignments()
		if assignments.size() >= workers.size():
			break
	return tick_number

## A world where every colonist's "mine" is off: a queued dig job must be
## marked labour_disabled (queued, not failed); a chop job (a different
## labour kind) must proceed unaffected; re-enabling mine for the colonist
## clears the reason on the next scan.
func _check_labour_disabled_reason() -> void:
	var world := _single_colonist_world(1)
	var colonist_id: String = world.get_colonists()[0]["id"]
	_expect(_set_labour(world, "off_mine", colonist_id, "mine", 0).get("ok", false),
		"set_labour to 0 must be accepted")

	var dig_result := world.apply({"actor": "test", "command_id": "dig_1", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": 1, "y": 0, "priority": 1}})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even though mine is disabled")
	var dig_id := String(dig_result.get("job_id", ""))
	var chop_result := world.apply({"actor": "test", "command_id": "chop_1", "tick": world.get_tick(),
		"type": "chop", "payload": {"x": 0, "y": 1, "priority": 1}})
	_expect(chop_result.get("ok", false), "chop submission must be accepted")
	var chop_id := String(chop_result.get("job_id", ""))

	world.tick()
	var dig_job := _find_job(world, dig_id)
	_expect(dig_job["status"] == "queued" and String(dig_job["reason"]) == "labour_disabled",
		"a dig job must be marked labour_disabled once every colonist's mine is off, got %s" % dig_job)
	var chop_job := _find_job(world, chop_id)
	_expect(chop_job["status"] == "active",
		"chop work must proceed unaffected while only mine is disabled, got %s" % chop_job)

	_expect(world.apply({"actor": "test", "command_id": "complete_chop", "tick": world.get_tick(),
		"type": "complete_job", "payload": {"job_id": chop_id}}).get("ok", false),
		"chop completion must be accepted")
	_expect(_set_labour(world, "on_mine", colonist_id, "mine", 2).get("ok", false),
		"re-enabling mine must be accepted")
	world.tick()
	dig_job = _find_job(world, dig_id)
	_expect(String(dig_job["reason"]) != "labour_disabled",
		"the reason must clear once a colonist re-enables the labour, got %s" % dig_job)

	var saw_unblocked := false
	for event in world.get_events():
		if event["type"] == "job_unblocked" and event["entity_id"] == dig_id:
			saw_unblocked = true
	_expect(saw_unblocked, "a job_unblocked event must fire for the dig job once mine is re-enabled")

## A haul job's labour kind ("haul") is unrelated to "mine": disabling mine
## for the only colonist must never mark an auto-submitted haul job
## labour_disabled.
func _check_haul_unaffected_by_labour_disabled() -> void:
	var world := _single_colonist_world(2)
	var colonist_id: String = world.get_colonists()[0]["id"]
	_expect(_set_labour(world, "off_mine", colonist_id, "mine", 0).get("ok", false),
		"set_labour to 0 must be accepted")
	var zone_result := world.apply({"actor": "test", "command_id": "zone_1", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 3, "y": 3, "width": 2, "height": 2}})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	world._items["item_wood_test"] = {"id": "item_wood_test", "x": 0, "y": 2, "kind": "wood", "count": 1}

	world.tick()
	var haul_jobs: Array[Dictionary] = []
	for job in world.get_jobs():
		if String(job["kind"]) == "haul":
			haul_jobs.append(job)
	_expect(haul_jobs.size() == 1, "exactly one haul job must be auto-submitted for the loose item, got %d" % haul_jobs.size())
	if haul_jobs.size() == 1:
		_expect(String(haul_jobs[0]["reason"]) != "labour_disabled",
			"a haul job must never be marked labour_disabled by an unrelated 'mine' disable, got %s" % haul_jobs[0])

## A synthetic CalendarService content override (mirroring test_calendar.gd's
## own "_init('', {...})" pattern) boosts "mine" for day 1 only
## (day_length_ticks 10). One colonist, chop submitted before dig at the same
## tick: inside the window, the boost outweighs submission order and dig
## activates first; outside the window (no boost), aging/submission order
## holds and chop (submitted first) activates first.
func _check_calendar_boost_orders_dig_first_inside_window() -> void:
	var boosted_calendar := CalendarServiceType.new("", {
		"day_length_ticks": 10,
		"windows": [{"id": "test_mine_boost", "labour": "mine", "from": 1, "to": 1, "boost": 2, "label": "test"}],
	})

	var inside := _single_colonist_world(3)
	inside._calendar = boosted_calendar
	var chop_inside := inside.apply({"actor": "test", "command_id": "chop_1", "tick": inside.get_tick(),
		"type": "chop", "payload": {"x": 0, "y": 1, "priority": 1}})
	var dig_inside := inside.apply({"actor": "test", "command_id": "dig_1", "tick": inside.get_tick(),
		"type": "dig", "payload": {"x": 1, "y": 0, "priority": 1}})
	_expect(chop_inside.get("ok", false) and dig_inside.get("ok", false), "orders must be accepted")
	# Both jobs become candidates for the sole idle colonist; a two-candidate
	# batch takes one scheduler tick per candidate to route-search (see
	# global_assignment.gd's cursor-driven batching), so a single tick() is
	# not enough for the batch to finish and activate its winner.
	inside.tick()
	inside.tick()
	_expect(_find_job(inside, String(dig_inside["job_id"]))["status"] == "active",
		"inside the boosted window, dig must activate first despite being submitted second")
	_expect(_find_job(inside, String(chop_inside["job_id"]))["status"] == "queued",
		"inside the boosted window, chop must still be queued")

	var outside := _single_colonist_world(4)
	outside._calendar = CalendarServiceType.new("", {
		"day_length_ticks": 10,
		"windows": [{"id": "test_mine_boost", "labour": "mine", "from": 1, "to": 1, "boost": 2, "label": "test"}],
	})
	for i in 10:
		outside.tick()
	var chop_outside := outside.apply({"actor": "test", "command_id": "chop_1", "tick": outside.get_tick(),
		"type": "chop", "payload": {"x": 0, "y": 1, "priority": 1}})
	var dig_outside := outside.apply({"actor": "test", "command_id": "dig_1", "tick": outside.get_tick(),
		"type": "dig", "payload": {"x": 1, "y": 0, "priority": 1}})
	_expect(chop_outside.get("ok", false) and dig_outside.get("ok", false), "orders must be accepted")
	outside.tick()
	outside.tick()
	_expect(_find_job(outside, String(chop_outside["job_id"]))["status"] == "active",
		"outside the window, aging/submission order holds: chop (submitted first) activates first")
	_expect(_find_job(outside, String(dig_outside["job_id"]))["status"] == "queued",
		"outside the window, dig must still be queued")

## Two identically-seeded WorldStates replaying the same set_labour + dig/chop
## command sequence must produce equal apply() results and equal
## state_hash() values (colonist-ai.md 3.2's determinism requirement),
## mirroring test_labour_table.gd's own _check_replay_determinism().
func _check_replay_determinism() -> void:
	var seed_value := 20260919267
	var first := _deterministic_world(seed_value)
	var second := _deterministic_world(seed_value)
	var colonist_id: String = first.get_colonists()[0]["id"]
	var commands := [
		{"actor": "player", "command_id": "labour_1", "tick": 0, "type": "set_labour",
			"payload": {"colonist": colonist_id, "kind": "chop", "level": 1}},
		{"actor": "test", "command_id": "dig_1", "tick": 0, "type": "dig",
			"payload": {"x": 1, "y": 0, "priority": 1}},
		{"actor": "test", "command_id": "chop_1", "tick": 0, "type": "chop",
			"payload": {"x": 0, "y": 1, "priority": 1}},
	]
	for command in commands:
		var first_result := first.apply(command)
		var second_result := second.apply(command)
		_expect(first_result == second_result, "apply() results diverged for command %s" % command)
	for i in 5:
		first.tick()
		second.tick()
	_expect(first.state_hash() == second.state_hash(),
		"state_hash() diverged: %s vs %s" % [first.state_hash(), second.state_hash()])

## colonist-ai.md 3.2's labour/calendar bonus gives
## ordinary work a positive bracket even at the default labour level (e.g.
## `4 - 3 = 1`), while a need job's labour is "" and always scores the
## neutral bracket (`4 - 4 = 0`, see _priority_bracket()'s LABOUR_LEVEL_MAX
## default). Left unchecked, that bonus can let a queued dig order outscore
## and win a colonist's slot over its own already-committed, restricted need
## job, breaking colonist-ai.md 3.1's needs-before-work layering. A heavy
## calendar boost on "mine" and a high-priority dig order both stack the deck
## as hard as possible in work's favor; the need job must still win.
func _check_committed_need_job_precedes_work_with_labour_and_calendar_boost() -> void:
	var world := _needs_isolated_world(700)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	# Water placed far enough away (distance 10, move_ticks_per_tile 4) that
	# travel spans many ticks -- long enough to observe the committed need job
	# still pending (not yet completed) across several scheduler ticks, rather
	# than the whole commit-travel-consume cycle collapsing into a single
	# tick the way an adjacent source would.
	world._tiles[world._tile_index(0, 10)] = WorldStateType.TILE_WATER
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "needs": {"food": 100, "water": 10, "rest": 100},
		"labourTable": _default_labour_table()})
	world._calendar = CalendarServiceType.new("", {
		"day_length_ticks": 1000,
		"windows": [{"id": "test_mine_boost", "labour": "mine", "from": 1, "to": 1, "boost": 10, "label": "test"}],
	})
	var dig_result := world.apply({"actor": "test", "command_id": "dig_1", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": 1, "y": 0, "priority": 2}})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result["job_id"])

	var saw_committed_need := false
	for i in 60:
		world.tick()
		var need_job_id := world.get_active_need_job_id("colonist_0")
		if not need_job_id.is_empty():
			saw_committed_need = true
			_expect(String(_find_job(world, dig_id)["status"]) != "active",
				"the HIGH-priority, calendar-boosted dig order must not win the colonist's slot while its own need job is pending, got %s" % _find_job(world, dig_id))
		elif saw_committed_need:
			break
	_expect(saw_committed_need, "the thirsty colonist must commit to and start pursuing a need job")

func _check_negative_calendar_boost_stays_eligible() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var negative_boost := Callable(self, "_fixed_negative_boost")
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3, "chop": 3}}]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(20, 20)
	# NORMAL priority (1), default labour level 3, boost -3: bracket = 1 + (-3)
	# + 4 - 3 = -1, a real negative score, not the sentinel the old
	# bracket-as-eligibility check used to treat as "labour disabled".
	var job_id := String(scheduler.submit(Vector2i(3, 0), 1, 0, "dig")["job_id"])
	var tick_number := _settle(scheduler, workers, passable, bounds, get_labour, negative_boost, 0)
	_expect(String(scheduler.get_assignments().get("a", {}).get("job_id", "")) == job_id,
		"a negative calendar boost must not be treated as labour-disabled: the job must still activate")
	_expect(String(scheduler.queue.get_job(job_id)["reason"]) != "labour_disabled",
		"an enabled labour with a negative boost must never be marked labour_disabled")

## Regression: eligibility used to be folded into the bracket's own sign, so a
## negative calendar boost discovered while a multi-tick route batch was
## still pending could make the ready-list rescore silently drop an otherwise
## eligible, already-routed candidate. A target far enough away to force the
## route search across two tick() calls (RouteType.STEP_BUDGET=64) lets the
## boost swing negative in between.
func _check_negative_calendar_boost_during_pending_route() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var dynamic_boost := Callable(self, "_dynamic_boost")
	_dynamic_boost_value = 5
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3, "chop": 3}}]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(130, 0)
	var job_id := String(scheduler.submit(Vector2i(100, 0), 1, 0, "dig")["job_id"])
	scheduler.tick(1, workers, passable, Vector2i.ZERO, bounds, get_labour, dynamic_boost)
	_expect(scheduler._pending.has("a"), "a distant target must leave a route batch pending across ticks")
	_dynamic_boost_value = -5
	scheduler.tick(2, workers, passable, Vector2i.ZERO, bounds, get_labour, dynamic_boost)
	_expect(String(scheduler.get_assignments().get("a", {}).get("job_id", "")) == job_id,
		"a negative calendar boost discovered mid-route must not cause an eligible candidate to be dropped")

func _labour_table_with(kind: String, level: int) -> Dictionary:
	var table := _default_labour_table()
	table[kind] = level
	return table

func _needs_isolated_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	for kind in world._need_definitions.keys():
		world._need_definitions[kind]["rate_per_day"] = 0
	return world

## Regression: _refresh_labour_disabled_reasons() used to read tick()'s own
## (need-search-filtered) `colonists` list instead of the full colony, so it
## could report labour_disabled while the only enabled colonist was simply
## mid-search (a), fail to report it once every colonist happened to be
## searching at once (an empty aggregation defaults every kind to "not
## disabled") (b), or fail to clear it when the colonist being re-enabled was
## itself excluded that same tick (c). Each case uses a fresh world with a
## reachable water tile at (0,1) so a colonist's water need reliably starts a
## search the instant it drops to "urgent" (colonist-ai.md 3.1); a search's
## first tick always ends still-searching (need_giver.gd's own comment: a
## commit attempt is always deferred to the tick after ranking finishes).
func _check_labour_disabled_reason_accounts_for_searching_colonists() -> void:
	# (a) the colony's only mine-enabled colonist is mid-search.
	var only_enabled_searching := _needs_isolated_world(701)
	only_enabled_searching._tiles[only_enabled_searching._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	only_enabled_searching._tiles[only_enabled_searching._tile_index(0, 1)] = WorldStateType.TILE_WATER
	only_enabled_searching._colonists.clear()
	only_enabled_searching._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "needs": {"food": 100, "water": 10, "rest": 100},
		"labourTable": _labour_table_with("mine", 3)})
	only_enabled_searching._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10,
		"route": null, "work": null, "needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": _labour_table_with("mine", 0)})
	var dig_a := only_enabled_searching.apply({"actor": "test", "command_id": "dig_1",
		"tick": only_enabled_searching.get_tick(), "type": "dig", "payload": {"x": 1, "y": 0, "priority": 1}})
	_expect(dig_a.get("ok", false), "dig submission must be accepted")
	only_enabled_searching.tick()
	_expect(only_enabled_searching._need_giver.searching_colonist_ids().has("colonist_0"),
		"colonist_0 must be mid-search for water the tick its onset starts")
	_expect(String(_find_job(only_enabled_searching, String(dig_a["job_id"]))["reason"]) != "labour_disabled",
		"the only colonist with mine enabled must still count while it is mid-search")

	# (b) every colonist has mine off and is mid-search at once.
	var all_searching := _needs_isolated_world(702)
	all_searching._tiles[all_searching._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	all_searching._tiles[all_searching._tile_index(0, 1)] = WorldStateType.TILE_WATER
	all_searching._colonists.clear()
	all_searching._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "needs": {"food": 100, "water": 10, "rest": 100},
		"labourTable": _labour_table_with("mine", 0)})
	all_searching._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10,
		"route": null, "work": null, "needs": {"food": 100, "water": 10, "rest": 100},
		"labourTable": _labour_table_with("mine", 0)})
	var dig_b := all_searching.apply({"actor": "test", "command_id": "dig_1",
		"tick": all_searching.get_tick(), "type": "dig", "payload": {"x": 1, "y": 0, "priority": 1}})
	_expect(dig_b.get("ok", false), "dig submission must be accepted")
	all_searching.tick()
	_expect(all_searching._need_giver.searching_colonist_ids().size() == 2,
		"both colonists must be mid-search this tick")
	_expect(String(_find_job(all_searching, String(dig_b["job_id"]))["reason"]) == "labour_disabled",
		"every colonist's mine being off must be reported even while every colonist is mid-search")

	# (c) re-enabling labour on a colonist the very tick it starts a fresh
	# search must still clear the reason on that same scan.
	var reenable_while_searching := _needs_isolated_world(703)
	reenable_while_searching._tiles[reenable_while_searching._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	reenable_while_searching._tiles[reenable_while_searching._tile_index(0, 1)] = WorldStateType.TILE_WATER
	reenable_while_searching._colonists.clear()
	reenable_while_searching._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": _labour_table_with("mine", 0)})
	reenable_while_searching._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10,
		"route": null, "work": null, "needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": _labour_table_with("mine", 0)})
	var dig_c := reenable_while_searching.apply({"actor": "test", "command_id": "dig_1",
		"tick": reenable_while_searching.get_tick(), "type": "dig", "payload": {"x": 1, "y": 0, "priority": 1}})
	_expect(dig_c.get("ok", false), "dig submission must be accepted")
	reenable_while_searching.tick()
	_expect(String(_find_job(reenable_while_searching, String(dig_c["job_id"]))["reason"]) == "labour_disabled",
		"both colonists' mine off with neither searching must still report labour_disabled")
	_expect(_set_labour(reenable_while_searching, "on_mine_0", "colonist_0", "mine", 2).get("ok", false),
		"re-enabling mine must be accepted")
	reenable_while_searching._colonists[0]["needs"]["water"] = 10
	reenable_while_searching.tick()
	_expect(reenable_while_searching._need_giver.searching_colonist_ids().has("colonist_0"),
		"colonist_0 must be excluded from this tick's own scheduling pool while re-enabling its labour")
	var dig_c_job := _find_job(reenable_while_searching, String(dig_c["job_id"]))
	_expect(String(dig_c_job["reason"]) != "labour_disabled",
		"re-enabling labour on a colonist mid-search must still clear labour_disabled on the same scan, got %s" % dig_c_job)
	var saw_unblocked_c := false
	for event in reenable_while_searching.get_events():
		if event["type"] == "job_unblocked" and event["entity_id"] == dig_c["job_id"]:
			saw_unblocked_c = true
	_expect(saw_unblocked_c, "a job_unblocked event must fire once every colonist's mine is no longer all off")

## Regression: GlobalAssignment's reservation-recheck branch used to run before
## the labour eligibility check, so a labour-disabled job whose target stayed
## reserved by another active job kept re-entering JobQueue.tick() (via
## advance_selection()) every tick, alternating its reason between
## blocked_target_reserved and labour_disabled and re-emitting job_blocked
## with no actual state change. Re-enabling labour while the target is still
## reserved must also emit job_unblocked for the labour_disabled clearing
## exactly once, even though the job immediately blocks again for the
## reservation.
func _check_labour_disabled_reservation_no_flapping_and_unblocks_once() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var no_boost := Callable(self, "_no_boost")
	var workers: Array[Dictionary] = [
		{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3, "chop": 3}},
		{"id": "b", "kind": "colonist", "x": 5, "y": 0, "labourTable": {"mine": 3, "chop": 3}},
	]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(20, 20)
	var target := Vector2i(1, 0)
	var first := String(scheduler.submit(target, 1, 0, "dig")["job_id"])
	var tick_number := _settle(scheduler, [workers[0]], passable, bounds, get_labour, no_boost, 0)
	_expect(scheduler.queue.get_job(first)["status"] == "active", "first dig job must activate and reserve its target")

	var second := String(scheduler.submit(target, 1, tick_number, "dig")["job_id"])
	tick_number += 1
	scheduler.tick(tick_number, [workers[1]], passable, Vector2i.ZERO, bounds, get_labour, no_boost)
	_expect(String(scheduler.queue.get_job(second)["reason"]) == "blocked_target_reserved",
		"a competing target must block the second job before labour is ever considered")

	workers[0]["labourTable"]["mine"] = 0
	workers[1]["labourTable"]["mine"] = 0
	var events_before := -1
	for i in 5:
		tick_number += 1
		scheduler.tick(tick_number, workers, passable, Vector2i.ZERO, bounds, get_labour, no_boost)
		var reason := String(scheduler.queue.get_job(second)["reason"])
		_expect(reason == "labour_disabled",
			"once every colonist's mine is off, the reservation-blocked job must settle on labour_disabled, got %s" % reason)
		var events_now := scheduler.queue.get_events().size()
		if events_before >= 0:
			_expect(events_now == events_before,
				"reason must stabilize -- no repeated job_blocked/job_unblocked churn on an unchanged condition")
		events_before = events_now

	workers[1]["labourTable"]["mine"] = 3
	tick_number += 1
	scheduler.tick(tick_number, workers, passable, Vector2i.ZERO, bounds, get_labour, no_boost)
	var unblocked_events := 0
	for event in scheduler.queue.get_events():
		if event["type"] == "job_unblocked" and event["entity_id"] == second:
			unblocked_events += 1
			_expect(String(event["data"].get("previous_reason", "")) == "labour_disabled",
				"job_unblocked must report labour_disabled as the previous reason")
	_expect(unblocked_events == 1, "labour re-enable must emit exactly one job_unblocked event, got %d" % unblocked_events)
	_expect(String(scheduler.queue.get_job(second)["reason"]) == "blocked_target_reserved",
		"the job must immediately re-block on the still-held reservation, got %s" % scheduler.queue.get_job(second))

## Regression: the needs-before-work fix used to rely
## on tick()'s own bounded JOB_EVALUATION_BUDGET scan discovering a
## restrict_to entry, so a committed need job sitting past the scan window was
## invisible to it and ordinary work kept being proposed to that worker
## instead. GlobalAssignment.tick()'s `committed_needs` param is looked up
## directly by id (_find_waiting_entry()), never by scanning, so a need job's
## position in `_waiting` can no longer matter.
func _check_committed_need_outside_scan_window_still_wins() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var no_boost := Callable(self, "_no_boost")
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3, "chop": 3}}]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(60, 5)

	# Fill exactly JOB_EVALUATION_BUDGET (32) entries so the need job below
	# lands one past the worker's own scan window.
	for i in range(SchedulerType.JOB_EVALUATION_BUDGET):
		scheduler.submit(Vector2i(i + 1, 0), 1, 0, "dig")
	var need_job_id := String(scheduler.submit(Vector2i(0, 1), 1, 0, "dig", "a")["job_id"])

	_settle_with_needs(scheduler, workers, passable, bounds, get_labour, no_boost, 0, {"a": need_job_id})
	_expect(String(scheduler.get_assignments().get("a", {}).get("job_id", "")) == need_job_id,
		"a committed need job past the scan window must still win the worker's slot")

## A committed need job whose target is currently reserved by a
## different active job must still exclude ordinary work from the worker's
## slot this tick -- blocked is still a higher decision layer than open work
## (colonist-ai.md 3.1), not a reason to fall through to work.
func _check_committed_need_with_reserved_target_blocks_other_work() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var no_boost := Callable(self, "_no_boost")
	var target := Vector2i(1, 0)
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(20, 20)

	var other_owner: Dictionary = {"id": "b", "kind": "colonist", "x": 5, "y": 0, "labourTable": {"mine": 3, "chop": 3}}
	scheduler.submit(target, 1, 0, "dig")
	_settle(scheduler, [other_owner], passable, bounds, get_labour, no_boost, 0)
	_expect(not String(scheduler.get_assignments().get("b", {}).get("job_id", "")).is_empty(),
		"setup: the other job must activate and reserve the shared target first")

	var need_job_id := String(scheduler.submit(target, 1, 1, "dig", "a")["job_id"])
	var filler_job_id := String(scheduler.submit(Vector2i(2, 0), 1, 1, "dig")["job_id"])
	var worker_a: Dictionary = {"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3, "chop": 3}}

	for i in range(5):
		scheduler.tick(2 + i, [worker_a], passable, Vector2i.ZERO, bounds, get_labour, no_boost, [], {"a": need_job_id})
		_expect(not scheduler.get_assignments().has("a"),
			"the worker must stay idle while its own committed need is blocked_target_reserved, got tick %d" % (2 + i))

	_expect(String(scheduler.queue.get_job(need_job_id)["reason"]) == "blocked_target_reserved",
		"the committed need job itself must report blocked_target_reserved")
	_expect(String(scheduler.queue.get_job(filler_job_id)["status"]) == "queued",
		"freely available ordinary work must never be offered to a worker with a blocked committed need")

## Regression: a worker's own in-progress ordinary-work route search (still
## `_pending`, not yet an assignment) used to be untouched by a need
## committing for that same worker mid-search, so it could still win the
## worker's slot once its own search concluded, entirely bypassing the need.
func _check_committed_need_discards_stale_pending_work_batch() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var no_boost := Callable(self, "_no_boost")
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3, "chop": 3}}]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(130, 5)

	var work_job_id := String(scheduler.submit(Vector2i(100, 0), 1, 0, "dig")["job_id"])
	scheduler.tick(1, workers, passable, Vector2i.ZERO, bounds, get_labour, no_boost)
	_expect(scheduler._pending.has("a"), "a distant target must leave a route batch pending across ticks")
	_expect(_pending_has_job(scheduler, "a", work_job_id), "the pending batch must be for the ordinary work job")

	var need_job_id := String(scheduler.submit(Vector2i(0, 1), 1, 1, "dig", "a")["job_id"])
	scheduler.tick(2, workers, passable, Vector2i.ZERO, bounds, get_labour, no_boost, [], {"a": need_job_id})
	_expect(not _pending_has_job(scheduler, "a", work_job_id),
		"a stale ordinary-work route batch must be discarded the instant a need commits for the same worker")

	var tick_number := 2
	for i in range(10):
		tick_number += 1
		scheduler.tick(tick_number, workers, passable, Vector2i.ZERO, bounds, get_labour, no_boost, [], {"a": need_job_id})
		if scheduler.get_assignments().has("a"):
			break
	_expect(String(scheduler.get_assignments().get("a", {}).get("job_id", "")) == need_job_id,
		"the committed need must win the worker's slot once its own route resolves")
	_expect(String(scheduler.queue.get_job(work_job_id)["status"]) == "queued",
		"the discarded ordinary work must never have activated for this worker")

func _boost_mine_only(labour: String, _tick: int) -> int:
	return 20 if labour == "mine" else 0

## suspend_assignment() restores an interrupted work job to `_waiting`
## restricted to the same worker (so it may resume later), but that restrict_to
## must never be mistaken for need priority: a heavily labour/calendar-boosted
## interrupted work entry must not be able to outscore its own replacement
## need job for the same worker's slot.
func _check_committed_need_beats_boosted_interrupted_work() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var boost_mine := Callable(self, "_boost_mine_only")
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 1, "chop": 3}}]
	var passable := func(_tile: Vector2i) -> bool: return true
	var bounds := Vector2i(20, 20)

	var work_job_id := String(scheduler.submit(Vector2i(1, 0), 2, 0, "dig")["job_id"])
	var tick_number := _settle(scheduler, workers, passable, bounds, get_labour, boost_mine, 0)
	_expect(String(scheduler.get_assignments().get("a", {}).get("job_id", "")) == work_job_id,
		"setup: the heavily boosted work job must activate first")

	scheduler.suspend_assignment("a", work_job_id)
	tick_number += 1
	# A different kind (unmapped by _dig_or_chop_labour, so labour "") stands
	# in for a need job: it gets none of "dig"'s labour/calendar bonus, so a
	# win here can only come from committed_needs' own exclusivity.
	var need_job_id := String(scheduler.submit(Vector2i(0, 1), 1, tick_number, "drink_water", "a")["job_id"])

	for i in range(10):
		tick_number += 1
		scheduler.tick(tick_number, workers, passable, Vector2i.ZERO, bounds, get_labour, boost_mine, [], {"a": need_job_id})
		if scheduler.get_assignments().has("a"):
			break
	_expect(String(scheduler.get_assignments().get("a", {}).get("job_id", "")) == need_job_id,
		"the replacement need must win over the interrupted work despite its labour/calendar boost")
	_expect(String(scheduler.queue.get_job(work_job_id)["status"]) == "queued",
		"the interrupted work must stay queued, not reactivated, while the need is committed")

## Regression: a stale multi-tick route search that fails after its job's labour
## has since gone globally disabled used to still call `selected.append()`
## unconditionally, so advance_selection() overwrote the labour_disabled
## reason with blocked_target_unreachable -- and a later re-enable then missed
## the required job_unblocked event, since the displayed reason no longer
## matched BLOCKED_LABOUR_DISABLED.
func _check_labour_disabled_reason_survives_failed_route_search() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 267
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var get_labour := Callable(self, "_dig_or_chop_labour")
	var no_boost := Callable(self, "_no_boost")
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0, "labourTable": {"mine": 3}}]
	# A wall column entirely separates the colonist from the target: the route
	# search must flood-fill its whole reachable side (more than one tick's
	# STEP_BUDGET=64 expansions) before concluding unreachable.
	var wall_passable := func(tile: Vector2i) -> bool: return tile.x != 10
	var bounds := Vector2i(20, 20)

	var job_id := String(scheduler.submit(Vector2i(20, 0), 1, 0, "dig")["job_id"])
	scheduler.tick(1, workers, wall_passable, Vector2i.ZERO, bounds, get_labour, no_boost)
	_expect(scheduler._pending.has("a"), "an unreachable target across a wall must leave a route batch pending")

	workers[0]["labourTable"]["mine"] = 0
	var tick_number := 1
	var concluded := false
	for i in range(20):
		tick_number += 1
		scheduler.tick(tick_number, workers, wall_passable, Vector2i.ZERO, bounds, get_labour, no_boost)
		_expect(String(scheduler.queue.get_job(job_id)["reason"]) == "labour_disabled",
			"a globally disabled job's reason must hold through its own failing route search, got tick %d" % tick_number)
		if not scheduler._pending.has("a"):
			concluded = true
			break
	_expect(concluded, "the unreachable route search must eventually conclude within this test's tick budget")
	_expect(String(scheduler.queue.get_job(job_id)["status"]) == "queued", "an unreachable target must never activate")

	workers[0]["labourTable"]["mine"] = 3
	tick_number += 1
	scheduler.tick(tick_number, workers, wall_passable, Vector2i.ZERO, bounds, get_labour, no_boost)
	_expect(String(scheduler.queue.get_job(job_id)["reason"]) != "labour_disabled",
		"re-enabling labour must clear the reason on the next scan")
	var unblocked := 0
	for event in scheduler.queue.get_events():
		if event["type"] == "job_unblocked" and event["entity_id"] == job_id:
			unblocked += 1
	_expect(unblocked == 1, "labour re-enable must emit exactly one job_unblocked event, got %d" % unblocked)

## The haul-backoff-vs-labour_disabled regression in test_job_queue.gd calls
## JobQueue directly, exercising neither GlobalAssignment's own labour
## refresh/reservation-recheck path nor HaulGiver's auto-submission -- so a
## defect confined to _refresh_labour_disabled_reasons() or the scan's
## reservation branch could slip past it. This drives the same
## scenario end to end through WorldState.tick(): a loose item with no
## stockpile zone establishes a real destination backoff; disabling "haul" for
## the colony's only colonist must show labour_disabled immediately, queued,
## without ever letting JobQueue.tick() re-enter the destination search early;
## re-enabling mid-backoff must emit exactly one job_unblocked and still not
## attempt a fresh search until retry_at naturally elapses.
func _check_scheduler_haul_backoff_labour_disable_regression() -> void:
	var world := _haul_backoff_world(710)
	var colonist_id: String = world.get_colonists()[0]["id"]

	var haul_job_id := ""
	var haul_job := {}
	for _i in 5:
		world.tick()
		haul_job_id = _find_haul_job_id(world)
		if haul_job_id.is_empty():
			continue
		haul_job = _find_job(world, haul_job_id)
		if haul_job["status"] == "queued" and String(haul_job["reason"]) == "blocked_destination_full":
			break
	_expect(not haul_job_id.is_empty(), "the scheduler must auto-submit a haul job for the loose item")
	_expect(String(haul_job.get("status", "")) == "queued" and String(haul_job.get("reason", "")) == "blocked_destination_full",
		"with no stockpile zone, GlobalAssignment/JobQueue must establish a real haul destination backoff, got %s" % haul_job)
	var retry_at := int(haul_job.get("retry_at", 0))
	_expect(retry_at > world.get_tick() + 2, "the backoff must leave real room before retry_at for this test to exercise")
	if retry_at <= world.get_tick() + 2:
		return
	# Establishing the backoff itself already emitted one haul_destination_attempt
	# (the attempt that found no free cell and set retry_at); every check below
	# looks for a SECOND, premature one, not merely the presence of this first one.
	var attempts_at_backoff := _events_for_job(world, "haul_destination_attempt", haul_job_id).size()

	_expect(_set_labour(world, "off_haul", colonist_id, "haul", 0).get("ok", false),
		"disabling haul must be accepted")
	world.tick()
	haul_job = _find_job(world, haul_job_id)
	_expect(haul_job["status"] == "queued" and String(haul_job["reason"]) == "labour_disabled",
		"the scheduler must show labour_disabled immediately through GlobalAssignment's own labour refresh, even mid-backoff, got %s" % haul_job)

	while world.get_tick() < retry_at - 2:
		world.tick()
		_expect(_events_for_job(world, "haul_destination_attempt", haul_job_id).size() == attempts_at_backoff,
			"JobQueue.tick() must never re-enter the destination search while every colonist's haul stays disabled")

	_expect(_set_labour(world, "on_haul", colonist_id, "haul", 3).get("ok", false),
		"re-enabling haul before the backoff elapses must be accepted")

	world.tick()
	_expect(world.get_tick() == retry_at - 1, "sanity: this tick must still land one short of retry_at")
	_expect(_events_for_job(world, "haul_destination_attempt", haul_job_id).size() == attempts_at_backoff,
		"no destination attempt may occur before the backoff naturally elapses, even immediately after labour is re-enabled")
	var unblocked := _events_for_job(world, "job_unblocked", haul_job_id)
	_expect(unblocked.size() == 1,
		"re-enabling haul mid-backoff must emit exactly one job_unblocked event through the scheduler, got %d" % unblocked.size())

	# The reservation-shortcut branch (see get_reservations()'s own backoff gate)
	# keeps refreshing this job by id, bypassing real routing, for as long as it
	# reports reserved -- one tick longer than `retry_at` itself, since JobQueue's
	# internal _tick used for that gate only advances inside this same
	# advance_selection() call, one call behind the scheduler's own tick_number.
	# The destination search only genuinely resumes once the job re-enters real
	# scoring/routing, so this allows a couple of scheduler ticks at/after
	# retry_at for that to happen, not exactly one.
	var resumed := false
	for _i in 3:
		world.tick()
		if _events_for_job(world, "haul_destination_attempt", haul_job_id).size() > attempts_at_backoff:
			resumed = true
			break
	_expect(resumed,
		"once the backoff naturally elapses through the scheduler, the destination search must resume within a few ticks")

func _find_haul_job_id(world: WorldStateType) -> String:
	for job in world.get_jobs():
		if String(job["kind"]) == "haul":
			return String(job["id"])
	return ""

func _events_for_job(world: WorldStateType, event_type: String, job_id: String) -> Array:
	var matches: Array = []
	for event in world.get_events():
		if event["type"] == event_type and event["entity_id"] == job_id:
			matches.append(event)
	return matches

## One colonist at (0,0) on an all-floor map, needs zeroed out (this scenario
## only cares about haul/labour scheduling), and a loose wood item at distance
## 2 with no stockpile zone anywhere on the map -- HaulGiver.find_free_haul_cell()
## then always returns null, so the very first activation attempt establishes a
## real BLOCKED_DESTINATION_FULL backoff (colonist-ai.md 3.3/3.4).
func _haul_backoff_world(seed_value: int) -> WorldStateType:
	var world := _needs_isolated_world(seed_value)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._items["item_wood_backoff"] = {"id": "item_wood_backoff", "x": 0, "y": 2, "kind": "wood", "count": 1}
	return world

func _settle_with_needs(scheduler: SchedulerType, workers: Array[Dictionary], passable: Callable, bounds: Vector2i,
		get_labour: Callable, get_boost: Callable, start_tick: int, committed_needs: Dictionary) -> int:
	var tick_number := start_tick
	for i in 10:
		tick_number += 1
		scheduler.tick(tick_number, workers, passable, Vector2i.ZERO, bounds, get_labour, get_boost, [], committed_needs)
		var assignments := scheduler.get_assignments()
		if assignments.size() >= workers.size():
			break
	return tick_number

func _pending_has_job(scheduler: SchedulerType, worker: String, job_id: String) -> bool:
	if not scheduler._pending.has(worker):
		return false
	for entry in scheduler._pending[worker]["candidates"]:
		if entry["id"] == job_id:
			return true
	return false

func _set_labour(world: WorldStateType, command_id: String, colonist: String, kind: String, level: int) -> Dictionary:
	return world.apply({"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": colonist, "kind": kind, "level": level}})

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if job["id"] == job_id:
			return job
	return {}

## Default labourTable shape (world_state.gd's own _default_labour_table()),
## spelled out here since a hand-built colonist below skips _spawn_colonists()
## and set_labour would otherwise be applied before _ensure_needs() ever
## backfills it (that backfill only runs from state_hash()/to_save_state()/
## _decay_needs(), none of which this test calls before its first command).
func _default_labour_table() -> Dictionary:
	return {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}

## One colonist at (0,0) on an all-floor map with a soil tile at (1,0) (dig
## target) and a tree at (0,1) (chop target), both distance 1 from the
## colonist -- reused by the labour_disabled, haul and calendar checks. A pick
## and an axe sit right under the colonist so dig/chop's needs_tool
## fetch_tool toil resolves without travel, matching this
## fixture's original tool-free assumption of reaching "active"/"completed"
## in a single tick.
func _single_colonist_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(0, 1)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world.spawn_ground_tool_item("pick", 0, 0)
	world.spawn_ground_tool_item("axe", 0, 0)
	return world

func _deterministic_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(0, 1)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	return world
