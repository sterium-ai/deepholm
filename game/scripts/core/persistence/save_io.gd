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
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const SaveWireType = preload("res://scripts/core/persistence/save_wire.gd")
const SCHEMA_VERSION := StateCodecType.SCHEMA_VERSION
## Always written by StateCodec.encode().
const TOP_LEVEL_FIELDS := ["schemaVersion", "contentVersion", "contentPacks", "seed", "tick", "epoch", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "crops", "groundBerries", "workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts", "toolFetchExcluded", "incidentScheduler", "scenarioStart"]
## Also always written by encode(), but optional on the wire: absent means the empty
## value decode() starts from (no sites, no owners, a fresh dig-find stream, ...).
const OPTIONAL_TOP_LEVEL_FIELDS := ["combatBlockedTargets", "digFindRng", "rescueVictimAssignments", "workProgressOwners", "suspendedWorkProgress", "approachJobTargets", "constructionSites", "areaOrders", "crafting"]

## Every entry point takes the session's ContentRegistry (A13b, ADR 010 amendment 2): its
## version, packs and tile/job/need ids are what a save is checked against. null builds the
## base bundle, as WorldState does.
## One pass (A7): the state is validated, packed (SaveWire) and stringified once; the integrity
## hash is taken once, over exactly the state text written, and the envelope is built around it.
static func write_atomic(path: String, state: Dictionary, before_rename: Callable = Callable(), after_temp_write: Callable = Callable(),
		content: ContentRegistryType = null) -> Dictionary:
	var registry := _session(content)
	var validation := _validate_state(state, registry)
	if not validation["ok"]:
		_remove_temporary(path + ".tmp")
		return _error(validation["code"], validation["message"], path)
	return commit_body(path, state_text(state), content_check(registry), before_rename, after_temp_write)

## Starts write_atomic()'s file work on a worker thread (A7) and returns its SaveWrite handle.
## Only SaveWire.pack() and the one JSON.stringify run on the calling thread: once this returns,
## nothing reads state or the world it was encoded from. The worker hashes, writes the
## candidate, reads it back through read()'s checks (a state that does not validate fails
## there, before the target changes) and renames. wait() returns what write_atomic() would.
static func begin_write(path: String, state: Dictionary, content: ContentRegistryType = null) -> SaveWrite:
	var check := content_check(_session(content))
	# The read-back scans with SaveJsonInts' shared RegEx: compile it here, not on the worker.
	SaveJsonInts._get_number_regex()
	return SaveWrite.new(path, state_text(state), check)

## The one JSON.stringify of a write: the packed state, exactly as the file holds it.
static func state_text(state: Dictionary) -> String:
	return JSON.stringify(SaveWireType.pack(state))

## What a save is checked against, as plain data a worker thread may read while the main
## thread keeps using the registry: its version, packs and content_rules().
static func content_check(registry: ContentRegistryType) -> Dictionary:
	return {"version": registry.version(), "packs": registry.packs().duplicate(true), "rules": content_rules(registry)}

## Hashes body, writes the envelope around it to path + ".tmp", reads that back through
## read()'s checks, then renames it over path. Reads no Object but the file system, so it is
## what SaveWrite runs on its worker thread.
static func commit_body(path: String, body: String, check: Dictionary, before_rename: Callable = Callable(),
		after_temp_write: Callable = Callable()) -> Dictionary:
	var temporary := path + ".tmp"
	var integrity := _sha256(body.to_utf8_buffer())
	var encoded := "{\"format\":%s,\"integrity\":\"%s\",\"state\":%s}" % [JSON.stringify(FORMAT), integrity, body]
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
	var verified := _read_and_verify(temporary, check)
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

static func read(path: String, content: ContentRegistryType = null) -> Dictionary:
	var result := _read_and_verify(path, content_check(_session(content)))
	if not result["ok"]:
		var failed := _error(result["code"], result["message"], path)
		if result.has("reason"):
			failed["reason"] = result["reason"]
		return failed
	return {"ok": true, "code": "ok", "message": "save loaded", "file": path, "state": result["state"]}

