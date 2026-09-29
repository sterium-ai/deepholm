extends SceneTree

## Scene-free acceptance coverage for validate-before-replace persistence.
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")

const TARGET := "user://test-save-io-atomicity.json"
const CORRUPT := "user://test-save-io-corrupt.json"
var failed := false
var _truncate_kind := ""

func _init() -> void:
	_cleanup()
	var old_state: Dictionary = StateCodecType.encode(DebugScenarioType.build(1201))
	var new_state: Dictionary = StateCodecType.encode(DebugScenarioType.build(1202))
	_expect(SaveIOType.write_atomic(TARGET, old_state)["ok"], "initial save must succeed")
	_check_truncation_preserves_target(old_state)
	_check_flipped_byte_preserves_target(old_state)
	_check_newer_version_preserves_target(old_state)
	_check_malformed_nested_state_rejected(old_state)
	_check_duplicate_item_id_is_schema_error(old_state)
	_check_missing_required_field_is_migration_error(old_state)
	_check_missing_nested_field_is_migration_error(old_state)
	_check_missing_schema_version_is_migration_error(old_state)
	_check_crash_boundary(old_state, new_state)

	# Time the save itself (encode + atomic write), not building the scenario.
	var full_world = DebugScenarioType.build()
	var started := Time.get_ticks_usec()
	var full_state: Dictionary = StateCodecType.encode(full_world)
	var measured := SaveIOType.write_atomic(TARGET, full_state)
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	_expect(measured["ok"], "48x48 DebugScenario save must succeed")
	print("test_save_io_atomicity: measured 48x48 write %.3f ms" % elapsed_ms)
	_expect(elapsed_ms < 1000.0, "full save must be well under one second")
	_cleanup()
	if failed:
		quit(1)
	else:
		print("test_save_io_atomicity: PASS")
		quit()

## Exercises truncation at the real atomic-write boundary: a new save's own
## temp candidate (TARGET + ".tmp") gets corrupted after write_atomic's
## internal write but before its read-back verification, via the
## after_temp_write seam. This proves the boundary itself -- a truncated
## candidate for this exact target -- leaves the prior good save at TARGET
## untouched, not just that reading some unrelated corrupt file fails.
func _check_truncation_preserves_target(expected: Dictionary) -> void:
	var candidate_state: Dictionary = StateCodecType.encode(DebugScenarioType.build(1203))
	var temp_path := TARGET + ".tmp"
	for offset_kind in ["start", "middle", "end"]:
		_remove(temp_path)
		_truncate_kind = offset_kind
		var hook := Callable(self, "_truncate_temp_candidate")
		var result: Dictionary = SaveIOType.write_atomic(TARGET, candidate_state, Callable(), hook)
		_expect(not result["ok"], "truncated write at %s must fail" % offset_kind)
		_expect(result["code"] == "parse_error", "truncated write must be a typed parse error")
		_expect(result["file"] == TARGET, "truncated write error must name the target file")
		_expect(not FileAccess.file_exists(temp_path), "truncated temp candidate must be discarded, not left behind")
		var still_good: Dictionary = SaveIOType.read(TARGET)
		_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive a truncated write attempt at the same path")

func _truncate_temp_candidate(temporary: String) -> void:
	var original := FileAccess.get_file_as_bytes(temporary)
	var offset := 1
	if _truncate_kind == "middle":
		offset = maxi(2, int(original.size() / 3))
	elif _truncate_kind == "end":
		offset = maxi(1, original.size() - 1)
	var truncated: PackedByteArray = original.slice(0, offset)
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	output.store_buffer(truncated)
	output.close()

func _check_flipped_byte_preserves_target(expected: Dictionary) -> void:
	var original_text := FileAccess.get_file_as_string(TARGET)
	var flipped: PackedByteArray = original_text.to_utf8_buffer()
	var tick_zero := original_text.find("\"tick\":0")
	_expect(tick_zero >= 0, "test fixture must contain a one-byte tick value")
	if tick_zero < 0:
		return
	# Change only the body byte for tick 0 -> 1, preserving valid JSON while
	# leaving the stored hash untouched.
	flipped[tick_zero + 7] = 49
	var output := FileAccess.open(CORRUPT, FileAccess.WRITE)
	output.store_buffer(flipped)
	output.close()
	var result: Dictionary = SaveIOType.read(CORRUPT)
	_expect(not result["ok"] and result["code"] == "integrity_mismatch", "flipped body byte must fail integrity")
	_expect(result["file"] == CORRUPT, "integrity error must name its file")
	var still_good: Dictionary = SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive integrity failure")
	_remove(CORRUPT)

