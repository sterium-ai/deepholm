extends SceneTree

## Content packs in saves (A13b, ADR 010 amendment 2, schema v3): a save records the packs it
## was made on (ContentRegistry.packs(), ordered {id, version}) and loads only on exactly those.
## Proves 1) a save made on a test pack loads on the same packs through SaveManager and the
## viewer's load path, ticking in step with the world that wrote it; 2) the same save fails
## with a typed content_packs_mismatch when the pack is missing, has another version, is
## listed in another order, or the session loads a pack the save was not made on; 3) SaveIO's
## tile, job and need whitelists come from the session registry (a pack tile is valid only on
## that pack); 4) a replay recorded on a pack replays on the same packs and is refused, typed,
## on the others; 5) malformed contentPacks are schema errors and the v2 -> v3 step adds an
## empty list.
##
## godot --headless --path game --script res://scripts/tests/test_save_content_packs.gd

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")
const SaveWiringType = preload("res://scripts/viewer/save_wiring.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const BootType = preload("res://scripts/boot.gd")

const BASE := ContentRegistryType.DEFAULT_CONTENT_DIR
const SCHEMAS := ContentRegistryType.DEFAULT_SCHEMA_DIR
const PACK_A_DIR := "user://test-save-content-packs-a"
const PACK_A2_DIR := "user://test-save-content-packs-a-v2"
const PACK_B_DIR := "user://test-save-content-packs-b"
const SAVE_DIR := "user://test-save-content-packs-slots"
const WRITE_PATH := "user://test-save-content-packs-write.json"
const SEED := 4141
## A tile only pack_a defines, placed in the world so the save cannot validate without it.
const PACK_TILE := "pack_moss"
const PACK_TILE_ENTRY := {"id": PACK_TILE, "passable": true, "move_cost": 2, "diggable": false,
	"display": {"label": "tile.soil"}, "move_ticks_per_tile": 4}
const PACK_TILE_AT := Vector2i(1, 1)

var _failed := false
var _base: ContentRegistryType
var _pack_a: ContentRegistryType
var _pack_a_v2: ContentRegistryType
var _pack_a_b: ContentRegistryType
var _pack_b_a: ContentRegistryType

func _init() -> void:
	_write_pack(PACK_A_DIR, "pack_a", "1", {
		"items": {"items": [{"id": "pack_hammer", "kind": "tool"}]},
		"tiles": {"tiles": [PACK_TILE_ENTRY]},
	})
	_write_pack(PACK_A2_DIR, "pack_a", "2", {
		"items": {"items": [{"id": "pack_hammer", "kind": "tool"}]},
		"tiles": {"tiles": [PACK_TILE_ENTRY]},
	})
	_write_pack(PACK_B_DIR, "pack_b", "1", {"items": {"items": [{"id": "pack_gem", "kind": "material"}]}})
	_base = ContentRegistryType.new()
	_pack_a = _registry([PACK_A_DIR])
	_pack_a_v2 = _registry([PACK_A2_DIR])
	_pack_a_b = _registry([PACK_A_DIR, PACK_B_DIR])
	_pack_b_a = _registry([PACK_B_DIR, PACK_A_DIR])
	for registry: ContentRegistryType in [_pack_a, _pack_a_v2, _pack_a_b, _pack_b_a]:
		_expect(registry.is_valid(), "every test registry must load: %s" % registry.get_error())
	if not _failed:
		_check_base_save_records_no_packs()
		_check_pack_save_loads_on_same_packs()
		_check_pack_save_refused_on_other_packs()
		_check_pack_order_is_part_of_the_match()
		_check_whitelists_come_from_the_registry()
		_check_replay_on_pack()
		_check_malformed_content_packs()
		_check_v2_to_v3_step()
	for dir: String in [PACK_A_DIR, PACK_A2_DIR, PACK_B_DIR, SAVE_DIR]:
		_cleanup_dir(dir)
	_remove(WRITE_PATH)
	if _failed:
		quit(1)
		return
	print("test_save_content_packs: PASS")
	quit()

func _fail(message: String) -> void:
	_failed = true
	push_error(message)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The real bundle with no packs records an empty list and loads on the base session.
func _check_base_save_records_no_packs() -> void:
	var world := WorldStateType.new(SEED, 3, 24, 24)
	var state := StateCodecType.encode(world)
	_expect(state.get("contentPacks") == [], "a base-bundle save must record contentPacks [], got %s" % [state.get("contentPacks")])
	_remove(WRITE_PATH)
	var written := SaveIOType.write_atomic(WRITE_PATH, state)
	_expect(written["ok"], "a base-bundle save must write: %s" % written)
	var read := SaveIOType.read(WRITE_PATH, _base)
	_expect(read["ok"], "a base-bundle save must load on the base session: %s" % read)
	var on_pack := SaveIOType.read(WRITE_PATH, _pack_a)
	_expect(not on_pack["ok"] and on_pack.get("code") == "content_packs_mismatch" and on_pack.get("reason") == "unexpected",
		"a base-bundle save must be refused on a session that loads a pack: %s" % on_pack)
	_remove(WRITE_PATH)

## Acceptance: a save made with a test pack loads on the same packs, through SaveManager and
## the viewer's SaveWiring.load_best(), decodes on the session registry and ticks in step.
func _check_pack_save_loads_on_same_packs() -> void:
	var world := _pack_world(_pack_a)
	var manager := SaveManagerType.new(SAVE_DIR, _pack_a)
	var saved := manager.save_manual(world, 1)
	_expect(saved["ok"], "a save made on pack_a must write: %s" % saved)
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SAVE_DIR + "/manual.json"))
	_expect(raw["state"]["contentPacks"] == [{"id": "pack_a", "version": "1"}],
		"the save must record pack_a version 1, got %s" % [raw["state"]["contentPacks"]])
	var loaded := SaveWiringType.load_best(SaveManagerType.new(SAVE_DIR, _pack_a))
	_expect(loaded.get("ok", false), "the pack_a save must load on pack_a: %s" % loaded)
	if not loaded.get("ok", false):
		return
	var restored: WorldStateType = loaded["world"]
	_expect(StateCodecType.content_of(restored) == _pack_a, "the viewer's load path must decode on the session registry")
	_expect(restored.get_tile(PACK_TILE_AT.x, PACK_TILE_AT.y) == PACK_TILE, "the pack tile must survive the round trip")
	_expect(restored.is_tool_kind("pack_hammer"), "the restored world must see the pack's item")
	_expect(restored.state_hash() == world.state_hash(), "save -> load on the same packs must keep the state_hash")
	for _i in 30:
		world.tick()
		restored.tick()
	_expect(restored.state_hash() == world.state_hash(), "the restored pack world must tick in step with the original")
	_cleanup_dir(SAVE_DIR)

