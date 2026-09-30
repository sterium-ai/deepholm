extends SceneTree

## SaveIO's exact-restore for the top-level "seed"
## field and rng.seed/rng.state must parse the complete JSON number token at
## each field, not a bare digit prefix. A JSON number can spell the same
## integer several ways (1000, 1e3, 1.000e3) and every spelling must restore
## to the identical exact value; a token with a genuine fractional remainder,
## or a magnitude outside the signed 64-bit range, must be rejected outright
## -- never silently truncated into a smaller, wrong-looking integer. These
## are file-backed: each case hand-builds the exact on-disk envelope text
## (with a correct integrity hash for that exact text), the same shape a
## hand-edited or foreign-tool-written save would have, then reads it back
## through the real SaveIO.read() pipeline.

const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const TARGET := "user://test-save-seed-fidelity.json"
const SENTINEL := "424242424242"

var _failed := false

func _init() -> void:
	_remove(TARGET)
	# Plain integer and equivalent alternate spellings must all restore to
	# the identical exact value (top-level seed).
	_run_case("seed", "1000", true, 1000)
	_run_case("seed", "1e3", true, 1000)
	_run_case("seed", "1.000e3", true, 1000)
	_run_case("seed", "100e-2", true, 1)
	_run_case("seed", "-42", true, -42)
	# Values beyond float's 2^53 exact-integer range must round-trip exactly.
	_run_case("seed", "9007199254740993", true, 9007199254740993) # 2^53 + 1
	# Signed 64-bit boundary: the exact limits must be preserved exactly...
	_run_case("seed", "9223372036854775807", true, 9223372036854775807) # INT64_MAX
	_run_case("seed", "-9223372036854775808", true, -9223372036854775807 - 1) # INT64_MIN
	# ...and one past either limit must be rejected, not wrapped/truncated.
	_run_case("seed", "9223372036854775808", false, 0)
	_run_case("seed", "-9223372036854775809", false, 0)
	_run_case("seed", "99999999999999999999", false, 0) # far beyond int64
	# A genuine fractional remainder must be rejected, even one that a naive
	# leading-digit read would have silently truncated into a valid-looking int.
	_run_case("seed", "1.5", false, 0)
	_run_case("seed", "1.23e1", false, 0) # 12.3 after exponent, still fractional

	# rng.seed and rng.state mirror the same parsing, independently of the
	# top-level "seed" field (the two must not be confused).
	_run_case("rng.seed", "1e3", true, 1000)
	_run_case("rng.seed", "1.5", false, 0)
	_run_case("rng.seed", "9223372036854775808", false, 0)
	_run_case("rng.state", "1e3", true, 1000)
	_run_case("rng.state", "1.5", false, 0)
	_run_case("rng.state", "9223372036854775808", false, 0)

	# Exponent magnitude must be bounded before expansion or
	# arithmetic that could overflow or allocate unboundedly, not merely
	# checked after the fact.
	_run_case("seed", "1e18", true, 1000000000000000000)
	_run_case("seed", "12000e-3", true, 12)
	# A zero mantissa is exactly 0 regardless of how extreme the exponent is,
	# and must resolve without ever allocating an exponent-sized string.
	_run_case("seed", "0e-999999999999999999", true, 0)
	_run_case("seed", "0e999999999999999999", true, 0)
	# Regression: a zero mantissa with a moderate positive exponent was once
	# rejected because the point-padding it computed (before noticing
	# the mantissa was zero) exceeded int64's own digit-count bound -- a
	# structurally different path than the oversized-exponent cases above.
	# "0e19" sits just under that padding bound; "0e20" is the first value
	# that crosses it.
	_run_case("seed", "0e19", true, 0)
	_run_case("seed", "0e20", true, 0)
	_run_case("seed", "0e21", true, 0)
	# Signed zero and fractional-zero spellings must resolve the same way.
	_run_case("seed", "-0e20", true, 0)
	_run_case("seed", "0.0e21", true, 0)
	_run_case("seed", "-0.0e21", true, 0)
	_run_case("seed", "-0", true, 0)
	_run_case("rng.seed", "0e20", true, 0)
	_run_case("rng.seed", "-0.0e21", true, 0)
	_run_case("rng.state", "0e20", true, 0)
	_run_case("rng.state", "-0.0e21", true, 0)
	# A non-zero mantissa with a huge negative exponent is never a whole
	# number; a huge positive one is unconditionally out of int64 range.
	# Both must be rejected -- correctly, and without doing unbounded work.
	_run_case("seed", "5e-999999999999999999", false, 0)
	_run_case("seed", "1e999999999999999999", false, 0)
	# An exponent token with enough digits to overflow a naive int64
	# conversion by itself, independent of the point-padding bound above.
	_run_case("seed", "1e99999999999999999999999999999999999999", false, 0)
	_run_case("seed", "1e-99999999999999999999999999999999999999", false, 0)

	var oversized_start := Time.get_ticks_usec()
	_run_case("rng.seed", "3e999999999999999999999999999999999999999999999999", false, 0)
	var oversized_usec := Time.get_ticks_usec() - oversized_start
	_expect(oversized_usec < 200000,
		"an oversized exponent token must be rejected with bounded work, not unbounded allocation (took %d us)" % oversized_usec)

	_run_escaped_key_cases()
	_run_envelope_decoy_case()

	_remove(TARGET)
	if _failed:
		quit(1)
		return
	print("test_save_seed_fidelity: PASS")
	quit()

