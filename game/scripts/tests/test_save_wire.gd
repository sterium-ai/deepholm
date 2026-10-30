extends SceneTree

## A7 (ADR 058) review rounds 1 and 2: SaveIO.read() refuses a malformed SaveWire encoding as
## a typed schema_error, even when the file's integrity hash is correct (a hand-edited,
## rehashed save), and never allocates or loops past the session's map size cap on the way.
## Each case takes the v5 fixture's state packed as SaveIO writes it, breaks one packed field,
## rehashes it the way SaveIO writes (SHA-256 of the state text exactly as written) and reads it
## back. The hostile sizes must be refused quickly, before anything is expanded:
## - a 1,000,000 x 1,000,000 map with one run of 10^12 tiles;
## - a 48 x 48 map whose second run length makes `size + length` wrap past int64;
## - a route box whose y does not fit in int32 (it used to narrow to a negative row).
## A harness failure (the file cannot be written) fails the test, and every check counts itself,
## so a check aborted by a script error cannot end in PASS.

const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const V5_FIXTURE := "res://scripts/tests/fixtures/save_schema_v5_fixture.json"
const PATH := "user://test-save-wire-malformed.json"
## Generous: each refusal is a size comparison; expanding even a 512x512 map takes far less.
const MAX_REFUSAL_MSEC := 2000
## One per _read_rehashed() call that completes: 1 + 1 + 1 + 1 + 6 + 1.
const EXPECTED_READS := 11

var _failed := false
var _reads_done := 0

func _init() -> void:
	# Read through SaveIO (exact 64-bit ints), then packed again as a write would: the base is the
	# fixture's state exactly as SaveIO puts it on disk.
	var loaded := SaveIOType.read(V5_FIXTURE)
	_expect(loaded.get("ok", false), "the v5 fixture must load: %s" % loaded)
	if not loaded.get("ok", false):
		quit(1)
		return
	var base: Dictionary = SaveWire.pack(loaded["state"]).duplicate(true)
	_check_rehashed_fixture_still_loads(base)
	_check_oversized_packed_map_refused_before_expanding(base)
	_check_overflowing_run_refused(base)
	_check_overflowing_route_box_refused(base)
	_check_malformed_packed_fields(base)
	_remove(PATH)
	_expect(_reads_done == EXPECTED_READS, "every case must run to the end: %d of %d reads completed" % [_reads_done, EXPECTED_READS])
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
	_expect(result.get("ok", false), "the rehashed v5 fixture state must load: %s" % result)

func _check_oversized_packed_map_refused_before_expanding(base: Dictionary) -> void:
	var state := base.duplicate(true)
	state["map"]["width"] = 1000000
	state["map"]["height"] = 1000000
	state["map"]["palette"] = ["soil"]
	state["map"]["tileRuns"] = [0, 1000000000000]
	_expect_quick_refusal(state, "an oversized packed map", "exceed the supported maximum")

## Review round 2: on a 48 x 48 map (2,304 tiles), 1,024 + 9,223,372,036,854,774,784 wraps to a
## negative int64; the cap must still hold.
func _check_overflowing_run_refused(base: Dictionary) -> void:
	var state := base.duplicate(true)
	state["map"]["width"] = 48
	state["map"]["height"] = 48
	state["map"]["palette"] = ["soil"]
	state["map"]["tileRuns"] = [0, 1024, 0, 9223372036854774784]
	_expect_quick_refusal(state, "a run length that overflows the tile count", "width*height")

## Review round 2: box y = 2^31 narrowed to int32 is negative; with empty bitsets it passed the
## length check and drove billions of loop iterations.
func _check_overflowing_route_box_refused(base: Dictionary) -> void:
	var state := base.duplicate(true)
	_set_pending_route(state, {"start": {"x": 0, "y": 0}, "target": {"x": 1, "y": 1}, "status": "searching",
		"path": [], "expansions": 1, "resumeCalls": 1, "box": [0, 2147483648, 0, 2147483647],
		"visitedBits": "", "cameFromDirs": "", "frontierTiles": ""})
	_expect_quick_refusal(state, "a route box outside int32", "box")

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
		_expect(not result.get("ok", true) and result.get("code") == "schema_error",
			"%s must be refused as schema_error, got %s" % [entry[0], result])
	# A packed route search with lengths that do not match its box.
	var bad_route := base.duplicate(true)
	_set_pending_route(bad_route, {"start": {"x": 0, "y": 0}, "target": {"x": 1, "y": 1}, "status": "searching",
		"path": [], "expansions": 1, "resumeCalls": 1, "box": [0, 0, 2, 2],
		"visitedBits": Marshalls.raw_to_base64(PackedByteArray([1, 0])),
		"cameFromDirs": Marshalls.raw_to_base64(PackedByteArray([0])), "frontierTiles": ""})
	var result := _read_rehashed(bad_route)
	_expect(not result.get("ok", true) and result.get("code") == "schema_error",
		"a packed route whose visitedBits do not match its box must be refused as schema_error, got %s" % result)

func _set_pending_route(state: Dictionary, route: Dictionary) -> void:
	state["scheduling"]["pending"] = {"colonist_0": {"candidates": [], "cursor": 0, "found": [],
		"start": {"x": 0, "y": 0}, "route": route}}

## state must be refused as schema_error whose message contains needle, within MAX_REFUSAL_MSEC.
func _expect_quick_refusal(state: Dictionary, label: String, needle: String) -> void:
	var started := Time.get_ticks_msec()
	var result := _read_rehashed(state)
	var elapsed := Time.get_ticks_msec() - started
	_expect(not result.get("ok", true) and result.get("code") == "schema_error"
		and String(result.get("message", "")).contains(needle),
		"%s must be refused as schema_error mentioning '%s': %s" % [label, needle, result])
	_expect(elapsed < MAX_REFUSAL_MSEC, "%s must be refused before anything is expanded (took %d ms)" % [label, elapsed])

## Writes state the way SaveIO does (integrity over the exact state text) and reads it back. A
## write failure fails the test and returns a result no check accepts.
func _read_rehashed(state: Dictionary) -> Dictionary:
	_remove(PATH)
	var body := JSON.stringify(state)
	var integrity := TestAccess.save_sha256(body.to_utf8_buffer())
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		_fail("could not open %s for writing (error %s)" % [PATH, FileAccess.get_open_error()])
		return {"ok": false, "code": "test_harness_write_failed"}
	var stored := file.store_string("{\"format\":%s,\"integrity\":\"%s\",\"state\":%s}" % [JSON.stringify(SaveIOType.FORMAT), integrity, body])
	file.close()
	if not stored or not FileAccess.file_exists(PATH):
		_fail("could not write %s" % PATH)
		return {"ok": false, "code": "test_harness_write_failed"}
	var result := SaveIOType.read(PATH)
	_reads_done += 1
	return result

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