func _check_newer_version_preserves_target(expected: Dictionary) -> void:
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TARGET))
	var state: Dictionary = envelope["state"]
	state["schemaVersion"] = StateCodecType.SCHEMA_VERSION + 1
	var output := FileAccess.open(CORRUPT, FileAccess.WRITE)
	output.store_string(JSON.stringify({"format": envelope["format"], "integrity": envelope["integrity"], "state": state}))
	output.close()
	var result: Dictionary = SaveIOType.read(CORRUPT)
	_expect(not result["ok"] and result["code"] == "save_from_newer_version", "newer schema must have distinct typed error")
	var still_good: Dictionary = SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive newer-version failure")
	_remove(CORRUPT)

func _check_malformed_nested_state_rejected(expected: Dictionary) -> void:
	# A save that is internally consistent (valid envelope, hash recomputed
	# to match) but whose nested scheduling.assignments entry has a
	# present-but-wrong-typed field must still be refused: the integrity hash
	# alone cannot prove the state's nested shape matches the schema. This
	# uses a type violation, not an absent field, so it stays a schema_error
	# instead of the missing-field migration error covered separately below.
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TARGET))
	var state: Dictionary = envelope["state"]
	state["scheduling"]["assignments"]["forged-worker"] = {"jobId": "job-1", "startedTick": 0, "travelTicks": "not-an-int", "path": []}
	var round_tripped = JSON.parse_string(JSON.stringify(state))
	var hash: String = SaveIOType._sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var output := FileAccess.open(CORRUPT, FileAccess.WRITE)
	output.store_string(JSON.stringify({"format": envelope["format"], "integrity": hash, "state": state}))
	output.close()
	var result: Dictionary = SaveIOType.read(CORRUPT)
	_expect(not result["ok"] and result["code"] == "schema_error", "malformed nested scheduling.assignments must be a typed schema error")
	_expect(result["file"] == CORRUPT, "schema error must name its file")
	var still_good: Dictionary = SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive malformed nested state")
	_remove(CORRUPT)

## A rehashed save (valid envelope, hash recomputed to match) whose items.list
## carries two entries sharing the same id must be refused: StateCodec's
## decoder keys world._items by id, so duplicate ids would silently overwrite
## one item with the other on load rather than crash, changing state_hash()
## with no typed error to explain why.
func _check_duplicate_item_id_is_schema_error(expected: Dictionary) -> void:
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TARGET))
	var state: Dictionary = envelope["state"].duplicate(true)
	state["items"] = {
		"nextId": 2,
		"list": [
			{"id": "item_1", "x": 1, "y": 1, "kind": "wood", "count": 1, "factionId": "colony"},
			{"id": "item_1", "x": 2, "y": 2, "kind": "wood", "count": 1, "factionId": "colony"},
		],
	}
	var round_tripped = JSON.parse_string(JSON.stringify(state))
	var hash: String = SaveIOType._sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var output := FileAccess.open(CORRUPT, FileAccess.WRITE)
	output.store_string(JSON.stringify({"format": envelope["format"], "integrity": hash, "state": state}))
	output.close()
	var result: Dictionary = SaveIOType.read(CORRUPT)
	_expect(not result["ok"] and result["code"] == "schema_error", "duplicate item ids must be rejected as a typed schema error: %s" % result)
	_expect(result["file"] == CORRUPT, "duplicate item id error must name its file")
	var still_good: Dictionary = SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive a duplicate-item-id save")
	_remove(CORRUPT)

## A rehashed save (valid envelope, hash recomputed to match) that is simply
## missing a required top-level field must fail with the migration error
## code, never schema_error and never a silently defaulted/partial state, per
## simulation-boundaries.md's persistence boundary and ADR 003 principle 3.
func _check_missing_required_field_is_migration_error(expected: Dictionary) -> void:
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TARGET))
	var state: Dictionary = envelope["state"]
	state.erase("tick")
	var round_tripped = JSON.parse_string(JSON.stringify(state))
	var hash: String = SaveIOType._sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var output := FileAccess.open(CORRUPT, FileAccess.WRITE)
	output.store_string(JSON.stringify({"format": envelope["format"], "integrity": hash, "state": state}))
	output.close()
	var result: Dictionary = SaveIOType.read(CORRUPT)
	_expect(not result["ok"] and result["code"] == "no_migration_available", "missing required field must be a typed migration error, not schema_error")
	_expect(not result.has("state"), "a failed read must never return a partial or default state")
	_expect(result["file"] == CORRUPT, "migration error must name its file")
	var still_good: Dictionary = SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive a missing-field save")
	_remove(CORRUPT)

