extends SceneTree

## Scene-free coverage for SaveManager's slot policy: autosave
## rotation (oldest-recorded-tick eviction, see save_manager.gd's header),
## manual-slot isolation from that rotation, and load_best()'s newest-first
## fallback past a corrupted candidate.

const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const ROTATION_DIR := "user://test-save-rotation"
const FALLBACK_DIR := "user://test-save-rotation-fallback"

var failed := false

const EPOCH_DIR := "user://test-save-rotation-epoch"

func _init() -> void:
	_cleanup_dir(ROTATION_DIR)
	_cleanup_dir(FALLBACK_DIR)
	_cleanup_dir(EPOCH_DIR)

	_check_rotation_and_manual_isolation()
	_check_load_best_skips_corrupted_newest_autosave()
	_check_new_game_epoch_outranks_old_autosave_after_restart()

	_cleanup_dir(ROTATION_DIR)
	_cleanup_dir(FALLBACK_DIR)
	_cleanup_dir(EPOCH_DIR)
	if failed:
		quit(1)
	else:
		print("test_save_rotation: PASS")
		quit()

func _world(seed_value: int) -> WorldStateType:
	return WorldStateType.new(seed_value)

## Advances tick by calling tick() the given number of times so each save in
## this test carries a strictly higher recorded tick than the last, matching
## how ticks behave in a real session.
func _advance(world: WorldStateType, ticks: int) -> void:
	for _i in ticks:
		world.tick()

## Four consecutive save_autosave() calls, with an interleaved save_manual()
## call after the 2nd, must: rotate the three autosave files by oldest
## recorded tick (1st save evicted by the 4th, leaving 2nd/3rd/4th on disk in
## their documented slots); and never let that rotation touch or evict the
## manual slot, which keeps whatever save_manual() last wrote.
func _check_rotation_and_manual_isolation() -> void:
	var manager := SaveManagerType.new(ROTATION_DIR)
	var world := _world(4001)

	var result_1 := manager.save_autosave(world) # tick 0 -> autosave-1
	_expect(result_1["ok"], "1st autosave must succeed")
	var tick_1 := world.get_tick()

	_advance(world, 1)
	var result_2 := manager.save_autosave(world) # -> autosave-2
	_expect(result_2["ok"], "2nd autosave must succeed")
	var tick_2 := world.get_tick()

	_advance(world, 1)
	var manual_world := _world(4002)
	_advance(manual_world, 5)
	var manual_result := manager.save_manual(manual_world)
	_expect(manual_result["ok"], "interleaved manual save must succeed")
	var manual_tick := manual_world.get_tick()

	var result_3 := manager.save_autosave(world) # -> autosave-3
	_expect(result_3["ok"], "3rd autosave must succeed")
	var tick_3 := world.get_tick()

	_advance(world, 1)
	var result_4 := manager.save_autosave(world) # oldest (tick_1) evicted -> autosave-1
	_expect(result_4["ok"], "4th autosave must succeed")
	var tick_4 := world.get_tick()

	_expect(tick_1 < tick_2 and tick_2 < tick_3 and tick_3 < tick_4,
		"test fixture must produce four strictly increasing ticks")

	var slot_1 := SaveIOType.read(ROTATION_DIR.path_join("autosave-1.json"))
	var slot_2 := SaveIOType.read(ROTATION_DIR.path_join("autosave-2.json"))
	var slot_3 := SaveIOType.read(ROTATION_DIR.path_join("autosave-3.json"))
	_expect(slot_1["ok"] and int(slot_1["state"]["tick"]) == tick_4,
		"autosave-1 must hold the 4th save after the 1st is evicted")
	_expect(slot_2["ok"] and int(slot_2["state"]["tick"]) == tick_2,
		"autosave-2 must still hold the 2nd save")
	_expect(slot_3["ok"] and int(slot_3["state"]["tick"]) == tick_3,
		"autosave-3 must still hold the 3rd save")

	var dir := DirAccess.open(ROTATION_DIR)
	var autosave_files: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("autosave-"):
			autosave_files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	autosave_files.sort()
	_expect(autosave_files == ["autosave-1.json", "autosave-2.json", "autosave-3.json"],
		"exactly three autosave files must exist on disk, no more, no fewer: %s" % [autosave_files])

	var manual_slot := SaveIOType.read(ROTATION_DIR.path_join("manual.json"))
	_expect(manual_slot["ok"] and int(manual_slot["state"]["tick"]) == manual_tick,
		"manual slot must still hold the interleaved manual save, untouched by autosave rotation")

