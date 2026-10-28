class_name SaveIO
extends SaveCheck

## File boundary for the versioned StateCodec dictionary. The candidate is
## written and independently read back before the active path is replaced.

## Envelope format. The schema version lives in state.schemaVersion (deepholm-save v1, R14).
const FORMAT := "deepholm-save"
## Envelope of every save written before the R14 reset (pre-release schemaVersion 1..27).
## Recognised only to reject it with a clear message; it is never migrated.
const PRE_RELEASE_FORMAT := "deepholm-save-v1"
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")
const SCHEMA_VERSION := StateCodecType.SCHEMA_VERSION
## Always written by StateCodec.encode().
const TOP_LEVEL_FIELDS := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts", "toolFetchExcluded", "incidentScheduler"]
## Also always written by encode(), but optional on the wire: absent means the empty
## value decode() starts from (no sites, no owners, a fresh dig-find stream, ...).
const OPTIONAL_TOP_LEVEL_FIELDS := ["combatBlockedTargets", "digFindRng", "rescueVictimAssignments", "workProgressOwners", "suspendedWorkProgress", "approachJobTargets", "constructionSites", "areaOrders"]

static func write_atomic(path: String, state: Dictionary, before_rename: Callable = Callable(), after_temp_write: Callable = Callable()) -> Dictionary:
	var file_name := path.get_file()
	var temporary := path + ".tmp"
	var validation := _validate_state(state)
	if not validation["ok"]:
		_remove_temporary(temporary)
		return _error(validation["code"], validation["message"], path)

	# rng.seed/state stay real JSON integers; read() recovers them exactly from the raw text.
	var json_safe: Dictionary = state.duplicate(true)
	var body := JSON.stringify(json_safe)
	# Hash the parsed-back form: read() can only hash floats, so both sides must match.
	var round_tripped: Variant = JSON.parse_string(body)
	var hash := _sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope := {"format": FORMAT, "integrity": hash, "state": json_safe}
	var encoded := JSON.stringify(envelope)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		_remove_temporary(temporary)
		return _error("write_failed", "could not open temporary save", path)
	file.store_string(encoded)
	# Flush and capture errors on both sides of close(): the final flush can fail too.
	file.flush()
	var flush_error := file.get_error()
	file.close()
	var close_error := file.get_error()
	if flush_error != OK or close_error != OK:
		_remove_temporary(temporary)
		var failing_error := close_error if close_error != OK else flush_error
		return _error("write_failed", "could not write temporary save (error %s)" % failing_error, path)

	# Test-only seam: corrupt the candidate so the read-back below must catch it.
	if after_temp_write.is_valid():
		after_temp_write.call(temporary)

	# Read the candidate back: catches truncation and storage failures before the target changes.
	var verified := _read_and_verify(temporary)
	if not verified["ok"]:
		_remove_temporary(temporary)
		return _error(verified["code"], verified["message"], path)
	if before_rename.is_valid() and not bool(before_rename.call(temporary, path)):
		_remove_temporary(temporary)
		return _error("write_interrupted", "write interrupted before atomic rename", path)

	var rename_result := _replace_target(temporary, path)
	if not rename_result["ok"]:
		_remove_temporary(temporary)
		return _error(rename_result["code"], rename_result["message"], path)
	return {"ok": true, "code": "ok", "message": "save written", "file": path}

static func read(path: String) -> Dictionary:
	var result := _read_and_verify(path)
	if not result["ok"]:
		return _error(result["code"], result["message"], path)
	return {"ok": true, "code": "ok", "message": "save loaded", "file": path, "state": result["state"]}

