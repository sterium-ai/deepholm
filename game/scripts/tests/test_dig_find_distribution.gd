extends SceneTree

## ADR 025 (docs/decisions/025-trench-trapped-actor-and-rescue.md): dig's
## completion effect rolls content/jobs.json's dig "find_table" against a
## dedicated seeded RandomNumberGenerator (WorldState._dig_find_random,
## salted with DIG_FIND_SEED_SALT). Drives 1000 real, seeded dig completions
## through world.tick() -- the same path every other dig test exercises, not
## a hand-rolled RNG in this test -- one fresh minimal world per seed (one
## dig each), so no world ever accumulates the job/item history a single
## long-lived 1000-dig world would. Checks the observed
## gold_coin/flint/coal/seed/none frequencies each land within +/-2
## percentage points of the table's declared 5/20/10/10/55 weights.

const WorldType = preload("res://scripts/core/world_state.gd")

const DIG_COUNT := 1000
const MAX_TICKS := 60
const BASE_SEED := 8675309
const TOLERANCE_PERCENT := 2.0
const EXPECTED_PERCENT := {
	"gold_coin": 5.0,
	"flint": 20.0,
	"coal": 10.0,
	"seed": 10.0,
	"none": 55.0,
}

var _failed := false

func _init() -> void:
	_check_find_distribution()
	_check_placement_rules()
	_check_single_completion_placement()
	_check_simultaneous_resolution_order()

	if _failed:
		quit(1)
		return
	print("test_dig_find_distribution: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _command(world: WorldType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

## A single soil tile at (1,0) next to the colonist's own (0,0); everything
## else rock, so routing is trivial. No "needs" key (mirrors
## test_movement_and_work.gd's own _build_world()): no need job can ever fire
## to interrupt the dig. "haul" is disabled in the colonist's own
## labourTable so the sand item this dig spawns never pulls the same
## colonist onto an auto-submitted (here permanently unreachable, no
## stockpile zone) haul job instead of finishing this test's one dig.
func _build_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value, 10)
	world._tiles.fill(WorldType.TILE_ROCK)
	world._tiles[world._tile_index(0, 0)] = WorldType.TILE_FLOOR
	world._tiles[world._tile_index(1, 0)] = WorldType.TILE_SOIL
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 0, "build": 3, "craft": 3, "cook": 3}})
	world.spawn_ground_tool_item("pick", 0, 0)
	return world

## The find item kind a completed dig at (1, 0) left behind ("" for no
## find): sand is always spawned first (WorldState._toil_on_work_complete()'s
## "dig" case spawns it immediately; ADR 025's find roll resolves later the
## same tick, in _resolve_dig_finds()), so among the tile's items the one
## that is not "sand" is the find, if any.
func _find_kind(world: WorldType) -> String:
	for item in world.get_items():
		if String(item["kind"]) != "sand":
			return String(item["kind"])
	return ""

func _check_find_distribution() -> void:
	var counts := {"gold_coin": 0, "flint": 0, "coal": 0, "seed": 0, "none": 0}

	for i in DIG_COUNT:
		var world := _build_world(BASE_SEED + i)
		var result := _command(world, "dig_1", "dig", {"x": 1, "y": 0, "priority": 1})
		_expect(result["ok"], "dig %d must be accepted: %s" % [i, result])
		if not result["ok"]:
			return

		var ticks := 0
		var completed := false
		while ticks < MAX_TICKS and not completed:
			world.tick()
			ticks += 1
			completed = world.get_tile(1, 0) == WorldType.TILE_TRENCH
		_expect(completed, "dig %d must complete within the tick budget" % i)
		if not completed:
			return

		var kind := _find_kind(world)
		if kind.is_empty():
			counts["none"] += 1
		else:
			_expect(counts.has(kind), "dig %d rolled an unknown find item kind '%s'" % [i, kind])
			if counts.has(kind):
				counts[kind] += 1

	for kind in EXPECTED_PERCENT.keys():
		var actual_percent := (float(counts[kind]) / float(DIG_COUNT)) * 100.0
		var expected_percent: float = EXPECTED_PERCENT[kind]
		_expect(absf(actual_percent - expected_percent) <= TOLERANCE_PERCENT,
			"'%s' must land within +/-%.0f percentage points of %.0f%% over %d digs (got %.2f%%, %d/%d)"
				% [kind, TOLERANCE_PERCENT, expected_percent, DIG_COUNT, actual_percent, counts[kind], DIG_COUNT])