## check is content_check()'s plain data, never the registry: this also runs on SaveWrite's thread.
static func _read_and_verify(path: String, check: Dictionary) -> Dictionary:
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
	# Locate "state" once; the integrity hash and every exact-int restore below share the scan.
	var located_state := SaveJsonInts._locate_state_object(text)
	# Version before hash: a newer producer gets the distinct version error.
	var integrity_ok := _integrity_matches(str(envelope["integrity"]), text, located_state, state as Dictionary)
	# Normalise ints for the type checks; the hash above used the exact wire text.
	_coerce_ints(state)
	var rng_restore := SaveJsonInts._restore_exact_rng(state, located_state)
	var seed_restore := SaveJsonInts._restore_exact_seed(state, located_state)
	var incident_rng_restore := SaveJsonInts._restore_exact_incident_rng(state, located_state)
	var dig_find_rng_restore := SaveJsonInts._restore_exact_dig_find_rng(state, located_state)
	var version_value: Variant = state.get("schemaVersion")
	if _is_int(version_value) and int(version_value) > SCHEMA_VERSION:
		return {"ok": false, "code": "save_from_newer_version", "message": "save schema is newer than this build", "file": path}
	if not integrity_ok:
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
	# Back to the plain state before anything reads a field SaveWire packs (A7).
	var wire_rules: Dictionary = check["rules"]
	var max_world_size: int = wire_rules["maxWorldSize"]
	var unpacked := SaveWireType.unpack(state as Dictionary, max_world_size)
	if not unpacked["ok"]:
		return {"ok": false, "code": unpacked["code"], "message": unpacked["message"], "file": path}
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
	var current_content_version: String = check["version"]
	var content_version_value: Variant = state.get("contentVersion")
	if content_version_value is String and String(content_version_value) != current_content_version:
		var resolved := SaveMigrationsType.resolve_content_version(state, current_content_version)
		if not resolved.get("ok", false):
			return {"ok": false, "code": "content_version_mismatch",
				"message": "save content version '%s' does not match current content version '%s'" % [content_version_value, current_content_version],
				"file": path}
		state = resolved["state"]
	# Before the shape check: a save on a missing pack names the pack, not one of its tiles.
	var loaded_packs: Array = check["packs"]
	var packs_check := check_content_packs((state as Dictionary).get("contentPacks"), loaded_packs)
	if not packs_check["ok"]:
		packs_check["file"] = path
		return packs_check
	var rules: Dictionary = check["rules"]
	var validation := _validate_state_rules(state as Dictionary, rules)
	if not validation["ok"]:
		return {"ok": false, "code": validation["code"], "message": validation["message"], "file": path}
	return {"ok": true, "state": state}

## A7 writers hash the state text exactly as written (one hash, no re-stringify). A file whose
## raw text does not match is checked the pre-A7 way, against JSON.stringify of the parsed
## state: what every earlier writer hashed, and what tests that rehash an edited state use.
## Runs before _coerce_ints(), like the pre-A7 hash.
static func _integrity_matches(integrity: String, text: String, located_state: Dictionary, state: Dictionary) -> bool:
	if located_state.get("ok", false):
		var start: int = located_state["start"]
		var end: int = located_state["end"]
		var raw := text.substr(start, end - start)
		if _sha256(raw.to_utf8_buffer()) == integrity:
			return true
	return _sha256(JSON.stringify(state).to_utf8_buffer()) == integrity

static func _coerce_ints(state: Dictionary) -> void:
	# The schema has no float fields, so every whole float from JSON is an int; walk the whole
	# tree rather than list paths. rng.seed/state are fixed exactly afterwards.
	SaveJsonInts._coerce_floats_to_ints(state)

## Mirrors docs/architecture/contracts/game-state.schema.json field for field, after the
## integrity hash already matched (a tampered-but-rehashed file must still fit the shape).
## Each module's validator (validators/*.gd) checks what that module persists; the order
## below is the order the checks run in, so the first error reported is stable.
## content null checks against the base bundle (headless tests call it that way).
static func _validate_state(state: Dictionary, content: ContentRegistryType = null) -> Dictionary:
	return _validate_state_rules(state, content_rules(_session(content)))

