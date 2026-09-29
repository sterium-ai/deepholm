extends SceneTree

## Acceptance coverage for issue #206: colonist_panel.gd must render each
## colonist's three need bars (colonist-ai.md 4 acceptance item 7) and the
## needs decision layer's own activity/reason vocabulary (colonist-ai.md
## 3.1/3.8: eating, sleeping, need_unmet:<kind>, blocked_source_reserved),
## driven end to end through a real WorldState -- the same needs decision
## layer test_need_jobs.gd exercises -- rather than a synthetic colonist/job
## pair, so this stays honest about what ColonistPanel._line_for() actually
## renders from WorldState's own getters.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const BootType = preload("res://scripts/boot.gd")

const MAX_TICKS := 400

var _failed := false

func _init() -> void:
	_check_need_bars_render_for_an_idle_colonist()
	_check_eating_colonist_shows_activity_and_toil()
	_check_drinking_colonist_shows_activity_and_toil()
	_check_eating_colonist_shows_activity_during_consume()
	_check_drinking_colonist_shows_activity_during_consume()
	_check_sleeping_colonist_shows_activity_and_toil()
	_check_need_unmet_colonist_shows_reason_and_remedy()
	_check_blocked_source_reserved_colonist_shows_reason_and_remedy()
	_check_need_source_missing_colonist_shows_reason_and_remedy()
	_check_trapped_colonist_shows_rescue_reason_and_remedy()
	_check_need_alert_list_dedupes_and_clears()
	_check_incident_started_events_appear_in_alert_list()
	_check_mixed_hands_render()

	if _failed:
		quit(1)
		return
	print("test_colonist_panel: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	return world

## Mirrors test_need_jobs.gd's _isolate_need(): zeroes every need kind's
## decay rate except `kind`, so a scenario built around one need is never
## disturbed by another need crossing its own threshold mid-run.
func _isolate_need(world: WorldStateType, kind: String) -> void:
	for other in world._need_definitions.keys():
		if other != kind:
			world._need_definitions[other]["rate_per_day"] = 0

func _colonist(id: String, x: int, y: int, needs: Dictionary) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "needs": needs.duplicate(),
		"route": null, "work": null, "hands": []}

func _check_mixed_hands_render() -> void:
	var world := _build_world(10003)
	var colonist := _colonist("hands_colonist", 0, 0, _full_needs())
	var empty_line := _panel_for(world)._line_for(colonist)
	_expect(empty_line.find("Hands:") < 0, "empty hands must show no hands line (got: %s)" % empty_line)
	colonist["hands"] = [{"kind": "wood", "count": 3}, {"kind": "stone", "count": 1}]
	world._colonists.append(colonist)
	var line := _panel_for(world)._line_for(_colonist_by_id(world, "hands_colonist"))
	_expect(line.find("Hands: wood x3, stone x1") >= 0,
		"the panel must show mixed hands entries (got: %s)" % line)

func _full_needs(overrides: Dictionary = {}) -> Dictionary:
	var needs := {"food": 100, "water": 100, "rest": 100}
	for kind in overrides:
		needs[kind] = overrides[kind]
	return needs

