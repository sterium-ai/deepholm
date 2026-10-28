extends SceneTree

## The save format after the R14 reset (ADR 049), now at schema v2 (A5, ADR 053:
## terminal jobs leave the save). Proves a save written before the reset is
## rejected with a clear message, the committed v1 fixture migrates to exactly the
## v2 fixture, a v1 save holding terminal jobs loads without them and with the
## original state_hash, the committed v2 fixture loads and re-encodes unchanged, a
## fresh save -> load keeps the exact state_hash, the migration chain and the
## content-rename hook still work, and the current-schema round trips that used to
## live beside the old migration chain.
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")
const SchedulingCodecType = preload("res://scripts/core/persistence/scheduling_codec.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

## Written on main at 63d3d5f (before R14) by docs/orca/handoffs/R14-write-save.gd:
## envelope "deepholm-save-v1", schemaVersion 27.
const PRE_RELEASE_FIXTURE := "res://scripts/tests/fixtures/pre_release_save_v27.json"
## The same session written after R14: envelope "deepholm-save", schemaVersion 1.
## The starting point of the v1 -> v2 migration test.
const V1_FIXTURE := "res://scripts/tests/fixtures/save_schema_v1_fixture.json"
## The same session written by this build (docs/orca/handoffs/A5-write-save.gd): schemaVersion 2.
const V2_FIXTURE := "res://scripts/tests/fixtures/save_schema_v2_fixture.json"
const V1_TERMINAL_JOBS_DIR := "user://test-save-migration-v1-terminal-jobs"
const PRE_RELEASE_SLOT_DIR := "user://test-save-migration-pre-release-slots"
const FRESH_SAVE_PATH := "user://test-save-migration-fresh.json"
const V2_RESAVE_PATH := "user://test-save-migration-v2-resave.json"
const MALFORMED_FIXTURE_DIR := "user://test-save-migration-malformed-fixture"
## Proves SaveIO.read() rejects a save whose contentVersion has no
## registered rename with the new typed content_version_mismatch code, never
## silently proceeding with a stale content id.
const CONTENT_MISMATCH_FIXTURE_DIR := "user://test-save-migration-content-mismatch-fixture"
## Proves the content-rename hook actually runs (not just the mismatch
## check itself) by registering a rename for this exact source contentVersion
## and asserting the loaded state's renamed content id took effect.
const CONTENT_RENAME_FIXTURE_DIR := "user://test-save-migration-content-rename-fixture"
const RENAME_SOURCE_CONTENT_VERSION := "test-legacy-content-version"
## Regression: calendar window ids come from content/calendar.json,
## whose own schema (game/content/schemas/calendar.schema.json) allows any
## non-empty string, not the stricter ^[a-z0-9_-]+$ pattern _matches_id_pattern()
## enforces for entity/job/item ids. A valid window id like "SpringSow" must
## still round-trip through SaveIO.read(), not just an in-memory _validate_state call.
const CALENDAR_ID_FIXTURE_DIR := "user://test-save-migration-calendar-id-fixture"

var _failed := false

func _init() -> void:
	_check_pre_release_save_is_rejected()
	_check_v1_fixture_migrates_to_v2_fixture()
	_check_v1_terminal_jobs_leave_the_save()
	_check_v2_fixture_loads_and_reencodes_unchanged()
	_check_fresh_save_load_keeps_state_hash()
	_check_empty_migration_chain()
	_check_malformed_current_state_rejected_through_save_io()
	_check_dig_find_rng_continuation_survives_save_load_round_trip()
	_check_multi_tile_object_round_trips_through_save_load()
	_check_object_without_orientation_field_loads_unchanged()
	_check_object_with_empty_orientation_field_loads_unchanged()
	_check_state_without_construction_sites_field_loads_unchanged()
	_check_construction_site_round_trips_through_save_load()
	_check_incident_scheduler_continuation_survives_save_load_round_trip()
	_check_content_version_mismatch_without_rename_fails()
	_check_content_version_mismatch_resolved_by_rename_loads()
	_check_calendar_alerts_fired_accepts_valid_non_lowercase_id()
	_check_non_default_labour_table_survives_save_load_round_trip()
	_check_mine_job_and_stone_item_survive_save_load_round_trip()
	_check_non_default_faction_and_health_survive_save_load_round_trip()
	_check_critical_interrupt_survives_save_load_round_trip()
	_check_unrecognized_version()
	if _failed:
		quit(1)
		return
	print("test_save_migration: PASS")
	quit()

## Acceptance (R14): a save written on main before the reset fails to load with a
## clear "unsupported pre-release save" message, both through SaveIO.read() and
## through SaveManager.load_best(), which reports it as a skipped slot.
func _check_pre_release_save_is_rejected() -> void:
	var result := SaveIOType.read(PRE_RELEASE_FIXTURE)
	_expect(not result["ok"], "a pre-release save must not load: %s" % result)
	_expect(String(result.get("code", "")) == "unsupported_pre_release_save",
		"a pre-release save must fail with unsupported_pre_release_save, got %s" % result)
	_expect(String(result.get("message", "")).begins_with("unsupported pre-release save"),
		"the rejection message must say 'unsupported pre-release save', got '%s'" % result.get("message", ""))
	_expect(not result.has("state"), "a rejected pre-release save must never hand back its state")

	_cleanup_dir(PRE_RELEASE_SLOT_DIR)
	var manager := SaveManagerType.new(PRE_RELEASE_SLOT_DIR)
	var bytes := FileAccess.get_file_as_bytes(PRE_RELEASE_FIXTURE)
	var file := FileAccess.open(PRE_RELEASE_SLOT_DIR + "/manual.json", FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var best := manager.load_best()
	_expect(not best["ok"], "load_best() must not load a pre-release manual slot: %s" % best)
	var skipped: Array = best.get("skipped", [])
	_expect(skipped.size() == 1 and String(skipped[0]["code"]) == "unsupported_pre_release_save",
		"load_best() must report the pre-release slot as skipped with unsupported_pre_release_save: %s" % [skipped])
	_cleanup_dir(PRE_RELEASE_SLOT_DIR)

## Acceptance (A5): the committed v1 fixture loads through SaveIO.read() migrated to
## v2, and equals the v2 fixture (the same session written by this build) exactly.
func _check_v1_fixture_migrates_to_v2_fixture() -> void:
	var result := SaveIOType.read(V1_FIXTURE)
	_expect(result["ok"], "the v1 fixture must load through SaveIO.read(): %s" % result)
	var v2 := SaveIOType.read(V2_FIXTURE)
	_expect(v2["ok"], "the v2 fixture must load through SaveIO.read(): %s" % v2)
	if not result["ok"] or not v2["ok"]:
		return
	_expect(int(result["state"]["schemaVersion"]) == 2, "the v1 fixture must load as schemaVersion 2")
	_expect(JSON.stringify(result["state"]) == JSON.stringify(v2["state"]),
		"the migrated v1 fixture must equal the v2 fixture exactly")

## Acceptance (A5): a v1 save that still lists terminal jobs (as every v1 save of a
## played session did) loads through SaveIO.read() as v2 without them, decodes to the
## state_hash of the world that wrote it, and keeps ticking in step with it.
func _check_v1_terminal_jobs_leave_the_save() -> void:
	var world := WorldStateType.new(1414, 3, 24, 24)
	var issued := 0
	for x in range(24):
		for type in ["chop", "dig"]:
			if issued < 6 and world.apply({"actor": "player", "command_id": "a5_%d_%s" % [x, type], "tick": world.get_tick(),
					"type": type, "payload": {"x": x, "y": 0, "priority": 1}}).get("ok", false):
				issued += 1
				break
	var first_job := String(world.get_jobs()[0]["id"])
	_expect(world.apply({"actor": "player", "command_id": "a5_cancel", "tick": world.get_tick(), "type": "cancel_job",
		"payload": {"job_id": first_job}}).get("ok", false), "cancelling the first order must apply")
	for _i in 60:
		world.tick()
	var v1_state := StateCodecType.encode(world)
	var live_jobs: Array = v1_state["jobs"]
	v1_state["jobs"] = SchedulingCodecType._encode_jobs(TestAccess.scheduler(world).queue.get_jobs())
	v1_state["schemaVersion"] = 1
	_expect(v1_state["jobs"].size() > live_jobs.size(), "the v1 state must really list terminal jobs for this to prove anything")
	var path := _write_state_fixture(V1_TERMINAL_JOBS_DIR, v1_state)
	var result := SaveIOType.read(path)
	_cleanup_dir(V1_TERMINAL_JOBS_DIR)
	_expect(result["ok"], "a v1 save with terminal jobs must load: %s" % result)
	if not result["ok"]:
		return
	_expect(int(result["state"]["schemaVersion"]) == 2, "it must load as schemaVersion 2")
	_expect(JSON.stringify(result["state"]["jobs"]) == JSON.stringify(live_jobs),
		"the migrated jobs must be exactly the live jobs this build saves")
	var loaded := StateCodecType.decode(result["state"])
	_expect(loaded.state_hash() == world.state_hash(), "the migrated save must decode to the original state_hash")
	for _i in 40:
		world.tick()
		loaded.tick()
	_expect(loaded.state_hash() == world.state_hash(), "the migrated world must keep ticking in step with the original")

## The committed v2 fixture loads through SaveIO.read(), decodes, and re-encodes to
## exactly the state it was read from (the persisted shape is the codec's shape), and
## the decoded world keeps its state_hash through a second write/read.
func _check_v2_fixture_loads_and_reencodes_unchanged() -> void:
	var result := SaveIOType.read(V2_FIXTURE)
	_expect(result["ok"], "the v2 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(int(state["schemaVersion"]) == 2 and StateCodecType.SCHEMA_VERSION == 2,
		"the v2 fixture and this build must both be schemaVersion 2")
	var world := StateCodecType.decode(state)
	var reencoded := StateCodecType.encode(world)
	_expect(JSON.stringify(reencoded) == JSON.stringify(state),
		"decode() -> encode() of the v2 fixture must reproduce its state exactly")
	_remove(V2_RESAVE_PATH)
	var write_result := SaveIOType.write_atomic(V2_RESAVE_PATH, reencoded)
	_expect(write_result["ok"], "the re-encoded v2 fixture must save: %s" % write_result)
	var reread := SaveIOType.read(V2_RESAVE_PATH)
	_expect(reread["ok"], "the re-saved v2 fixture must load: %s" % reread)
	if reread["ok"]:
		_expect(StateCodecType.decode(reread["state"]).state_hash() == world.state_hash(),
			"a second write/read of the v2 fixture must keep the decoded state_hash")
	_remove(V2_RESAVE_PATH)

## Acceptance (R14): fresh save -> load -> identical state_hash, through real files,
## and the loaded world keeps ticking in step with the original.
func _check_fresh_save_load_keeps_state_hash() -> void:
	var world := WorldStateType.new(141414, 3, 24, 24)
	for _i in 40:
		world.tick()
	_remove(FRESH_SAVE_PATH)
	var write_result := SaveIOType.write_atomic(FRESH_SAVE_PATH, StateCodecType.encode(world))
	_expect(write_result["ok"], "a fresh save must write: %s" % write_result)
	var read_result := SaveIOType.read(FRESH_SAVE_PATH)
	_expect(read_result["ok"], "a fresh save must read back: %s" % read_result)
	_remove(FRESH_SAVE_PATH)
	if not read_result["ok"]:
		return
	var loaded := StateCodecType.decode(read_result["state"])
	_expect(loaded.state_hash() == world.state_hash(), "fresh save -> load must keep the exact state_hash")
	for _i in 40:
		world.tick()
		loaded.tick()
	_expect(loaded.state_hash() == world.state_hash(), "a loaded world must keep ticking in step with the original")

## Migrating to the same version is a no-op, and any version below 1 has no
## migration (saves before the R14 reset are refused, never migrated).
func _check_empty_migration_chain() -> void:
	var state := {"schemaVersion": 1}
	var same := SaveMigrationsType.migrate(state, 1, 1)
	_expect(same["ok"] and same["state"] == state, "migrate(v1 -> v1) must return the state unchanged: %s" % same)
	var below := SaveMigrationsType.migrate({"schemaVersion": 0}, 0, StateCodecType.SCHEMA_VERSION)
	_expect(not below["ok"] and below["code"] == "no_migration_available",
		"a version below 1 must report no_migration_available: %s" % below)

## A malformed current-schema save is rejected through SaveIO.read() with the right
## code, never fabricated into a valid-looking state or crashing on a cast. These are
## the cases the pre-reset wall-rename path guarded (missing or wrong-typed
## containers, non-Dictionary entries, non-String kinds and contentVersion), now
## checked on the plain current-content path.
func _check_malformed_current_state_rejected_through_save_io() -> void:
	var site := {"id": "site_1", "kind": 123, "origin": {"x": 0, "y": 0}, "orientation": "",
		"requiredMaterials": [], "heldMaterials": [], "progress": 0, "buildTicks": 1, "maxBuilders": 1, "builderIds": []}
	var job := {"id": "job_1", "kind": "dig", "status": "queued", "priority": 1, "target": {"x": 0, "y": 0},
		"reason": "", "remedy": "", "blockingJobId": "", "itemId": "", "cell": null, "retryAt": 0, "backoffTicks": 0,
		"buildKind": 123}
	var cases := [
		["missing objects", "objects", null, "no_migration_available"],
		["missing jobs", "jobs", null, "no_migration_available"],
		["missing contentVersion", "contentVersion", null, "no_migration_available"],
		["non-String contentVersion", "contentVersion", 10, "schema_error"],
		["non-Array objects", "objects", "not-an-array", "schema_error"],
		["non-Dictionary objects entry", "objects", ["not-a-dictionary"], "schema_error"],
		["non-Array constructionSites", "constructionSites", "not-an-array", "schema_error"],
		["non-Dictionary constructionSites entry", "constructionSites", ["not-a-dictionary"], "schema_error"],
		["non-Array jobs", "jobs", "not-an-array", "schema_error"],
		["non-Dictionary jobs entry", "jobs", ["not-a-dictionary"], "schema_error"],
		["non-String objects[].kind", "objects", [{"target": {"x": 0, "y": 0}, "kind": 123, "factionId": "colony"}], "schema_error"],
		["non-String constructionSites[].kind", "constructionSites", [site], "schema_error"],
		["retired jobs[].buildKind field", "jobs", [job], "schema_error"],
	]
	for case in cases:
		var state := _minimal_current_schema_state(StateCodecType.content_version(), "wood")
		if case[2] == null:
			state.erase(case[1])
		else:
			state[case[1]] = case[2]
		var path := _write_state_fixture(MALFORMED_FIXTURE_DIR, state)
		var result := SaveIOType.read(path)
		_expect(not result["ok"] and result["code"] == case[3],
			"a save with %s must be rejected with %s: %s" % [case[0], case[3], result])
	_cleanup_dir(MALFORMED_FIXTURE_DIR)

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## Proves the dig-find RNG's own continuation --
## a non-freshly-seeded stream (distinct seed and state from a brand-new
## WorldState's own construction-time values) -- survives a real
## WorldState.to_save_state() -> StateCodec.encode() -> from_save_state() ->
## StateCodec.decode() round trip exactly, the same way
## _check_incident_scheduler_continuation_survives_save_load_round_trip()
## proves it for the incident scheduler's own RNG, and that state_hash()
## actually changes when this stream's position differs (so a diverged find
## sequence can never hide behind an unchanged hash).
func _check_dig_find_rng_continuation_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260925, 10)
	var hash_before_draw := world.state_hash()
	TestAccess.item_table(world).dig_find_random.seed = 777
	TestAccess.item_table(world).dig_find_random.randi() # advances .state away from its fresh-seed default
	var expected_rng_seed: int = TestAccess.item_table(world).dig_find_random.seed
	var expected_rng_state: int = TestAccess.item_table(world).dig_find_random.state
	_expect(world.state_hash() != hash_before_draw,
		"advancing the dig-find RNG stream must change state_hash(), or a diverged find sequence could hide behind an unchanged hash")

	var saved := world.to_save_state()
	_expect(int(saved["digFindRng"]["seed"]) == expected_rng_seed and int(saved["digFindRng"]["state"]) == expected_rng_state,
		"to_save_state() must encode the live dig-find RNG stream exactly")
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(TestAccess.item_table(restored).dig_find_random.seed == expected_rng_seed and TestAccess.item_table(restored).dig_find_random.state == expected_rng_state,
		"a save/load round trip must preserve the dig-find RNG's own stream exactly")
	_expect(restored.state_hash() == world.state_hash(),
		"a save/load round trip must reproduce the exact same state_hash() once the dig-find RNG is restored")

## Content/objects.json's "test_footprint_crate" (footprint [2, 1],
## rotatable) placed "vertical" occupies (5, 5) and (5, 6). Proves the full
## WorldState.to_save_state() -> StateCodec.encode() -> from_save_state() ->
## StateCodec.decode() stack persists it as exactly one record naming its
## origin tile and orientation (ADR 039), not one per occupied
## tile, and that a real WorldState reconstructed from that one record
## re-occupies both footprint tiles with a byte-identical state_hash().
func _check_multi_tile_object_round_trips_through_save_load() -> void:
	var world := WorldStateType.new(20260926, 10)
	var origin := Vector2i(5, 5)
	TestAccess.set_tile(world, origin.x, origin.y, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, origin.x, origin.y + 1, WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).set_object(origin.x, origin.y, "test_footprint_crate", "colony", "vertical")
	_expect(world.get_object(origin.x, origin.y) == "test_footprint_crate" and world.get_object(origin.x, origin.y + 1) == "test_footprint_crate",
		"setup must occupy both footprint tiles before the round trip")
	var before_hash := world.state_hash()

	var saved := world.to_save_state()
	var footprint_records: Array = []
	for entry in (saved["objects"] as Array):
		if String((entry as Dictionary).get("kind", "")) == "test_footprint_crate":
			footprint_records.append(entry)
	_expect(footprint_records.size() == 1, "a multi-tile object must persist as exactly one record, not one per occupied tile")
	if footprint_records.size() == 1:
		var record: Dictionary = footprint_records[0]
		_expect(record["target"] == {"x": origin.x, "y": origin.y}, "the persisted record must name the object's origin tile")
		_expect(String(record.get("orientation", "")) == "vertical", "the persisted record must carry the placed orientation")

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.get_object(origin.x, origin.y) == "test_footprint_crate" and restored.get_object(origin.x, origin.y + 1) == "test_footprint_crate",
		"a restored multi-tile object must occupy both footprint tiles")
	_expect(restored.state_hash() == before_hash, "a multi-tile object must round-trip with an unchanged state_hash()")