## _validate_state() against content_rules()'s plain data (all SaveWrite's thread has).
static func _validate_state_rules(state: Dictionary, rules: Dictionary) -> Dictionary:
	var tile_ids: Array[String] = rules["tiles"]
	var job_kinds: Array[String] = rules["jobKinds"]
	var need_kinds: Array[String] = rules["needs"]
	var skill_rules: Dictionary = rules["skills"]
	var max_world_size: int = rules["maxWorldSize"]
	if not _keys_allowed(state, TOP_LEVEL_FIELDS + OPTIONAL_TOP_LEVEL_FIELDS):
		return _fail("unexpected top-level field")
	for key in TOP_LEVEL_FIELDS:
		if not state.has(key):
			return _fail_missing("missing required field '%s'" % key)
	if not _is_int(state["schemaVersion"]) or int(state["schemaVersion"]) != SCHEMA_VERSION:
		return _fail("schemaVersion does not match current schema")
	if not (state["contentVersion"] is String) or str(state["contentVersion"]).is_empty():
		return _fail("invalid contentVersion")
	var packs_shape := _valid_content_packs(state["contentPacks"])
	if not packs_shape["ok"]:
		return packs_shape
	if not _is_int(state["seed"]):
		return _fail("invalid seed type")
	if not _is_int_min(state["tick"], 0):
		return _fail("invalid tick type or value")
	if not _is_int_min(state["epoch"], 0):
		return _fail("invalid epoch type or value")
	var map_check := MapValidator._valid_map(state["map"], tile_ids, max_world_size)
	if not map_check["ok"]:
		return map_check
	var w := int(state["map"]["width"])
	var h := int(state["map"]["height"])
	var crop_ids: Array[String] = rules["crops"]
	var checks: Array[Callable] = [
		func() -> Dictionary: return ItemValidator._valid_items(state.get("items"), w, h),
		func() -> Dictionary: return ObjectValidator._valid_objects(state["objects"], w, h),
		func() -> Dictionary: return _optional(state, "constructionSites", func(v: Variant) -> Dictionary: return ObjectValidator._valid_construction_sites(v, w, h)),
		func() -> Dictionary: return _optional(state, "crafting", func(v: Variant) -> Dictionary: return CraftingValidator._valid_crafting(v, w, h)),
		func() -> Dictionary: return _optional(state, "areaOrders", func(v: Variant) -> Dictionary: return ObjectValidator._valid_area_orders(v, w, h)),
		func() -> Dictionary: return ObjectValidator._valid_zones(state.get("zones"), w, h, crop_ids),
		func() -> Dictionary: return {"ok": true} if _is_int_min(state.get("nextZoneId"), 1) else _fail("invalid nextZoneId"),
		func() -> Dictionary: return FarmValidator._valid_crops(state.get("crops"), w, h, crop_ids),
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
		func() -> Dictionary: return EntityValidator._valid_entities(state["entities"], w, h, need_kinds, skill_rules),
		func() -> Dictionary: return ItemValidator._valid_inventory(state["inventory"]),
		func() -> Dictionary: return SchedulingValidator._valid_jobs(state["jobs"], w, h, job_kinds),
		func() -> Dictionary: return SchedulingValidator._valid_scheduling(state["scheduling"], w, h),
		func() -> Dictionary: return SchedulingValidator._valid_rng(state["rng"]),
		func() -> Dictionary: return CalendarValidator._valid_incident_scheduler(state.get("incidentScheduler")),
		func() -> Dictionary: return CalendarValidator._valid_scenario_start(state.get("scenarioStart")),
		func() -> Dictionary: return _optional(state, "digFindRng", func(v: Variant) -> Dictionary: return ItemValidator._valid_dig_find_rng(v)),
	]
	for check in checks:
		var result: Dictionary = check.call()
		if not result["ok"]:
			return result
	return {"ok": true}

