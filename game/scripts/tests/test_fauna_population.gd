extends SceneTree

## F6b-1 (ADR 070) population acceptance, headless through ticks on an all-soil 48x48 surface:
## grasshoppers alone reach their cap and hold it; two birds keep them below it and survive; a wolf
## with no prey starves within its window.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const DAY_TICKS := 2200
const SAMPLE_TICKS := 100

var _failed := false

func _init() -> void:
	_check_grasshoppers_reach_cap_and_hold()
	_check_birds_keep_grasshoppers_below_cap()
	_check_wolf_without_prey_starves()
	if _failed:
		quit(1)
		return
	print("test_fauna_population: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _soil_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.object_table(world).objects.clear()
	return world

func _spawn_grasshoppers(world: WorldStateType) -> void:
	for i in 20:
		world._fauna.spawn("grasshopper", Vector3i(10 + i % 5, 10 + i / 5, 0))

## 20 grasshoppers, no predators: the count reaches the cap (60) and never exceeds it.
func _check_grasshoppers_reach_cap_and_hold() -> void:
	var world := _soil_world(7)
	_spawn_grasshoppers(world)
	var cap := int(world._fauna.get_species("grasshopper")["cap"])
	var reached_tick := -1
	var low_after_reached := cap
	for i in 20 * DAY_TICKS:
		world.tick()
		if i % SAMPLE_TICKS != 0:
			continue
		var count: int = world._fauna.count_of("grasshopper")
		_expect(count <= cap, "grasshoppers must never exceed the cap %d (saw %d)" % [cap, count])
		if count == cap and reached_tick < 0:
			reached_tick = i
		if reached_tick >= 0:
			low_after_reached = mini(low_after_reached, count)
	_expect(reached_tick >= 0, "20 grasshoppers alone must reach the cap %d within 20 days" % cap)
	_expect(low_after_reached >= cap - 3, "grasshoppers must stay at the cap once reached (dipped to %d)" % low_after_reached)
	_expect(world._fauna.count_of("grasshopper") == cap, "grasshoppers must end at the cap")

## 20 grasshoppers + 2 birds: grasshoppers stay below the cap the whole run and birds survive.
func _check_birds_keep_grasshoppers_below_cap() -> void:
	var world := _soil_world(7)
	_spawn_grasshoppers(world)
	for i in 2:
		world._fauna.spawn("bird", Vector3i(20 + i, 20, 0))
	var cap := int(world._fauna.get_species("grasshopper")["cap"])
	var peak := 0
	for i in 20 * DAY_TICKS:
		world.tick()
		if i % SAMPLE_TICKS != 0:
			continue
		peak = maxi(peak, world._fauna.count_of("grasshopper"))
		_expect(world._fauna.count_of("bird") > 0, "the birds must survive (all dead at tick %d)" % i)
	_expect(peak < cap, "birds must keep grasshoppers below the cap %d (peak %d)" % [cap, peak])
	_expect(world._fauna.count_of("grasshopper") > 0, "birds must not wipe the grasshoppers out")

## A lone wolf (no prey) is alive just before its starvation window and dead just after.
func _check_wolf_without_prey_starves() -> void:
	var world := _soil_world(9)
	world._fauna.spawn("wolf", Vector3i(24, 24, 0))
	var starve := int(world._fauna.get_species("wolf")["starve_ticks"])
	_expect(starve == 6 * DAY_TICKS, "the wolf's starvation window must be 6 days (got %d ticks)" % starve)
	for _i in starve - 10:
		world.tick()
	_expect(world._fauna.count_of("wolf") == 1, "the wolf must still be alive just before its window")
	for _i in 20:
		world.tick()
	_expect(world._fauna.count_of("wolf") == 0, "a wolf without prey must starve within its window")