## Game-state.schema.json's "orientation" field is optional --
## absent means footprint [1,1]/no rotation, so a current-schema-version save
## written before rotation existed (no object entry ever named it) must still
## validate and decode unchanged, exactly like objects[].health/
## route.rerouting's own optional-field precedent.
func _check_object_without_orientation_field_loads_unchanged() -> void:
	var state := _minimal_current_schema_state("test-content", "wood")
	state["objects"] = [{"target": {"x": 0, "y": 0}, "kind": "wall", "factionId": "colony"}]
	var validation := TestAccess.save_validate_state(state)
	_expect(validation["ok"], "a current-schema object entry with no orientation field must validate: %s" % validation.get("message", ""))
	if not validation["ok"]:
		return
	var world := StateCodecType.decode(state)
	_expect(world.get_object(0, 0) == "wall", "decode() must restore an object entry with no orientation field")
	_expect(world.get_object_faction_id(0, 0) == "colony", "decode() must restore its factionId")

## An explicit orientation: "" must validate and
## decode identically to the field's absence -- "" is the same "no rotation"
## default, not a third distinct value, so SaveIO._valid_object() and the
## schema must both accept it (previously only "horizontal"/"vertical" were
## legal, rejecting a save that wrote "" explicitly).
func _check_object_with_empty_orientation_field_loads_unchanged() -> void:
	var state := _minimal_current_schema_state("test-content", "wood")
	state["objects"] = [{"target": {"x": 0, "y": 0}, "kind": "wall", "factionId": "colony", "orientation": ""}]
	var validation := TestAccess.save_validate_state(state)
	_expect(validation["ok"], "a current-schema object entry with orientation '' must validate: %s" % validation.get("message", ""))
	if not validation["ok"]:
		return
	var world := StateCodecType.decode(state)
	_expect(world.get_object(0, 0) == "wall", "decode() must restore an object entry with orientation ''")
	_expect(world.get_object_faction_id(0, 0) == "colony", "decode() must restore its factionId")