## Pure placement-ordering coverage (ADR 025's row-major rule): calls
## WorldState._dig_item_placement() directly, isolated from job scheduling,
## so each exclusion reason (an impassable tile, a passable-but-excluded
## trench tile) and the full-block fallback are pinned to an exact
## coordinate rather than a loose "is sand somewhere near the trench" check.
func _check_placement_rules() -> void:
	var world := WorldType.new(1, 10)
	world._tiles.fill(WorldType.TILE_FLOOR)

	# All four neighbours open: row-major order (north, west, east, south) picks north.
	var picked := world._dig_item_placement(5, 5)
	_expect(picked == Vector2i(5, 4), "an open north neighbour must win, got %s" % [picked])

	# North blocked by an impassable tile (rock): west wins next.
	world._tiles[world._tile_index(5, 4)] = WorldType.TILE_ROCK
	picked = world._dig_item_placement(5, 5)
	_expect(picked == Vector2i(4, 5), "with north impassable, west must win, got %s" % [picked])

	# North+west blocked -- west is a trench tile specifically (passable but
	# excluded by kind, not by impassability): east wins.
	world._tiles[world._tile_index(4, 5)] = WorldType.TILE_TRENCH
	picked = world._dig_item_placement(5, 5)
	_expect(picked == Vector2i(6, 5),
		"a passable trench neighbour must still be excluded, east must win, got %s" % [picked])

	# North+west+east blocked: south wins.
	world._tiles[world._tile_index(6, 5)] = WorldType.TILE_ROCK
	picked = world._dig_item_placement(5, 5)
	_expect(picked == Vector2i(5, 6), "with only south open, south must win, got %s" % [picked])

	# All four neighbours blocked: falls back to the dug tile itself.
	world._tiles[world._tile_index(5, 6)] = WorldType.TILE_ROCK
	picked = world._dig_item_placement(5, 5)
	_expect(picked == Vector2i(5, 5),
		"with every neighbour blocked, placement must fall back to the tile itself, got %s" % [picked])

## End-to-end wiring check: a real dig completion (through world.tick(), not
## a staged call) must drop its sand exactly at the row-major placement rule's
## computed coordinate, never inside the trench, and exactly once.
func _check_single_completion_placement() -> void:
	var world := _build_world(20260923)
	var result := _command(world, "dig_1", "dig", {"x": 1, "y": 0, "priority": 1})
	_expect(result["ok"], "single-completion dig must be accepted: %s" % [result])
	if not result["ok"]:
		return

	var ticks := 0
	var completed := false
	while ticks < MAX_TICKS and not completed:
		world.tick()
		ticks += 1
		completed = world.get_tile(1, 0) == WorldType.TILE_TRENCH
	_expect(completed, "single-completion dig must finish within the tick budget")
	if not completed:
		return

	# (1, 0)'s only qualifying neighbour: north (1, -1) is off the map, so
	# west (0, 0) -- floor, passable, non-trench, and vacated once the
	# colonist steps onto (1, 0) itself to work -- wins under the row-major rule.
	var expected_at := Vector2i(0, 0)
	var items := world.get_items()
	var sand_count := 0
	for item in items:
		var at := Vector2i(int(item["x"]), int(item["y"]))
		_expect(at == expected_at,
			"item '%s' must land at the computed placement %s, got %s" % [item["kind"], expected_at, at])
		_expect(world.get_tile(at.x, at.y) != WorldType.TILE_TRENCH,
			"item '%s' must never land inside the trench tile" % item["kind"])
		if String(item["kind"]) == "sand":
			sand_count += 1
	_expect(sand_count == 1, "exactly one sand item must be spawned, got %d" % sand_count)
	_expect(items.size() == sand_count or items.size() == sand_count + 1,
		"completion must spawn only the guaranteed sand plus at most one find, got %d items" % items.size())

