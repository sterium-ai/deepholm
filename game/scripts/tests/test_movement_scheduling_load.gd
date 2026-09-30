extends SceneTree

## Covers the load and interruption behavior of the
## walk/work execution added to WorldState.tick(). Reuses the 300-tick
## service bound test_scheduling_fairness.gd already proves for ADR 004
## (docs/decisions/004-global-assignment-fairness-policy.md) rather than
## re-deriving a new number.

const WorldType = preload("res://scripts/core/world_state.gd")

## Cited from test_scheduling_fairness.gd's MAX_WAIT, not re-derived here.
const MAX_WAIT := 300

var _failed := false

func _init() -> void:
	_check_no_idle_while_work_available()
	_check_cancel_mid_walk_reassigns()
	_check_cancel_mid_walk_with_queued_job_reassigns_same_tick()
	_check_save_load_mid_walk()
	_check_handover_wait_is_bounded_without_other_queued_work()

	if _failed:
		quit(1)
		return
	print("test_movement_scheduling_load: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _command(world: WorldType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

# --- (a) 3 colonists, 20 mixed orders: no colonist idles while eligible work exists ---

const LOAD_AREA_WIDTH := 10
const LOAD_AREA_HEIGHT := 6
const LOAD_MAX_TICKS := 1500

## A fully open, fully connected 10x6 soil block (everything else rock), so
## every target inside it is reachable from anywhere else inside it: the
## per-tick check below only needs to confirm a target's reservation is free,
## not run a separate reachability search.
func _build_load_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	for y in LOAD_AREA_HEIGHT:
		for x in LOAD_AREA_WIDTH:
			world._tiles[world._tile_index(x, y)] = WorldType.TILE_SOIL
	# The 12 "dig"-labour targets below are mine, not dig, and
	# left as rock (mine's own precondition) here -- mine's completion turns
	# rock into floor, never trench, so nothing this open, unrestricted,
	# 3-colonist/1500-tick fairness scenario ever routes or fetch_tool-chases
	# a tool across (a dropped tool lands wherever a colonist last stood,
	# not a fixed home slot) can ever trap a colonist permanently -- this
	# scenario does not rely on ADR 026's rescue, so a single trapped
	# colonist here would idle for the rest of the run.
	for target in _load_mine_targets():
		world._tiles[world._tile_index(target.x, target.y)] = WorldType.TILE_ROCK
	world._colonists.clear()
	for i in 3:
		world._colonists.append({"id": "colonist_%d" % i, "kind": "colonist", "x": i, "y": 0, "route": null, "work": null, "carrying": null})
	# Mixed chop/dig orders mean a colonist must be able to fetch either kind
	# in turn (fetch_tool drops a mismatched held tool first, so a
	# dropped tool ends up wherever a colonist last stood, not back at a home
	# slot). Several of each kind, scattered across the work area rather than
	# clustered at the colonists' shared start, keeps a free one always close
	# by regardless of where tools have scattered to by a given tick, so tool
	# logistics never becomes this scenario's bottleneck -- it is a scheduling
	# fairness test, not a tool-supply one.
	for point in [Vector2i(0, 0), Vector2i(9, 0), Vector2i(0, 5), Vector2i(9, 5), Vector2i(4, 2)]:
		world.spawn_ground_tool_item("pick", point.x, point.y)
		world.spawn_ground_tool_item("axe", point.x, point.y)
	return world

func _load_tree_targets() -> Array[Vector2i]:
	return [Vector2i(1, 2), Vector2i(3, 2), Vector2i(5, 2), Vector2i(7, 2),
		Vector2i(1, 4), Vector2i(3, 4), Vector2i(5, 4), Vector2i(7, 4)]

## This used to be "dig" on soil (always walkable, before and
## after), whose target tile becomes trench once dug -- trapping any
## colonist whose route (or a fetch_tool leg chasing a tool dropped
## elsewhere) later steps onto one. "mine" exercises the same
## needs_tool-pick/fetch_tool/toil path dig does (see _build_load_world()'s
## own comment) and its completion effect is floor, never trench, but
## unlike soil its target tile is rock -- impassable -- until mined, so
## these 12 stay scattered, isolated cells (no two share an edge) rather
## than one contiguous line: a solid, not-yet-mined wall across row y=1
## would itself have blocked every colonist from ever reaching y=2-5 at all,
## a reachability regression this fixture's own "fully open, fully
## connected" contract (_build_load_world()'s doc comment) never allows.
func _load_mine_targets() -> Array[Vector2i]:
	return [Vector2i(4, 0), Vector2i(6, 0), Vector2i(8, 0),
		Vector2i(0, 1), Vector2i(2, 1), Vector2i(6, 1), Vector2i(8, 1),
		Vector2i(2, 3), Vector2i(3, 3), Vector2i(5, 3), Vector2i(7, 3), Vector2i(8, 3)]

## Row y=5 is otherwise untouched by any dig/chop target, so a 10-cell zone
## there gives every one of chop's 8 wood items (and their auto-submitted
## haul jobs) somewhere to actually land. Without this, every haul job would
## be permanently blocked_destination_full with no zone ever able to free a
## cell, and their unbounded ADR 004 aging would keep leapfrogging each other
## for the sole free worker's attention forever, never letting a fresh
## candidate get its first real evaluation -- an artificial thundering herd
## this test's own 20-order workload never intended to create, not a
## real scheduler fairness bug.
func _add_stockpile_zone(world: WorldType) -> void:
	var result := _command(world, "haul_zone", "zone_add", {"x": 0, "y": 5, "width": LOAD_AREA_WIDTH, "height": 1})
	_expect(result["ok"], "stockpile zone_add must be accepted: %s" % result)

func _submit_load_orders(world: WorldType) -> int:
	_add_stockpile_zone(world)
	var order_index := 0
	for target in _load_tree_targets():
		world._tiles[world._tile_index(target.x, target.y)] = WorldType.TILE_TREE
	for target in _load_tree_targets():
		var result := _command(world, "chop_%d" % order_index, "chop", {"x": target.x, "y": target.y, "priority": 1})
		_expect(result["ok"], "chop order %d must be accepted: %s" % [order_index, result])
		order_index += 1
	for target in _load_mine_targets():
		var result := _command(world, "mine_%d" % order_index, "mine", {"x": target.x, "y": target.y, "priority": 1})
		_expect(result["ok"], "mine order %d must be accepted: %s" % [order_index, result])
		order_index += 1
	return order_index

## "eligible" excludes any job already carrying a nonempty reason (blocked by
## reservation, unreachability, or a permanently-full
## haul destination): those jobs are not actually pickable work right now, and
## must not count toward "no colonist may idle while work is available" any
## more than a target-reserved dig/chop job already didn't (that case happens
## to also show up in `reservations`, but blocked_destination_full never
## reserves a tile at all, so the reason check is what actually excludes it).
## Also excludes any job currently sitting in a worker's pending evaluation
## batch (get_pending()): a freshly auto-submitted haul job has
## an empty reason for the one tick between being proposed and its route
## search/destination check resolving, so a colonist mid-evaluation of that
## exact job would otherwise be flagged as "idling while it was available",
## even though it is, at that moment, the only thing already working it.
func _has_eligible_queued_job(world: WorldType) -> bool:
	var reservations := world.get_reservations()
	var under_evaluation: Dictionary = {}
	var pending: Dictionary = world._scheduler.get_pending()
	for worker in pending:
		for candidate in (pending[worker]["candidates"] as Array):
			under_evaluation[candidate["id"]] = true
	for job in world.get_jobs():
		if (job["status"] == "queued" and not reservations.has(job["target"])
				and String(job.get("reason", "")).is_empty() and not under_evaluation.has(job["id"])):
			return true
	return false

func _idle_colonists(world: WorldType) -> Array[String]:
	var idle: Array[String] = []
	for colonist in world.get_colonists():
		if colonist["route"] == null and colonist["work"] == null:
			idle.append(colonist["id"])
	return idle

## Counts only the 20 scripted dig/chop orders `total` refers to: a completed
## auto-submitted haul job (which _add_stockpile_zone() lets actually
## succeed) must never let this return true while a scripted
## order is still outstanding.
func _all_orders_done(world: WorldType, total: int) -> bool:
	var completed := 0
	for job in world.get_jobs():
		if job["status"] == "completed" and String(job["kind"]) != "haul":
			completed += 1
	return completed == total

## Reassignment cannot be instantaneous: WorldState.tick()'s mandated order
## runs _scheduler.tick() before _advance_colonists(), so a colonist that
## finishes work this tick is invisible to this same tick's evaluation (one
## tick, not indefinite -- the same reconciliation lag that applies to an
## external cancel_job/fail_job/invalidate_job). Beyond that,
## GlobalAssignment evaluates one route candidate per pending worker per
## _scheduler.tick() call (see global_assignment.gd's cursor-driven batch
## loop, proven multi-tick by test_scheduling_fairness.gd's
## _check_route_cost_changes_choice), so a colonist mid-evaluation (present in
## _scheduler.get_pending()) can also stay idle for a tick or two while its
## batch resolves -- that is ADR 004's own candidate-pairing design. The
## drop_tool toil never adds a fourth
## idle tick on top of these two: it is inserted only at a toil boundary
## (colonist.route/work both null) and, whether it drops in place or starts a
## route toward a stockpile cell, colonist.route is never left null on the
## same tick advance() dispatches it (ToolDropToil.advance() always either
## drops synchronously and falls through to the job's own next toil the same
## tick, or leaves colonist.route non-null -- even a route whose own reroute
## search has not resumed yet this tick, since _resume_go_to_reroute() only
## resumes the persisted search object, it never clears the route dict back
## to null) -- so a drop_tool leg is never itself observable as "idle" by
## _idle_colonists()'s own route==null && work==null test below. Streaks of
## 1-3 ticks are therefore still the only ones expected for ordinary
## reassignment/route-evaluation lag.
##
## Earlier versions widened this check to tolerate a longer
## handover wait (a gated exemption, then a split into separate assigned/
## unassigned populations) instead of asking why a freshly assigned job could
## sit idle at all. The real cause was in tool_fetch_toil.gd: a freshly
## assigned job whose needs_tool candidate search landed on a tool already
## held by a busy foreign colonist could start waiting on its very first tick
## of assignment, even while a farther but immediately free tool of the same
## kind sat unused -- a wait this check correctly flagged as "idle while
## eligible work exists" (the busy colonist's own other job was that eligible
## work in this load scenario). Fixed at the source (ToolFetchToil.advance()
## now prefers any candidate not currently held by a busy colonist, falling
## back to a busy-held one only when no free alternative exists) rather than
## exempted here: this check is therefore the exact original, single
## continuous per-colonist streak, unconditional on assignment status, with
## no handover-specific carve-out at all -- a real, unavoidable handover wait
## (no free tool anywhere, as `_check_handover_wait_is_bounded_without_other_
## queued_work()` below constructs directly) never arises in this scenario's
## own geometry (10 tools shared by 3 colonists across 20 orders), so it never
## needs one.
func _waiting_for_handover(world: WorldType, colonist_id: String) -> bool:
	var assignment = world.get_assignments().get(colonist_id)
	if assignment == null:
		return false
	var wait: Dictionary = world._toils.waiting_for_handover(colonist_id, String(assignment["job_id"]))
	return not wait.is_empty()

## Generous upper bound on a single genuine handover wait, so handover
## progress is tested independently: the busy holder's
## own current toil can, worst case in this load scenario, still be walking
## the full load area toward its target (at most ~16 tiles, LOAD_AREA_WIDTH +
## LOAD_AREA_HEIGHT, at content/tiles.json's move_ticks_per_tile: 4) and then
## working it (chop's own 40 work_ticks, the longer of dig/chop's two), before
## its own drop_tool leg even starts (at most TOOL_DROP_RADIUS: 5 tiles,
## tool_drop_toil.gd, again at 4 ticks/tile). 16*4 + 40 + 5*4 = 164; rounded
## up with headroom. A wait exceeding this could not be explained by any
## holder still genuinely mid-toil in this scenario's own geometry, so it
## must be a real stall.
const HANDOVER_WAIT_TICK_BOUND := 200

func _check_no_idle_while_work_available() -> void:
	var world := _build_load_world(9001)
	var total := _submit_load_orders(world)
	var idle_streaks: Dictionary = {}
	var ticks := 0
	while not _all_orders_done(world, total) and ticks < LOAD_MAX_TICKS:
		world.tick()
		ticks += 1
		if not _has_eligible_queued_job(world):
			idle_streaks.clear()
			continue
		var idle_now: Dictionary = {}
		for id in _idle_colonists(world):
			idle_now[id] = true
			idle_streaks[id] = int(idle_streaks.get(id, 0)) + 1
			_expect(int(idle_streaks[id]) <= 3,
				"colonist %s idled %d ticks in a row while eligible, reachable work existed (tick %d)" %
					[id, idle_streaks[id], world.get_tick()])
		for id in idle_streaks.keys():
			if not idle_now.has(id):
				idle_streaks[id] = 0
	_expect(_all_orders_done(world, total), "all 20 orders must complete within the load test's tick budget")

## Dedicated, gate-independent handover-progress test: proves
## the handover mechanism's own bound holds with at most two jobs ever queued
## at a time (never a third), so the mechanism cannot be hiding behind
## _has_eligible_queued_job() finding something else to point at, and drives
## the full lifecycle through to the point where the requester -- previously
## waiting, route/work both null -- actually starts its own route once the
## wait ends, proving the transition out of the wait works too.
##
## Two colonists, one pick, same shape as test_tool_items.gd's own
## _check_requester_waits_for_real_handover_then_completes(): colonist_0
## (labour "mine" disabled) starts holding the pick as a leftover and takes
## forage_a; colonist_1 (labour "forage" disabled) has nothing to do until
## dig_b is submitted, needing the same pick -- now reserved by colonist_1 but
## still physically held by colonist_0, busy on forage_a -- so colonist_1
## must wait. Only once forage_a completes and forage_b (colonist_0's own
## next dispatched job, submitted only at that point -- so a third job is
## never queued while colonist_1 waits) sends colonist_0 to drop the pick does
## colonist_1's own wait end and its fetch route begin.
func _check_handover_wait_is_bounded_without_other_queued_work() -> void:
	var world := WorldType.new(9002)
	world._tiles.fill(WorldType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"})["ok"],
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"})["ok"],
		"berry_bush B placement must be accepted")
	var forage_a := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a["ok"], "forage_a must be accepted")
	var forage_a_id := String(forage_a["job_id"])

	var forage_a_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist_in(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			forage_a_busy = true
			break
	_expect(forage_a_busy, "colonist_0 must be busy on forage_a before dig_b (and its reservation) ever exists")

	world._tiles[world._tile_index(10, 9)] = WorldType.TILE_SOIL
	var dig_b := _command(world, "dig_b", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_b["ok"], "dig_b must be accepted")
	var dig_b_id := String(dig_b["job_id"])

	var wait_streaks: Dictionary = {}
	var forage_a_done := false
	var forage_b_id := ""
	var seen_route_after_wait := false
	var dig_b_done := false
	var ticks := 0
	while not dig_b_done and ticks < LOAD_MAX_TICKS:
		world.tick()
		ticks += 1
		if not forage_a_done:
			for job in world.get_jobs():
				if job["id"] == forage_a_id and job["status"] == "completed":
					forage_a_done = true
					# colonist_0's own NEXT dispatched job, submitted only now
					# -- a third job is never queued while colonist_1 waits.
					var forage_b := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
					_expect(forage_b["ok"], "forage_b must be accepted right as forage_a completes")
					forage_b_id = String(forage_b.get("job_id", ""))
		var waiting := _waiting_for_handover(world, "colonist_1")
		if waiting:
			wait_streaks["colonist_1"] = int(wait_streaks.get("colonist_1", 0)) + 1
			_expect(int(wait_streaks["colonist_1"]) <= HANDOVER_WAIT_TICK_BOUND,
				"colonist_1 waited %d ticks for the tool handover with no progress (tick %d) -- looks like a stall" %
					[wait_streaks["colonist_1"], world.get_tick()])
		else:
			wait_streaks["colonist_1"] = 0
			var colonist_1 := _find_colonist_in(world, "colonist_1")
			if colonist_1.get("route") != null:
				seen_route_after_wait = true
		for job in world.get_jobs():
			if job["id"] == dig_b_id and job["status"] == "completed":
				dig_b_done = true
	_expect(forage_a_done, "forage_a must complete within budget")
	_expect(not forage_b_id.is_empty(), "forage_b must have been submitted once forage_a completed")
	_expect(dig_b_done, "dig_b must complete once colonist_0's own next dispatched job drops the handed-over pick")
	_expect(seen_route_after_wait,
		"colonist_1 must be observed actually routing (not merely waiting) once the handover wait ends")

func _find_colonist_in(world: WorldType, colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

# --- (b) cancel mid-walk: reservation and colonist release next tick, then reuse ---

## A 10-tile soil corridor: colonist_0 at (0,0), first order far enough away
## (distance 9, 4 ticks/tile) that one tick after activation the colonist is
## still walking, never arrived.
func _build_corridor_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	for x in range(0, 10):
		world._tiles[world._tile_index(x, 0)] = WorldType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	# Already held: this scenario's exact one-tick-precision assertions leave
	# no room for fetch_tool's own travel tick.
	world.set_tool_item_held(world.spawn_ground_tool_item("pick", 0, 0), "colonist_0")
	return world

func _check_cancel_mid_walk_reassigns() -> void:
	var world := _build_corridor_world(555)
	var target := Vector2i(9, 0)
	var submit_result := _command(world, "far", "dig", {"x": target.x, "y": target.y, "priority": 1})
	_expect(submit_result["ok"], "far order must be accepted")
	if not submit_result["ok"]:
		return
	var job_id: String = submit_result["job_id"]

	world.tick() # Activation: route initialized and advanced by one tick this same tick.
	var mid_walk := world.get_colonists()[0]
	_expect(mid_walk["route"] != null, "colonist must be mid-walk (route in progress) before cancelling")
	_expect(mid_walk["x"] == 0 and mid_walk["y"] == 0, "colonist must not have arrived yet")

	var cancel_result := _command(world, "cancel_far", "cancel_job", {"job_id": job_id})
	_expect(cancel_result["ok"], "cancel_job must be accepted while the colonist is mid-walk")
	_expect(not world.get_reservations().has(target), "cancel_job must release the reservation immediately")

	world.tick() # The very next tick(): colonist's stale route/work are reconciled and cleared.
	var after_cancel := world.get_colonists()[0]
	_expect(after_cancel["route"] == null, "colonist's route must be cleared the tick after cancellation")
	_expect(after_cancel["work"] == null, "colonist's work must be cleared the tick after cancellation")
	_expect(not world.get_reservations().has(target), "reservation must stay released after the reconciling tick")

	var next_target := Vector2i(5, 0)
	var submitted_tick := world.get_tick()
	var second_result := _command(world, "near", "dig", {"x": next_target.x, "y": next_target.y, "priority": 1})
	_expect(second_result["ok"], "a fresh order must be accepted for the freed colonist")
	if not second_result["ok"]:
		return
	var second_job_id: String = second_result["job_id"]

	var activated := false
	var ticks := 0
	while not activated and ticks < MAX_WAIT:
		world.tick()
		ticks += 1
		for job in world.get_jobs():
			if job["id"] == second_job_id and job["status"] == "active":
				activated = true
	_expect(activated, "the freed colonist must pick up the next eligible order")
	_expect(world.get_tick() - submitted_tick <= MAX_WAIT,
		"reassignment after a mid-walk cancellation must not exceed the proven %d-tick service bound" % MAX_WAIT)

# --- (b) cancel mid-walk with another order already queued: reassignment can
# land on the very tick after cancellation, before route/work reconciliation ---

## Regression for the case where _scheduler.tick() reassigns the freed
## colonist to an already-queued job on the same tick _advance_colonists()
## would otherwise reconcile its stale route -- the window
## world_state.gd._advance_colonists() closes by comparing route/work's
## job_id against the current assignment before deciding whether to start
## fresh. Without that reconciliation the colonist would keep walking toward
## the cancelled "far" target using its old path instead of "near"'s.
func _check_cancel_mid_walk_with_queued_job_reassigns_same_tick() -> void:
	var world := _build_corridor_world(4242)
	var far_target := Vector2i(9, 0)
	var near_target := Vector2i(2, 0)
	var far_result := _command(world, "far", "dig", {"x": far_target.x, "y": far_target.y, "priority": 1})
	_expect(far_result["ok"], "far order must be accepted")
	if not far_result["ok"]:
		return
	var far_job_id: String = far_result["job_id"]

	world.tick() # far activates: colonist_0 begins walking toward (9,0).
	var mid_walk := world.get_colonists()[0]
	_expect(mid_walk["route"] != null and mid_walk["route"]["job_id"] == far_job_id,
		"colonist must be mid-walk toward far before cancelling")

	var near_result := _command(world, "near", "dig", {"x": near_target.x, "y": near_target.y, "priority": 1})
	_expect(near_result["ok"], "near order must be accepted while far is still active")
	if not near_result["ok"]:
		return
	var near_job_id: String = near_result["job_id"]

	var cancel_result := _command(world, "cancel_far", "cancel_job", {"job_id": far_job_id})
	_expect(cancel_result["ok"], "cancel_job must be accepted while colonist is mid-walk")

	var near_done := false
	var ticks := 0
	while not near_done and ticks < MAX_WAIT:
		world.tick()
		ticks += 1
		var colonist := world.get_colonists()[0]
		_expect(colonist["x"] <= near_target.x,
			"colonist must never walk past near's target toward the cancelled far target (tick %d, x=%d)" %
				[world.get_tick(), colonist["x"]])
		var route = colonist["route"]
		_expect(route == null or route["job_id"] == near_job_id,
			"colonist's route must never still reference the cancelled far job (tick %d)" % world.get_tick())
		var work = colonist["work"]
		_expect(work == null or work["job_id"] == near_job_id,
			"colonist's work must never still reference the cancelled far job (tick %d)" % world.get_tick())
		for job in world.get_jobs():
			if job["id"] == near_job_id and job["status"] == "completed":
				near_done = true
	_expect(near_done, "the queued near job must complete after the mid-walk cancellation frees the colonist")

# --- (b) same-tick save/load mid-walk: both copies must tick identically ---

const SAVE_LOAD_ADVANCE_TICKS := 60

func _check_save_load_mid_walk() -> void:
	var world := _build_corridor_world(777)
	var target := Vector2i(9, 0)
	var submit_result := _command(world, "far", "dig", {"x": target.x, "y": target.y, "priority": 1})
	_expect(submit_result["ok"], "far order must be accepted")

	world.tick()
	world.tick()
	var mid_walk := world.get_colonists()[0]
	_expect(mid_walk["route"] != null, "colonist must be mid-walk before the save")

	var saved := world.to_save_state()
	var restored := WorldType.from_save_state(saved)
	_expect(restored.state_hash() == world.state_hash(),
		"a mid-walk save/load round trip must match the source's hash before any further ticks")

	for _i in SAVE_LOAD_ADVANCE_TICKS:
		world.tick()
		restored.tick()
	_expect(world.state_hash() == restored.state_hash(),
		"identically advancing the source and its mid-walk restore must keep matching state_hash()")