## Game-state.schema.json's "constructionSites" top-level field is
## optional -- absent means no active construction sites, so a current-schema-
## version save written before construction sites existed (no such field at all) must still
## validate and decode unchanged, exactly like objects[].orientation's own
## optional-field precedent above.
func _check_state_without_construction_sites_field_loads_unchanged() -> void:
	var state := _minimal_current_schema_state("test-content", "wood")
	_expect(not state.has("constructionSites"), "the minimal fixture must genuinely omit constructionSites for this to be a real proof")
	var validation := TestAccess.save_validate_state(state)
	_expect(validation["ok"], "a current-schema state with no constructionSites field must validate: %s" % validation.get("message", ""))
	if not validation["ok"]:
		return
	var world := StateCodecType.decode(state)
	_expect(world.get_construction_sites().is_empty(), "decode() must restore no construction sites when the field is absent")

## A save mid-construction (partial materials, partial progress, one
## builder) round-trips with hash equality -- exercised end-to-end in
## test_construction_site.gd; this proves the persisted wire shape itself
## (one record under "constructionSites", not one per footprint tile, mirroring
## "objects"'s own origin-record convention) survives SaveIO's own schema
## validator, not only StateCodec's internal round trip.
func _check_construction_site_round_trips_through_save_load() -> void:
	var world := WorldStateType.new(20260927, 10)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.object_table(world).objects.clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "route": null, "work": null, "carrying": null})
	var apply_result := world.apply({"actor": "test", "command_id": "wb", "tick": world.get_tick(), "type": "build",
		"payload": {"kind": "workbench", "x": 5, "y": 5}})
	_expect(bool(apply_result.get("ok", false)), "the setup build command must be accepted: %s" % apply_result)
	_expect(not world.get_construction_site(5, 5).is_empty(), "setup must create a real site before the round trip")
	var before_hash := world.state_hash()
	var saved := world.to_save_state()
	var sites: Array = saved.get("constructionSites", [])
	_expect(sites.size() == 1, "a single active site must persist as exactly one constructionSites record")
	var validation := TestAccess.save_validate_state(saved)
	_expect(validation["ok"], "a state with an in-progress construction site must validate: %s" % validation.get("message", ""))
	var restored := WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == before_hash, "a construction-site save/load round trip must preserve state_hash() exactly")
	_expect(not restored.get_construction_site(5, 5).is_empty(), "the restored world must still show the site")