## Writes two autosaves (autosave-1 older, autosave-2 newer), then corrupts
## autosave-2's body so SaveIO.read() rejects it on integrity while its
## recorded tick stays readable (mirrors a real bit flip, not a truncation).
## load_best() must still recognize autosave-2 as the newest candidate by its
## recorded tick, skip it with the typed reason SaveIO gives, and fall back
## to the next-newest valid save (autosave-1).
func _check_load_best_skips_corrupted_newest_autosave() -> void:
	var manager := SaveManagerType.new(FALLBACK_DIR)
	var older := _world(5001)
	var older_result := manager.save_autosave(older) # -> autosave-1
	_expect(older_result["ok"], "older autosave must succeed")
	var older_tick := older.get_tick()

	var newer := _world(5002)
	_advance(newer, 3)
	var newer_result := manager.save_autosave(newer) # -> autosave-2
	_expect(newer_result["ok"], "newer autosave must succeed")
	var newer_tick := newer.get_tick()
	_expect(older_tick < newer_tick, "test fixture must make autosave-2 the newer save")

	var newest_path := FALLBACK_DIR.path_join("autosave-2.json")
	_corrupt_content_version(newest_path)

	var corrupted_read := SaveIOType.read(newest_path)
	_expect(not corrupted_read["ok"] and corrupted_read["code"] == "integrity_mismatch",
		"corrupted newest autosave must fail SaveIO.read() with a typed integrity reason")

	var load_result := manager.load_best()
	_expect(load_result["ok"], "load_best() must fall back to the next-newest valid save")
	_expect(load_result.get("slot") == "autosave-1", "fallback must land on autosave-1")
	_expect(int(load_result.get("tick", -1)) == older_tick, "fallback save must be the older, valid one")

	var skipped: Array = load_result.get("skipped", [])
	_expect(skipped.size() == 1, "exactly one candidate must be reported skipped")
	if skipped.size() == 1:
		var entry: Dictionary = skipped[0]
		_expect(entry["file"] == newest_path, "skipped entry must name the corrupted file")
		_expect(entry["slot"] == "autosave-2", "skipped entry must name its slot")
		_expect(entry["code"] == "integrity_mismatch", "skipped entry must carry SaveIO's typed reason code")
		_expect(String(entry["message"]).length() > 0, "skipped entry must carry a human-readable reason")

## Flips a byte inside the contentVersion string (never read by
## _peek_tick()) so the stored integrity hash no longer matches the body,
## without disturbing the recorded tick used to order candidates.
func _corrupt_content_version(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var marker := "\"contentVersion\":\""
	var start := text.find(marker)
	_expect(start >= 0, "test fixture save must contain contentVersion")
	if start < 0:
		return
	var char_index := start + marker.length()
	var bytes := text.to_utf8_buffer()
	bytes[char_index] = bytes[char_index] + 1
	var output := FileAccess.open(path, FileAccess.WRITE)
	output.store_buffer(bytes)
	output.close()

## Ranking candidates by raw tick alone would let an old game's high-tick
## autosave outrank a brand-new game's low-tick manual save. Proves
## SaveManager's (epoch, tick) ordering end to end, including a
## simulated process restart (a fresh SaveManager instance with no in-memory
## state, exactly like SaveManagerType.new(dir) after boot.gd re-launches).
func _check_new_game_epoch_outranks_old_autosave_after_restart() -> void:
	var manager := SaveManagerType.new(EPOCH_DIR)
	var old_world := _world(6001)
	_advance(old_world, 1000)
	var old_result := manager.save_autosave(old_world) # epoch defaults to 0
	_expect(old_result["ok"], "old game's high-tick autosave must succeed")

	var new_epoch := manager.next_epoch()
	_expect(new_epoch > 0, "next_epoch() must mint an epoch strictly above the old game's recorded epoch")

	var new_world := _world(6002)
	_advance(new_world, 10)
	var new_result := manager.save_manual(new_world, new_epoch)
	_expect(new_result["ok"], "new game's low-tick manual save must succeed")

	var restarted := SaveManagerType.new(EPOCH_DIR)
	var load_result := restarted.load_best()
	_expect(load_result["ok"], "restart must find a valid save")
	_expect(load_result.get("slot") == SaveManagerType.MANUAL_SLOT,
		"restart must resume the new game's manual save, not the old game's higher-tick autosave: %s" % load_result)
	_expect(int(load_result.get("epoch", -1)) == new_epoch,
		"restart must report the new game's epoch, got %s" % load_result)
	_expect(int(load_result.get("tick", -1)) == new_world.get_tick(),
		"restart must report the new game's own (lower) tick, got %s" % load_result)

	var good = restarted.get_last_known_good()
	_expect(good != null and int(good["epoch"]) == new_epoch and int(good["tick"]) == new_world.get_tick(),
		"last-known-good after restart must reflect the new game, not the old higher-tick one: %s" % [good])

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true

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
