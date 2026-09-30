extends SceneTree

## test_new_game_dig_chop.gd tops every colonist's needs up to 100 every
## tick, so it never proves normal initial gameplay -- that a
## fresh New Game's generator-placed resources are enough to service real
## food/water/rest decay for all three colonists while ordinary player orders
## also get worked. This drives a real New Game (boot.gd's own build path,
## never a hand-built fixture) with needs decaying exactly like real play.
##
## The bounded initial-needs scenario this proves (ADR 020): mapgen.json's
## berry_bush_count is a starting allotment, not a
## regrowing supply (each forage yields exactly one ground berry -- see
## world_state.gd's _spawn_berries_item()). WorldGenerator.place_spawn() only
## ever guarantees one reachable bush per colonist (the nearest one, within
## spawn_food_step_limit), never a distinct one for each of the three -- so
## this forages every distinct bush within a wide net of the colony's own
## centroid (BUSH_SEARCH_RADIUS, never per-colonist exclusive picking, which
## could walk a colonist's own target arbitrarily far chasing distinctness),
## up to colonist_count + 2, and one chop order per colonist against its own
## distinct reachable tree (needing a real fetched axe, same as
## test_new_game_dig_chop.gd; trees are plentiful -- 40 by default, versus 8
## bushes -- so per-colonist distinctness holds for them). It then just ticks
## the real work engine -- need-driven eat_food/drink_water/sleep jobs
## interleave with the player orders exactly as they would in a real session,
## sleep included now that boot.gd places one starting bed per colonist
## (without them normal generation supplies no rest-need source at all).
## Real need-driven eat_food then distributes the resulting ground
## berries to whichever hungry colonist reaches one first, exactly like real
## play, rather than this test hand-assigning "whose" berry each one is.
## Within a bounded but generous tick budget (see TICK_BUDGET's own doc
## comment), this asserts per colonist (not just an aggregate count): its own
## chop order completes, and it individually experiences at least one real
## food-need restore and one real rest-need restore (detected as a large
## single-tick jump in that colonist's own need value -- a real eat_food/
## sleep completion, not merely a bush being cleared). This deliberately does
## not assert needs never bottom out:
## NeedGiver (game/scripts/core/jobs/givers/need_giver.gd) only searches
## reactively once a need crosses "urgent"
## (25), so a source near the documented 40-step travel bound can legitimately
## let a need reach 0 while a colonist is en route to it -- the guarantee this
## proves is that the initial forage/chop/eat/sleep cycle actually completes,
## for every colonist, under real decay, not indefinite sustainability or a
## zero-avoidance promise this codebase's existing need-search behaviour
## cannot make.
##
## An unrestricted forage/chop order pool lets the fair
## scheduler hand any one colonist a run of several regular jobs in a row
## (on seed 555002, colonist_2 alone ate 4 of the colony's 5 one-time
## berries while colonist_0 got none) -- not because colonist_0 could not
## reach a bush, but because NeedGiver's own onset_failed (candidates
## momentarily empty) leaves it looking idle to the fair scheduler the very
## same tick, which can then hand it a fresh multi-tick regular-job route
## before its own need is ever reconsidered (NeedGiver has no interrupt for
## "en route to a regular job, toil not yet started", only for "already
## working"). Every forage/chop order below names its own colonist as
## "assignee" (the existing dig/chop/forage assignee restriction), so the
## fair scheduler can never hand one
## colonist's own guaranteed order to a different colonist.