func _colonist_by_id(world: WorldStateType, id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == id:
			return colonist
	return {}

## Mirrors test_need_jobs.gd's _jobs_of_kind(): a still-in-progress search
## has not yet submitted a job at all, so "no job of this kind exists yet"
## is the job-queue-visible proof that the search is still running -- the
## same evidence test_need_jobs.gd uses now that need jobs live in the real
## job queue instead of a separate table.
func _jobs_of_kind(world: WorldStateType, kind: String) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	for job in world.get_jobs():
		if String(job["kind"]) == kind:
			jobs.append(job)
	return jobs

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

func _panel_for(world: WorldStateType) -> ColonistPanelType:
	var panel := ColonistPanelType.new()
	panel.world = world
	panel._text_table = TextTableType.new()
	return panel

func _check_trapped_colonist_shows_rescue_reason_and_remedy() -> void:
	var world := _build_world(10002)
	world._colonists.append(_colonist("trapped", 0, 0, _full_needs()))
	world._colonists[0]["trapped"] = {"tile": Vector2i(0, 0), "ticksRemaining": 40, "fromTile": Vector2i(1, 0)}
	world._set_rescue_reason("trapped", WorldStateType.REASON_NO_RESCUER_AVAILABLE)
	var line := _panel_for(world)._line_for(world._colonists[0])
	_expect(line.find("trapped in a trench, no one can help") >= 0,
		"a trapped colonist with no rescuer must show the literal rescue reason (got: %s)" % line)
	_expect(line.find("Wait for a rescuer to become available") >= 0,
		"a trapped colonist with no rescuer must show the rescue remedy (got: %s)" % line)

## BootType.new() alone never loads scenes/scenes/boot.tscn -- its _init()
## (see boot.gd) only builds a WorldState, a text table, and a plain Label,
## none of which need a SceneTree node to exist, mirroring how _panel_for()
## above uses ColonistPanelType directly without add_child(). The default
## world DebugScenarioType.build() constructs there is replaced with the
## scripted scenario the caller built, exactly like the panel helpers do.
func _boot_for(world: WorldStateType) -> BootType:
	var boot := BootType.new()
	boot.world = world
	return boot

## A colonist with distinct food/water/rest values and no job at all still
## renders all three need bars, read straight off get_colonists()'s "needs"
## field, and shows no "Need reason:" line while none is exposed.
func _check_need_bars_render_for_an_idle_colonist() -> void:
	var world := _build_world(10001)
	world._colonists.append(_colonist("colonist_0", 0, 0, {"food": 80, "water": 45, "rest": 100}))
	var colonist := _colonist_by_id(world, "colonist_0")
	var panel := _panel_for(world)
	var line: String = panel._line_for(colonist)

	_expect(line.find("Food: 80/100") >= 0, "the panel must show the food bar (got: %s)" % line)
	_expect(line.find("Water: 45/100") >= 0, "the panel must show the water bar (got: %s)" % line)
	_expect(line.find("Rest: 100/100") >= 0, "the panel must show the rest bar (got: %s)" % line)
	_expect(line.find("Need reason:") < 0, "a colonist with no exposed need reason must show no need-reason line (got: %s)" % line)

## A hungry colonist with a reachable, unreserved ground-berries source far
## enough away to spend several ticks walking there: while mid-route, the
## panel must show the eat_food job's activity label and the "Traveling"
## toil, driven only by the colonist's own route.job_id resolved through
## get_jobs() -- never by comparing the colonist's tile to the berries tile.
## Need jobs share the same job queue as any other job now (colonist-ai.md
## 3.1/3.4), so their ids are plain "job_N" like a dig/chop/haul job's, not a
## "need_"-prefixed id; a route belongs to this colonist's need job exactly
## when its job_id matches world.get_active_need_job_id().
func _check_eating_colonist_shows_activity_and_toil() -> void:
	var world := _build_world(20001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._ground_berries["20_0"] = 1

	var line := ""
	for _i in MAX_TICKS:
		world.tick()
		var colonist := _colonist_by_id(world, "colonist_0")
		var route = colonist.get("route")
		if route != null and String(route.get("job_id", "")) == world.get_active_need_job_id("colonist_0"):
			line = _panel_for(world)._line_for(colonist)
			break
	_expect(not line.is_empty(), "the scenario must reach a colonist mid-route toward its eat_food job")
	if line.is_empty():
		return
	_expect(line.find("Eating") >= 0, "the panel must show the eat_food job's activity label (got: %s)" % line)
	_expect(line.find("Toil: Traveling") >= 0, "the panel must show the go_to toil while walking to the food source (got: %s)" % line)

## Mirrors _check_eating_colonist_shows_activity_and_toil() for drink_water: a
## thirsty colonist with a reachable, unreserved water tile far enough away to
## spend several ticks walking there must show the drink_water job's activity
## label and the "Traveling" toil while mid-route, from colonist.route.job_id
## resolved through get_jobs() -- never by comparing the colonist's tile to
## the water tile. See the eat_food scenario above for why the match is
## against world.get_active_need_job_id() rather than a "need_" id prefix.
func _check_drinking_colonist_shows_activity_and_toil() -> void:
	var world := _build_world(21001)
	_isolate_need(world, "water")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"water": 20})))
	world._tiles[world._tile_index(20, 0)] = WorldStateType.TILE_WATER

	var line := ""
	for _i in MAX_TICKS:
		world.tick()
		var colonist := _colonist_by_id(world, "colonist_0")
		var route = colonist.get("route")
		if route != null and String(route.get("job_id", "")) == world.get_active_need_job_id("colonist_0"):
			line = _panel_for(world)._line_for(colonist)
			break
	_expect(not line.is_empty(), "the scenario must reach a colonist mid-route toward its drink_water job")
	if line.is_empty():
		return
	_expect(line.find("Drinking") >= 0, "the panel must show the drink_water job's activity label (got: %s)" % line)
	_expect(line.find("Toil: Traveling") >= 0, "the panel must show the go_to toil while walking to the water source (got: %s)" % line)