## Proves the incident scheduler's own continuation state -- non-empty
## per-incident cooldowns, a non-zero last-processed day, and a
## non-freshly-seeded RNG stream (distinct seed and state from a brand-new
## IncidentScheduler's own construction-time values) -- survives a real
## WorldState.to_save_state() -> StateCodec.encode() -> from_save_state() ->
## StateCodec.decode() round trip exactly, covering
## _encode_incident_scheduler()/decode()'s restore end to end, the same way
## _check_non_default_labour_table_survives_save_load_round_trip() proves it
## for the labour table.
func _check_incident_scheduler_continuation_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260924, 10)
	TestAccess.set_incident_cooldown_until_day(world, {"wildlife_wander": 12, "trader_visit": 19})
	TestAccess.set_incident_last_processed_day(world, 7)
	TestAccess.incident_random(world).seed = 555
	TestAccess.incident_random(world).randi() # advances .state away from its fresh-seed default
	var expected_cooldowns: Dictionary = TestAccess.incident_cooldown_until_day(world).duplicate()
	var expected_day: int = TestAccess.incident_last_processed_day(world)
	var expected_rng_seed: int = TestAccess.incident_random(world).seed
	var expected_rng_state: int = TestAccess.incident_random(world).state

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(TestAccess.incident_cooldown_until_day(restored) == expected_cooldowns,
		"a save/load round trip must preserve the incident scheduler's cooldownUntilDay exactly")
	_expect(TestAccess.incident_last_processed_day(restored) == expected_day,
		"a save/load round trip must preserve the incident scheduler's lastProcessedDay exactly")
	_expect(TestAccess.incident_random(restored).seed == expected_rng_seed and TestAccess.incident_random(restored).state == expected_rng_state,
		"a save/load round trip must preserve the incident scheduler's own RNG stream exactly")

