extends SceneTree

## L2 evidence for the state_hash() literals that moved. Two scenarios, each hashed twice: by
## WorldState.state_hash() itself, and by the same snapshot (WorldState.state_hash()'s body,
## copied) under the pre-L2 projection: every layer-0 Vector3i printed as the Vector2i it was,
## "z" dropped beside every x/y, "layer_count" dropped. If L2 changed nothing but the added
## layer fields, the projection reproduces the pre-L2 literals:
## - test_toils_dig_chop_regression.gd (its _build_world()/_run_scenario() copied verbatim
##   below, 260 ticks): 1312885732 / 4178825690;
## - test_world_state_determinism.gd's _check_incidents_disabled_matches_pre_incident_baseline()
##   (seed 20260922, default size, incidents off, 650 ticks), state_hash(false): 3266324817 (F3's literal).
## Run from the repo root (exit 0 when both projections match):
##   godot --headless --path game --script ../docs/orca/handoffs/L2-hash_projection.gd

const WorldType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")
const CombatSystemType = preload("res://scripts/core/actors/combat_system.gd")

const PRE_L2_HASH := 1312885732
const PRE_L2_COLONY_HASH := 4178825690
const PRE_L2_BASELINE_HASH := 3266324817
const TOTAL_TICKS := 260

func _init() -> void:
	var world := _build_world(190190)
	_run_scenario(world)
	for _i in TOTAL_TICKS:
		world.tick()
	var full := world.state_hash()
	var colony := world.state_hash(false)
	var projected := hash(JSON.stringify(_pre_l2(_snapshot(world, true))))
	var projected_colony := hash(JSON.stringify(_pre_l2(_snapshot(world, false))))
	# The copied snapshot must be state_hash()'s own: same hash before projecting.
	var copy_ok := hash(JSON.stringify(_snapshot(world, true))) == full and hash(JSON.stringify(_snapshot(world, false))) == colony
	print("L2-hash_projection: state_hash()=%d state_hash(false)=%d copy_matches=%s" % [full, colony, copy_ok])
	print("L2-hash_projection: projected=%d (pre-L2 %d) projected_colony=%d (pre-L2 %d)" % [projected, PRE_L2_HASH, projected_colony, PRE_L2_COLONY_HASH])
	var baseline := WorldType.new(20260922, 10, WorldType.MAP_WIDTH, WorldType.MAP_HEIGHT, false)
	for _i in 650:
		baseline.tick()
	var baseline_hash := baseline.state_hash(false)
	var projected_baseline := hash(JSON.stringify(_pre_l2(_snapshot(baseline, false))))
	copy_ok = copy_ok and hash(JSON.stringify(_snapshot(baseline, false))) == baseline_hash
	print("L2-hash_projection: baseline state_hash(false)=%d projected=%d (pre-L2 %d)" % [baseline_hash, projected_baseline, PRE_L2_BASELINE_HASH])
	var ok := copy_ok and projected == PRE_L2_HASH and projected_colony == PRE_L2_COLONY_HASH and projected_baseline == PRE_L2_BASELINE_HASH
	print("L2-hash_projection: %s" % ("MATCH" if ok else "MISMATCH"))
	quit(0 if ok else 1)

## WorldState.state_hash()'s snapshot, copied (the method hashes it in place).
func _snapshot(w: WorldType, include_incidents: bool) -> Dictionary:
	w._needs_system.ensure_needs()
	w._ensure_held_tool()
	CombatSystemType.ensure_health(w._colonists, w._content)
	var snapshot := {
		"seed": w._seed,
		"tick": w._clock.tick,
		"tool_items": w._tool_store.items,
		"next_tool_item_id": w._tool_store.next_id,
		"tool_reservations": w._tool_store.reservations.snapshot(),
		"colonists": StateCodec._hash_colonists(w._colonists, w._reroutes),
		"jobs": w.get_jobs([], false),
		"scheduling": w._scheduler.snapshot(),
		"calendar_alerts_fired": w._calendar_alerts_fired,
		"tool_fetch_excluded": w._toils.get_fetch_tool_excluded(),
		"combat_blocked_targets": StateCodec._encode_combat_blocked_targets(w._combat_giver.get_blocked_targets()),
		"rescue_victim_assignments": StateCodec._encode_rescue_victim_assignments(w._rescue_giver.get_job_victims()),
		"approach_job_targets": StateCodec._encode_approach_job_targets(w._approach_giver.get_job_targets()),
	}
	if not w._area_orders.is_idle(): snapshot["area_orders"] = w._area_orders.encode()
	w._tile_grid.hash_into(snapshot)
	w._object_table.hash_into(snapshot)
	w._zone_table.hash_into(snapshot)
	w._item_table.hash_into(snapshot)
	w._progress_table.hash_into(snapshot)
	w._construction.hash_into(snapshot)
	w._farm.hash_into(snapshot)
	w._crafting.hash_into(snapshot)
	if include_incidents: snapshot["incidents"] = {"cooldown_until_day": w._incidents._cooldown_until_day, "last_processed_day": w._incidents._last_processed_day, "rng_seed": w._incidents._random.seed, "rng_state": w._incidents._random.state}
	return snapshot

## The pre-L2 shape of value (see the class doc); a tile off layer 0 is left as it is.
func _pre_l2(value: Variant) -> Variant:
	if value is Vector3i:
		var tile: Vector3i = value
		return Vector2i(tile.x, tile.y) if tile.z == 0 else tile
	if value is Dictionary:
		var dict: Dictionary = value
		var copy: Dictionary = {}
		for key: Variant in dict:
			if key is String and (key == "layer_count" or (key == "z" and dict.has("x") and dict.has("y"))):
				continue
			copy[_pre_l2(key)] = _pre_l2(dict[key])
		return copy
	if value is Array:
		var items: Array = []
		for item: Variant in value:
			items.append(_pre_l2(item))
		return items
	return value

# --- test_toils_dig_chop_regression.gd's scenario, verbatim ------------------------

func _build_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldType.TILE_ROCK)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	for x in range(0, 10):
		TestAccess.set_tile(world, x, 0, WorldType.TILE_SOIL)
		TestAccess.set_tile(world, x, 2, WorldType.TILE_SOIL)
	TestAccess.set_tile(world, 9, 0, WorldType.TILE_TREE)
	TestAccess.set_tile(world, 9, 2, WorldType.TILE_TREE)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "z": 0, "route": null, "work": null})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 2, "z": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 0)
	world.spawn_ground_tool_item("axe", 8, 0)
	world.spawn_ground_tool_item("pick", 0, 2)
	world.spawn_ground_tool_item("axe", 8, 2)
	return world

func _run_scenario(world: WorldType) -> void:
	Scenarios.command(world, "dig_1", "dig", {"x": 3, "y": 0, "z": 0, "priority": 2})
	Scenarios.command(world, "dig_2", "dig", {"x": 5, "y": 0, "z": 0, "priority": 2})
	world.tick()
	world.tick()
	Scenarios.command(world, "chop_1", "chop", {"x": 9, "y": 0, "z": 0, "priority": 1})
	Scenarios.command(world, "dig_3", "dig", {"x": 3, "y": 2, "z": 0, "priority": 2})
	world.tick()
	world.tick()
	world.tick()
	Scenarios.command(world, "chop_2", "chop", {"x": 9, "y": 2, "z": 0, "priority": 1})
	Scenarios.command(world, "dig_4", "dig", {"x": 7, "y": 0, "z": 0, "priority": 2})