## The content-defined whitelists a save is validated against, read from the registry so a
## pack's tiles, job kinds and needs are valid in a save made on that pack.
static func content_rules(registry: ContentRegistryType) -> Dictionary:
	return {
		"tiles": _ids(registry, "tiles"),
		"jobKinds": _ids(registry, "jobs"),
		"needs": _ids(registry, "needs"),
		"crops": _ids(registry, "crops"),
		# F3 (ADR 062): skill levels and the carry bonus in a saved colonist's hands.
		"skills": registry.document("skills").duplicate(true),
		# A saved map keeps its exact size on load, so only WorldGenerator's upper bound applies.
		"maxWorldSize": int(registry.document("mapgen").get("max_world_size", WorldGeneratorType.DEFAULT_MAX_WORLD_SIZE)),
	}

static func _ids(registry: ContentRegistryType, kind: String) -> Array[String]:
	var id_field: String = ContentRegistryType.ID_FIELD_BY_KIND[kind]
	var ids: Array[String] = []
	for entry: Dictionary in registry.list(kind):
		var id: String = entry[id_field]
		ids.append(id)
	return ids

## "contentPacks": the ordered [{id, version}] of ContentRegistry.packs() the save was made on.
static func _valid_content_packs(value: Variant) -> Dictionary:
	if not (value is Array):
		return _fail("invalid contentPacks type")
	var seen: Dictionary = {}
	for item: Variant in value:
		if not (item is Dictionary):
			return _fail("invalid contentPacks entry type")
		var pack: Dictionary = item
		var check := _require_fields(pack, ["id", "version"], "contentPacks entry")
		if not check["ok"]:
			return check
		for key: String in ["id", "version"]:
			if not (pack[key] is String) or (pack[key] as String).is_empty():
				return _fail("invalid contentPacks entry %s" % key)
		if seen.has(pack["id"]):
			return _fail("duplicate contentPacks id '%s'" % pack["id"])
		seen[pack["id"]] = true
	return {"ok": true}

## {"ok": true} only when saved lists exactly the loaded packs, same versions, same order;
## otherwise content_packs_mismatch with "reason" missing, version, unexpected or order. A
## malformed list fails as _validate_state() would. ReplayLog checks its start state here too.
static func check_content_packs(saved: Variant, loaded: Array) -> Dictionary:
	if saved == null:
		return _fail_missing("missing required field 'contentPacks'")
	var shape := _valid_content_packs(saved)
	if not shape["ok"]:
		return shape
	# Both lists are {id: String, version: String}: saved passed the shape check above and
	# loaded is ContentRegistry.packs().
	var loaded_ids: Array[String] = []
	var loaded_versions: Dictionary = {}
	for pack: Dictionary in loaded:
		var loaded_id: String = pack["id"]
		loaded_ids.append(loaded_id)
		loaded_versions[loaded_id] = pack["version"]
	var saved_ids: Array[String] = []
	for pack: Dictionary in saved:
		var id: String = pack["id"]
		var version: String = pack["version"]
		if not loaded_versions.has(id):
			return _packs_mismatch("missing", "save needs content pack '%s' (version '%s'), which is not loaded" % [id, version])
		if loaded_versions[id] != version:
			return _packs_mismatch("version", "save was made with content pack '%s' version '%s', this session loads version '%s'" % [id, version, loaded_versions[id]])
		saved_ids.append(id)
	for loaded_id in loaded_ids:
		if not saved_ids.has(loaded_id):
			return _packs_mismatch("unexpected", "this session loads content pack '%s', which the save was not made with" % loaded_id)
	if saved_ids != loaded_ids:
		return _packs_mismatch("order", "save lists its content packs in another order than this session loads them")
	return {"ok": true}

static func _packs_mismatch(reason: String, message: String) -> Dictionary:
	return {"ok": false, "code": "content_packs_mismatch", "reason": reason, "message": message}

static func _session(content: ContentRegistryType) -> ContentRegistryType:
	return content if content != null else ContentRegistryType.new()

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