const BootScenePath := "res://scenes/boot.tscn"
const NEW_GAME_SEED := 555002
## A colonist's in-progress "work" toil is interruptible by its own critical
## need (NeedGiver._evaluate()): with three
## colonists all starting at full needs simultaneously, their first few
## urgent/critical onsets land in a similar tick window, so a work session
## (25-40 ticks) can keep losing a race against a fresh interruption several
## times before the timing desynchronises enough for an uninterrupted stretch
## to complete it. ADR 024 slowed decay to points-per-day against a
## 2200-tick day: a need no longer starts its first urgent onset until roughly
## 1650-2500 ticks in (water/rest/food respectively, from full to the urgent
## threshold of 25), where the earlier per-tick scale reached it within
## ~40-75 ticks.
## 60000 keeps the prior budget's own contention-absorbing margin (20000, the
## single-colonist predecessor's empirically-needed value) on top of that
## much later first-onset floor, generous enough for all three colonists at
## once, not merely each one's own best-case travel+work cost.
const TICK_BUDGET := 60000
const SEARCH_RADIUS := 60
## Wider than SEARCH_RADIUS/the generator's own per-colonist 40-step
## accessibility guarantee (which only promises one reachable bush, never a
## distinct one per colonist): gathering distinct bushes from this much wider
## net around the colony's own centroid is what actually finds enough of
## them, real forage yield being one berry per bush with no regrowth.
const BUSH_SEARCH_RADIUS := 120
## A restore (eat_food/drink_water/sleep completing) always jumps a need back
## to at least "restore" (needs.json, >= 100 for every kind today) in a
## single tick; ordinary decay only ever moves a need by at most 1 point per
## tick (ActorNeeds.apply_tick()'s accumulator, ADR 024: every
## content rate_per_day is below day_length_ticks, so at most one point can
## ever be subtracted in a single tick). 30 comfortably separates the two so
## this never misreads decay as a restore.
const RESTORE_JUMP_THRESHOLD := 30

