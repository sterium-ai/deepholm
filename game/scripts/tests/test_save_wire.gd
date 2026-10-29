extends SceneTree

## A7 (ADR 058) review round 1: SaveIO.read() refuses a malformed SaveWire encoding as a typed
## schema_error, even when the file's integrity hash is correct (a hand-edited, rehashed save),
## and never allocates past the session's map size cap on the way. Each case takes the v5
## fixture's state packed as SaveIO writes it, breaks one packed field, rehashes it the way SaveIO writes (SHA-256
## of the state text exactly as written) and reads it back. The oversized map is
## 1,000,000 x 1,000,000 with one run of 10^12 tiles: it must be refused quickly, before any
## tile is expanded.

const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const V5_FIXTURE := "res://scripts/tests/fixtures/save_schema_v5_fixture.json"
const PATH := "user://test-save-wire-malformed.json"
## Generous: the refusal is a size comparison; expanding even a 512x512 map takes far less.
const MAX_REFUSAL_MSEC := 2000

var _failed := false

func _init() -> void:
	# Read through SaveIO (exact 64-bit ints), then packed again as a write would: the base is the
	# fixture's state exactly as SaveIO puts it on disk.
	var loaded := SaveIOType.read(V5_FIXTURE)
	_expect(loaded["ok"], "the v5 fixture must load: %s" % loaded)
	if not loaded["ok"]:
		quit(1)
		return
	var base: Dictionary = SaveWire.pack(loaded["state"]).duplicate(true)
	_check_rehashed_fixture_still_loads(base)
	_check_oversized_packed_map_refused_before_expanding(base)
	_check_malformed_packed_fields(base)
	_remove(PATH)
	if _failed:
		quit(1)
		return
	print("test_save_wire: PASS")
	quit()

func _fail(message: String) -> void:
	_failed = true
	push_error(message)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The harness itself: the unchanged state, rehashed and rewritten, loads.
func _check_rehashed_fixture_still_loads(base: Dictionary) -> void:
	var result := _read_rehashed(base.duplicate(true))
	_expect(result["ok"], "the rehashed v5 fixture state must load: %s" % result)

func _check_oversized_packed_map_refused_before_expanding(base: Dictionary) -> void:
	var state := base.duplicate(true)
	state["map"]["width"] = 1000000
	state["map"]["height"] = 1000000
	state["map"]["palette"] = ["soil"]
	state["map"]["tileRuns"] = [0, 1000000000000]
	var started := Time.get_ticks_msec()
	var result := _read_rehashed(state)
	var elapsed := Time.get_ticks_msec() - started
	_expect(not result["ok"] and result.get("code") == "schema_error"
		and String(result.get("message", "")).contains("exceed the supported maximum"),
		"an oversized packed map must be refused as schema_error naming the size cap: %s" % result)
	_expect(elapsed < MAX_REFUSAL_MSEC, "the oversized packed map must be refused before expanding it (took %d ms)" % elapsed)

## [label, mutate(state)] cases, each a schema_error.
func _check_malformed_packed_fields(base: Dictionary) -> void:
	var cases: Array = [
		["a run longer than width*height", func(s: Dictionary) -> void: s["map"]["tileRuns"] = [0, 10000000]],
		["a palette index out of range", func(s: Dictionary) -> void: s["map"]["tileRuns"] = [99, 1]],
		["an odd tileRuns length", func(s: Dictionary) -> void: s["map"]["tileRuns"] = [0]],
		["both tiles and tileRuns", func(s: Dictionary) -> void: s["map"]["tiles"] = []],
		["a record row of the wrong length", func(s: Dictionary) -> void: (s["entities"] as Array)[1] = [1, 2]],
		["a record table header with a repeated key", func(s: Dictionary) -> void: (s["entities"] as Array)[0] = {"$keys": ["id", "id"]}],
	]
	for entry: Array in cases:
		var state := base.duplicate(true)
		(entry[1] as Callable).call(state)
		var result := _read_rehashed(state)
		_expect(not result["ok"] and result.get("code") == "schema_error",
			"%s must be refused as schema_error, got %s" % [entry[0], result])
	# A packed route search with lengths that do not match its box.
	var route := {"start": {"x": 0, "y": 0}, "target": {"x": 1, "y": 1}, "status": "searching", "path": [],
		"expansions": 1, "resumeCalls": 1, "box": [0, 0, 2, 2], "visitedBits": Marshalls.raw_to_base64(PackedByteArray([1, 0])),
		"cameFromDirs": Marshalls.raw_to_base64(PackedByteArray([0])), "frontierTiles": ""}
	var bad_route := base.duplicate(true)
	bad_route["scheduling"]["pending"] = {"colonist_0": {"candidates": [], "cursor": 0, "found": [],
		"start": {"x": 0, "y": 0}, "route": route}}
	var result := _read_rehashed(bad_route)
	_expect(not result["ok"] and result.get("code") == "schema_error",
		"a packed route whose visitedBits do not match its box must be refused as schema_error, got %s" % result)

## Writes state the way SaveIO does (integrity over the exact state text) and reads it back.
func _read_rehashed(state: Dictionary) -> Dictionary:
	var body := JSON.stringify(state)
	var integrity := TestAccess.save_sha256(body.to_utf8_buffer())
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	file.store_string("{\"format\":%s,\"integrity\":\"%s\",\"state\":%s}" % [JSON.stringify(SaveIOType.FORMAT), integrity, body])
	file.close()
	return SaveIOType.read(PATH)

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
