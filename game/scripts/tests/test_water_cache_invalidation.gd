extends SceneTree

## WorldState._tile_grid.water_tile_cache (a performance cache for
## _need_source_candidates("water")) originally assumed TILE_WATER
## tiles never change after generation. That is false: a berry_bush object
## sitting on a TILE_WATER tile is reachable independently of place_object
## (place_object itself rejects a water footprint tile, so this fixture forces the object directly onto _objects the way
## test_build.gd/test_colonist_sprites.gd force their own fixtures, exactly
## mirroring what _set_object() does internally); forage then accepts that
## bush as its target regardless of the tile beneath it, and
## _toil_on_work_complete() converts the tile to TILE_FLOOR exactly like any
## other forage target. Previously, a cache already built before that
## mutation kept offering the now-floor tile as a "water" need source
## forever after, while a StateCodec-decoded copy -- which always rebuilds
## its cache from the current _tiles, never a stale one -- would never make that
## mistake, silently diverging live and decoded candidate discovery. This
## proves the live world's cache now updates at the same "tile actually
## changed kind" hook that already drives dirty-cell/region/room refreshes in
## _toil_on_work_complete(), so live and save/load-restored discovery agree.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 918001
const WATER_TILE := Vector3i(5, 5, 0)
const COLONIST_START := Vector3i(0, 5, 0)
const FORAGE_TICK_BUDGET := 200

var _failed := false

func _init() -> void:
	_check_cache_updates_when_forage_clears_water_tile()

	if _failed:
		quit(1)
		return
	print("test_water_cache_invalidation: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _check_cache_updates_when_forage_clears_water_tile() -> void:
	var world := WorldStateType.new(SEED, 10, 20, 20)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_SOIL)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	TestAccess.set_tile(world, WATER_TILE.x, WATER_TILE.y, WorldStateType.TILE_WATER)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": COLONIST_START.x, "y": COLONIST_START.y, "z": 0, "route": null, "work": null, "carrying": null})

	# Force the water-tile cache to build before the mutation below, so this
	# proves the cache is kept in sync, not merely lazily rebuilt fresh every
	# time (which would hide the bug this test exists to catch).
	_expect(TestAccess.tile_grid(world).get_water_tiles().has(WATER_TILE),
		"setup: the water tile cache must include the fixture's own water tile before any mutation")

	# place_object now rejects a water footprint tile with the
	# same typed invalid_target reason it already used for a tree tile, so the
	# supported command can no longer put the bush on water. Assert that
	# contract explicitly (it replaced the old "accepted on water" assertion),
	# then force the berry_bush directly onto internal state -- the same
	# fixture-forcing pattern test_build.gd/test_colonist_sprites.gd already
	# use -- so the cache-invalidation path this test targets is still
	# exercised regardless of how the object got there.
	var place_result: Dictionary = world.apply({
		"actor": "test", "command_id": "place_bush_on_water", "tick": world.get_tick(),
		"type": "place_object", "payload": {"x": WATER_TILE.x, "y": WATER_TILE.y, "z": 0, "kind": "berry_bush"},
	})
	_expect(not place_result.get("ok", false)
			and String(place_result.get("rejection", {}).get("reason", "")) == "invalid_target",
		"place_object must reject a berry_bush on a water tile with invalid_target: %s" % place_result)
	_expect(world.get_object(WATER_TILE.x, WATER_TILE.y).is_empty(),
		"a rejected place_object must leave the water tile empty")
	TestAccess.object_table(world).set_object(Vector3i(WATER_TILE.x, WATER_TILE.y, 0), "berry_bush")

	var forage_result: Dictionary = world.apply({
		"actor": "test", "command_id": "forage_water_bush", "tick": world.get_tick(),
		"type": "forage", "payload": {"x": WATER_TILE.x, "y": WATER_TILE.y, "z": 0, "priority": 1, "assignee": "colonist_0"},
	})
	_expect(forage_result.get("ok", false), "forage must accept the water-tile bush as its target: %s" % forage_result)

	var completed := false
	for _i in FORAGE_TICK_BUDGET:
		world.tick()
		if world.get_object(WATER_TILE.x, WATER_TILE.y) != "berry_bush":
			completed = true
			break
	_expect(completed, "the forage order on the water-tile bush must complete within %d ticks" % FORAGE_TICK_BUDGET)
	if not completed:
		return

	_expect(world.get_tile(WATER_TILE.x, WATER_TILE.y) == WorldStateType.TILE_FLOOR,
		"forage must convert the water tile to floor exactly like any other forage target")

	var live_candidates: Array[Vector3i] = TestAccess.needs_system(world).need_source_candidates("water")
	_expect(not live_candidates.has(WATER_TILE),
		"the live world's water-tile cache must stop offering a tile that is no longer water once forage converts it to floor")

	# Save/load equivalence: a StateCodec-decoded copy always rebuilds its
	# cache from the current _tiles (it never had a chance to go stale), so it is
	# independent ground truth here -- the live world's own candidates must
	# now match it exactly, proving the invalidation fix (not merely a decode
	# side effect) is what keeps them in sync.
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_candidates: Array[Vector3i] = TestAccess.needs_system(restored).need_source_candidates("water")
	_expect(not restored_candidates.has(WATER_TILE),
		"a freshly decoded world must never offer the former water tile either")
	_expect(live_candidates == restored_candidates,
		"live and save/load-restored water candidates must agree after the mutation (got live=%s restored=%s)" % [live_candidates, restored_candidates])
	_expect(restored.state_hash() == world.state_hash(),
		"a save/load round trip right after the forage-on-water mutation must match the source's hash")