## SaveIO.read() must reject a save whose stored contentVersion does not
## match the content bundle currently on disk (StateCodec.content_version())
## with the new typed content_version_mismatch code when no content-rename
## entry resolves it -- never silently proceeding with a stale content id.
func _check_content_version_mismatch_without_rename_fails() -> void:
	var current_content_version := StateCodecType.content_version()
	var state := _minimal_current_schema_state("definitely-not-" + current_content_version, "wood")
	var path := _write_state_fixture(CONTENT_MISMATCH_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_expect(not result["ok"] and result["code"] == "content_version_mismatch",
		"a save whose contentVersion has no registered rename must fail with content_version_mismatch: %s" % result)
	_cleanup_dir(CONTENT_MISMATCH_FIXTURE_DIR)

## Proves the content-rename hook actually runs, not just the mismatch
## check itself: a save's contentVersion resolved by a registered rename must
## load successfully, and the rename's own id remap (here, an item's "kind")
## must have taken effect in the state SaveIO.read() hands back.
func _check_content_version_mismatch_resolved_by_rename_loads() -> void:
	var current_content_version := StateCodecType.content_version()
	_expect(current_content_version != RENAME_SOURCE_CONTENT_VERSION,
		"test fixture content version must actually differ from the current registry version")
	var state := _minimal_current_schema_state(RENAME_SOURCE_CONTENT_VERSION, "legacy_wood")
	var path := _write_state_fixture(CONTENT_RENAME_FIXTURE_DIR, state)
	SaveMigrationsType.register_content_rename(RENAME_SOURCE_CONTENT_VERSION, Callable(self, "_rename_legacy_wood_item_kind"))
	var result := SaveIOType.read(path)
	SaveMigrationsType.unregister_content_rename(RENAME_SOURCE_CONTENT_VERSION)
	_expect(result["ok"], "a save whose contentVersion is resolved by a registered rename must load: %s" % result)
	_cleanup_dir(CONTENT_RENAME_FIXTURE_DIR)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	_expect(String(loaded_state["contentVersion"]) == current_content_version,
		"a resolved save must report the current content version after load")
	var loaded_kind := String((loaded_state["items"]["list"] as Array)[0]["kind"])
	_expect(loaded_kind == "wood",
		"the registered rename must actually remap the renamed content id, not just flip the version: got '%s'" % loaded_kind)

## Regression: a real calendar window id is allowed to be any
## non-empty string (game/content/schemas/calendar.schema.json), so a window
## named "SpringSow" -- mixed case, no underscore/hyphen -- must still round
## trip through a full save file, not just satisfy an in-memory Dictionary
## check. SaveIO's stricter ^[a-z0-9_-]+$ id pattern once rejected
## it, so a colony that legitimately fired that window's alert could never
## save again.
func _check_calendar_alerts_fired_accepts_valid_non_lowercase_id() -> void:
	var window_id := "SpringSow"
	var state := _minimal_current_schema_state(StateCodecType.content_version(), "wood")
	state["calendarAlerts"] = {"fired": [window_id]}
	var validation := TestAccess.save_validate_state(state)
	_expect(validation["ok"], "a valid non-lowercase calendar id must pass _validate_state: %s" % validation.get("message", ""))

	var path := _write_state_fixture(CALENDAR_ID_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(CALENDAR_ID_FIXTURE_DIR)
	_expect(result["ok"], "a save with a valid non-lowercase calendar id must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	_expect((loaded_state["calendarAlerts"]["fired"] as Array) == [window_id],
		"SaveIO.read() must preserve the calendar id '%s' exactly, got %s" % [window_id, loaded_state["calendarAlerts"]])

## Proves a non-default labourTable (set via set_labour, per world_state.gd's
## _apply_set_labour_command()) survives a real save/load round trip exactly,
## not just a migration-shaped dictionary: WorldState.to_save_state() goes
## through StateCodec.encode() and from_save_state() through
## StateCodec.decode(), the same pair every other in-flight state check in
## test_save_determinism.gd exercises, covering _encode_labour_table()/
## _decode_labour_table() end to end.
func _check_non_default_labour_table_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260919, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() >= 2, "expected at least two colonists for this check")
	if colonists.size() < 2:
		return
	var target_id: String = colonists[0]["id"]
	var other_id: String = colonists[1]["id"]
	var result := world.apply({
		"actor": "player", "command_id": "labour_round_trip", "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": target_id, "kind": "mine", "level": 0},
	})
	_expect(result.get("ok", false), "set_labour setup must be accepted: %s" % result)
	var second := world.apply({
		"actor": "player", "command_id": "labour_round_trip_2", "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": target_id, "kind": "cook", "level": 4},
	})
	_expect(second.get("ok", false), "second set_labour setup must be accepted: %s" % second)

	var expected_target_table: Dictionary = {}
	for colonist in world.get_colonists():
		if colonist["id"] == target_id:
			expected_target_table = (colonist["labourTable"] as Dictionary).duplicate()
	_expect(expected_target_table == {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 4},
		"setup must leave the target colonist's table non-default in exactly the expected shape")

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	for colonist in restored.get_colonists():
		if colonist["id"] == target_id:
			_expect(colonist["labourTable"] == expected_target_table,
				"a save/load round trip must preserve the targeted colonist's complete labourTable exactly")
		elif colonist["id"] == other_id:
			_expect(colonist["labourTable"] == TestAccess.default_labour_table(world),
				"a save/load round trip must not disturb a different colonist's untouched labourTable")

