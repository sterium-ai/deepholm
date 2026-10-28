extends SceneTree

## A0 benchmark: save/load size and time vs. actor count on a 256x256 map
## (seed 42). Each world gets one till order per colonist and runs TICKS
## ticks first, so the save carries live jobs, in-flight route searches and
## an event log, not just a fresh map. Times StateCodec.encode(),
## SaveIO.write_atomic(), SaveIO.read() (parse + integrity) and
## StateCodec.decode(), prints the file size, and checks that the decoded
## world's state_hash() equals the original's.
## Also measures whether a dropped WorldState is freed: the Object count
## before building worlds and after releasing them (RefCounted cycles through
## bound Callables would keep them alive).
##
## Evidence, not a gate: always exits 0. Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_save_load.gd

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const SEED := 42
const SIZE := 256
const ACTOR_COUNTS := [10, 100, 1000]
const TICKS := 10
const SAVE_PATH := "user://bench-save-load.json"

func _init() -> void:
	print(BenchCommon.header("bench_save_load"))
	for actor_count in ACTOR_COUNTS:
		_run(actor_count)
	_leak_check()
	print("bench_save_load: done")
	quit(0)

func _run(actor_count: int) -> void:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, actor_count)
	BenchCommon.submit_till_orders(world, actor_count)
	for i in TICKS:
		world.tick()
	_remove_save()
	var t := Time.get_ticks_usec()
	var state := StateCodecType.encode(world)
	var encode_usec := Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	var write_result = SaveIOType.write_atomic(SAVE_PATH, state)
	var write_usec := Time.get_ticks_usec() - t
	var file_bytes := 0
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		file_bytes = file.get_length()
		file.close()
	t = Time.get_ticks_usec()
	var read_result := SaveIOType.read(SAVE_PATH)
	var read_usec := Time.get_ticks_usec() - t
	var decode_usec := 0
	var hash_match := false
	if read_result.get("ok", false):
		t = Time.get_ticks_usec()
		var loaded := StateCodecType.decode(read_result["state"])
		decode_usec = Time.get_ticks_usec() - t
		hash_match = loaded != null and loaded.state_hash() == world.state_hash()
	# Pieces of write_atomic() timed on their own: schema validation and one
	# JSON.stringify of the state (write_atomic stringifies three times and
	# parses once, then read-back-verifies the file).
	t = Time.get_ticks_usec()
	TestAccess.save_validate_state(state)
	var validate_usec := Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	JSON.stringify(state)
	var stringify_usec := Time.get_ticks_usec() - t
	print("bench_save_load: actors=%d write_atomic parts: _validate_state=%.1fms one JSON.stringify=%.1fms" % [
		TestAccess.colonists(world).size(), validate_usec / 1000.0, stringify_usec / 1000.0])
	var sections := _section_sizes(state)
	print("bench_save_load: actors=%d ticks=%d file=%.1fKB encode=%.1fms write_atomic=%.1fms read+integrity=%.1fms decode=%.1fms total_save=%.1fms total_load=%.1fms read_ok=%s hash_match=%s write=%s" % [
		TestAccess.colonists(world).size(), TICKS, file_bytes / 1024.0, encode_usec / 1000.0, write_usec / 1000.0,
		read_usec / 1000.0, decode_usec / 1000.0, (encode_usec + write_usec) / 1000.0,
		(read_usec + decode_usec) / 1000.0, read_result.get("ok", false), hash_match, _short(write_result)])
	print("bench_save_load: actors=%d largest sections (JSON chars): %s" % [TestAccess.colonists(world).size(), sections])
	BenchCommon.row("bench_save_load", "round trip", "actors=%d" % TestAccess.colonists(world).size(), {
		"ticks": TICKS, "file KB": "%.1f" % (file_bytes / 1024.0), "encode ms": "%.1f" % (encode_usec / 1000.0),
		"write_atomic ms": "%.1f" % (write_usec / 1000.0), "_validate_state ms": "%.1f" % (validate_usec / 1000.0),
		"one JSON.stringify ms": "%.1f" % (stringify_usec / 1000.0), "read+integrity ms": "%.1f" % (read_usec / 1000.0),
		"decode ms": "%.1f" % (decode_usec / 1000.0), "total save ms": "%.1f" % ((encode_usec + write_usec) / 1000.0),
		"total load ms": "%.1f" % ((read_usec + decode_usec) / 1000.0), "read ok": read_result.get("ok", false),
		"hash match": hash_match, "write": _short(write_result), "largest sections": sections})
	_remove_save()

## The five largest top-level (and one level down) sections of the encoded state.
func _section_sizes(state: Dictionary) -> String:
	var sizes: Array = []
	for key in state:
		var value = state[key]
		if value is Dictionary:
			for sub in value:
				sizes.append([JSON.stringify(value[sub]).length(), "%s.%s" % [key, sub]])
		else:
			sizes.append([JSON.stringify(value).length(), String(key)])
	sizes.sort_custom(func(a, b): return a[0] > b[0])
	var parts: Array[String] = []
	for i in mini(5, sizes.size()):
		parts.append("%s=%.1fKB" % [sizes[i][1], sizes[i][0] / 1024.0])
	return ", ".join(parts)

func _leak_check() -> void:
	# One warm-up world first, so one-time script/resource loads are not counted.
	var warm := WorldStateType.new(SEED, 10, 64, 64)
	warm.tick()
	warm = null
	var before := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	for i in 3:
		var world := WorldStateType.new(SEED + i, 10, 64, 64)
		world.tick()
		world = null
	var after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	print("bench_save_load: leak check: Object count before=%d after building+dropping 3 WorldStates=%d (delta=%d)" % [
		before, after, after - before])
	BenchCommon.row("bench_save_load", "leak check", "build and drop 3 WorldStates (64x64)", {
		"objects before": before, "objects after": after, "delta": after - before})

func _short(value) -> String:
	if value is Dictionary:
		return "ok" if value.get("ok", false) else String(value.get("error", value))
	return str(value)

func _remove_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