## Review round 1 finding: for the single tick between route arrival and the
## instant `consume` toil, the toil executor has already nulled colonist.route
## but has not yet called _toils.consume() -- that happens on the *next*
## tick's call -- so both route and work are null while the job is still
## pending in NeedGiver. The panel must keep showing "Eating" (via
## world.get_active_need_job_id(), not route/work) and the "Consuming" toil
## at that instant, never falling back to idle/no-work. Requiring the job's
## own status to already be "active" excludes the single earlier tick where
## the job was just submitted (still "queued") and route/work are null only
## because assignment has not happened yet -- not the consume instant this
## scenario targets.
func _check_eating_colonist_shows_activity_during_consume() -> void:
	var world := _build_world(20002)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._ground_berries["20_0"] = 1

	var line := ""
	for _i in MAX_TICKS:
		world.tick()
		var colonist := _colonist_by_id(world, "colonist_0")
		var job_id := world.get_active_need_job_id("colonist_0")
		var job := _find_job(world, job_id)
		if not job_id.is_empty() and job.get("status") == "active" \
				and colonist.get("route") == null and colonist.get("work") == null:
			line = _panel_for(world)._line_for(colonist)
			break
	_expect(not line.is_empty(), "the scenario must reach the eat_food job's consume phase")
	if line.is_empty():
		return
	_expect(line.find("Eating") >= 0, "the panel must show Eating during the consume phase (got: %s)" % line)
	_expect(line.find("Toil: Consuming") >= 0, "the panel must show the consume toil during the consume phase (got: %s)" % line)

## Mirrors _check_eating_colonist_shows_activity_during_consume() for
## drink_water.
func _check_drinking_colonist_shows_activity_during_consume() -> void:
	var world := _build_world(21002)
	_isolate_need(world, "water")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"water": 20})))
	world._tiles[world._tile_index(20, 0)] = WorldStateType.TILE_WATER

	var line := ""
	for _i in MAX_TICKS:
		world.tick()
		var colonist := _colonist_by_id(world, "colonist_0")
		var job_id := world.get_active_need_job_id("colonist_0")
		var job := _find_job(world, job_id)
		if not job_id.is_empty() and job.get("status") == "active" \
				and colonist.get("route") == null and colonist.get("work") == null:
			line = _panel_for(world)._line_for(colonist)
			break
	_expect(not line.is_empty(), "the scenario must reach the drink_water job's consume phase")
	if line.is_empty():
		return
	_expect(line.find("Drinking") >= 0, "the panel must show Drinking during the consume phase (got: %s)" % line)
	_expect(line.find("Toil: Consuming") >= 0, "the panel must show the consume toil during the consume phase (got: %s)" % line)