## Acceptance: the same save fails typed when its pack is missing or has another version, and
## SaveManager reports the slot as skipped with that code rather than loading it.
func _check_pack_save_refused_on_other_packs() -> void:
	var path := _write_pack_save(_pack_a)
	var cases := {"missing": _base, "version": _pack_a_v2, "unexpected": _pack_a_b}
	for reason: String in cases:
		var result := SaveIOType.read(path, cases[reason])
		_expect(not result["ok"] and result.get("code") == "content_packs_mismatch" and result.get("reason") == reason,
			"a pack_a save on the '%s' session must fail content_packs_mismatch/%s: %s" % [reason, reason, result])
		_expect(not result.has("state"), "a refused save must never hand back its state (%s)" % reason)
	var best := SaveManagerType.new(SAVE_DIR, _base).load_best()
	var skipped: Array = best.get("skipped", [])
	_expect(not best["ok"] and skipped.size() == 1 and skipped[0]["code"] == "content_packs_mismatch",
		"load_best() on the base session must skip the pack_a save as content_packs_mismatch: %s" % best)
	# The viewer names the reason when it resumes from an older slot past this one.
	var message := SaveWiringType.resume_message(TextTableType.new(),
		{"slot": "autosave-1", "tick": 5, "skipped": [{"slot": "manual", "code": "content_packs_mismatch"}]})
	_expect(message.contains("different content packs") and not message.contains("save.reason."),
		"the resume message must explain a content_packs_mismatch skip in words: '%s'" % message)
	_cleanup_dir(SAVE_DIR)

## Acceptance: packs listed in another order are another content bundle (a later root wins
## overrides), so a save on [pack_a, pack_b] is refused on [pack_b, pack_a].
func _check_pack_order_is_part_of_the_match() -> void:
	var path := _write_pack_save(_pack_a_b)
	var same := SaveIOType.read(path, _pack_a_b)
	_expect(same["ok"], "a [pack_a, pack_b] save must load on [pack_a, pack_b]: %s" % same)
	var swapped := SaveIOType.read(path, _pack_b_a)
	_expect(not swapped["ok"] and swapped.get("code") == "content_packs_mismatch" and swapped.get("reason") == "order",
		"a [pack_a, pack_b] save must fail content_packs_mismatch/order on [pack_b, pack_a]: %s" % swapped)
	_cleanup_dir(SAVE_DIR)