## Shared body for the missing-field checks below: mutate a rehashed copy of
## the good save's state, confirm it is refused with the migration error
## code (never schema_error, never a partial state), and confirm the target
## at TARGET is untouched.
func _expect_migration_error_for_mutated_state(expected: Dictionary, state: Dictionary, label: String) -> void:
	var round_tripped = JSON.parse_string(JSON.stringify(state))
	var hash: String = SaveIOType._sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var output := FileAccess.open(CORRUPT, FileAccess.WRITE)
	output.store_string(JSON.stringify({"format": SaveIOType.FORMAT, "integrity": hash, "state": state}))
	output.close()
	var result: Dictionary = SaveIOType.read(CORRUPT)
	_expect(not result["ok"] and result["code"] == "no_migration_available", "%s must be a typed migration error, not schema_error" % label)
	_expect(not result.has("state"), "a failed read must never return a partial or default state (%s)" % label)
	_expect(result["file"] == CORRUPT, "migration error must name its file (%s)" % label)
	var still_good: Dictionary = SaveIOType.read(TARGET)
	_expect(still_good["ok"] and still_good["state"] == expected, "good target must survive %s" % label)
	_remove(CORRUPT)

## A required field absent at a nested level -- not just the top level --
## must also fail with the migration error code. Covers two representative
## depths: a field inside an optional-but-present sub-object (entity.needs),
## and a field two levels deep inside a pluggable structure that itself
## nests tiles (scheduling.pending's route.cameFrom pairs).
func _check_missing_nested_field_is_migration_error(expected: Dictionary) -> void:
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TARGET))

	var entity_state: Dictionary = envelope["state"].duplicate(true)
	entity_state["entities"].append({"id": "forged-colonist", "kind": "colonist", "x": 0, "y": 0, "needs": {"hunger": 10, "health": 10}})
	_expect_migration_error_for_mutated_state(expected, entity_state, "entity needs missing 'sleep'")

	var pending_state: Dictionary = envelope["state"].duplicate(true)
	pending_state["scheduling"]["pending"]["forged-worker"] = {
		"candidates": [], "cursor": 0, "found": [], "start": {"x": 0, "y": 0},
		"route": {
			"start": {"x": 0, "y": 0}, "target": {"x": 1, "y": 1}, "status": "searching",
			"frontier": [], "visited": [], "cameFrom": [{"child": {"x": 1, "y": 1}}],
			"path": [], "expansions": 0, "resumeCalls": 0
		}
	}
	_expect_migration_error_for_mutated_state(expected, pending_state, "route cameFrom entry missing 'parent'")

## A rehashed save missing its schemaVersion entirely must fail with the
## migration error code, not the schema_error used for a present-but-wrong
## typed schemaVersion.
func _check_missing_schema_version_is_migration_error(expected: Dictionary) -> void:
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TARGET))
	var state: Dictionary = envelope["state"].duplicate(true)
	state.erase("schemaVersion")
	_expect_migration_error_for_mutated_state(expected, state, "missing schemaVersion")

func _check_crash_boundary(old_state: Dictionary, new_state: Dictionary) -> void:
	var crash: Callable = Callable(self, "_refuse_rename")
	var interrupted: Dictionary = SaveIOType.write_atomic(TARGET, new_state, crash)
	_expect(not interrupted["ok"] and interrupted["code"] == "write_interrupted", "crash hook must stop before rename")
	var unchanged: Dictionary = SaveIOType.read(TARGET)
	_expect(unchanged["ok"] and unchanged["state"] == old_state, "pre-rename crash must leave old state")
	var completed: Dictionary = SaveIOType.write_atomic(TARGET, new_state)
	_expect(completed["ok"], "rename must complete")
	var replaced: Dictionary = SaveIOType.read(TARGET)
	_expect(replaced["ok"] and replaced["state"] == new_state, "after rename target must be new state")

func _refuse_rename(_temporary: String, _target: String) -> bool:
	return false

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _cleanup() -> void:
	_remove(TARGET)
	_remove(CORRUPT)