## Cumulative-weight lookup mirroring WorldState._roll_dig_find(), used only
## to build this test's independent oracle -- never substituted for the real
## _dig_find_random/_resolve_dig_finds() path under test below.
func _kind_for_roll(find_table: Array, roll: int) -> String:
	var cumulative := 0
	for entry in find_table:
		cumulative += int(entry["weight"])
		if roll < cumulative:
			var item = entry.get("item")
			return String(item) if item != null else ""
	return ""

## ADR 025: simultaneous dig completions resolve in ascending job-id order,
## never colonist-iteration/append order, and each consumes exactly one
## _dig_find_random draw. Stages _pending_dig_finds directly with the higher
## job id appended first -- the order a colonist array iterated out of
## job-id order would produce -- and calls the real _resolve_dig_finds(), so
## the exercised RNG stream and weight table are production's own; only the
## job-completion scheduling that would normally populate the queue is
## bypassed, since tick-level timing is not what this test targets.
func _check_simultaneous_resolution_order() -> void:
	var probe := WorldType.new(1, 10)
	var find_table: Array = probe._content.get_entry("jobs", "dig").get("yields", {}).get("find_table", [])

	# Search for a world seed whose first draw (the lower job id's, resolved
	# first) lands on "no find", so that outcome is exercised explicitly
	# rather than left to chance.
	var seed_value := -1
	for candidate in range(1, 2000):
		var probe_rng := RandomNumberGenerator.new()
		probe_rng.seed = candidate + WorldType.DIG_FIND_SEED_SALT
		if _kind_for_roll(find_table, probe_rng.randi_range(0, 99)).is_empty():
			seed_value = candidate
			break
	_expect(seed_value != -1, "must find a seed whose first dig-find roll is 'none' within the search budget")
	if seed_value == -1:
		return

	var world := WorldType.new(seed_value, 10)
	world._tiles.fill(WorldType.TILE_ROCK)
	# Two isolated trench tiles, each with exactly one open neighbour, far
	# enough apart that their placements can never collide.
	world._tiles[world._tile_index(1, 0)] = WorldType.TILE_TRENCH
	world._tiles[world._tile_index(0, 0)] = WorldType.TILE_FLOOR
	world._tiles[world._tile_index(9, 9)] = WorldType.TILE_TRENCH
	world._tiles[world._tile_index(9, 8)] = WorldType.TILE_FLOOR
	world._objects.clear()
	world._object_factions.clear()
	world._items.clear()
	world._item_factions.clear()

	# job_5 appended before job_2: the order a colonist array iterated out of
	# job-id order would produce, not ascending job-id order.
	world._pending_dig_finds = [
		{"job_id": "job_5", "x": 9, "y": 9},
		{"job_id": "job_2", "x": 1, "y": 0},
	]
	world._resolve_dig_finds()

	var reference := RandomNumberGenerator.new()
	reference.seed = seed_value + WorldType.DIG_FIND_SEED_SALT
	var expected_kind_job2 := _kind_for_roll(find_table, reference.randi_range(0, 99))
	var expected_kind_job5 := _kind_for_roll(find_table, reference.randi_range(0, 99))

	_expect(expected_kind_job2.is_empty(),
		"test setup must exercise job_2's no-find outcome, got '%s'" % expected_kind_job2)

	var items := world.get_items()
	_expect(items.size() == (1 if not expected_kind_job5.is_empty() else 0),
		"only job_5's find (if any) may be spawned; job_2 rolled no find, got %d items" % items.size())

	if not expected_kind_job5.is_empty():
		var found := false
		for item in items:
			if Vector2i(int(item["x"]), int(item["y"])) == Vector2i(9, 8) and String(item["kind"]) == expected_kind_job5:
				found = true
		_expect(found, "job_5's find '%s' must land at its own placement (9, 8)" % expected_kind_job5)

	_expect(world._dig_find_random.state == reference.state,
		"resolving 2 pending finds must consume exactly 2 draws in ascending job-id order, state mismatch")
