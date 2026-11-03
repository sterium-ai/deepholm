extends SceneTree

## F5b evidence for test_world_state_determinism.gd's PRE_INCIDENT_BASELINE_HASH move. F5b
## (ADR 065) appends `heal` to the worker's labours, and world seeding draws every colonist's
## starting skills from one RNG in labour order (world_seeding.gd _seed_skills()), so each
## colonist's levels are drawn differently. This script builds the test's world (seed 20260922,
## 10 colonists, incidents off), re-draws the skills from the same RNG over the pre-F5b labour
## list (heal removed), runs the test's 650 ticks and drops `heal` from the colony-only snapshot:
## it must give the pre-F5b literal 2778412269 back, so the only change is the extra draw and the
## heal entries. heal enables no job, so its level and table entry steer nothing.
## Run from the repo root (exit 0 on a match):
##   godot --headless --path game --script ../docs/orca/handoffs/F5b-baseline_projection.gd

const WorldType = preload("res://scripts/core/world_state.gd")
const WorldSeedingType = preload("res://scripts/core/worldgen/world_seeding.gd")
const SkillsType = preload("res://scripts/core/actors/components/skills.gd")
const CombatSystemType = preload("res://scripts/core/actors/combat_system.gd")

const SEED := 20260922
const PRE_F5B_HASH := 2778412269
const TICKS := 650

func _init() -> void:
	var current := WorldType.new(SEED, 10, WorldType.MAP_WIDTH, WorldType.MAP_HEIGHT, false)
	var world := WorldType.new(SEED, 10, WorldType.MAP_WIDTH, WorldType.MAP_HEIGHT, false)
	var tunables: Dictionary = world._content.get_entry("actors", "colonist").get("tunables", {})
	var labours: Array = (tunables.get("worker", {}) as Dictionary).get("labours", []).duplicate()
	labours.erase("heal")
	var random := RandomNumberGenerator.new()
	random.seed = (SEED + WorldType.PLACEMENT_SEED_SALT) ^ WorldSeedingType.SKILL_SEED_SALT
	var rules := SkillsType.rules(world._content)
	for colonist in world._colonists:
		var heal: Dictionary = colonist["skills"]["heal"]
		var skills := SkillsType.seed_levels(rules, labours, random)
		skills["heal"] = heal
		colonist["skills"] = skills
	for _i in TICKS:
		current.tick()
		world.tick()
	var copy_ok := hash(JSON.stringify(_snapshot(current, false))) == current.state_hash(false)
	var projected := hash(JSON.stringify(_pre_f5b(_snapshot(world, false))))
	print("F5b-baseline_projection: state_hash(false)=%d copy_matches=%s" % [current.state_hash(false), copy_ok])
	print("F5b-baseline_projection: projected=%d (pre-F5b %d)" % [projected, PRE_F5B_HASH])
	var ok := copy_ok and projected == PRE_F5B_HASH
	print("F5b-baseline_projection: %s" % ("MATCH" if ok else "MISMATCH"))
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

## The pre-F5b shape of value: `heal` dropped from every map keyed by labour (one that also has `cook`).
func _pre_f5b(value: Variant) -> Variant:
	if value is Dictionary:
		var dict: Dictionary = value
		var copy: Dictionary = {}
		for key: Variant in dict:
			if key is String and key == "heal" and dict.has("cook"):
				continue
			copy[key] = _pre_f5b(dict[key])
		return copy
	if value is Array:
		var items: Array = []
		for item: Variant in value:
			items.append(_pre_f5b(item))
		return items
	return value