## The "mine" job kind and "stone" item kind are new content (rock
## outcrops mined like trees); this proves a real WorldState
## save/load round trip carries an active mine job and a ground stone item
## through unchanged, mirroring the labour-table check above rather than the
## v13-v21 migration-backfill checks (there is nothing to backfill:
## an old save with no mine job or stone item must keep loading unchanged).
## colonist_0 is given a held "pick" tool up front so the submitted mine job
## reaches "active" status on its very first tick instead of first spending a
## tick on the fetch_tool toil (jobs.json's "mine" entry needs_tool: "pick").
func _check_mine_job_and_stone_item_survive_save_load_round_trip() -> void:
	var world := WorldStateType.new(353001, 10)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_ROCK)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "hands": [], "labourTable": TestAccess.default_labour_table(world)})
	world.set_tool_item_held(world.spawn_ground_tool_item("pick", 0, 0), "colonist_0")

	var submit := world.apply({
		"actor": "test", "command_id": "mine_1", "tick": world.get_tick(),
		"type": "mine", "payload": {"x": 1, "y": 0, "priority": 1},
	})
	_expect(submit.get("ok", false), "mine submission must be accepted: %s" % submit)
	var job_id := String(submit.get("job_id", ""))

	var active := false
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job["id"]) == job_id and String(job["status"]) == "active":
				active = true
		if active:
			break
	_expect(active, "setup: the mine job must reach active status before saving")
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_ROCK, "setup: the target tile must still be rock, not yet mined")

	TestAccess.item_table(world).spawn_item("stone", 5, 5)
	var stone_item_id := ""
	for item in world.get_items():
		if String(item["kind"]) == "stone":
			stone_item_id = String(item["id"])
	_expect(not stone_item_id.is_empty(), "setup: a ground stone item must exist before saving")

	var saved := world.to_save_state()
	var validation := TestAccess.save_validate_state(saved)
	_expect(validation.get("ok", false),
		"a save state holding an active mine job and a ground stone item must pass SaveIO._validate_state(), got %s" % validation.get("message", ""))

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_job := {}
	for job in restored.get_jobs():
		if String(job["id"]) == job_id:
			restored_job = job
	_expect(String(restored_job.get("kind", "")) == "mine" and String(restored_job.get("status", "")) == "active",
		"a save/load round trip must preserve the active mine job's kind and status exactly, got %s" % restored_job)
	_expect(restored_job.get("target") == Vector2i(1, 0),
		"a save/load round trip must preserve the mine job's target tile exactly")

	var restored_stone := {}
	for item in restored.get_items():
		if String(item["id"]) == stone_item_id:
			restored_stone = item
	_expect(restored_stone.get("kind") == "stone" and int(restored_stone.get("x", -1)) == 5
			and int(restored_stone.get("y", -1)) == 5 and int(restored_stone.get("count", -1)) == 1,
		"a save/load round trip must preserve the ground stone item exactly, got %s" % restored_stone)

