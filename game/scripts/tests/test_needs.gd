extends SceneTree

## Exercises WorldState's per-colonist needs (colonist-ai.md 3.1/3.8, issue
## #349/ADR 023): content declares food/water/rest with a per-day
## (`rate_per_day`) decay rate applied through a deterministic per-colonist,
## per-need integer accumulator (never a float) and warn/urgent/critical
## thresholds; a freshly spawned colonist starts every need full with its
## accumulator at 0; each need decays by its own kind's declared rate,
## clamped at 0, at the exact tick the task's acceptance criteria name; decay
## is identical across two independently-ticked, identically-seeded worlds
## and survives a save/load in the middle of a day; and StateCodec round-trips
## a live WorldState's needs and accumulators unchanged. No consumption,
## replenishment, or decision-layer reaction to a threshold here -- that is a
## later increment (see the task's Non-goals).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const NEEDS_CONTENT_PATH := "res://content/needs.json"
const NEED_KINDS := ["food", "water", "rest"]

var _failed := false

func _init() -> void:
	_check_needs_content_file()
	_check_fresh_colonist_needs_start_full()
	_check_needs_decay_by_declared_rate()
	_check_needs_clamp_at_zero()
	_check_needs_reach_zero_at_expected_tick()
	_check_needs_decay_deterministic_across_seeded_runs()
	_check_needs_decay_survives_save_load_mid_day()
	_check_state_codec_round_trip_preserves_needs()

	if _failed:
		quit(1)
		return
	print("test_needs: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _load_need_definitions() -> Dictionary:
	var file := FileAccess.open(NEEDS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_fail("could not open %s" % NEEDS_CONTENT_PATH)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("needs")) != TYPE_ARRAY:
		_fail("%s must contain a top-level 'needs' array" % NEEDS_CONTENT_PATH)
		return {}
	var definitions: Dictionary = {}
	for entry in parsed["needs"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			definitions[String(entry["kind"])] = entry
	return definitions

## game/content/needs.json must declare food, water and rest, each with a
## numeric rate_per_day and warn/urgent/critical thresholds (docs/architecture/
## colonist-ai.md 3.1: "Needs have three thresholds in data"; issue #349
## renamed the per-tick "rate" field to the per-day "rate_per_day").
func _check_needs_content_file() -> void:
	if _failed:
		return
	var definitions := _load_need_definitions()
	for kind in NEED_KINDS:
		var entry = definitions.get(kind)
		_expect(entry != null, "needs.json must declare kind '%s'" % kind)
		if entry == null:
			continue
		_expect(not entry.has("rate"), "needs.json '%s' must no longer declare the old per-tick 'rate' field" % kind)
		for field in ["rate_per_day", "warn", "urgent", "critical"]:
			_expect(typeof(entry.get(field)) == TYPE_FLOAT or typeof(entry.get(field)) == TYPE_INT,
				"needs.json '%s' must declare a numeric '%s'" % [kind, field])

## A freshly spawned colonist's needs dictionary has exactly food/water/rest,
## each starting at the full value (WorldState.NEED_FULL), with its sibling
## needsAccumulator starting at 0 for every kind (issue #349).
func _check_fresh_colonist_needs_start_full() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4242, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() > 0, "a freshly generated world must have at least one colonist")
	var need_full := world._need_full
	for colonist in colonists:
		var needs: Dictionary = colonist.get("needs", {})
		var accumulator: Dictionary = colonist.get("needsAccumulator", {})
		for kind in NEED_KINDS:
			_expect(needs.get(kind) == need_full,
				"colonist %s's '%s' need must start full (%d), got %s" %
					[colonist["id"], kind, need_full, needs.get(kind)])
			_expect(int(accumulator.get(kind, -1)) == 0,
				"colonist %s's '%s' needsAccumulator must start at 0, got %s" %
					[colonist["id"], kind, accumulator.get(kind)])

## After N ticks, each need equals max(0, full - floor(rate_per_day * N /
## day_length_ticks)) for its own kind's content-declared rate (colonist-ai.md
## 3.1, ADR 023): the accumulator adds rate_per_day every tick and subtracts
## exactly day_length_ticks -- never resetting to 0 -- each time it reaches
## that threshold, so the point count after N ticks is exactly an integer
## floor division, with no float anywhere.
func _check_needs_decay_by_declared_rate() -> void:
	if _failed:
		return
	var definitions := _load_need_definitions()
	var world := WorldStateType.new(1001, 10)
	var day_length := world._calendar.day_length_ticks()
	var ticks := 220
	for _i in ticks:
		world.tick()
	var need_full := world._need_full
	for colonist in world.get_colonists():
		var needs: Dictionary = colonist["needs"]
		for kind in NEED_KINDS:
			var rate := int(definitions[kind]["rate_per_day"])
			var expected := maxi(0, need_full - (rate * ticks) / day_length)
			_expect(int(needs[kind]) == expected,
				"colonist %s's '%s' need after %d ticks must be %d (rate_per_day %d, day_length_ticks %d), got %s" %
					[colonist["id"], kind, ticks, expected, rate, day_length, needs[kind]])

## A need's decay is clamped at 0: it must never go negative even after far
## more ticks than it takes to reach zero from full.
func _check_needs_clamp_at_zero() -> void:
	if _failed:
		return
	var definitions := _load_need_definitions()
	var world := WorldStateType.new(2002, 10)
	# issue #300 round 1 revision: the real river-aware generator can place a
	# colonist close enough to water/food/a bed that a need job actually
	# completes within this test's own tick window, which used to be
	# incidentally true for this seed/size under the old generator but was
	# never this test's actual claim ("decay clamps at 0 with no source ever
	# reachable"). Removing every tile/object a need source could resolve
	# against makes that claim terrain-independent instead of seed-dependent.
	world._tiles.fill("rock")
	world._objects.clear()
	world._object_factions.clear()
	var day_length := world._calendar.day_length_ticks()
	var need_full := world._need_full
	var slowest_rate := 999999
	for kind in NEED_KINDS:
		slowest_rate = mini(slowest_rate, int(definitions[kind]["rate_per_day"]))
	var ticks := ((need_full * day_length) / maxi(slowest_rate, 1)) + 200
	for _i in ticks:
		world.tick()
	for colonist in world.get_colonists():
		var needs: Dictionary = colonist["needs"]
		for kind in NEED_KINDS:
			_expect(int(needs[kind]) == 0,
				"colonist %s's '%s' need must be clamped at 0 after %d ticks, got %s" %
					[colonist["id"], kind, ticks, needs[kind]])
			_expect(int(needs[kind]) >= 0, "a need must never go negative")

## The task's own acceptance criteria (issue #349): from full, with no
## reachable source, food reaches 0 after 2200*100/67 ≈ 3284 ticks, water
## after 2200 ticks (its rate_per_day equals `full`), and rest after 2750
## ticks -- each ±1 tick for rounding. Computed here as an exact integer
## ceiling division (no float), matching ActorNeeds.apply_tick()'s own
## accumulate-then-subtract-the-remainder arithmetic.
func _check_needs_reach_zero_at_expected_tick() -> void:
	if _failed:
		return
	var definitions := _load_need_definitions()
	var world := WorldStateType.new(3300, 10)
	world._tiles.fill("rock")
	world._objects.clear()
	world._object_factions.clear()
	var day_length := world._calendar.day_length_ticks()
	var need_full := world._need_full
	var expected: Dictionary = {}
	var max_expected := 0
	for kind in NEED_KINDS:
		var rate := int(definitions[kind]["rate_per_day"])
		var numerator := need_full * day_length
		var ticks_to_zero := (numerator + rate - 1) / rate # integer ceiling division
		expected[kind] = ticks_to_zero
		max_expected = maxi(max_expected, ticks_to_zero)

	var zero_tick: Dictionary = {}
	var tick := 0
	var budget := max_expected + 20
	while tick < budget and zero_tick.size() < NEED_KINDS.size():
		world.tick()
		tick += 1
		var needs: Dictionary = world.get_colonists()[0]["needs"]
		for kind in NEED_KINDS:
			if not zero_tick.has(kind) and int(needs[kind]) == 0:
				zero_tick[kind] = tick

	for kind in NEED_KINDS:
		_expect(zero_tick.has(kind), "'%s' must reach 0 within the tick budget (expected ~%d)" % [kind, expected[kind]])
		if zero_tick.has(kind):
			_expect(absi(int(zero_tick[kind]) - int(expected[kind])) <= 1,
				"'%s' must reach 0 at tick %d (±1 for rounding), got %d" % [kind, expected[kind], zero_tick[kind]])

## Two independently constructed, identically-seeded worlds ticked the same
## number of times must decay every need and every accumulator identically
## (AGENTS.md's determinism rule; ADR 023's integer-only accumulator).
func _check_needs_decay_deterministic_across_seeded_runs() -> void:
	if _failed:
		return
	var first := WorldStateType.new(5005, 10)
	var second := WorldStateType.new(5005, 10)
	for _i in 300:
		first.tick()
		second.tick()
	var first_colonists := first.get_colonists()
	var second_colonists := second.get_colonists()
	_expect(first_colonists.size() == second_colonists.size(), "two identically-seeded worlds must spawn the same colonist count")
	for i in first_colonists.size():
		_expect(first_colonists[i]["needs"] == second_colonists[i]["needs"],
			"two identically-seeded worlds must decay needs identically: %s vs %s" % [first_colonists[i]["needs"], second_colonists[i]["needs"]])
		_expect(first_colonists[i]["needsAccumulator"] == second_colonists[i]["needsAccumulator"],
			"two identically-seeded worlds must carry identical needsAccumulator state: %s vs %s" %
				[first_colonists[i]["needsAccumulator"], second_colonists[i]["needsAccumulator"]])
	_expect(first.state_hash() == second.state_hash(), "two identically-seeded worlds must reach the same state_hash()")

## The per-need accumulator is real persisted state, not an in-memory-only
## value: saving mid-day (a tick count that is not a multiple of
## day_length_ticks, so every accumulator holds a genuine partial carry),
## restoring, and continuing to tick both the live and restored copies must
## decay every need identically to an uninterrupted run (issue #349's own
## acceptance: "decay is identical ... after a save/load in the middle of a
## day (accumulator persisted)").
func _check_needs_decay_survives_save_load_mid_day() -> void:
	if _failed:
		return
	var live := WorldStateType.new(6006, 10)
	for _i in 137:
		live.tick()
	var live_colonists_before := live.get_colonists()
	var has_partial_carry := false
	for colonist in live_colonists_before:
		var accumulator: Dictionary = colonist.get("needsAccumulator", {})
		for kind in NEED_KINDS:
			if int(accumulator.get(kind, 0)) > 0:
				has_partial_carry = true
	_expect(has_partial_carry, "137 ticks mid-day must leave at least one colonist's accumulator with a genuine partial carry")

	var saved := live.to_save_state()
	var restored := StateCodecType.decode(saved)
	_expect(restored.state_hash() == live.state_hash(),
		"a save/load round trip taken mid-day must match the source's hash before any further ticks")
	var restored_colonists := restored.get_colonists()
	for i in live_colonists_before.size():
		_expect(live_colonists_before[i]["needsAccumulator"] == restored_colonists[i]["needsAccumulator"],
			"a save/load round trip must preserve each colonist's needsAccumulator exactly: %s vs %s" %
				[live_colonists_before[i]["needsAccumulator"], restored_colonists[i]["needsAccumulator"]])

	for _i in 300:
		live.tick()
		restored.tick()
	_expect(live.state_hash() == restored.state_hash(),
		"identically advancing the source and its mid-day restore must keep matching state_hash()")
	var live_colonists_after := live.get_colonists()
	var restored_colonists_after := restored.get_colonists()
	for i in live_colonists_after.size():
		_expect(live_colonists_after[i]["needs"] == restored_colonists_after[i]["needs"],
			"decay after a mid-day save/load must match an uninterrupted run's needs exactly: %s vs %s" %
				[live_colonists_after[i]["needs"], restored_colonists_after[i]["needs"]])

## StateCodec.encode()/decode() must round-trip a live WorldState's needs and
## needsAccumulator unchanged, including a colonist whose needs have already
## partially decayed.
func _check_state_codec_round_trip_preserves_needs() -> void:
	if _failed:
		return
	var world := WorldStateType.new(3003, 10)
	for _i in 7:
		world.tick()
	var before := world.get_colonists()

	var encoded := StateCodecType.encode(world)
	var decoded := StateCodecType.decode(encoded)
	var after := decoded.get_colonists()

	_expect(before.size() == after.size(), "round trip must preserve colonist count")
	for i in before.size():
		_expect(before[i]["needs"] == after[i]["needs"],
			"round trip must preserve colonist %s's needs unchanged: %s vs %s" %
				[before[i]["id"], before[i]["needs"], after[i]["needs"]])
		_expect(before[i]["needsAccumulator"] == after[i]["needsAccumulator"],
			"round trip must preserve colonist %s's needsAccumulator unchanged: %s vs %s" %
				[before[i]["id"], before[i]["needsAccumulator"], after[i]["needsAccumulator"]])

	_expect(world.state_hash() == decoded.state_hash(),
		"a round-tripped world must reproduce the same state_hash()")