var _failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var boot_scene: PackedScene = load(BootScenePath)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	await process_frame
	boot_node._start_new_game(NEW_GAME_SEED)
	var world = boot_node.get("world")
	_expect(world != null, "New Game must produce a world")
	if world == null:
		_finish(boot_node)
		return

	var colonists: Array = world.get_colonists()
	_expect(colonists.size() == 3, "New Game must spawn exactly 3 colonists, found %d" % colonists.size())

	var centroid := Vector2i.ZERO
	for colonist in colonists:
		centroid += Vector2i(int(colonist["x"]), int(colonist["y"]))
	if not colonists.is_empty():
		centroid /= colonists.size()

	# An unrestricted forage order lets the fair scheduler hand
	# any colonist's bush to any colonist, with no floor on how many any one of
	# them ends up doing -- on seed 555002 this let colonist_2 alone complete
	# (and eat from) 4 of the colony's 5 one-time, non-regrowing berries while
	# colonist_0 never won a single race, because an unrestricted regular job
	# also leaves a colonist that just went idle (NeedGiver's own onset_failed,
	# candidates empty, sets no reservation) immediately available for the fair
	# scheduler to hand a fresh multi-tick travel commitment the very same tick
	# -- during which the colonist en route (route set, "work" not yet started)
	# cannot be interrupted by any need at all, critical or otherwise (that gap
	# lives in NeedGiver). So each colonist
	# gets one guaranteed bush of its own first, submitted with "assignee" (the
	# existing dig/chop/forage assignee restriction, not a new mechanism)
	# so the fair scheduler can never hand it to a different colonist -- this
	# is what actually keeps a single colonist's own real timing from starving
	# it out from under a shared, unrestricted pool. Berries never regrow, so
	# this also gathers the wider shared pool up to a generous cap (never
	# per-colonist exclusive picking for the bonus bushes, which could walk a
	# colonist's own target arbitrarily far chasing distinctness) as slack on
	# top of each colonist's own guaranteed one -- real need-driven eat_food
	# distributes those extra berries to whichever hungry colonist reaches one
	# first, exactly like real play.
	var own_bushes: Array[Vector2i] = []
	var bush_targets: Array[Vector2i] = []
	for colonist in colonists:
		var colonist_id: String = colonist["id"]
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var own_bush := _nearest_object_excluding(world, origin, "berry_bush", own_bushes, BUSH_SEARCH_RADIUS)
		_expect(own_bush != Vector2i(-1, -1), "colonist %s must have a reachable berry bush of its own near spawn" % colonist_id)
		if own_bush != Vector2i(-1, -1):
			own_bushes.append(own_bush)
			bush_targets.append(own_bush)
			_submit(world, "forage", own_bush, colonist_id)
	var wide_bushes: Array[Vector2i] = _nearest_objects(world, centroid, "berry_bush", colonists.size() + 2, BUSH_SEARCH_RADIUS)
	_expect(wide_bushes.size() >= colonists.size(), "the colony's own surroundings must have at least %d reachable berry bushes total, found %d" % [colonists.size(), wide_bushes.size()])
	for bush in wide_bushes:
		if own_bushes.has(bush):
			continue
		bush_targets.append(bush)
		_submit(world, "forage", bush)

	var used_trees: Array[Vector2i] = []
	var tree_targets: Dictionary = {} # colonist_id -> Vector2i
	for colonist in colonists:
		var colonist_id: String = colonist["id"]
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var tree := _nearest_tile_excluding(world, origin, "tree", used_trees)
		_expect(tree != Vector2i(-1, -1), "colonist %s must have a reachable tree tile of its own near spawn" % colonist_id)
		if tree != Vector2i(-1, -1):
			used_trees.append(tree)
			tree_targets[colonist_id] = tree
			# assignee-restricted: this is already "the
			# colonist's own" tree by construction (nearest, excluding others'
			# already-picked ones) -- restricting the job to match stops the
			# fair scheduler from instead handing a different colonist's own
			# tree assignment to it, which starved food-seeking for the same
			# reason the unrestricted bush pool did above.
			_submit(world, "chop", tree, colonist_id)

	var forage_done: Dictionary = {} # "x_y" -> bool, one entry per bush_targets member
	var chop_done: Dictionary = {} # colonist_id -> bool
	var food_restored: Dictionary = {} # colonist_id -> bool
	var rest_restored: Dictionary = {} # colonist_id -> bool
	var water_restored: Dictionary = {} # colonist_id -> bool
	var previous_needs: Dictionary = {} # colonist_id -> {kind: value}
	for colonist in colonists:
		previous_needs[String(colonist["id"])] = (colonist["needs"] as Dictionary).duplicate()

	var ticks := 0
	while ticks < TICK_BUDGET and not _all_done(colonists, bush_targets, forage_done, tree_targets, chop_done, food_restored, rest_restored):
		world.tick()
		ticks += 1
		for bush in bush_targets:
			if world.get_object(bush.x, bush.y) != "berry_bush":
				forage_done["%d_%d" % [bush.x, bush.y]] = true
		for colonist_id in tree_targets.keys():
			var tree: Vector2i = tree_targets[colonist_id]
			if world.get_tile(tree.x, tree.y) == "floor":
				chop_done[colonist_id] = true
		for colonist in world.get_colonists():
			var colonist_id: String = colonist["id"]
			var needs: Dictionary = colonist["needs"]
			var previous: Dictionary = previous_needs.get(colonist_id, {})
			for kind in ["food", "water", "rest"]:
				var value := int(needs.get(kind, 0))
				var prior := int(previous.get(kind, value))
				if value - prior >= RESTORE_JUMP_THRESHOLD:
					match kind:
						"food": food_restored[colonist_id] = true
						"water": water_restored[colonist_id] = true
						"rest": rest_restored[colonist_id] = true
			previous_needs[colonist_id] = needs.duplicate()

	for bush in bush_targets:
		_expect(bool(forage_done.get("%d_%d" % [bush.x, bush.y], false)),
			"the forage order at %s must complete within %d ticks of real need decay on a New Game world" % [bush, TICK_BUDGET])
	for colonist in colonists:
		var colonist_id: String = colonist["id"]
		if tree_targets.has(colonist_id):
			_expect(bool(chop_done.get(colonist_id, false)),
				"colonist %s's chop order must complete within %d ticks of real need decay on a New Game world with a real fetched axe" % [colonist_id, TICK_BUDGET])
		_expect(bool(food_restored.get(colonist_id, false)),
			"colonist %s must complete at least one real eat_food restore within %d ticks, proving the colony's foraged ground berries are reachable and eaten" % [colonist_id, TICK_BUDGET])
		_expect(bool(rest_restored.get(colonist_id, false)),
			"colonist %s must complete at least one real sleep restore within %d ticks, proving boot.gd's starting bed is reachable and usable" % [colonist_id, TICK_BUDGET])
		_expect(bool(water_restored.get(colonist_id, false)),
			"colonist %s must complete at least one real drink_water restore within %d ticks (water is never generator-scarce, unlike bushes)" % [colonist_id, TICK_BUDGET])

	_finish(boot_node)