## A tired colonist with a reachable, unreserved bed far enough away that the
## colonist is still mid-`work` (sleeping) partway through the sleep job's
## WORK_TICKS duration: the panel must show the sleep job's activity label
## and the "Working" toil, from colonist.work.job_id resolved through
## get_jobs(), exactly like a dig/chop colonist's own work toil. See the
## eat_food scenario above for why the match is against
## world.get_active_need_job_id() rather than a "need_" id prefix.
func _check_sleeping_colonist_shows_activity_and_toil() -> void:
	var world := _build_world(30001)
	_isolate_need(world, "rest")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))
	var place_result: Dictionary = world.apply({
		"actor": "test", "command_id": "place_bed", "tick": world.get_tick(),
		"type": "place_object", "payload": {"x": 5, "y": 0, "kind": "bed"},
	})
	_expect(place_result.get("ok", false), "placing the bed fixture object must be accepted")

	var line := ""
	for _i in MAX_TICKS:
		world.tick()
		var colonist := _colonist_by_id(world, "colonist_0")
		var work = colonist.get("work")
		if work != null and String(work.get("job_id", "")) == world.get_active_need_job_id("colonist_0"):
			line = _panel_for(world)._line_for(colonist)
			break
	_expect(not line.is_empty(), "the scenario must reach a colonist mid-work on its sleep job")
	if line.is_empty():
		return
	_expect(line.find("Sleeping") >= 0, "the panel must show the sleep job's activity label (got: %s)" % line)
	_expect(line.find("Toil: Working") >= 0, "the panel must show the work toil while sleeping (got: %s)" % line)

## With no reachable food source anywhere, the colonist's need reason
## settles to need_unmet:food (colonist-ai.md 3.8) while it keeps working
## (here: staying idle with no other order, per colonist-ai.md 3.1's "the
## colonist keeps working"); the panel must show that reason and its
## client-derived remedy alongside the food need bar.
func _check_need_unmet_colonist_shows_reason_and_remedy() -> void:
	var world := _build_world(40001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))

	var line := ""
	for _i in 60:
		world.tick()
		if world.get_colonist_need_reason("colonist_0") == "need_unmet:food":
			line = _panel_for(world)._line_for(_colonist_by_id(world, "colonist_0"))
			break
	_expect(not line.is_empty(), "the scenario must reach need_unmet:food within the tick budget")
	if line.is_empty():
		return
	_expect(line.find("Need reason: No reachable, unreserved food source is available") >= 0,
		"the panel must show the need_unmet:food reason text (got: %s)" % line)
	_expect(line.find("Need remedy: Provide a reachable food source") >= 0,
		"the panel must show need_unmet:food's remedy text (got: %s)" % line)
	_expect(line.find("Food: ") >= 0, "the panel must still show the food need bar (got: %s)" % line)

	var boot := _boot_for(world)
	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text.find("colonist_0: Food need unmet") >= 0,
		"boot's alert area must list the need_unmet:food colonist (got: %s)" % boot._need_alerts_label.text)