## SaveIO keeps no tile, job or need literals: its whitelists are the registry's ids, so the
## pack's tile is valid on the pack and a schema error on the base bundle.
func _check_whitelists_come_from_the_registry() -> void:
	var base_rules := SaveIOType.content_rules(_base)
	_expect(base_rules["tiles"] == _ids(_base, "tiles", "id"), "the tile whitelist must be tiles.json's ids")
	_expect(base_rules["jobKinds"] == _ids(_base, "jobs", "kind"), "the job whitelist must be jobs.json's kinds")
	_expect(base_rules["needs"] == _ids(_base, "needs", "kind"), "the need whitelist must be needs.json's kinds")
	_expect(int(base_rules["maxWorldSize"]) == int(_base.document("mapgen")["max_world_size"]), "the size cap must be mapgen.json's")
	_expect(SaveIOType.content_rules(_pack_a)["tiles"].has(PACK_TILE), "the pack's tile must be in the pack session's whitelist")
	var state := StateCodecType.encode(_pack_world(_pack_a))
	_expect(SaveIOType._validate_state(state, _pack_a)["ok"], "a pack save must validate on its pack")
	_remove(WRITE_PATH)
	var on_base := SaveIOType.write_atomic(WRITE_PATH, state, Callable(), Callable(), _base)
	_expect(not on_base["ok"] and on_base.get("code") == "schema_error" and String(on_base.get("message")) == "invalid map tile",
		"writing a pack-tile save against the base whitelist must be a schema_error on the tile: %s" % on_base)
	_expect(not FileAccess.file_exists(WRITE_PATH), "a refused write must leave no file")

## Acceptance: a replay recorded on a pack replays on the same packs (also after the file
## round trip) and is refused typed on a missing pack, another version or another order.
func _check_replay_on_pack() -> void:
	var world: WorldStateType = BootType.build_default_world(SEED, null, _pack_a_b)
	var recorder := CommandRecorderType.new()
	# The New Game world runs incidents, so the replay re-enables them (the recorder's default).
	recorder.start(world, 5)
	var dug := 0
	for x in world.get_map_width():
		if dug < 3 and world.apply({"actor": "player", "command_id": "a13b_dig_%d" % x, "tick": world.get_tick(),
				"type": "dig", "payload": {"x": x, "y": 2, "priority": 1}}).get("ok", false):
			dug += 1
	for _i in 40:
		world.tick()
		recorder.observe_tick(world)
	var recording: ReplayLogType = recorder.stop()
	_expect(recording.initial_state["contentPacks"] == [{"id": "pack_a", "version": "1"}, {"id": "pack_b", "version": "1"}],
		"the recording's start state must list its packs: %s" % [recording.initial_state["contentPacks"]])
	var replayed := recording.replay(Callable(), _pack_a_b)
	_expect(replayed.get("ok", false) and int(replayed.get("checkpoints", 0)) > 1,
		"a replay recorded on [pack_a, pack_b] must replay on the same packs: %s" % replayed)
	var file_text := JSON.stringify(recording.to_dict())
	var from_file := ReplayLogType.from_dict(JSON.parse_string(file_text), _pack_a_b)
	_expect(from_file.get("ok", false), "the recording must survive its file round trip on its packs: %s" % from_file)
	if from_file.get("ok", false):
		var again: Dictionary = (from_file["log"] as ReplayLogType).replay(Callable(), _pack_a_b)
		_expect(again.get("ok", false), "the file round trip must replay on the same packs: %s" % again)
	var cases := {"missing": _pack_a, "order": _pack_b_a}
	for reason: String in cases:
		var refused := recording.replay(Callable(), cases[reason])
		_expect(refused.get("code") == "content_packs_mismatch" and refused.get("reason") == reason,
			"the replay must be refused content_packs_mismatch/%s: %s" % [reason, refused])
	var on_v2 := _registry([PACK_A2_DIR, PACK_B_DIR])
	var version := recording.replay(Callable(), on_v2)
	_expect(version.get("code") == "content_packs_mismatch" and version.get("reason") == "version",
		"the replay must be refused content_packs_mismatch/version on pack_a v2: %s" % version)

