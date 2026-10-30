extends SceneTree

## A0 benchmark: save/load size and time vs. actor count on a 256x256 map
## (seed 42). Each world gets one till order per colonist and runs TICKS
## ticks first, so the save carries live jobs, in-flight route searches and
## an event log, not just a fresh map. Times StateCodec.encode(),
## SaveIO.write_atomic(), SaveIO.read() (parse + integrity) and
## StateCodec.decode(), prints the file size, and checks that the decoded
## world's state_hash() equals the original's.
## A7: also times the threaded save, SaveIO.begin_write(): "main-thread save" is
## encode() plus begin_write() (SaveWire.pack() and the one JSON.stringify), the
## part the game waits for; "worker" is the wait() for hash, write, read-back
## and rename on the SaveWrite thread.
## Also measures whether a dropped WorldState is freed: the Object count
## before building worlds and after releasing them, once dropped as they are
## and once after WorldState.dispose() (RefCounted cycles through bound
## Callables keep an undisposed world alive).
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
const THREADED_PATH := "user://bench-save-load-threaded.json"

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
	# The threaded save the game uses (SaveManager.begin_save_*()): encode() and
	# begin_write() on this thread, the rest on the SaveWrite worker.
	t = Time.get_ticks_usec()
	var threaded_state := StateCodecType.encode(world)
	var begin := SaveIOType.begin_write(THREADED_PATH, threaded_state)
	var main_thread_usec := Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	var threaded_result := begin.wait()
	var worker_wait_usec := Time.get_ticks_usec() - t
	var threaded_read := SaveIOType.read(THREADED_PATH)
	var threaded_match: bool = threaded_read.get("ok", false) and StateCodecType.decode(threaded_read["state"]).state_hash() == world.state_hash()
	if FileAccess.file_exists(THREADED_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(THREADED_PATH))
	print("bench_save_load: actors=%d threaded save: main_thread(encode+begin_write)=%.1fms worker_wait=%.1fms write=%s hash_match=%s" % [
		TestAccess.colonists(world).size(), main_thread_usec / 1000.0, worker_wait_usec / 1000.0, _short(threaded_result), threaded_match])
	BenchCommon.row("bench_save_load", "threaded save", "actors=%d" % TestAccess.colonists(world).size(), {
		"main-thread save ms": "%.1f" % (main_thread_usec / 1000.0), "worker wait ms": "%.1f" % (worker_wait_usec / 1000.0),
		"write": _short(threaded_result), "hash match": threaded_match})
	# Pieces of write_atomic() timed on their own: schema validation and one
	# JSON.stringify of the packed state (A7: write_atomic() stringifies and
	# hashes once, then read-back-verifies the file).
	t = Time.get_ticks_usec()
	TestAccess.save_validate_state(state)
	var validate_usec := Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	SaveIOType.state_text(state)
	var stringify_usec := Time.get_ticks_usec() - t
	print("bench_save_load: actors=%d write_atomic parts: _validate_state=%.1fms one JSON.stringify=%.1fms" % [
		TestAccess.colonists(world).size(), validate_usec / 1000.0, stringify_usec / 1000.0])
	# As written: the SaveWire-packed state (A7).
	var sections := _section_sizes(SaveWire.pack(state))
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

## The five largest top-level (and one level down) sections of the packed state.
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
	warm.dispose()
	warm = null
	for disposed in [false, true]:
		var before := int(Performance.get_monitor(Performance.OBJECT_COUNT))
		for i in 3:
			var world := WorldStateType.new(SEED + i, 10, 64, 64)
			world.tick()
			if disposed:
				world.dispose()
			world = null
		var after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
		var label := "after dispose()" if disposed else "without dispose()"
		print("bench_save_load: leak check (%s): Object count before=%d after building+dropping 3 WorldStates=%d (delta=%d)" % [
			label, before, after, after - before])
		BenchCommon.row("bench_save_load", "leak check", "build and drop 3 WorldStates (64x64), %s" % label, {
			"objects before": before, "objects after": after, "delta": after - before})

func _short(value) -> String:
	if value is Dictionary:
		return "ok" if value.get("ok", false) else String(value.get("error", value))
	return str(value)

func _remove_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