func _all_done(colonists: Array, bush_targets: Array, forage_done: Dictionary, tree_targets: Dictionary, chop_done: Dictionary, food_restored: Dictionary, rest_restored: Dictionary) -> bool:
	for bush in bush_targets:
		if not bool(forage_done.get("%d_%d" % [bush.x, bush.y], false)):
			return false
	for colonist in colonists:
		var colonist_id: String = colonist["id"]
		if tree_targets.has(colonist_id) and not bool(chop_done.get(colonist_id, false)):
			return false
		if not bool(food_restored.get(colonist_id, false)):
			return false
		if not bool(rest_restored.get(colonist_id, false)):
			return false
	return true

func _submit(world, job_type: String, target: Vector2i, assignee: String = "") -> void:
	var payload := {"x": target.x, "y": target.y, "priority": 1}
	if not assignee.is_empty():
		payload["assignee"] = assignee
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": "%s_new_game_forage_chop_%d_%d" % [job_type, target.x, target.y], "tick": world.get_tick(),
		"type": job_type, "payload": payload,
	})
	_expect(result.get("ok", false), "%s command on a New Game world must be accepted: %s" % [job_type, result])

func _nearest_tile_excluding(world, origin: Vector2i, kind: String, excluded: Array[Vector2i]) -> Vector2i:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	for radius in range(0, SEARCH_RADIUS + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				var pos := Vector2i(x, y)
				if world.get_tile(x, y) == kind and world.get_object(x, y) == "" and not excluded.has(pos):
					return pos
	return Vector2i(-1, -1)

## Nearest single object of `kind` (Chebyshev ring expansion from `origin`),
## skipping anything already in `excluded` -- mirrors _nearest_tile_excluding()
## but for an object (a berry_bush), not a tile kind. Vector2i(-1, -1) when
## none exists within `radius_limit`.
func _nearest_object_excluding(world, origin: Vector2i, kind: String, excluded: Array[Vector2i], radius_limit: int) -> Vector2i:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	for radius in range(0, radius_limit + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				var pos := Vector2i(x, y)
				if world.get_object(x, y) == kind and not excluded.has(pos):
					return pos
	return Vector2i(-1, -1)

## Up to `max_count` distinct objects of `kind`, nearest-first (Chebyshev ring
## expansion from `origin`), within `radius` -- may return fewer than
## `max_count` if that many do not exist within range.
func _nearest_objects(world, origin: Vector2i, kind: String, max_count: int, radius_limit: int) -> Array[Vector2i]:
	var width: int = world.get_map_width()
	var height: int = world.get_map_height()
	var found: Array[Vector2i] = []
	for radius in range(0, radius_limit + 1):
		if found.size() >= max_count:
			break
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if world.get_object(x, y) == kind:
					found.append(Vector2i(x, y))
					if found.size() >= max_count:
						return found
	return found

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _finish(boot_node: Node) -> void:
	root.remove_child(boot_node)
	boot_node.free()
	if _failures.is_empty():
		print("test_new_game_forage_chop: PASS")
		quit()
		return
	for failure in _failures:
		push_error("test_new_game_forage_chop: " + failure)
	quit(1)