## A malformed contentPacks is a schema error (a missing field is the migration error), never
## a silent default.
func _check_malformed_content_packs() -> void:
	var good := StateCodecType.encode(WorldStateType.new(SEED, 3, 16, 16))
	var cases := {
		"not an array": [{"x": 1}, "schema_error"],
		"entry not an object": [["pack_a"], "schema_error"],
		"entry without version": [[{"id": "pack_a"}], "no_migration_available"],
		"entry with an extra field": [[{"id": "pack_a", "version": "1", "url": "x"}], "schema_error"],
		"empty id": [[{"id": "", "version": "1"}], "schema_error"],
		"non-String version": [[{"id": "pack_a", "version": 1}], "schema_error"],
		"duplicate id": [[{"id": "pack_a", "version": "1"}, {"id": "pack_a", "version": "1"}], "schema_error"],
	}
	for label: String in cases:
		var bad := good.duplicate(true)
		bad["contentPacks"] = cases[label][0]
		var result := SaveIOType._validate_state(bad, _base)
		_expect(not result["ok"] and result.get("code") == cases[label][1],
			"contentPacks %s must fail %s: %s" % [label, cases[label][1], result])
	var missing := good.duplicate(true)
	missing.erase("contentPacks")
	var missing_result := SaveIOType._validate_state(missing, _base)
	_expect(not missing_result["ok"] and missing_result.get("code") == "no_migration_available",
		"a v3 state without contentPacks must fail no_migration_available: %s" % missing_result)

## v2 -> v3 adds an empty list right after contentVersion and refuses a v2 state that already
## claims one; the input is never mutated.
func _check_v2_to_v3_step() -> void:
	var v3 := StateCodecType.encode(WorldStateType.new(SEED, 3, 16, 16))
	var v2 := v3.duplicate(true)
	v2.erase("contentPacks")
	v2["schemaVersion"] = 2
	var before := JSON.stringify(v2)
	var migrated := SaveMigrationsType.migrate(v2, 2, 3)
	_expect(migrated["ok"], "a v2 state must migrate to v3: %s" % migrated)
	_expect(JSON.stringify(v2) == before, "the migration must not mutate its argument")
	if migrated["ok"]:
		var keys: Array = (migrated["state"] as Dictionary).keys()
		_expect(keys.find("contentPacks") == keys.find("contentVersion") + 1, "contentPacks must follow contentVersion")
		_expect(JSON.stringify(migrated["state"]) == JSON.stringify(v3), "the migrated state must equal this build's v3 encode")
	v2["contentPacks"] = []
	var refused := SaveMigrationsType.migrate(v2, 2, 3)
	_expect(not refused["ok"] and refused.get("code") == "schema_error", "a v2 state that already has contentPacks must be refused: %s" % refused)

# --- helpers ----------------------------------------------------------------

## A small world on registry with the pack tile placed, ticked a little so jobs and needs move.
func _pack_world(registry: ContentRegistryType) -> WorldStateType:
	var world := WorldStateType.new(SEED, 3, 24, 24, false, registry)
	TestAccess.set_tile(world, PACK_TILE_AT.x, PACK_TILE_AT.y, PACK_TILE)
	for _i in 20:
		world.tick()
	return world

## The manual slot of SAVE_DIR, written by a SaveManager on registry from a world on it.
func _write_pack_save(registry: ContentRegistryType) -> String:
	_cleanup_dir(SAVE_DIR)
	var saved := SaveManagerType.new(SAVE_DIR, registry).save_manual(_pack_world(registry), 1)
	_expect(saved["ok"], "the pack save must write: %s" % saved)
	return SAVE_DIR + "/manual.json"

func _registry(pack_dirs: Array) -> ContentRegistryType:
	var dirs: Array[String] = []
	dirs.assign(pack_dirs)
	return ContentRegistryType.new(BASE, SCHEMAS, dirs)

func _ids(registry: ContentRegistryType, kind: String, field: String) -> Array[String]:
	var ids: Array[String] = []
	for entry: Dictionary in registry.list(kind):
		ids.append(String(entry[field]))
	return ids

func _write_pack(dir: String, pack_id: String, version: String, files: Dictionary) -> void:
	_cleanup_dir(dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_write_json(dir + "/pack.json", {"id": pack_id, "version": version})
	for kind: String in files:
		_write_json("%s/%s.json" % [dir, kind], files[kind])

func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

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