## Every live-spawned colonist starts at the default "colony"/full-health values,
## so a round trip of defaults would pass even if StateCodec silently reset
## factionId/health on every encode/decode. This check proves the opposite: a real,
## non-default factionId and two non-default health snapshots (an injured one
## with a non-default maxHp, and a dead one) survive an actual
## WorldState.to_save_state() -> StateCodec.encode()/SaveIO round trip ->
## WorldState.from_save_state() -> StateCodec.decode() cycle exactly, proving
## _encode_entities()/_decode_entities() genuinely carry these fields rather
## than only ever writing/reading their defaults.
func _check_non_default_faction_and_health_survive_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260920, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() >= 3, "expected at least three colonists for this check")
	if colonists.size() < 3:
		return
	var faction_id: String = colonists[0]["id"]
	var injured_id: String = colonists[1]["id"]
	var dead_id: String = colonists[2]["id"]

	var expected_faction := "raiders"
	var expected_injured_health := {"hp": 40, "maxHp": 150, "dead": false}
	var expected_dead_health := {"hp": 0, "maxHp": 80, "dead": true}
	for i in TestAccess.colonists(world).size():
		var id := String(TestAccess.colonists(world)[i]["id"])
		if id == faction_id:
			TestAccess.colonists(world)[i]["factionId"] = expected_faction
		elif id == injured_id:
			TestAccess.colonists(world)[i]["health"] = expected_injured_health.duplicate()
		elif id == dead_id:
			TestAccess.colonists(world)[i]["health"] = expected_dead_health.duplicate()

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	for colonist in restored.get_colonists():
		var id := String(colonist["id"])
		if id == faction_id:
			_expect(String(colonist.get("factionId", "")) == expected_faction,
				"a save/load round trip must preserve a non-default factionId exactly")
		elif id == injured_id:
			_expect(colonist.get("health") == expected_injured_health,
				"a save/load round trip must preserve a non-default, non-full health snapshot exactly")
		elif id == dead_id:
			_expect(colonist.get("health") == expected_dead_health,
				"a save/load round trip must preserve a dead:true health snapshot exactly")