static func _read_and_verify(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "code": "read_failed", "message": "could not open save", "file": path}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return {"ok": false, "code": "parse_error", "message": "save JSON is unparseable or truncated", "file": path}
	var envelope: Dictionary = parsed
	if envelope.get("format") == PRE_RELEASE_FORMAT:
		return {"ok": false, "code": "unsupported_pre_release_save",
			"message": "unsupported pre-release save: it was written by a development build before the save format reset and cannot be loaded; start a new game",
			"file": path}
	if envelope.get("format") != FORMAT or not envelope.has("integrity") or not envelope.has("state"):
		return {"ok": false, "code": "invalid_envelope", "message": "save envelope is missing or invalid", "file": path}
	var state: Variant = envelope["state"]
	if not (state is Dictionary):
		return {"ok": false, "code": "schema_error", "message": "save state is not an object", "file": path}
	# Version before hash: a newer producer gets the distinct version error.
	var stored_state_hash := _sha256(JSON.stringify(state).to_utf8_buffer())
	# Normalise ints for the type checks; the hash above used the exact wire text.
	_coerce_ints(state)
	# Locate "state" once; every exact-int restore below shares the scan.
	var located_state := SaveJsonInts._locate_state_object(text)
	var rng_restore := SaveJsonInts._restore_exact_rng(state, located_state)
	var seed_restore := SaveJsonInts._restore_exact_seed(state, located_state)
	var incident_rng_restore := SaveJsonInts._restore_exact_incident_rng(state, located_state)
	var dig_find_rng_restore := SaveJsonInts._restore_exact_dig_find_rng(state, located_state)
	var version_value: Variant = state.get("schemaVersion")
	if _is_int(version_value) and int(version_value) > SCHEMA_VERSION:
		return {"ok": false, "code": "save_from_newer_version", "message": "save schema is newer than this build", "file": path}
	if str(envelope["integrity"]) != stored_state_hash:
		return {"ok": false, "code": "integrity_mismatch", "message": "save integrity hash does not match", "file": path}
	# After version and hash: a fractional or out-of-int64 seed/rng token is a schema
	# violation, never truncated into a plausible integer.
	if not rng_restore["ok"]:
		return {"ok": false, "code": "schema_error", "message": rng_restore["message"], "file": path}
	if not seed_restore["ok"]:
		return {"ok": false, "code": "schema_error", "message": seed_restore["message"], "file": path}
	if not incident_rng_restore["ok"]:
		return {"ok": false, "code": "schema_error", "message": incident_rng_restore["message"], "file": path}
	if not dig_find_rng_restore["ok"]:
		return {"ok": false, "code": "schema_error", "message": dig_find_rng_restore["message"], "file": path}
	if not state.has("schemaVersion"):
		return {"ok": false, "code": "no_migration_available", "message": "missing required field 'schemaVersion'", "file": path}
	if not _is_int(version_value):
		return {"ok": false, "code": "schema_error", "message": "schemaVersion must be an integer", "file": path}
	var version := int(version_value)
	if version > SCHEMA_VERSION:
		return {"ok": false, "code": "save_from_newer_version", "message": "save schema is newer than this build", "file": path}
	if version < SCHEMA_VERSION:
		var migrated: Dictionary = SaveMigrationsType.migrate(state, version, SCHEMA_VERSION)
		if not migrated.get("ok", false):
			return {"ok": false, "code": migrated.get("code", "no_migration_available"), "message": migrated.get("message", "migration failed"), "file": path}
		state = migrated["state"]
	# Another content bundle gets one chance through a registered rename
	# (SaveMigrations.resolve_content_version()), otherwise it is rejected, never loaded stale.
	var current_content_version := StateCodecType.content_version()
	var content_version_value: Variant = state.get("contentVersion")
	if content_version_value is String and String(content_version_value) != current_content_version:
		var resolved := SaveMigrationsType.resolve_content_version(state, current_content_version)
		if not resolved.get("ok", false):
			return {"ok": false, "code": "content_version_mismatch",
				"message": "save content version '%s' does not match current content version '%s'" % [content_version_value, current_content_version],
				"file": path}
		state = resolved["state"]
	var validation := _validate_state(state)
	if not validation["ok"]:
		return {"ok": false, "code": validation["code"], "message": validation["message"], "file": path}
	return {"ok": true, "state": state}

static func _coerce_ints(state: Dictionary) -> void:
	# The schema has no float fields, so every whole float from JSON is an int; walk the whole
	# tree rather than list paths. rng.seed/state are fixed exactly afterwards.
	SaveJsonInts._coerce_floats_to_ints(state)