## Builds a full schema-shaped minimal state, substitutes `field`'s value
## with a distinctive sentinel literal, then rewrites the sentinel to the
## exact raw `token` text in the encoded JSON before hashing -- so the
## on-disk file contains precisely `token`, however it is spelled, at
## exactly one field.
func _run_case(field: String, token: String, expect_ok: bool, expected_value: int) -> void:
	var state := _minimal_state()
	match field:
		"seed":
			state["seed"] = int(SENTINEL)
		"rng.seed":
			(state["rng"] as Dictionary)["seed"] = int(SENTINEL)
		"rng.state":
			(state["rng"] as Dictionary)["state"] = int(SENTINEL)
		_:
			_fail("unknown field '%s'" % field)
			return
	var state_text := JSON.stringify(state)
	_expect(state_text.count(SENTINEL) == 1,
		"sentinel must appear exactly once in the encoded state for field '%s'" % field)
	state_text = state_text.replace(SENTINEL, token)
	var round_tripped = JSON.parse_string(state_text)
	_expect(round_tripped != null, "the hand-built state text for field '%s'='%s' must itself be parseable JSON" % [field, token])
	var hash := _sha256_hex(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope_text := "{\"format\":\"%s\",\"integrity\":\"%s\",\"state\":%s}" % [SaveIOType.FORMAT, hash, state_text]
	_write(TARGET, envelope_text)
	var result := SaveIOType.read(TARGET)
	if expect_ok:
		_expect(result.get("ok", false), "field '%s' token '%s' must be accepted: %s" % [field, token, result])
		if result.get("ok", false):
			var loaded_state: Dictionary = result["state"]
			var actual: int
			match field:
				"seed":
					actual = int(loaded_state["seed"])
				"rng.seed":
					actual = int((loaded_state["rng"] as Dictionary)["seed"])
				"rng.state":
					actual = int((loaded_state["rng"] as Dictionary)["state"])
			_expect(actual == expected_value,
				"field '%s' token '%s' must restore to exact value %d, got %d" % [field, token, expected_value, actual])
	else:
		_expect(not result.get("ok", false),
			"field '%s' token '%s' must be rejected, not silently coerced" % [field, token])
		_expect(result.get("code", "") == "schema_error",
			"field '%s' token '%s' rejection must be a typed schema_error, got '%s'" % [field, token, result.get("code", "")])

## A JSON key written with a \uXXXX escape (e.g. "seed"
## spelled "\u0073eed") must decode to the same field a plain key would --
## SaveIO's exact-restore now locates fields structurally, not by text
## search, so it must not be fooled by an escaped key it never has to text-
## match literally. Builds the same minimal state as `_minimal_state()` but
## with full control over exactly how each top-level key, and each of rng's
## two keys, is spelled on the wire -- `JSON.stringify(state)` alone cannot
## give that control since it always emits a key's own plain, unescaped text.
const _ESCAPED_SEED_KEY := "\"\\u0073eed\"" # "\u0073eed" -> "seed"
const _ESCAPED_STATE_KEY := "\"\\u0073tate\"" # "\u0073tate" -> "state"
const _ESCAPED_RNG_KEY := "\"\\u0072ng\"" # "\u0072ng" -> "rng"

func _run_escaped_key_cases() -> void:
	var state := _minimal_state()
	# Distinctive, mutually distinguishable, and each beyond float's 2^53
	# exact-integer range, so a value that silently fell back to the lossy
	# float-coerced reading would visibly mismatch rather than accidentally
	# still match by coincidence.
	state["seed"] = 9007199254740993
	(state["rng"] as Dictionary)["seed"] = 9007199254740997
	(state["rng"] as Dictionary)["state"] = 9007199254741001

	_assert_escaped_round_trip(state, {"seed": _ESCAPED_SEED_KEY}, "escaped top-level seed key")
	_assert_escaped_round_trip(state, {"rng.seed": _ESCAPED_SEED_KEY}, "escaped rng.seed key")
	_assert_escaped_round_trip(state, {"rng.state": _ESCAPED_STATE_KEY}, "escaped rng.state key")
	_assert_escaped_round_trip(state, {"rng": _ESCAPED_RNG_KEY}, "escaped rng object key")
	_assert_escaped_round_trip(state,
		{"seed": _ESCAPED_SEED_KEY, "rng": _ESCAPED_RNG_KEY, "rng.seed": _ESCAPED_SEED_KEY, "rng.state": _ESCAPED_STATE_KEY},
		"every relevant key escaped at once")

## An envelope carrying a decoy top-level "seed" and a decoy top-level "rng"
## object -- sibling to "state", sharing the exact field names the exact-
## restore looks for -- must never supply the restored value; only the
## authenticated "state" object's own fields may.
func _run_envelope_decoy_case() -> void:
	var state := _minimal_state()
	state["seed"] = 123456789012345
	(state["rng"] as Dictionary)["seed"] = 222222222222222
	(state["rng"] as Dictionary)["state"] = 333333333333333
	var state_text := _build_minimal_state_text(state, {})
	var round_tripped = JSON.parse_string(state_text)
	_expect(round_tripped != null, "envelope decoy case: hand-built state text must itself be parseable JSON")
	var hash := _sha256_hex(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope_text := "{\"format\":\"%s\",\"integrity\":\"%s\",\"seed\":999999999999999,\"rng\":{\"seed\":888888888888888,\"state\":777777777777777},\"state\":%s}" \
		% [SaveIOType.FORMAT, hash, state_text]
	_write(TARGET, envelope_text)
	var result := SaveIOType.read(TARGET)
	_expect(result.get("ok", false), "envelope decoy case must be accepted: %s" % result)
	if result.get("ok", false):
		var loaded_state: Dictionary = result["state"]
		_expect(int(loaded_state["seed"]) == 123456789012345,
			"envelope-level decoy 'seed' must never override state.seed, got %s" % loaded_state.get("seed"))
		var loaded_rng: Dictionary = loaded_state["rng"]
		_expect(int(loaded_rng["seed"]) == 222222222222222,
			"envelope-level decoy 'rng.seed' must never override state.rng.seed, got %s" % loaded_rng.get("seed"))
		_expect(int(loaded_rng["state"]) == 333333333333333,
			"envelope-level decoy 'rng.state' must never override state.rng.state, got %s" % loaded_rng.get("state"))
	_remove(TARGET)

func _assert_escaped_round_trip(state: Dictionary, key_spellings: Dictionary, label: String) -> void:
	var state_text := _build_minimal_state_text(state, key_spellings)
	var round_tripped = JSON.parse_string(state_text)
	_expect(round_tripped != null, "%s: hand-built state text must itself be parseable JSON" % label)
	if round_tripped == null:
		return
	var hash := _sha256_hex(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope_text := "{\"format\":\"%s\",\"integrity\":\"%s\",\"state\":%s}" % [SaveIOType.FORMAT, hash, state_text]
	_write(TARGET, envelope_text)
	var result := SaveIOType.read(TARGET)
	_expect(result.get("ok", false), "%s must be accepted: %s" % [label, result])
	if result.get("ok", false):
		var loaded_state: Dictionary = result["state"]
		_expect(int(loaded_state["seed"]) == int(state["seed"]),
			"%s: seed must restore exactly, expected %d got %s" % [label, int(state["seed"]), loaded_state.get("seed")])
		var loaded_rng: Dictionary = loaded_state["rng"]
		var expected_rng: Dictionary = state["rng"]
		_expect(int(loaded_rng["seed"]) == int(expected_rng["seed"]),
			"%s: rng.seed must restore exactly, expected %d got %s" % [label, int(expected_rng["seed"]), loaded_rng.get("seed")])
		_expect(int(loaded_rng["state"]) == int(expected_rng["state"]),
			"%s: rng.state must restore exactly, expected %d got %s" % [label, int(expected_rng["state"]), loaded_rng.get("state")])
	_remove(TARGET)

## Emits the full minimal-state JSON text by hand, field by field, so each
## key's exact on-disk spelling is fully controlled (`key_spellings` maps
## "seed"/"rng"/"rng.seed"/"rng.state" to a literal raw key token, e.g.
## `"\"\\u0073eed\""`, overriding that key's default plain `JSON.stringify()`
## spelling). Every value still goes through `JSON.stringify()` so its own
## encoding stays exactly what the real codec would produce.
func _build_minimal_state_text(state: Dictionary, key_spellings: Dictionary) -> String:
	var order := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory", "jobs",
		"scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
		"toolItems", "toolReservations", "needJobAssignments", "calendarAlerts", "toolFetchExcluded", "incidentScheduler"]
	var parts := PackedStringArray()
	for key in order:
		var key_text: String = key_spellings.get(key, JSON.stringify(key))
		if key == "rng":
			var rng: Dictionary = state["rng"]
			var rng_parts := PackedStringArray()
			for rng_key in ["seed", "state"]:
				var rng_key_text: String = key_spellings.get("rng.%s" % rng_key, JSON.stringify(rng_key))
				rng_parts.append("%s:%s" % [rng_key_text, JSON.stringify(rng[rng_key])])
			parts.append("%s:{%s}" % [key_text, ",".join(rng_parts)])
		else:
			parts.append("%s:%s" % [key_text, JSON.stringify(state[key])])
	return "{%s}" % ",".join(parts)

## A minimal but fully current-schema-shaped 1x1 state, mirroring
## test_save_dimensions.gd's own `_minimal_state_at_size()` helper -- no
## entities/items/etc. to worry about, since only seed/rng parsing is under
## test here.
func _minimal_state() -> Dictionary:
	return {
		"schemaVersion": StateCodecType.SCHEMA_VERSION, "contentVersion": StateCodecType.content_version(),
		"seed": 42, "tick": 0, "epoch": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"], "generatorVersion": WorldGeneratorType.GENERATOR_VERSION},
		"entities": [], "inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {}, "activatedEntries": {},
		},
		"rng": {"seed": 42, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [], "toolItems": {"nextId": 1, "list": []},
		"toolReservations": {}, "needJobAssignments": [], "calendarAlerts": {"fired": []},
		"toolFetchExcluded": [],
		"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 42, "state": 0}},
	}

func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