## Proves NeedGiver's own colonist_id -> job_id
## association and the interrupted dig job's requeued scheduler entry both
## survive a real save/load round trip -- not just a migration-shaped
## dictionary, WorldState.to_save_state()/from_save_state() end to end -- so
## a need job that was already committed at save time can still resolve_job()
## its way back to the paused colonist and resume the original work job with
## its tile progress kept, not lost or restarted, after loading.
func _check_critical_interrupt_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(130001, 10)
	for other in TestAccess.need_definitions(world).keys():
		if other != "food":
			TestAccess.need_definitions(world)[other]["rate_per_day"] = 0
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({
		"id": "colonist_0", "kind": "colonist", "x": 9, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": TestAccess.default_labour_table(world),
		"route": null, "work": null, "hands": [],
	})
	TestAccess.set_tile(world, 10, 0, WorldStateType.TILE_SOIL)
	# Far enough that the eat_food search/walk spans several ticks, so the
	# save captures a genuinely still-pending need job rather than one that
	# already committed, walked, ate, and resumed the dig job all within the
	# same tick the critical interrupt fired.
	TestAccess.item_table(world).ground_berries["9_20"] = 1
	world.spawn_ground_tool_item("pick", 9, 0)

	var dig_result := world.apply({
		"actor": "test", "command_id": "dig_1", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": 10, "y": 0, "priority": 1},
	})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 30:
		world.tick()
		for colonist in world.get_colonists():
			if colonist["id"] == "colonist_0" and colonist.get("work") != null:
				work_started = true
		if work_started:
			break
	_expect(work_started, "colonist_0 must start the dig job's work toil within the tick budget")
	if not work_started:
		return
	for _i in 5:
		world.tick()

	for i in TestAccess.colonists(world).size():
		if String(TestAccess.colonists(world)[i]["id"]) == "colonist_0":
			TestAccess.colonists(world)[i]["needs"]["food"] = 5
	world.tick()

	# Tick until the eat_food job is actually committed (not just searching),
	# so the save captures NeedGiver's own persisted association in use, not
	# just an in-flight search, which is deliberately not persisted.
	var committed := false
	for _i in 60:
		if not TestAccess.need_giver(world).get_pending_assignments().is_empty():
			committed = true
			break
		world.tick()
	_expect(committed, "colonist_0's need search must commit to a job within the tick budget")
	if not committed:
		return

	var saved := world.to_save_state()
	_expect((saved["needJobAssignments"] as Array).size() == 1,
		"a save taken while a need job is pending must persist NeedGiver's own colonist->job association")
	_expect((saved["pausedJobs"] as Array).size() == 1,
		"a save taken mid-interrupt must persist the paused dig job")
	# A suspended job's own progress persists via
	# job-id-keyed "suspendedWorkProgress", not the shared tile-keyed
	# "workProgress" array -- world_state.gd's own _suspend_work_progress()
	# moves it out the instant the interrupt clears colonist.work.
	var suspended_work_progress: Array = saved["suspendedWorkProgress"]
	var dig_target_progress := int(suspended_work_progress[0]["ticksRemaining"]) if suspended_work_progress.size() > 0 else -1
	_expect(dig_target_progress > 0 and dig_target_progress < int(TestAccess.work_ticks(world)["dig"]),
		"a save taken mid-interrupt must persist the dig job's own partial progress")

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	# from_save_state() constructs a brand new WorldState, which reloads
	# _need_definitions fresh from content/needs.json: the water/rest rate=0
	# override above is test-only scaffolding (content, not persisted runtime
	# state), so it must be re-applied here too, or water/rest resume normal
	# decay post-load and trigger their own unrelated interrupts, diverging
	# this check from what it actually means to test.
	for other in TestAccess.need_definitions(restored).keys():
		if other != "food":
			TestAccess.need_definitions(restored)[other]["rate_per_day"] = 0
	_expect(TestAccess.need_giver(restored).get_pending_assignments() == TestAccess.need_giver(world).get_pending_assignments(),
		"loading must restore NeedGiver's own colonist->job association exactly")

	var eat_completed := false
	var dig_completed := false
	var colonist_0_ever_fed := false
	for _i in 300:
		restored.tick()
		for job in restored.get_jobs():
			if String(job["kind"]) == "eat_food" and job["status"] == "completed":
				eat_completed = true
			if String(job["id"]) == dig_job_id and job["status"] == "completed":
				dig_completed = true
		for colonist in restored.get_colonists():
			if colonist["id"] == "colonist_0" and int(colonist.get("needs", {}).get("food", 0)) == 100:
				colonist_0_ever_fed = true
		if eat_completed and dig_completed:
			break

	_expect(eat_completed, "the eat_food job must complete after loading")
	_expect(dig_completed, "the interrupted dig job must resume (not be lost) and complete after loading")
	_expect(restored.get_tile(10, 0) == WorldStateType.TILE_TRENCH,
		"the resumed dig job must still finish transforming its target tile after loading")
	_expect(colonist_0_ever_fed,
		"the interrupted colonist's own food need must be restored at some point after loading")

func _check_unrecognized_version() -> void:
	var result := SaveMigrationsType.migrate({"schemaVersion": 0}, 0, 3)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"unrecognized older versions must report no_migration_available")

## Writes state to a user:// file as a real save envelope, hashed exactly the
## way SaveIO.write_atomic() hashes its own body (JSON.stringify, then a round
## trip through JSON.parse_string, since that is the form SaveIO.read()
## re-hashes on the way back in) -- write_atomic() itself can't be reused here
## since it validates against the current content version, rejecting a
## deliberately mismatched-content-version fixture outright.
func _write_state_fixture(dir_path: String, state: Dictionary) -> String:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(dir_path):
		dir.make_dir_recursive(dir_path)
	var path := dir_path + "/fixture.json"
	var body := JSON.stringify(state)
	var round_tripped = JSON.parse_string(body)
	var hash := TestAccess.save_sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope := {"format": SaveIOType.FORMAT, "integrity": hash, "state": state}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.close()
	return path

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

## A minimal but fully current-schema-shaped state (empty entities/jobs/etc.,
## _validate_state has no minimum-count requirement on any collection) with
## one ground item, used by the content-version mismatch checks above: only
## contentVersion and the one item's "kind" vary between calls.
func _minimal_current_schema_state(content_version: String, item_kind: String) -> Dictionary:
	return {
		"schemaVersion": SaveIOType.SCHEMA_VERSION, "contentVersion": content_version, "seed": 1, "tick": 0,
		"epoch": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"], "generatorVersion": 1},
		"entities": [],
		"inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {}, "activatedEntries": {},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 2, "list": [{"id": "item_1", "x": 0, "y": 0, "kind": item_kind, "count": 1, "factionId": "colony"}]},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [], "toolItems": {"nextId": 1, "list": []},
		"toolReservations": {}, "needJobAssignments": [], "calendarAlerts": {"fired": []},
		"toolFetchExcluded": [],
		"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1, "state": 0}},
	}

## Test-registered content-rename remap (see
## _check_content_version_mismatch_resolved_by_rename_loads()): renames every
## "legacy_wood" item kind to "wood", proving the hook remaps content ids
## inside the loaded state rather than just relabeling contentVersion.
func _rename_legacy_wood_item_kind(state: Dictionary) -> Dictionary:
	var remapped: Dictionary = state.duplicate(true)
	var items: Dictionary = (remapped["items"] as Dictionary).duplicate(true)
	var list: Array = []
	for entry in (items["list"] as Array):
		var updated: Dictionary = (entry as Dictionary).duplicate(true)
		if String(updated["kind"]) == "legacy_wood":
			updated["kind"] = "wood"
		list.append(updated)
	items["list"] = list
	remapped["items"] = items
	return remapped

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true