## Mirrors test_need_jobs.gd's _check_blocked_source_reserved_then_need_unmet:
## a single far-away candidate whose search spans several ticks, with a
## competing reservation injected mid-search (simulating another colonist
## winning the race). The panel must show blocked_source_reserved's reason
## and remedy the instant WorldState itself exposes it.
func _check_blocked_source_reserved_colonist_shows_reason_and_remedy() -> void:
	var world := _build_world(50001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._ground_berries["47_47"] = 1

	world.tick()
	_expect(_jobs_of_kind(world, "eat_food").is_empty(),
		"a far-away single candidate must still be searching after one tick (no job submitted yet)")
	for _i in 4:
		world.tick()
	_expect(_jobs_of_kind(world, "eat_food").is_empty(),
		"the search must still be in progress before the injected race (no job submitted yet)")

	var table := world._scheduler.queue.get_reservation_table()
	table.acquire("tile:47,47", "external_job")

	var line := ""
	for _i in 60:
		world.tick()
		if world.get_colonist_need_reason("colonist_0") == "blocked_source_reserved":
			line = _panel_for(world)._line_for(_colonist_by_id(world, "colonist_0"))
			break
	table.release("tile:47,47", "external_job")

	_expect(not line.is_empty(), "the scenario must observe blocked_source_reserved within the tick budget")
	if line.is_empty():
		return
	_expect(line.find("Need reason: The nearest need source was just reserved by another colonist") >= 0,
		"the panel must show the blocked_source_reserved reason text (got: %s)" % line)
	_expect(line.find("Need remedy: Wait for the reserving job to release the source") >= 0,
		"the panel must show blocked_source_reserved's remedy text (got: %s)" % line)

## need_source_missing:<kind> is never emitted by the shipped WorldState
## (colonist-ai.md's "Implemented: increment D" note: only need_unmet:<kind>,
## blocked_source_reserved, and blocked_source_unreachable ship in the core
## today) -- so, exactly like other tests here reach into WorldState internals
## to script an otherwise-hard-to-reach scenario (_isolate_need, direct
## _ground_berries/reservation-table pokes), this scenario
## writes the reason string get_colonist_need_reason() reads directly, to
## prove the panel and the boot alert list render/alert it correctly wherever
## need_unmet is rendered/alerted, ready for the day WorldState exposes the
## distinct reason itself.
func _check_need_source_missing_colonist_shows_reason_and_remedy() -> void:
	var world := _build_world(60001)
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"water": 20})))
	world._need_status["colonist_0"] = "need_source_missing:water"

	var line: String = _panel_for(world)._line_for(_colonist_by_id(world, "colonist_0"))
	_expect(line.find("Need reason: No water source exists anywhere on the map") >= 0,
		"the panel must show the need_source_missing:water reason text (got: %s)" % line)
	_expect(line.find("Need remedy: Place a water source on the map") >= 0,
		"the panel must show need_source_missing:water's remedy text (got: %s)" % line)

	var boot := _boot_for(world)
	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text.find("colonist_0: Water source missing") >= 0,
		"boot's alert area must list the need_source_missing:water colonist (got: %s)" % boot._need_alerts_label.text)

## colonist-ai.md 4 acceptance item 7 / boot.gd's own contract: the alert list
## lists each currently-unmet-need colonist exactly once no matter how many
## refreshes run while the condition holds, and drops the colonist the instant
## its reason clears -- never by removing a line, but by rebuilding the whole
## label from scratch each call (see _update_need_alerts_label()).
func _check_need_alert_list_dedupes_and_clears() -> void:
	var world := _build_world(70001)
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._need_status["colonist_0"] = "need_unmet:food"
	var boot := _boot_for(world)

	boot._update_need_alerts_label()
	var first_pass := boot._need_alerts_label.text
	boot._update_need_alerts_label()
	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text == first_pass,
		"repeated refreshes with the same condition must not grow the alert list (got: %s)" % boot._need_alerts_label.text)
	_expect(boot._need_alerts_label.text.split("\n").count("colonist_0: Food need unmet") == 1,
		"the alert list must list colonist_0 exactly once (got: %s)" % boot._need_alerts_label.text)

	world._need_status["colonist_0"] = ""
	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text.find("colonist_0") < 0,
		"the alert list must clear once the colonist's need reason clears (got: %s)" % boot._need_alerts_label.text)

## F5 (issue #296 acceptance item 6): a real spawn_incident command's
## resulting incident_started event must appear in the same alert list the
## need lines above populate, unlike a need reason it is never dropped again
## on a later refresh with no new incident, since the event stays in
## WorldState.get_events() -- an incident is a one-time historical fact, not
## an ongoing condition to clear.
func _check_incident_started_events_appear_in_alert_list() -> void:
	var world := WorldStateType.new(80001, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var boot := _boot_for(world)

	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text.find("Incident: trader_visit") < 0,
		"the alert list must not show an incident before any has been spawned (got: %s)" % boot._need_alerts_label.text)

	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "spawn_trader_visit", "tick": world.get_tick(),
		"type": "spawn_incident", "payload": {"id": "trader_visit"},
	})
	_expect(result.get("ok", false), "spawn_incident for trader_visit must succeed on a fresh map")

	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text.find("Incident: trader_visit (traders)") >= 0,
		"the alert list must show the fired incident's id and faction (got: %s)" % boot._need_alerts_label.text)

	boot._update_need_alerts_label()
	boot._update_need_alerts_label()
	_expect(boot._need_alerts_label.text.split("\n").count("Incident: trader_visit (traders)") == 1,
		"repeated refreshes with no new incident must not duplicate the line (got: %s)" % boot._need_alerts_label.text)