## Mirrors docs/architecture/contracts/game-state.schema.json field for field, after the
## integrity hash already matched (a tampered-but-rehashed file must still fit the shape).
## Each module's validator (validators/*.gd) checks what that module persists; the order
## below is the order the checks run in, so the first error reported is stable.
static func _validate_state(state: Dictionary) -> Dictionary:
	if not _keys_allowed(state, TOP_LEVEL_FIELDS + OPTIONAL_TOP_LEVEL_FIELDS):
		return _fail("unexpected top-level field")
	for key in TOP_LEVEL_FIELDS:
		if not state.has(key):
			return _fail_missing("missing required field '%s'" % key)
	if not _is_int(state["schemaVersion"]) or int(state["schemaVersion"]) != SCHEMA_VERSION:
		return _fail("schemaVersion does not match current schema")
	if not (state["contentVersion"] is String) or str(state["contentVersion"]).is_empty():
		return _fail("invalid contentVersion")
	if not _is_int(state["seed"]):
		return _fail("invalid seed type")
	if not _is_int_min(state["tick"], 0):
		return _fail("invalid tick type or value")
	if not _is_int_min(state["epoch"], 0):
		return _fail("invalid epoch type or value")
	var map_check := MapValidator._valid_map(state["map"])
	if not map_check["ok"]:
		return map_check
	var w := int(state["map"]["width"])
	var h := int(state["map"]["height"])
	var checks: Array[Callable] = [
		func() -> Dictionary: return ItemValidator._valid_items(state.get("items"), w, h),
		func() -> Dictionary: return ObjectValidator._valid_objects(state["objects"], w, h),
		func() -> Dictionary: return _optional(state, "constructionSites", func(v: Variant) -> Dictionary: return ObjectValidator._valid_construction_sites(v, w, h)),
		func() -> Dictionary: return _optional(state, "areaOrders", func(v: Variant) -> Dictionary: return ObjectValidator._valid_area_orders(v, w, h)),
		func() -> Dictionary: return ObjectValidator._valid_zones(state.get("zones"), w, h),
		func() -> Dictionary: return {"ok": true} if _is_int_min(state.get("nextZoneId"), 1) else _fail("invalid nextZoneId"),
		func() -> Dictionary: return ItemValidator._valid_ground_berries(state.get("groundBerries"), w, h),
		func() -> Dictionary: return WorkProgressValidator._valid_work_progress(state.get("workProgress"), w, h),
		func() -> Dictionary: return _optional(state, "workProgressOwners", func(v: Variant) -> Dictionary: return WorkProgressValidator._valid_work_progress_owners(v, w, h)),
		func() -> Dictionary: return _optional(state, "suspendedWorkProgress", func(v: Variant) -> Dictionary: return WorkProgressValidator._valid_suspended_work_progress(v)),
		func() -> Dictionary: return GiverValidator._valid_paused_jobs(state.get("pausedJobs")),
		func() -> Dictionary: return GiverValidator._valid_need_job_assignments(state.get("needJobAssignments")),
		func() -> Dictionary: return _optional(state, "rescueVictimAssignments", func(v: Variant) -> Dictionary: return GiverValidator._valid_rescue_victim_assignments(v)),
		func() -> Dictionary: return _optional(state, "combatBlockedTargets", func(v: Variant) -> Dictionary: return GiverValidator._valid_combat_blocked_targets(v, w, h)),
		func() -> Dictionary: return _optional(state, "approachJobTargets", func(v: Variant) -> Dictionary: return GiverValidator._valid_approach_job_targets(v, w, h)),
		func() -> Dictionary: return CalendarValidator._valid_calendar_alerts(state.get("calendarAlerts")),
		func() -> Dictionary: return ToolValidator._valid_tool_fetch_excluded(state.get("toolFetchExcluded"), state.get("toolItems")),
		func() -> Dictionary: return ToolValidator._valid_tool_items(state.get("toolItems"), w, h),
		func() -> Dictionary: return ToolValidator._valid_tool_reservations(state.get("toolReservations"), state.get("toolItems")),
		func() -> Dictionary: return EntityValidator._valid_entities(state["entities"], w, h),
		func() -> Dictionary: return ItemValidator._valid_inventory(state["inventory"]),
		func() -> Dictionary: return SchedulingValidator._valid_jobs(state["jobs"], w, h),
		func() -> Dictionary: return SchedulingValidator._valid_scheduling(state["scheduling"], w, h),
		func() -> Dictionary: return SchedulingValidator._valid_rng(state["rng"]),
		func() -> Dictionary: return CalendarValidator._valid_incident_scheduler(state.get("incidentScheduler")),
		func() -> Dictionary: return _optional(state, "digFindRng", func(v: Variant) -> Dictionary: return ItemValidator._valid_dig_find_rng(v)),
	]
	for check in checks:
		var result: Dictionary = check.call()
		if not result["ok"]:
			return result
	return {"ok": true}

## An optional top-level field is checked only when present (see OPTIONAL_TOP_LEVEL_FIELDS).
static func _optional(state: Dictionary, key: String, check: Callable) -> Dictionary:
	if not state.has(key):
		return {"ok": true}
	return check.call(state[key])

static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

static func _remove_temporary(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

static func _replace_target(temporary: String, target: String) -> Dictionary:
	# One rename overwrites the target: there is never a moment with neither save in place.
	var temporary_absolute := ProjectSettings.globalize_path(temporary)
	var target_absolute := ProjectSettings.globalize_path(target)
	var rename_error := DirAccess.rename_absolute(temporary_absolute, target_absolute)
	if rename_error != OK:
		return {"ok": false, "code": "rename_failed", "message": "could not atomically replace save (%s)" % rename_error}
	return {"ok": true}

static func _error(code: String, message: String, file: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message, "file": file}
